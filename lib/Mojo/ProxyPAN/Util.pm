package Mojo::ProxyPAN::Util;
use Mojo::Base -strict, -signatures;

use CPAN::Meta;            # reads META.json / META.yml / META.yaml
use Exporter qw(import);
use File::Find ();
use Module::Metadata;      # parses package + version from .pm
use Mojo::Collection;
use Mojo::ProxyPAN::Distribution;
use Mojo::File qw(path tempdir);

our @EXPORT_OK = qw(read_provides scan_lib merge_provides to_collection);

# Small helper: read META provides if present
sub read_provides ($root) {
  for my $mf (grep { -f $_ } map { $root->child($_)->to_string } qw(META.json META.yml META.yaml)) {
    my $meta = eval { CPAN::Meta->load_file($mf) } or next;
    my $p = $meta->provides // {};
    # Normalize to { module => {version => ..., file => ...} }
    return {
      map {
        my $v = $p->{$_}{version};
        my $f = $p->{$_}{file};
        ($_ => {dist => $meta->name, version => defined $v ? "$v" : 'undef', file => $f })
      } keys %$p
    };
  }
  return {};
}

# Fallback/merge: scan lib/**/*.pm and extract packages + versions
sub scan_lib ($root) {
  my %found;
  my $lib = $root->child('lib');
  my @pm;
  if (-d $lib->to_string) {
    File::Find::find(
      { wanted => sub { push @pm, $File::Find::name if /\.pm\z/ }, no_chdir => 1 },
      $lib->to_string
    );
  }
  else {
    # Rare distributions without lib/
    File::Find::find(
      { wanted => sub {
          my $f = $File::Find::name;
          return if $f !~ /\.pm\z/;
          return if $f =~ m{/(?:t|xt|inc|share|examples?|eg|script|bin)/};
          push @pm, $f;
        },
        no_chdir => 1
      },
      $root->to_string
    );
  }

  for my $pm (@pm) {
    my $mm = Module::Metadata->new_from_file($pm) or next;
    # packages_inside covers multiple packages in one file (common in XS or exporters)
    my @pkgs = $mm->packages_inside;
    @pkgs = ($mm->name) if !@pkgs && $mm->name; # fallback to "main" package
    for my $pkg (@pkgs) {
      next unless defined $pkg && length $pkg;
      my $ver = $mm->version($pkg);
      # store relative path for readability
      my $rel = path($pm)->to_rel($root)->to_string;
      $found{$pkg} //= { version => defined $ver ? "$ver" : 'undef', file => $rel };
    }
  }

  return \%found;
}

# Merge META provides with scan results; META takes precedence, then add any missing
sub merge_provides ($meta_prov, $scan) {
  my %merged = %$meta_prov; # copy
  for my $pkg (keys %$scan) {
    $merged{$pkg} //= $scan->{$pkg};
  }
  return \%merged;
}

# Convert merged hash -> Mojo::Collection of Mojo::ProxyPAN::Distribution objects
sub to_collection ($merged, $filename) {
  my $dists = Mojo::Collection->new;
  for my $pkg (sort keys %$merged) {
    my $v = $merged->{$pkg}{version};
    my $f = $merged->{$pkg}{file} // ''; # may be undef if not in META/scan
    push @$dists, Mojo::ProxyPAN::Distribution->new({
      module   => $pkg,
      version  => defined $v ? "$v" : 'undef',
      filename => $filename,
    });
  }
  return $dists;
}

1;