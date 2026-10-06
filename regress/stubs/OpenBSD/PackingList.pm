# $OpenBSD$
#
# Minimal stub of OpenBSD::PackingList(3p) used to compile sysclean.pl on
# systems that do not provide the real module.
package OpenBSD::PackingList;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(DependOnly);

sub from_installation { return undef }

sub DependOnly { return undef }

1;
