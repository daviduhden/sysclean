package OpenBSD::LibSpec;

package OpenBSD::Library;

sub from_string {
    my ( $class, $path ) = @_;
    return bless { path => $path }, $class;
}

sub is_better { return 0 }

1;
