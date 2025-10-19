package Mojolicious::Plugin::DarkPAN::Hooks;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $config) {
  $app->hook(before_dispatch => \&_before_dispatch);
}

sub _before_dispatch ($c) {
  $c->log->trace(sprintf '%s "%s"', $c->req->method, $c->req->url);
}

1;