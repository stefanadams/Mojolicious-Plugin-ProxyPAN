use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojolicious::Lite -signatures;
use Mojo::File qw(path tempdir);
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

# Use in-memory database for testing
$ENV{SQLITE_DB} = ':memory:';
$ENV{DARKPAN_PATH} = "$FindBin::Bin/fixtures/authors/id";

# Load the plugin like the main app does

BEGIN {
  eval { require Archive::Extract; 1 } or plan skip_all => 'Archive::Extract not installed in current perl';
  eval { require Mojolicious; 1 }     or plan skip_all => 'Mojolicious not installed in current perl';
  eval { require Mojo::SQLite; 1 }    or plan skip_all => 'Mojo::SQLite not installed in current perl';
}

my $t = Test::Mojo->new;
$t->app->plugin('ProxyPAN');
my $app = $t->app;

# Test basic_authz helper
subtest 'basic_authz helper' => sub {
  my $c = $t->app->build_controller;
  
  # Test with no authorization header
  is $c->basic_authz, undef, 'Returns undef when no auth header';
  
  # Test with Basic auth
  $c->req->headers->authorization('Basic dXNlcjpwYXNz');  # user:pass
  is $c->basic_authz, 'user:pass', 'Decodes Basic auth correctly';
  
  # Test with invalid auth type
  $c->req->headers->authorization('Bearer token123');
  is $c->basic_authz, undef, 'Returns undef for non-Basic auth';
};

# Test current_path helper
subtest 'current_path helper' => sub {
  # We can't easily test this without actual routing, so just check it exists
  ok $app->renderer->get_helper('current_path'), 'current_path helper method exists';
};

# Test proxypan.paths helper
subtest 'proxypan.paths helper' => sub {
  my $paths = $app->proxypan->paths;
  isa_ok $paths, 'Mojo::Collection', 'proxypan.paths returns Mojo::Collection';
  ok $paths->size > 0, 'At least one path configured';
  isa_ok $paths->first, 'Mojo::File', 'Each path is a Mojo::File object';
};

# Test proxypan.packages helper
# subtest 'proxypan.packages helper' => sub {
#   # Insert test data
#   my $db = $app->sql->db;
#   $db->query('DELETE FROM packages');
#   $db->insert('packages', {
#     module => 'Test::Module',
#     version => '1.23',
#     filename => 'T/TE/TEST/Test-Module-1.23.tar.gz'
#   });
  
#   my $packages = $app->proxypan->packages;
#   isa_ok $packages, 'Mojo::Collection', 'packages returns collection';
#   is $packages->size, 1, 'Returns correct number of packages';
  
#   my $pkg = $packages->first;
#   isa_ok $pkg, 'Mojo::ProxyPAN::Distribution', 'Package is Distribution object';
#   is $pkg->module, 'Test::Module', 'Package has correct module name';
#   is $pkg->version, '1.23', 'Package has correct version';
#   is $pkg->filename, 'T/TE/TEST/Test-Module-1.23.tar.gz', 'Package has correct filename';
# };

# Test reply helpers
subtest 'reply.empty helper' => sub {
  $t->get_ok('/test_empty' => sub {
    my $c = shift;
    $c->reply->empty(204);
  });
  
  # Manual test since we can't easily inject a route
  my $c = $app->build_controller;
  $c->reply->empty(204);
  is $c->res->code, 204, 'reply.empty sets status code';
  is $c->res->body, '', 'reply.empty returns empty body';
};

# Test reply.history helper
subtest 'reply.history helper' => sub {
  # Simply test that we can call the helper
  ok $app->renderer->get_helper('reply.history'), 'reply.history helper registered';
};

# Test reply.packages helper
subtest 'reply.packages helper' => sub {
  # Just test the helper exists
  my $c = $app->build_controller;
  ok $app->renderer->get_helper('reply.packages'), 'reply.packages helper registered';
};

done_testing();
