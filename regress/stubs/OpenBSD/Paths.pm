# $OpenBSD$
#
# Minimal stub of OpenBSD::Paths(3p) used to compile sysclean.pl on systems
# that do not provide the real module.
package OpenBSD::Paths;

use strict;
use warnings;

sub srclocatedb { return '/nonexistent' }
sub xlocatedb   { return '/nonexistent' }

1;
