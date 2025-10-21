package Mojolicious::Plugin::DarkPAN::Helpers;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::DarkPAN::Distribution;
use Mojo::ByteStream qw(b);
use Mojo::Collection qw(c);
use Mojo::File qw(path);
use Mojo::SQLite;
use Mojo::URL;

has darkpan_paths => 'authors/id';

sub register ($self, $app, $config) {
  $app->helper('basic_authz'          => \&_basic_authz);
  $app->helper('current_path'         => \&_current_path);
  $app->helper('darkpan.packages'     => \&_darkpan_packages);
  $app->helper('darkpan.paths'        => sub { _darkpan_paths(shift, [split /:/, $ENV{DARKPAN_PATH} || $config->{darkpan_paths} || $self->darkpan_paths]) });
  $app->helper('darkpan.save_package' => \&_darkpan_save_package);
  $app->helper('proxied'              => \&_proxied);
  $app->helper('reply.empty'          => \&_reply_empty);
  $app->helper('reply.history'        => \&_reply_history);
  $app->helper('reply.packages'       => \&_reply_packages);
  $app->helper('sql'                  => sub { _sql(shift, $ENV{SQLITE_DB} || $config->{sqlite_db}) });
}

sub _basic_authz ($c) {
  my $authz = $c->req->headers->authorization || '';
  return undef unless $authz =~ /^Basic\s+(.*?)$/;
  return Mojo::Util::b64_decode($1);
}

sub _current_path ($c) {
  path($c->match->path_for($c->current_route)->{path})->to_rel('/');
}

sub _darkpan_paths ($c, $darkpan_paths) {
  c(@$darkpan_paths)->map(sub { path($_) })->map(sub { $_->is_abs ? $_ : $c->app->home->child($_) });
}

sub _darkpan_packages ($c) {
  $c->sql->db->select('packages', ['module', 'version', 'filename'], undef, {-desc => 'module'})->hashes
    ->map(sub { Mojo::DarkPAN::Distribution->new([$_->{module}, $_->{version}, $_->{filename}]) });
}

sub _darkpan_save_package ($c, $tmpfile, $dist) {
  my $move_to = $c->darkpan->paths->first->child($dist->path);
  my $db = $c->sql->db;
  eval {
    my $tx = $db->begin;
    $db->insert('packages', {module => $dist->module, version => $dist->version, filename => $dist->path}, {on_conflict => undef});
    $tx->commit;
  };
  $c->log->info(sprintf 'Saving uploaded distribution %s %s to %s', $dist->module, $dist->version, $tmpfile->move_to($move_to->tap(sub { $_->dirname->make_path }))) unless $@;
}

sub _proxied ($c, $url) { $c->req->url->host_port eq $url->host_port or 0 }

sub _reply_empty ($c, $code=204, $err='') {
  $c->log->error($err) if $err; $c->render(data => '', status => $code)
}

sub _reply_history ($c, $module=undef) {
  my $modules = $c->darkpan->packages->grep(sub { !$module || $_->module eq $module })->sort->uniq('module')->join("\n");
  $c->render(data => $modules) if $modules->size;
}

sub _reply_packages ($c, $bytes=undef) {
  $c->res->headers->content_type('application/x-gzip');
  my $stream = Mojo::ByteStream->new($bytes) if $bytes;
  $c->render(data => $c->darkpan->packages->sort->uniq('module')->join("\n")->tap(sub { $stream and $_ = $_->new($stream->gunzip . $_) })->gzip);
}

sub _sql ($c, $sqlite_db) {
  state $sql = Mojo::SQLite->new(sprintf 'sqlite:%s', $sqlite_db || sprintf '%s.%s.db', $c->app->moniker, $c->app->mode);
}

1;