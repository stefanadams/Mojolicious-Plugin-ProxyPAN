package Mojolicious::Plugin::DarkPAN;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

sub register ($self, $app, $config) {
  $app->plugin('HeaderCondition');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Helpers');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Hooks');
  $app->plugin('Mojolicious::Plugin::DarkPAN::Routes');
  $app->sql->migrations->from_data('Mojolicious::Plugin::DarkPAN')->migrate;
}

1;

__DATA__
@@ migrations
  -- 1 up
create table packages (id integer primary key autoincrement, module text, version text, filename text);
insert into packages (module, version, filename) values ('Example::Module', '1.23', 'Example-Module-1.23.tar.gz');
insert into packages (module, version, filename) values ('Example::Module', '2.34', 'A/AA/AAA/Example-Module-2.34.tar.gz');
-- 1 down
drop table packages;
EOF
