package Mojolicious::Plugin::ProxyPAN::Hooks;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $config) {
  $app->hook(before_dispatch => \&_before_dispatch);
}

sub _before_dispatch ($c) {
  $c->req->url->userinfo($c->basic_authz);
  $c->log->trace(sprintf '%s "%s"', $c->req->method, $c->req->url->to_abs);
}

1;