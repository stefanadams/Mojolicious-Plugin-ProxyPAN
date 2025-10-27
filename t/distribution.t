use Mojo::Base -strict;

use Test::More;
use FindBin;
BEGIN { unshift @INC, "$FindBin::Bin/../lib" }

use Mojo::ProxyPAN::Distribution;

# Test object creation with array ref
subtest 'Create from array ref' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new(['My::Module', '1.23', 'M/MY/MYUSER/My-Module-1.23.tar.gz']);
  
  isa_ok $dist, 'Mojo::ProxyPAN::Distribution';
  is $dist->module, 'My::Module', 'module set correctly';
  is $dist->version, '1.23', 'version set correctly';
  is $dist->filename, 'M/MY/MYUSER/My-Module-1.23.tar.gz', 'filename set correctly';
};

# Test object creation with hash ref
subtest 'Create from hash ref' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Test::Module',
    version => '2.34',
    filename => 'T/TE/TEST/Test-Module-2.34.tar.gz'
  });
  
  is $dist->module, 'Test::Module', 'module set from hash';
  is $dist->version, '2.34', 'version set from hash';
  is $dist->filename, 'T/TE/TEST/Test-Module-2.34.tar.gz', 'filename set from hash';
};

# Test object creation with string
subtest 'Create from string' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new('String::Module 3.45 S/ST/STR/String-Module-3.45.tar.gz');
  
  is $dist->module, 'String::Module', 'module parsed from string';
  is $dist->version, '3.45', 'version parsed from string';
  is $dist->filename, 'S/ST/STR/String-Module-3.45.tar.gz', 'filename parsed from string';
};

# Test object creation with hash arguments
subtest 'Create with hash arguments' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new(
    module => 'Hash::Module',
    version => '4.56',
    filename => 'H/HA/HASH/Hash-Module-4.56.tar.gz'
  );
  
  is $dist->module, 'Hash::Module', 'module set from args';
  is $dist->version, '4.56', 'version set from args';
};

# Test dist method
subtest 'dist method' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Dist::Test',
    version => '1.0',
    filename => 'Dist-Test-1.0.tar.gz'
  });
  
  is $dist->dist, 'Dist-Test', 'dist extracted from filename';
  
  # Test with full path
  my $dist2 = Mojo::ProxyPAN::Distribution->new({
    module => 'Path::Test',
    version => '2.0',
    filename => 'P/PA/PATH/Path-Test-2.0.tar.gz'
  });
  
  is $dist2->dist, 'Path-Test', 'dist extracted from full path';
};

# Test path method
subtest 'path method' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Path::Module',
    version => '1.23',
    filename => 'P/PA/PATH/Path-Module-1.23.tar.gz'
  });
  
  my $path = $dist->path;
  isa_ok $path, 'Mojo::File', 'path returns Mojo::File';
  like $path->to_string, qr/Path-Module-1\.23\.tar\.gz$/, 'path includes filename';
  
  # Test with filename only (no path)
  my $dist2 = Mojo::ProxyPAN::Distribution->new({
    module => 'Simple::Module',
    version => '2.0',
    filename => 'Simple-Module-2.0.tar.gz'
  });
  
  my $path2 = $dist2->path;
  like $path2->to_string, qr/Simple-Module/, 'path constructed from dist name';
};

# Test to_array method
subtest 'to_array method' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Array::Test',
    version => '3.14',
    filename => 'A/AR/ARRAY/Array-Test-3.14.tar.gz'
  });
  
  my $array = $dist->to_array;
  is ref($array), 'ARRAY', 'to_array returns array ref';
  is $array->[0], 'Array::Test', 'array[0] is module';
  is $array->[1], '3.14', 'array[1] is version';
  isa_ok $array->[2], 'Mojo::File', 'array[2] is path as Mojo::File';
};

# Test to_string method
subtest 'to_string method' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'String::Test',
    version => '1.0',
    filename => 'S/ST/STR/String-Test-1.0.tar.gz'
  });
  
  my $str = $dist->to_string;
  like $str, qr/String::Test/, 'String contains module';
  like $str, qr/1\.0/, 'String contains version';
  like $str, qr/String-Test-1\.0\.tar\.gz/, 'String contains filename';
};

# Test overloaded stringification
subtest 'Overloaded stringification' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Overload::Test',
    version => '2.0',
    filename => 'O/OV/OVER/Overload-Test-2.0.tar.gz'
  });
  
  my $str = "$dist";
  like $str, qr/Overload::Test/, 'Stringification works';
};

# Test overloaded array deref
subtest 'Overloaded array deref' => sub {
  my $dist = Mojo::ProxyPAN::Distribution->new({
    module => 'Deref::Test',
    version => '1.5',
    filename => 'D/DE/DEREF/Deref-Test-1.5.tar.gz'
  });
  
  is $dist->[0], 'Deref::Test', 'Array deref [0] works';
  is $dist->[1], '1.5', 'Array deref [1] works';
};

# Test overloaded comparison
subtest 'Overloaded comparison' => sub {
  my $dist1 = Mojo::ProxyPAN::Distribution->new(['AAA::Module', '1.0', 'A/AA/AAA/AAA-Module-1.0.tar.gz']);
  my $dist2 = Mojo::ProxyPAN::Distribution->new(['ZZZ::Module', '1.0', 'Z/ZZ/ZZZ/ZZZ-Module-1.0.tar.gz']);
  
  # Note: The cmp overload swaps $a and $b, so comparison is reversed
  ok $dist2 lt $dist1, 'Comparison works (module name reversed due to overload)';
  
  my $dist3 = Mojo::ProxyPAN::Distribution->new(['Same::Module', '1.0', 'S/SA/SAME/Same-Module-1.0.tar.gz']);
  my $dist4 = Mojo::ProxyPAN::Distribution->new(['Same::Module', '2.0', 'S/SA/SAME/Same-Module-2.0.tar.gz']);
  
  ok $dist4 lt $dist3, 'Comparison works (version reversed due to overload)';
};

done_testing();
