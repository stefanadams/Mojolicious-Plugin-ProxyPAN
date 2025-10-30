package Mojolicious::Plugin::ProxyPAN::Helpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Archive::Extract;
use Mojo::ProxyPAN::Distribution;
use Mojo::ByteStream qw(b);
use Mojo::Collection qw(c);
use Mojo::File qw(path tempdir tempfile);
use Mojo::ProxyPAN::Util qw(read_provides scan_lib merge_provides to_collection);
use Mojo::SQLite;
use Mojo::URL;
use Mojo::Util qw(camelize);
use YAML::XS qw(Dump);

has proxypan_paths => 'authors/id';

sub register ($self, $app, $config) {
  $app->helper('basic_authz'           => \&_basic_authz);
  $app->helper('current_path'          => \&_current_path);
  $app->helper('proxy_p'               => \&_proxy_p);
  $app->helper('proxypan.package'      => \&_proxypan_package);
  $app->helper('proxypan.packages'     => \&_proxypan_packages);
  $app->helper('proxypan.paths'        => sub { _proxypan_paths(shift, [split /:/, $ENV{PROXYPAN_PATH} || $config->{proxypan_paths} || $self->proxypan_paths]) });
  $app->helper('proxypan.save'         => \&_proxypan_save);
  $app->helper('proxypan.save_asset'   => \&_proxypan_save_asset);
  $app->helper('proxypan.save_content' => \&_proxypan_save_content);
  $app->helper('proxypan.save_dist'    => \&_proxypan_save_dist);
  $app->helper('proxied'               => \&_proxied);
  $app->helper('reply.empty'           => \&_reply_empty);
  $app->helper('reply.history'         => \&_reply_history);
  $app->helper('reply.package'         => \&_reply_package);
  $app->helper('reply.packages'        => \&_reply_packages);
  $app->helper('sql'                   => sub { _sql(shift, $ENV{SQLITE_DB} || $config->{sqlite_db}) });
}

sub _basic_authz ($c) {
  my $authz = $c->req->headers->authorization || '';
  return undef unless $authz =~ /^Basic\s+(.*?)$/;
  return Mojo::Util::b64_decode($1);
}

sub _current_path ($c) {
  path($c->match->path_for($c->current_route)->{path})->to_rel('/');
}

sub _proxy_p ($c, $base, $on=undef, $cb=undef) {
  my $tx = $c->render_later->tx;

  my $req = $c->req;
  my $method = $req->method;
  my $headers = $req->headers->clone->dehop;
  my $body = $req->clone->build_body;
  my $url = $base->clone->path_query($req->url->path_query)->fragment($req->url->fragment);
  $c->log->info(sprintf 'Proxying from %s (%s)%s', $method, $url->base, $url->path);
  $url->base($base) if $base->host;
  $c->log->info(sprintf 'Proxying to %s (%s)%s', $method, $url->base, $url->path);
  $req->headers->host($url->host_port) if $url->host_port;
  my $source_tx = $c->ua->build_tx($method => $url => $headers->to_hash => $body);
  $source_tx->req->headers->header('X-ProxyPan' => 1);
  # head_req($source_tx->req);

  # $c->proxy->start_p($source_tx)->catch(sub ($err) {
  #   $c->app->log->error(sprintf 'Error proxying to %s: %s', $source_tx->req->url->host_port || $source_tx->req->url->path, $err);
  #   $c->reply->empty(500);
  # });
  # $source_tx->once(connection => sub ($source_tx, $connection) {
  #   my $msg = $on eq 'write' ? Mojo::Message::Request->new : Mojo::Message::Response->new;
  #   Mojo::IOLoop->stream($connection)->on($on => sub ($stream, $bytes) {
  #     $msg->parse($bytes);
  #     $cb->($msg) if $msg->is_finished;
  #   });
  # }) if $on && ref $cb eq 'CODE';

  $cb->($req) if ($on//'') eq 'upload' && ref $cb eq 'CODE';

  my $promise = Mojo::Promise->new;
  $source_tx->res->content->auto_upgrade(0)->auto_decompress(0)->once(
    body => sub {
      my $source_content = shift;

      my $source_res = $source_tx->res;
      my $res        = $tx->res;
      my $content    = $res->content;
      $res->code($source_res->code)->message($source_res->message);
      my $headers = $source_res->headers->clone->dehop;
      $content->headers($headers);
      $promise->resolve;

      my $source_stream = Mojo::IOLoop->stream($source_tx->connection);
      return unless my $stream = Mojo::IOLoop->stream($tx->connection);

      if (($on//'') eq 'download' && ref $cb eq 'CODE') {
        my $msg = Mojo::Message::Response->new;
        $stream->on(write => sub ($stream, $bytes) {
          $msg->parse($bytes);
          $cb->($msg) if $msg->is_finished;
        });
      }

      my $write = $source_content->is_chunked ? 'write_chunk' : 'write';
      $source_content->unsubscribe('read')->on(
        read => sub {
          my $data = pop;

          $content->$write(length $data ? $data : ()) and $tx->resume;

          # Throttle transparently when backpressure rises
          return if $stream->can_write;
          $source_stream->stop;
          $stream->once(drain => sub { $source_stream->start });
        }
      );

      $source_res->once(finish => sub {
        $content->$write('') and $tx->resume;
        # $cb->($content) if $cb;
      });
    }
  );
  # weaken $source_tx;
  $source_tx->once(finish => sub { $promise->reject(_tx_error(@_)) });

  $c->ua->start_p($source_tx)->catch(sub { });

  return $promise->catch(sub ($err) {
    $c->app->log->error(sprintf 'Error proxying to %s: %s', $source_tx->req->url->host_port || $source_tx->req->url->path, $err);
    $c->reply->empty(500);
  });
}
sub _tx_error { (shift->error // {})->{message} // 'Unknown error' }

sub _proxypan_paths ($c, $proxypan_paths) {
  c(@$proxypan_paths)->map(sub { path($_) })->map(sub { $_->is_abs ? $_ : $c->app->home->child($_) });
}

sub _proxypan_package ($c, $module) {
  eval { $c->sql->db->select('history', undef, {module => $module})->hashes };
}

sub _proxypan_packages ($c) {
  $c->sql->db->select('packages', ['module', 'version', 'filename'], undef, {-desc => 'module'})->hashes
    ->map(sub { Mojo::ProxyPAN::Distribution->new([$_->{module}, $_->{version}, $_->{filename}]) });
}

sub _proxypan_save ($c, $obj, $filename) {
  if (!ref $obj) {
    $c->log->error("Not an object for saving to ProxyPAN");
  }
  elsif ($obj->isa('Mojo::Asset')) {
    return $c->proxypan->save_asset($obj, $filename);
  }
  elsif ($obj->isa('Mojo::Content')) {
    return $c->proxypan->save_content($obj, $filename);
  }
  elsif ($obj->isa('Mojo::ProxyPAN::Distribution')) {
    return $c->proxypan->save_dist($obj, $filename);
  }
  else {
    $c->log->error("Unknown object type for saving to ProxyPAN: " . ref $obj);
  }
}

sub _proxypan_save_asset ($c, $asset, $filename) {
  my $dirname  = path($filename)->dirname;
  my $basename = path($filename)->basename;
  my $tmpdir   = tempdir;
  my $tmpfile  = path($tmpdir, $basename);
  my $workdir  = tempdir;
  $asset->move_to($tmpfile);
  my $ae = Archive::Extract->new(archive => $tmpfile);
  $c->log->error("Failed to extract uploaded tarball") and return unless $ae && $ae->extract(to => $workdir);
  my $root = path($ae->extract_path);
  my $packages = to_collection(merge_provides(read_provides($root), scan_lib($root)), $filename);
  $c->proxypan->save_dist($packages, $tmpfile);
}

sub _proxypan_save_content ($c, $content, $filename) {
  $c->proxypan->save_asset($content->asset, $filename) unless $content->is_multipart;
}

sub _proxypan_save_dist ($c, $packages, $tmpfile) {
  my $dist = $packages->first('is_main');
  die "Not a Mojo::ProxyPAN::Distribution object" unless ref $dist eq 'Mojo::ProxyPAN::Distribution';
  my $move_to = $c->proxypan->paths->first->child($dist->path);
  my $package = {
    distfile => $dist->path->to_string,
    version  => $dist->version,
    provides => {$packages->map(sub { $_->module => $_->version })->to_array->@*},
  };
  my $db = $c->sql->db;
  eval {
    my $tx = $db->begin;
    $db->insert('package', {filename => $dist->path, dist => $dist->dist, module => $dist->module, version => $dist->version, package => Dump($package)}, {on_conflict => undef});
    $packages->each(sub {
      $db->insert('packages', {module => $_->module, version => $_->version, filename => $dist->path}, {on_conflict => undef});
    });
    $tx->commit;
  };
  $c->log->error("Database error saving package " . $dist->module . " " . $dist->version . ": $@") if $@;
  $c->log->info(sprintf 'Saving uploaded distribution %s %s to %s', $dist->module, $dist->version, $tmpfile->move_to($move_to->tap(sub { $_->dirname->make_path }))) unless $@;
}

sub _proxied ($c, $url) { $c->req->url->host_port eq $url->host_port or 0 }

sub _reply_empty ($c, $code=204, $err='') {
  $c->log->error($err) if $err; $c->render(data => '', status => $code)
}

sub _reply_history ($c, $module) {
  my $modules = $c->proxypan->packages->grep(sub { $_->module eq $module })->sort->uniq('version')->join("\n");
  return $c->render(data => "$modules\n") if $modules->size;
  $c->log->info("Module '$module' not found in local ProxyPAN history database");
  return undef;
}

sub _reply_package ($c, $module) {
  my $package = $c->proxypan->package($module);
  return $c->render(data => $package) if $package;
  $c->log->info("Module '$module' not found in local ProxyPAN package database");
  return undef;
}

sub _reply_packages ($c, $bytes=undef) {
  $c->res->headers->content_type('application/x-gzip');
  my $stream = Mojo::ByteStream->new($bytes) if $bytes;
  $c->render(data => $c->proxypan->packages->sort->uniq('module')->join("\n")->tap(sub { $stream and $_ = $_->new($stream->gunzip . $_) })->gzip);
}

sub _sql ($c, $sqlite_db) {
  state $sql = Mojo::SQLite->new(sprintf 'sqlite:%s', $sqlite_db || sprintf '%s.%s.db', $c->app->moniker, $c->app->mode);
}

1;