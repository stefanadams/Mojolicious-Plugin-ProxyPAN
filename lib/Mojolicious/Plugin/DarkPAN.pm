package Mojolicious::Plugin::DarkPAN;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $config) {
  $app->plugin('HeaderCondition');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Helpers');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Hooks');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Routes' => $config);
  $app->sql->migrations->from_data('Mojolicious::Plugin::DarkPAN')->migrate;
  $app->ua->on(prepare => sub ($ua, $tx) {
    $tx->req->url->scheme('http') if $tx->req->url->scheme && $tx->req->url->scheme eq 'https';
  });
}

1;

__DATA__
@@ migrations
  -- 1 up
create table packages (id integer primary key autoincrement, module text, version text, filename text unique);
insert into packages (module, version, filename) values ('Example::Module', '1.23', 'Example-Module-1.23.tar.gz');
insert into packages (module, version, filename) values ('Example::Module', '2.34', 'A/AA/AAA/Example-Module-2.34.tar.gz');
-- 1 down
drop table packages;
EOF
