package Mojolicious::Plugin::DarkPAN::Routes;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Archive::Extract;
use Mojo::ByteStream qw(b);
use Mojo::Collection qw(c);
use Mojo::DarkPAN::Util qw(read_provides scan_lib merge_provides to_collection);
use Mojo::File qw(path tempdir tempfile);
use Mojo::Message::Response;
use Mojo::URL;

has cpan_url   => 'http://www.cpan.org';
has metadb_url => 'http://cpanmetadb.plackperl.org';
has pause_url  => '/reply/ok'; # 'http://pause.perl.org';

sub register ($self, $app, $config) {
  $app->helper('cpan_url'   => sub { Mojo::URL->new($ENV{CPAN_URL} || $config->{cpan_url} || $self->cpan_url) });
  $app->helper('metadb_url' => sub { Mojo::URL->new($ENV{METADB_URL} || $config->{metadb_url} || $self->metadb_url) });
  $app->helper('pause_url'  => sub { Mojo::URL->new($ENV{PAUSE_URL}  || $config->{pause_url}  || $self->pause_url) });

  my $r = $app->routes;
  $r->add_condition(darkpan => sub ($route, $c, $captures, $bool) {
    my $darkpan = $c->req->headers->header('X-DarkPan') || 0;
    # Winner
    return 1 if $darkpan eq $bool;
    # Loser
    return undef;
  });

  $r->any('/reply/ok' => sub ($c) { $c->reply->empty(200) })->name('reply_ok');

  my $mock = $r->under('/')->requires(agent => qr/^(?!cpanminus$)/, darkpan => 0);
  $mock->post('/pause/authenquery' => \&_pause)->name('pause');
  $mock->any('/*all' => \&_mock_all)->name('mock_all');

  my $cpanm = $r->under('/')->requires(agent => qr/cpanminus/, darkpan => 0);
  $cpanm->get('/v1.0/history/:module' => \&_history)->name('history');
  $cpanm->get('/modules/02packages.details.txt.gz' => \&_packages)->name('packages');
  $cpanm->get('/authors/id/*filename' => \&_download)->name('download');
  $cpanm->any('/*all' => \&_all)->name('all');
}

sub _mock_all ($c) {
  $c->log->trace(sprintf 'Mocking request: %s %s', $c->req->method, $c->req->url);
  warn $c->req->url->to_unsafe_string;
  $c->reply->empty(200);
}

sub _all ($c) {
  $c->log->trace(sprintf 'Proxying request: %s %s', $c->req->method, $c->req->url);
  my $tx = $c->ua->build_tx($c->req->method => $c->req->url->to_abs => $c->req->headers->to_hash => $c->req->body);
  $tx->req->headers->header('X-DarkPan' => 1);
  $c->proxy->start_p($tx)->catch(sub ($err) {
    $c->reply->empty(400 => "Proxy could not connect to backend web service: $err");
  });
}

sub _download ($c) {
  $c->render_later;
  my $path = Mojo::Collection->new(Mojo::File->new($c->param('filename'))->to_array->@*)->grep(sub { $_ ne '' });

  $c->darkpan->paths->each(sub ($e, $num) {
    return if $c->res->code;
    $_->list_tree->grep(sub{$_->to_rel($e)->to_string eq $path->join('/')})->first(sub {
      $c->log->trace("Found cached file: $_");
      $c->reply->file($_->to_abs->to_string);
    });
  });
  return if $c->res->code;

  if ($c->cpan_url->to_string && !($path->size < 4) && !$c->param('no_forward')) {
    $c->log->info(sprintf 'Distribution "%s" not found locally, downloading from %s', $c->current_path, $c->cpan_url->host_port || $c->cpan_url->path);
    my $tx = $c->ua->build_tx($c->req->method => $c->cpan_url->path($c->current_path) => $c->req->headers->to_hash => $c->req->body);
    $tx->req->headers->header('X-DarkPan' => 1);
    $c->proxy->start_p($tx)->catch(sub ($err) {
      $c->app->log->error("Error proxying to CPAN: $err");
      $c->reply->empty(500);
    });
    $tx->on(connection => sub ($tx, $connection) {
      my $res = Mojo::Message::Response->new;
      Mojo::IOLoop->stream($connection)->on(read => sub ($stream, $bytes) {
        $res->parse($bytes);
        return unless $res->is_finished;
        my $cache = $c->darkpan->paths->first->child($c->param('filename'))->tap(sub{ $_->dirname->make_path });
        $c->log->info("Caching downloaded distribution to $cache");
        $res->content->asset->move_to($cache);
      });
    });
  }
  else {
    $c->reply->empty(404);
  }
}

sub _history ($c) {
  $c->render_later;
  return if $c->reply->history($c->param('module'));
  if ($c->metadb_url->to_string && !$c->param('no_forward')) {
    $c->log->info(sprintf 'Module "%s" not found locally, checking %s', $c->param('module'), $c->metadb_url->host_port || $c->metadb_url->path);
    my $tx = $c->ua->build_tx($c->req->method => $c->metadb_url->path($c->current_path) => $c->req->headers->to_hash => $c->req->body);
    $tx->req->headers->header('X-DarkPan' => 1);
    $c->proxy->start_p($tx)->catch(sub ($err) {
      $c->app->log->error(sprintf 'Error proxying to %s: %s', $c->metadb_url->host_port || $c->metadb_url->path, $err);
      $c->reply->empty(500);
    });
  }
  else {
    $c->reply->empty(404);
  }
}

sub _packages ($c) {
  $c->render_later;
  my $cache = $c->darkpan->paths->first->child($c->current_path);
  return $c->reply->packages($cache->slurp) if -e $cache;
  if ($c->cpan_url->to_string && !$c->param('no_forward')) {
    $c->ua->get_p($c->cpan_url->path($c->current_path))->then(sub ($tx) {
      die "Failed to fetch from CPAN" unless $tx->result->is_success;
      $tx->result->content->asset->move_to($cache->tap(sub{ $_->dirname->make_path }));
      $c->reply->packages($tx->result->body);
    })->catch(sub ($err) {
      $c->app->log->error("Error proxying to CPAN: $err");
      $c->reply->empty(500);
    });
  }
  else {
    $c->reply->packages;
  }
}

sub _pause ($c) {
  $c->render_later;
  my $userinfo = $c->req->url->userinfo;

  if ($c->pause_url->to_string && !$c->param('no_forward')) {
    my $url = $c->pause_url->clone->userinfo($userinfo);
    $url->path($c->current_path) if $url->host_port;
    $c->req->headers->remove('Host');
    $c->log->info(sprintf 'Proxying PAUSE authenquery to %s %s', $c->req->method, $url);
    my $tx = $c->ua->build_tx($c->req->method => $url => $c->req->headers->dehop->to_hash => $c->req->clone->build_body);
    $tx->req->headers->header('X-DarkPan' => 1);
    $c->proxy->start_p($tx)->catch(sub ($err) {
      $c->app->log->error("Error proxying to PAUSE: $err");
      $c->reply->empty(500);
    });
    $tx->on(connection => sub ($tx, $connection) {
      my $req = Mojo::Message::Request->new;
      Mojo::IOLoop->stream($connection)->on(write => sub ($stream, $bytes) {
        $req->parse($bytes);
        return unless $req->is_finished;
        my ($part) = grep { $_->headers->content_disposition =~ /name="pause99_add_uri_httpupload"/ } @{$req->content->parts};
        my ($filename) = $part->headers->content_disposition =~ /filename="(.*?)"/;
        my $dirname  = path($filename)->dirname;
        my $basename = path($filename)->basename;
        my $tmpdir   = tempdir;
        my $tmpfile  = path($tmpdir, $basename);
        my $workdir  = tempdir;
        $part->asset->move_to($tmpfile);
        my $ae = Archive::Extract->new(archive => $tmpfile);
        $c->log->error("Failed to extract uploaded tarball") and return unless $ae && $ae->extract(to => $workdir);
        my $root = path($ae->extract_path);
        my $packages = to_collection(merge_provides(read_provides($root), scan_lib($root)), $filename);
        $c->darkpan->save_package($tmpfile, $packages->first);
      });
    });
  }
  else {
    $c->reply->empty(404);
  }
}

sub _upload1 ($c) {
  # 1) Get the tarball payload
  # allow raw body upload with ?filename=...
  my $filename = $c->param('filename');
  my $dirname = path($filename)->dirname;
  my $basename = path($filename)->basename;
  my $tmpdir   = tempdir;
  my $tmpfile  = path($tmpdir, $basename);
  my $bytes    = $c->req->body;
  return $c->reply->empty(400) unless defined $bytes && length $bytes;
  $tmpfile->spurt($bytes);

  # 2) Extract to a temp directory
  my $workdir = tempdir;
  my $ae = Archive::Extract->new(archive => $tmpfile);
  return $c->reply->empty(422 => sprintf 'Failed to extract uploaded tarball "%s": %s', $tmpfile, ($ae ? $ae->error : 'invalid archive'))
    unless $ae && $ae->extract(to => $workdir);

  # 3) Collect modules from META provides + lib scan and Build Mojo::Collection of Mojo::DarkPAN::Distribution objects
  my $root = path($ae->extract_path); # root of extracted dist
  my $col = to_collection(merge_provides(read_provides($root), scan_lib($root)), $filename);

  # 4) Render result
  $c->darkpan->save_package($tmpfile, $col->first);
  $c->render(text => $col->join("\n"));
}

1;