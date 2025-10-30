package Mojolicious::Plugin::ProxyPAN::Routes;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::IOLoop;
use Mojo::URL;

sub register ($self, $app, $config) {
  $app->plugin('HeaderCondition');

  my $r = $app->routes->namespaces([__PACKAGE__])->add_condition(proxypan => \&_proxypan);

  my $intercept = $r->under('/')->requires(proxypan => 0);
  $intercept->post('/pause/authenquery')->to('pause#upload', base => $config->{pause_url})->name('pause_upload');
  $intercept->get('/v1.0/:api/:module' => [api => [qw(history package)]])->to('metadb#api', base => $config->{metadb_url})->name('metadb_api');
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
  return if $self->reply->$api($self->param('module'));

  $self->proxy_p($self->base_url, download => sub ($msg) {
    if ($api eq 'package') {
      my $package = Load($msg->body);
      my ($dist, $version) = $package->{distfile} =~ m{([^/\\]+)-v?([\d._]+)\.(tar\.gz|tgz|zip)\z};
      $package->{distfile} = path($package->{distfile})->basename;
      $version = '6.03_1';
      $package->{dist} = {$dist=~s/-/::/gr => looks_like_number($version) ? 0+$version : $version};
      $package->{module} = $self->param('module');
      my ($m, $v) = each $package->{dist}->%*;
      warn Dump($package);

      # my $db = $self->sql->db;
      # eval {
      #   my $tx = $db->begin;
      #   $db->insert('package', {filename => $package->{distfile}, dist => $dist, module => $m, version => $v}, {on_conflict => undef});
      #   foreach my $m (keys $package->{provides}->%*) {
      #     my $v = $package->{provides}->{$m};
      #     $db->insert('history', {module => $m, version => $v, filename => $package->{distfile}}, {on_conflict => undef});
      #   }
      #   $tx->commit;
      # };
    }
  });
}

package Mojolicious::Plugin::ProxyPAN::Routes::Pause;
use Mojo::Base 'Mojolicious::Plugin::ProxyPAN::Routes::Base', -signatures;

use Mojo::Message::Request;

has base => 'http://pause.perl.org';

sub upload ($self) {
  $self->proxy_p($self->base_url, upload => sub ($msg) {
    my $filename = $msg->body_params->param('pause99_add_uri_upload');
    my ($part) = grep { $_->headers->content_disposition =~ /name="pause99_add_uri_httpupload"/ } @{$msg->content->parts};
    $self->proxypan->save($part->asset, $filename);
  });
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
  $self->proxypan->paths->each(sub ($e, $num) {
    return if $self->res->code;
    $_->list_tree->grep(sub{$_->to_rel($e)->to_string eq $path->leading_slash(0)})->first(sub {
      $self->log->trace("Found cached file: $_");
      $self->reply->file($_->to_abs->to_string);
    });
  });
  return if $self->res->code;
  $self->log->info(sprintf 'Distribution "%s" not found locally', $filename);

  $self->proxy_p($self->base_url, download => sub ($msg) {
    $self->proxypan->save($msg->content, $filename);
  });
}

sub packages ($self) {
  $self->render_later;

  my $base = Mojo::URL->new($ENV{CPAN_URL} || $self->stash('base') || $self->base);

  my $cache = $self->proxypan->paths->first->child($self->current_path);
  return $self->reply->packages($cache->slurp) if -e $cache;
  return $self->reply->empty(404) unless $base->to_string || $self->param('no_forward');

  $self->ua->get_p($base->path($self->current_path))->then(sub ($tx) {
    die "Failed to fetch from CPAN" unless $tx->result->is_success;
    $tx->result->content->asset->move_to($cache->tap(sub{ $_->dirname->make_path }));
    $self->reply->packages($tx->result->body);
  })->catch(sub ($err) {
    $self->app->log->error("Error proxying to CPAN: $err");
    $self->reply->empty(500);
  });
}

1;