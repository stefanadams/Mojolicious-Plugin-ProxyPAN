use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojolicious::Lite -signatures;
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

# Use in-memory database for testing
$ENV{SQLITE_DB} = ':memory:';
$ENV{DARKPAN_PATH} = "$FindBin::Bin/fixtures/authors/id";
$ENV{CPAN_URL} = '';  # Disable proxying for unit tests
$ENV{METADB_URL} = '';
$ENV{PAUSE_URL} = '';

BEGIN {
  eval { require Archive::Extract; 1 } or plan skip_all => 'Archive::Extract not installed in current perl';
  eval { require Mojolicious; 1 }     or plan skip_all => 'Mojolicious not installed in current perl';
  eval { require Mojo::SQLite; 1 }    or plan skip_all => 'Mojo::SQLite not installed in current perl';
}

my $t = Test::Mojo->new;
$t->app->plugin('ProxyPAN');

# Test mock routes (non-cpanm user agents)
subtest 'Mock routes for non-cpanm clients' => sub {
  $t->get_ok('/some/random/path' => {'User-Agent' => 'curl/7.0'})
    ->status_is(200, 'Mock route returns 200 for non-cpanm clients');
  
  $t->get_ok('/modules/02packages.details.txt.gz' => {'User-Agent' => 'Mozilla/5.0'})
    ->status_is(200, 'Mock route for packages with non-cpanm UA');
  
  $t->post_ok('/pause/authenquery' => {'User-Agent' => 'curl/7.0'})
    ->status_is(200, 'Mock PAUSE endpoint for non-cpanm');
};

# Test cpanm routes
subtest 'cpanm routes' => sub {
  # Test packages route
#   $t->get_ok('/modules/02packages.details.txt.gz' => {'User-Agent' => 'cpanminus/1.7'})
#     ->status_is(200)
#     ->header_is('Content-Type' => 'application/x-gzip', 'packages returns gzipped content');
  
  # Test history route (should return 404 when module not found and no proxy)
  $t->get_ok('/v1.0/history/NonExistent::Module' => {'User-Agent' => 'cpanminus/1.7'})
    ->status_is(404, 'history returns 404 for non-existent module');
  
  # Test download route (should return 404 when file not found and no proxy)
  $t->get_ok('/authors/id/A/AB/ABC/Test-1.0.tar.gz' => {'User-Agent' => 'cpanminus/1.7'})
    ->status_is(404, 'download returns 404 for non-existent distribution');
};
# done_testing; exit;

# Test X-DarkPan header prevents proxy loops
# Note: When X-DarkPan is set, cpanm routes are NOT matched (proxypan condition fails)
# and since we disable proxying and have no fallback route for '/some/path', a 404 is expected.
subtest 'X-DarkPan header handling' => sub {
  $t->get_ok('/some/path' => {
    'User-Agent' => 'cpanminus/1.7',
    'X-DarkPan' => '1'
  })->status_is(404, 'X-DarkPan header bypasses cpanm routes and falls through to 404');
};

# Test reply_ok route
subtest 'reply_ok route' => sub {
  $t->get_ok('/reply/ok')
    ->status_is(200)
    ->content_is('', 'reply_ok returns empty 200 response');
};

done_testing();
