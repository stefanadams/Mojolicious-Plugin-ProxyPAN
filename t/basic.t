use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojolicious::Lite -signatures;
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

# Use in-memory database for testing
$ENV{SQLITE_DB} = ':memory:';
$ENV{DARKPAN_PATH} = "$FindBin::Bin/fixtures/authors/id";

# Skip if required runtime deps for the plugin aren't available in this Perl
BEGIN {
	eval { require Archive::Extract; 1 } or plan skip_all => 'Archive::Extract not installed in current perl';
	eval { require Mojolicious; 1 }     or plan skip_all => 'Mojolicious not installed in current perl';
	eval { require Mojo::SQLite; 1 }    or plan skip_all => 'Mojo::SQLite not installed in current perl';
}

my $t = Test::Mojo->new;

# Test app loads
ok $t->app, 'App loaded successfully';
$t->app->plugin('ProxyPAN');

# Test basic routes exist
ok $t->app->routes->find('packages'), 'packages route exists';
ok $t->app->routes->find('download'), 'download route exists';
ok $t->app->routes->find('history'), 'history route exists';
ok $t->app->routes->find('pause'), 'pause route exists';

# Test SQL helper returns Mojo::SQLite instance
isa_ok $t->app->sql, 'Mojo::SQLite', 'sql helper returns Mojo::SQLite';

# Test proxypan helper
isa_ok $t->app->proxypan->paths, 'Mojo::Collection', 'proxypan.paths returns collection';
isa_ok $t->app->proxypan->packages, 'Mojo::Collection', 'proxypan.packages returns collection';

# Test database migration ran
my $db = $t->app->sql->db;
ok $db->query('SELECT * FROM packages LIMIT 1'), 'packages table exists';

done_testing();
