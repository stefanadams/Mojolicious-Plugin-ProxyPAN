package Mojo::ProxyPAN::Distribution;
use Mojo::Base -base, -signatures;
use overload
  cmp => sub {
    my ($b, $a) = @_;
    return $a->module cmp $b->module
      || $a->version cmp $b->version
      || $a->filename cmp $b->filename;
  },
  '""' => sub { shift->to_string },
  '@{}' => sub { shift->to_array };

use Mojo::File;

has 'filename' => sub { die 'filename is required' };
has 'module' => sub { die 'module is required' };
has 'version' => sub { die 'version is required' };

sub dist ($self, $dist=undef, $version=undef) {
  if ($dist) {
    $self->{dist} = $dist;
    return $self;
  }
  else {
    return $self->{dist} if defined $self->{dist};
    ($dist, $version) = $self->filename =~ m{([^/\\]+)-v?([\d._]+)\.(tar\.gz|tgz|zip)\z};
    $self->{dist} = $dist if defined $dist;
    return $self->{dist};
  }
}

sub is_main ($self) {
  return $self->module =~ s/::/-/gr eq $self->dist;
}

sub new {
  my $self = shift->SUPER::new;
  my ($arg, $args) = (@_ % 2 ? shift : undef, {@_});
  if (ref $arg eq 'ARRAY') {
    $self->module($arg->[0]);
    $self->version($arg->[1]);
    $self->filename($arg->[2]);
  }
  elsif (ref $arg eq 'HASH') {
    %$self = %$arg;
  }
  elsif ($arg && !ref $arg) {
    my ($module, $version, $filename) = split /\s+/, $arg, 3;
    $self->module($module);
    $self->version($version);
    $self->filename($filename);
  }
  %$self = %$args if scalar keys %$args;
  return $self;
}

sub path ($self) {
  my $filename = Mojo::File->new($self->filename);
  $#$filename ? $filename : Mojo::File->new(0, 0, 0, $self->dist, $self->filename);
}

sub to_array ($self) {
  return [$self->module, $self->version, $self->path];
}

sub to_string ($self) {
  return sprintf "%-40s %10s  %s", $self->module, $self->version, $self->path;
}

1;