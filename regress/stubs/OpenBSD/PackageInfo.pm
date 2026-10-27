package OpenBSD::PackageInfo;

use strict;

use Exporter 'import';
our @EXPORT = qw(installed_packages lock_db);

sub installed_packages { return () }
sub lock_db            { return }

1;
