# $OpenBSD$
#
# Minimal stub of OpenBSD::Pledge(3p) used to compile and test sysclean.pl
# on systems that do not provide the real module (e.g. during development).
# It never touches the running process; it only records the promises.
package OpenBSD::Pledge;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(pledge);
our @PROMISES;

sub pledge {
	@PROMISES = @_;
	return 1;
}

1;
