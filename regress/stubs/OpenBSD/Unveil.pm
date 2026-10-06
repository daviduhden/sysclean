# $OpenBSD$
#
# Minimal stub of OpenBSD::Unveil(3p) used to compile and test sysclean.pl
# on systems that do not provide the real module (e.g. during development).
package OpenBSD::Unveil;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(unveil);
our @UNVEILS;
our $LOCKED = 0;

sub unveil {
    if ( scalar(@_) == 0 ) {
        $LOCKED = 1;
        return 1;
    }
    push @UNVEILS, [@_];
    return 1;
}

1;
