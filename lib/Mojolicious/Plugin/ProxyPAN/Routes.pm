package Mojolicious::Plugin::ProxyPAN::Routes;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::IOLoop;
use Mojo::URL;

sub register ($self, $app, $config) {
  $app->plugin('HeaderCondition');

  my $r = $app->routes->namespaces([__PACKAGE__])->add_condition(proxypan => \&_proxypan);

  my $intercept = $r->under('/')->requires(proxypan => 0);
  $intercept->post('/pause/authenquery')->to('pause#upload', base => $config->{pause_url}, method => $config->{pause_method})->name('pause_upload');
  $intercept->get('/v1.0/:api/:module' => [api => [qw(history package)]])->to('metadb#api', base => $config->{metadb_url})->name('metadb_api');
  $intercept->get('/v1/download_url/:module')->to('metacpan#download_url', base => $config->{metacpan_url}, cpan => $config->{cpan_url})->name('metacpan_download_url');
  $intercept->get('/authors/00whois' => [format => [qw(html xml)]])->to('cpan#not_implemented', base => $config->{cpan_url})->name('whois');
  $intercept->get('/authors/01mailrc.txt.gz')->to('cpan#not_implemented', base => $config->{cpan_url})->name('cpan_mailrc');
  $intercept->get('/authors/id/*filename')->to('cpan#download', base => $config->{cpan_url})->name('cpan_download');
  $intercept->get('/modules/01modules.index' => [format => [qw(html)]])->to('cpan#not_implemented', base => $config->{cpan_url})->name('cpan_modules');
  $intercept->get('/modules/01modules.mtime' => [format => [qw(html)]])->to('cpan#not_implemented', base => $config->{cpan_url})->name('cpan_recent');
  $intercept->get('/modules/02packages.details.txt.gz')->to('cpan#packages', base => $config->{cpan_url})->name('cpan_packages');
  $intercept->get('/modules/03modlist.data.gz')->to('cpan#not_implemented', base => $config->{cpan_url})->name('cpan_modlist');
  $intercept->get('/modules/06perms.txt.gz')->to('cpan#not_implemented', base => $config->{cpan_url})->name('cpan_perms');

  $r->any('/*whatever')->to('mock#whatever')->name('whatever');
}

sub _proxypan ($route, $c, $captures, $bool) {
  my $proxypan = $c->req->headers->header('X-ProxyPan') || 0;
  my $ok = $proxypan eq $bool ? 1 : undef;
  $c->log->trace(sprintf 'requires proxypan => %s', $bool) unless $ok;
  return $ok;
}

package Mojolicious::Plugin::ProxyPAN::Routes::Base;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::IOLoop;
use Mojo::Message::Request;
use Mojo::Message::Response;
use Mojo::ProxyPAN::Util qw(head_req);
use Mojo::URL;

has 'base';

sub base_url ($self) { Mojo::URL->new($self->_env_url || $self->stash('base') || $self->base) }

sub _env_url { $ENV{uc(sprintf '%s_URL', ((split /::/, ref $_[0])[-1]))} }

package Mojolicious::Plugin::ProxyPAN::Routes::Mock;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

sub whatever ($self) {
  $self->log->trace(sprintf 'Mocking %s request: %s %s', $self->req->headers->user_agent, $self->req->method, $self->req->url);
  $self->reply->empty(200);
}

package Mojolicious::Plugin::ProxyPAN::Routes::Metadb;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

use Mojo::File qw(path);
use YAML::XS qw(Dump Load);
use Scalar::Util qw(looks_like_number);

has base => 'http://cpanmetadb.plackperl.org';

sub api ($self) {
  my $api = $self->stash('api');
  return if !$self->param('nolocal') && $self->reply->$api($self->param('module'));

  $self->stash('intercept_cb' => sub ($c, $tx) {
    # my $package = Load($body);
    # my ($dist, $version) = $package->{distfile} =~ m{([^/\\]+)-v?([\d._]+)\.(tar\.gz|tgz|zip)\z};
    # $package->{distfile} = path($package->{distfile})->basename;
    # $package->{dist} = {$dist=~s/-/::/gr => looks_like_number($version) ? 0+$version : $version};
    # $package->{module} = $self->param('module');
    # my ($m, $v) = each $package->{dist}->%*;
    # warn Dump($package);
    # return Dump($package);
  }) if $api eq 'package';
  $self->proxy_p($self->base_url, download => sub ($msg) {
    if ($api eq 'package') {
      my $package = Load($msg->body);
      my ($dist, $version) = $package->{distfile} =~ m{([^/\\]+)-v?([\d._]+)\.(tar\.gz|tgz|zip)\z};
      $package->{distfile} = path($package->{distfile})->basename;
      $package->{dist} = {$dist=~s/-/::/gr => looks_like_number($version) ? 0+$version : $version};
      $package->{module} = $self->param('module');
      my ($m, $v) = each $package->{dist}->%*;
      # warn Dump($package);
    }
  });
}

package Mojolicious::Plugin::ProxyPAN::Routes::Pause;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

use Mojo::Message::Request;

has base   => 'http://pause.perl.org';
has method => sub { $ENV{PAUSE_METHOD} || shift->stash('method') };

sub upload ($self) {
  $self->stash(method => $self->method) if $self->method;
  my $filename = $self->req->body_params->param('pause99_add_uri_upload');
  my ($part) = grep { $_->headers->content_disposition =~ /name="pause99_add_uri_httpupload"/ } @{$self->req->content->parts};
  my $path = $self->proxypan->save($part->asset, $filename);
  $self->req->url->path->parse($self->base_url->path->to_string =~ s@%f@$path@r);
  $self->proxy_p(Mojo::URL->new->scheme($self->base_url->scheme)->host($self->base_url->host)->port($self->base_url->port));
}

package Mojolicious::Plugin::ProxyPAN::Routes::Metacpan;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

use Mojo::Collection;
use Mojo::Message::Response;

has base => 'http://fastapi.metacpan.org';
has cpan => 'http://www.cpan.org';

sub cpan_url ($self) { Mojo::URL->new($ENV{CPAN_URL} || $self->stash('cpan') || $self->cpan) }

sub download_url ($self) {
  my $module = $self->param('module');
  my %version = (version => [{'>=' => $self->param('version')}]);
  my $result = $self->sql->db->select('download_url_vw', ['filename', 'distribution', 'release', 'version'], {module => $module, %version})->hash;
  if ($result) {
    $self->log->trace(sprintf 'Found download URL for module %s: %s', $module, $result->{filename});
    $result->{download_url} = Mojo::URL->new($self->cpan_url)->path(sprintf '/authors/id/%s/%s', $result->{distribution}, $result->{filename})->to_abs;
    $self->render(json => $result);
  }
  else {
    $self->proxy_p($self->base_url);
  }
}

package Mojolicious::Plugin::ProxyPAN::Routes::Cpan;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

use Mojo::Collection;
use Mojo::Message::Response;

has base => 'http://www.cpan.org';

sub not_implemented ($self) {
  $self->proxy_p($self->base_url);
}

sub download ($self) {
  my $path = Mojo::Path->new($self->param('filename'))->canonicalize;
  my $filename = $path->parts->[-1];
  my $dist = eval { $self->sql->db->select('distributions', ['dist'], {filename => $filename})->hash->{dist} };
  $self->proxypan->paths->each(sub ($e, $num) {
    return if $self->res->code;
    my $file = $e->child($dist ? ($dist, $filename) : $filename);
    return unless -e $file;
    $self->log->trace("Found cached file: $file");
    $self->reply->file($file->to_string);
  });
  return if $self->res->code;
  $self->log->info(sprintf 'File "%s" not found locally', $self->param('filename'));
  $self->log->info(sprintf 'Not a CPAN distribution: %s', $self->param('filename')) and return $self->reply->empty(404) unless $path->parts->@* == 4;

  $self->proxy_p($self->base_url, download => sub ($msg) {
    $self->proxypan->save($msg->content, $filename);
  });
}

sub packages ($self) {
  $self->render_later;

  my $base = Mojo::URL->new($ENV{CPAN_URL} || $self->stash('base') || $self->base);
  return $self->reply->empty(404) unless $base->to_string || $self->param('no_forward');

  my $cache = $self->proxypan->paths->first->child($self->current_path);
  $self->ua->get_p($base->path($self->current_path))->then(sub ($tx) {
    die "Failed to fetch from CPAN" unless $tx->result->is_success;
    $self->log->trace(sprintf 'Fetched %s from CPAN', $self->current_path);
    $tx->result->content->asset->move_to($cache->tap(sub{ $_->dirname->make_path }));
    $self->reply->packages($tx->result->body);
  })->catch(sub ($err) {
    return $self->reply->packages($cache->slurp) if -e $cache;
    return $self->reply->empty(404);
  });
}

1;