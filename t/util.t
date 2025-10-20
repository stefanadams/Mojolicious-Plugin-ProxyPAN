use Mojo::Base -strict;

use Test::More;
use Mojo::File qw(path tempdir);
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

use Mojo::ProxyPAN::Util qw(read_provides scan_lib merge_provides to_collection);

# Create a temporary test distribution
my $tmpdir = tempdir;
my $root = $tmpdir->child('Test-Dist-1.0');
$root->make_path;

# Create lib directory structure
my $lib = $root->child('lib');
$lib->make_path;

# Create a test module
$lib->child('Test')->make_path;
$lib->child('Test', 'Dist.pm')->spew(<<'EOF');
package Test::Dist;
use strict;
use warnings;
our $VERSION = '1.0';
1;
EOF

# Ensure nested directory exists before writing Helper.pm
$lib->child('Test','Dist')->make_path;
$lib->child('Test', 'Dist', 'Helper.pm')->spew(<<'EOF');
package Test::Dist::Helper;
use strict;
our $VERSION = '0.5';
1;
EOF

# Test read_provides
subtest 'read_provides' => sub {
  # Create META.json
  $root->child('META.json')->spurt(<<'EOF');
{
  "name": "Test-Dist",
  "version": "1.0",
  "provides": {
    "Test::Dist": {
      "file": "lib/Test/Dist.pm",
      "version": "1.0"
    },
    "Test::Dist::Helper": {
      "file": "lib/Test/Dist/Helper.pm",
      "version": "0.5"
    }
  }
}
EOF
  
  my $provides = read_provides($root);
  is ref($provides), 'HASH', 'read_provides returns hash ref';
  ok exists $provides->{'Test::Dist'}, 'Found Test::Dist in provides';
  is $provides->{'Test::Dist'}{version}, '1.0', 'Version correct in provides';
  ok exists $provides->{'Test::Dist::Helper'}, 'Found Test::Dist::Helper in provides';
  is $provides->{'Test::Dist::Helper'}{version}, '0.5', 'Helper version correct';
};

# Test scan_lib
subtest 'scan_lib' => sub {
  my $scanned = scan_lib($root);
  is ref($scanned), 'HASH', 'scan_lib returns hash ref';
  ok exists $scanned->{'Test::Dist'}, 'Found Test::Dist by scanning';
  ok exists $scanned->{'Test::Dist::Helper'}, 'Found Test::Dist::Helper by scanning';
  like $scanned->{'Test::Dist'}{file}, qr/lib\/Test\/Dist\.pm/, 'File path is relative';
};

# Test merge_provides
subtest 'merge_provides' => sub {
  my $meta = {
    'Test::Dist' => {
      version => '1.0',
      file => 'lib/Test/Dist.pm'
    }
  };
  
  my $scan = {
    'Test::Dist' => {
      version => '0.9',  # Different version
      file => 'lib/Test/Dist.pm'
    },
    'Test::Dist::Helper' => {
      version => '0.5',
      file => 'lib/Test/Dist/Helper.pm'
    }
  };
  
  my $merged = merge_provides($meta, $scan);
  
  is $merged->{'Test::Dist'}{version}, '1.0', 'META takes precedence';
  ok exists $merged->{'Test::Dist::Helper'}, 'Scanned package included';
  is $merged->{'Test::Dist::Helper'}{version}, '0.5', 'Scanned version preserved';
};

# Test to_collection
subtest 'to_collection' => sub {
  my $provides = {
    'Test::Module' => {
      version => '1.23',
      file => 'lib/Test/Module.pm'
    },
    'Test::Other' => {
      version => '2.34',
      file => 'lib/Test/Other.pm'
    }
  };
  
  my $collection = to_collection($provides, 'T/TE/TEST/Test-Module-1.23.tar.gz');
  
  isa_ok $collection, 'Mojo::Collection', 'to_collection returns Mojo::Collection';
  is $collection->size, 2, 'Collection has correct size';
  
  my $first = $collection->first;
  isa_ok $first, 'Mojo::ProxyPAN::Distribution', 'Collection contains Distribution objects';
  ok $first->module, 'Distribution has module name';
  ok $first->version, 'Distribution has version';
  is $first->filename, 'T/TE/TEST/Test-Module-1.23.tar.gz', 'Distribution has correct filename';
};

# Test with META.yml instead of META.json
subtest 'read_provides with META.yml' => sub {
  my $tmpdir2 = tempdir;
  my $root2 = $tmpdir2->child('YAML-Test-1.0');
  $root2->make_path;
  
  $root2->child('META.yml')->spurt(<<'EOF');
---
name: YAML-Test
version: 1.0
provides:
  YAML::Test:
    file: lib/YAML/Test.pm
    version: 1.0
EOF
  
  my $provides = read_provides($root2);
  ok exists $provides->{'YAML::Test'}, 'Found module in META.yml';
  is $provides->{'YAML::Test'}{version}, '1.0', 'Version from META.yml correct';
};

# Test with no META file
subtest 'read_provides with no META' => sub {
  my $tmpdir3 = tempdir;
  my $root3 = $tmpdir3->child('NoMeta-1.0');
  $root3->make_path;
  
  my $provides = read_provides($root3);
  is ref($provides), 'HASH', 'Returns empty hash when no META';
  is scalar(keys %$provides), 0, 'Hash is empty';
};

# Test scan_lib with no lib directory
subtest 'scan_lib with no lib dir' => sub {
  my $tmpdir4 = tempdir;
  my $root4 = $tmpdir4->child('NoLib-1.0');
  $root4->make_path;
  
  # Create a .pm file in root
  $root4->child('NoLib.pm')->spurt(<<'EOF');
package NoLib;
our $VERSION = '1.0';
1;
EOF
  
  my $scanned = scan_lib($root4);
  ok exists $scanned->{'NoLib'}, 'Found module without lib/ directory';
};

done_testing();
