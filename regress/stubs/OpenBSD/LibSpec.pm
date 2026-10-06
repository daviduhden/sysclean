# $OpenBSD$
#
# Minimal stub of OpenBSD::LibSpec(3p) and OpenBSD::Library used to compile
# sysclean.pl on systems that do not provide the real modules.
package OpenBSD::Library;

use strict;
use warnings;

sub from_string {
    my ( $class, $string ) = @_;
    return bless { string => $string }, $class;
}

sub is_better { return 0 }

package OpenBSD::LibSpec;

use strict;
use warnings;

1;
