package OpenBSD::Pledge;

use Exporter 'import';
our @EXPORT = qw(pledge);
our @PROMISES = ();

sub pledge {
    push @PROMISES, [@_];
    return 1;
}

1;
