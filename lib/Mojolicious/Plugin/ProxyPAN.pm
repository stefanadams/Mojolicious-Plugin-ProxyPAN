package Mojolicious::Plugin::ProxyPAN;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $config) {
  $app->plugin('Mojolicious::Plugin::ProxyPAN::Helpers');
  $app->plugin('Mojolicious::Plugin::ProxyPAN::Hooks');
  $app->plugin('Mojolicious::Plugin::ProxyPAN::Routes' => $config);
  $app->sql->migrations->from_data('Mojolicious::Plugin::ProxyPAN')->migrate;
  $app->ua->on(prepare => sub ($ua, $tx) {
    $tx->req->url->scheme('http') if $tx->req->url->scheme && $tx->req->url->scheme eq 'https';
  });
}

1;

__DATA__
@@ migrations
  -- 1 up
create table package  (filename text primary key, dist text, module text, version text);
create table history (
  id integer primary key autoincrement,
  module text,
  version text,
  filename text,
  foreign key(filename) references package(filename),
  unique(module, version, filename)
);
-- 1 down
drop table history;
drop table package;
EOF
