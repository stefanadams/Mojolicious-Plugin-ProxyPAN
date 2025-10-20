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
PRAGMA foreign_keys = ON;
create table distributions  (filename text primary key, dist text, version text);
create table provides (
  module text not null,
  module_version text not null,
  filename text not null,
  primary key (module, module_version, filename),
  foreign key(filename) references distributions(filename)
);
create view download_url_vw as select filename,dist distribution,printf('%s-%s',dist,version) release,version,module from provides p left join distributions d using(filename);
CREATE VIEW history_vw as SELECT
  printf('%-40s  %10s  %s', module, module_version, d.filename) history,
  d.filename,
  dist,
  version,
  module,
  module_version
FROM distributions d
LEFT JOIN provides p USING (filename)
WHERE module IS NOT NULL
ORDER BY version ASC;
CREATE VIEW provides_vw as SELECT
  d.filename,
  d.dist,
  d.version,
  COALESCE(
    json_group_object(p.module, p.module_version),
    json('{}')
  ) AS provides
FROM distributions AS d
LEFT JOIN provides AS p
  ON d.filename = p.filename
GROUP BY d.filename, d.dist, d.version;
CREATE VIEW package1_vw as SELECT
  d.filename,
  d.dist,
  d.version,
  json_group_array(
    json_object(
      'module', p.module,
      'module_version', p.module_version
    )
  ) AS provides
FROM distributions AS d
LEFT JOIN provides AS p
  ON d.filename = p.filename
GROUP BY d.filename, d.dist, d.version;
-- 1 down
drop table history;
drop table package;
EOF