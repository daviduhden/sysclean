# $OpenBSD$
#
# Minimal stub of OpenBSD::PackageInfo(3p) used to compile sysclean.pl on
# systems that do not provide the real module.
package OpenBSD::PackageInfo;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(lock_db installed_packages);

sub lock_db { return 1 }
sub installed_packages { return () }

1;
