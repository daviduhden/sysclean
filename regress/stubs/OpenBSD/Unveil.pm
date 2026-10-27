package OpenBSD::Unveil;

use strict;

use Exporter 'import';
our @EXPORT  = qw(unveil);
our @UNVEILS = ();
our $LOCKED  = 0;

sub unveil {
    if (@_) {
        push @UNVEILS, [@_];
        return 1;
    }
    $LOCKED = 1;
    return 1;
}

1;
