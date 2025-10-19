package Mojolicious::Plugin::DarkPAN::Routes;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Archive::Extract;
use Mojo::ByteStream qw(b);
use Mojo::Collection qw(c);
use Mojo::DarkPAN::Util qw(read_provides scan_lib merge_provides to_collection);
use Mojo::File qw(path tempdir tempfile);
use Mojo::Message::Response;
use Mojo::URL;

sub register ($self, $app, $config) {
  my $r = $app->routes;
  my $cpan = $r->under('/')->requires(agent => qr/cpanminus/);
  $cpan->get('/v1.0/history/:module' => \&_history)->name('history');
  $cpan->get('/modules/02packages.details.txt.gz' => \&_packages)->name('packages');
  $cpan->get('/authors/id/*filename' => \&_download)->name('download');
  $cpan->put('*dummy/authors/id/*filename' => {dummy => ''} => \&_upload)->name('upload');
  $cpan->any('/*all' => \&_all)->name('all');
}

sub _all ($c) {
  $c->log->trace(sprintf 'Proxying request: %s %s', $c->req->method, $c->req->url);
  my $tx = $c->ua->build_tx($c->req->method => $c->req->url->to_abs => $c->req->headers->to_hash => $c->req->body);
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
    $c->log->info(sprintf 'Distribution "%s" not found locally, proxying to CPAN', $c->current_path);
    my $tx = $c->ua->build_tx(GET => $c->cpan_url->path($c->current_path));
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
        $c->log->info("Caching CPAN distribution to $cache");
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
    $c->log->info(sprintf 'Module "%s" not found locally, proxying to CPAN Meta DB', $c->param('module'));
    $c->proxy->get_p($c->metadb_url->path($c->current_path))->catch(sub ($err) {
      $c->app->log->error("Error proxying to CPAN Meta DB: $err");
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

sub _upload ($c) {
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