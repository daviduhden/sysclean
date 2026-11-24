package OpenBSD::LibSpec;

use strict;

sub from_string {
    my ( $class, $name ) = @_;
    my ( $dir, $stem, $major, $minor ) =
      $name =~ m{\A(?:(.+)/)?([^/]+)\.([0-9]+)\.([0-9]+)\z};
    return
      bless { dir => $dir, stem => $stem, major => $major, minor => $minor },
      $class;
}

sub is_valid { return defined( $_[0]{stem} ) }
sub stem     { return $_[0]{stem} }

sub match {
    my ( $spec, $lib, $base ) = @_;
    return 0
      if $lib->{stem} ne $spec->{stem}
      || $lib->{major} != $spec->{major}
      || $lib->{minor} < $spec->{minor};
    return $lib->{dir} eq "$base/$spec->{dir}" if defined( $spec->{dir} );
    return
      scalar grep { $lib->{dir} eq $_ }
      ( "$base/lib", '/usr/lib', '/usr/X11R6/lib' );
}

package OpenBSD::Library;

sub from_string {
    my ( $class, $path ) = @_;
    my ( $dir, $stem, $major, $minor ) =
      $path =~ m{\A(.*)/lib([^/]+)\.so\.([0-9]+)\.([0-9]+)\z};
    return
      bless { dir => $dir, stem => $stem, major => $major, minor => $minor },
      $class;
}

sub is_valid { return defined( $_[0]{stem} ) }
sub stem     { return $_[0]{stem} }
sub key      { return "$_[0]{dir}/$_[0]{stem}" }

sub is_better {
    my ( $current, $old ) = @_;
    return $current->{major} > $old->{major}
      || ( $current->{major} == $old->{major}
        && $current->{minor} > $old->{minor} );
}

1;
