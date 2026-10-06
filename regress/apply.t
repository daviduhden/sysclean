#!/usr/bin/perl
#
# $OpenBSD$
#
# Unit tests for the apply (-x) mode of sysclean.
#
# These tests exercise the safe-removal helpers only: they do not need an
# OpenBSD system.  Stub modules for the OpenBSD::* interfaces live in
# regress/stubs and are used when the real modules are not available.

use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/stubs";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# loading the script must not execute the main program (guarded by caller)
require "$FindBin::Bin/../sysclean.pl";

pass('sysclean.pl loaded without running the main program');

# build a fake instance with the attributes used by the helpers
sub new_sysclean {
    my (%args) = @_;

    return bless {
        apply    => $args{apply}    // 1,
        expected => $args{expected} // {},
        ignored  => $args{ignored}  // {},
        actions  => [],
        removed  => {
            files  => 0,
            dirs   => 0,
            users  => 0,
            groups => 0,
            failed => 0
        },
      },
      'sysclean';
}

# capture stdout/stderr so that removal messages do not disturb the TAP output
sub capture_both($code) {
    my ( $out, $err ) = ( '', '' );

    {
        local *STDOUT;
        local *STDERR;
        open STDOUT, '>', \$out or die "capture stdout: $!";
        open STDERR, '>', \$err or die "capture stderr: $!";
        $code->();
    }

    return ( $out, $err );
}

#
# check_removable_path()
#

{
    my $sc = new_sysclean(
        expected => { '/var/expected' => 1 },
        ignored  => { '/var/ignored'  => 1 },
    );

    is( $sc->check_removable_path('/var/obsolete'),
        undef, 'absolute path is removable' );
    like(
        $sc->check_removable_path('relative'),
        qr/not an absolute/,
        'relative path is refused'
    );
    like( $sc->check_removable_path(''), qr/empty/, 'empty path is refused' );
    like(
        $sc->check_removable_path('/'),
        qr/refusing to remove/,
        'the root directory is refused'
    );
    like( $sc->check_removable_path('/var/../etc/obsolete'),
        qr/\.\./, "'..' component is refused" );
    like( $sc->check_removable_path('/var/expected'),
        qr/expected/, 'expected path is refused' );
    like( $sc->check_removable_path('/var/ignored'),
        qr/ignored/, 'ignored path is refused' );
}

#
# sort_paths_deepest_first()
#

{
    my $sc = new_sysclean();
    my @sorted =
      $sc->sort_paths_deepest_first( [ '/a', '/a/b', '/a/b/c', '/x' ] );

    is_deeply(
        \@sorted,
        [ '/a/b/c', '/a/b', '/a', '/x' ],
        'paths are sorted deepest-first'
    );
}

#
# valid_account_name()
#

{
    ok( sysclean::valid_account_name('_foo'),      '_foo is a valid name' );
    ok( sysclean::valid_account_name('foo.bar-1'), 'foo.bar-1 is valid' );
    ok( !sysclean::valid_account_name('a b'),      'space is invalid' );
    ok( !sysclean::valid_account_name('-x'),       '-x is invalid' );
    ok( !sysclean::valid_account_name(''),         'empty name is invalid' );
    ok( !sysclean::valid_account_name(undef),      'undef name is invalid' );
}

#
# remove_path(): files, symlinks and directories
#

{
    my $sc  = new_sysclean();
    my $dir = tempdir( CLEANUP => 1 );

    # regular file
    my $file = "$dir/obsolete";
    open( my $fh, '>', $file ) or die "open $file: $!";
    print $fh "data\n";
    close($fh);
    ok( -f $file, 'file exists before removal' );

    my ($out) = capture_both( sub { $sc->remove_path($file) } );
    ok( !-e $file, 'file removed' );
    is( $sc->{removed}{files}, 1, 'file removal counted' );
    like( $out, qr/^unlink /m, 'unlink is reported' );

    # symbolic link must be removed, not followed
    my $target = "$dir/target";
    open( $fh, '>', $target ) or die "open $target: $!";
    close($fh);
    my $link = "$dir/link";
    symlink( $target, $link ) or die "symlink: $!";
    my $link_ok;
    capture_both( sub { $link_ok = $sc->remove_path($link) } );
    ok( $link_ok,   'symlink removed' );
    ok( !-l $link,  'symlink is gone' );
    ok( -f $target, 'symlink target is preserved' );

    # empty directory is removed
    my $empty = "$dir/empty";
    mkdir($empty) or die "mkdir $empty: $!";
    my $empty_ok;
    capture_both( sub { $empty_ok = $sc->remove_path($empty) } );
    ok( $empty_ok,  'empty directory removed' );
    ok( !-e $empty, 'empty directory is gone' );
    is( $sc->{removed}{dirs}, 1, 'directory removal counted' );

    # non-empty directory is not removed
    my $full = "$dir/full";
    make_path($full);
    open( $fh, '>', "$full/child" ) or die "open child: $!";
    close($fh);
    my ( undef, $err ) = capture_both( sub { $sc->remove_path($full) } );
    ok( -d $full, 'non-empty directory is preserved' );
    like( $err, qr/rmdir/, 'failure is warned about' );
}

#
# remove_path(): never touches expected/ignored paths
#

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $keep = "$dir/keep";
    open( my $fh, '>', $keep ) or die "open $keep: $!";
    close($fh);

    my $sc = new_sysclean( expected => { $keep => 1 } );
    my ( undef, $err ) = capture_both( sub { $sc->remove_path($keep) } );
    ok( -e $keep, 'expected file is preserved' );
    like( $err, qr/expected/, 'refusal is warned about' );
}

#
# queue_*() only records actions in apply mode
#

{
    my $ro = new_sysclean( apply => 0 );
    $ro->queue_path('/x');
    $ro->queue_user('foo');
    $ro->queue_group('foo');
    is( scalar( @{ $ro->{actions} } ),
        0, 'no action queued outside apply mode' );

    my $rw = new_sysclean( apply => 1 );
    $rw->queue_path('/x');
    $rw->queue_user('foo');
    $rw->queue_group('foo');
    is( scalar( @{ $rw->{actions} } ), 3, 'actions queued in apply mode' );
}

#
# prepare_apply() tightens unveil(2)/pledge(2)
#

{
    my $sc  = new_sysclean();
    my $dir = tempdir( CLEANUP => 1 );

    @OpenBSD::Unveil::UNVEILS  = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    $sc->prepare_apply( ["$dir/obsolete"], ['_foo'], [] );

    ok( $OpenBSD::Unveil::LOCKED, 'unveil is locked' );
    like( join( ' ', @OpenBSD::Pledge::PROMISES ),
        qr/\bcpath\b/, 'cpath is promised' );
    like( join( ' ', @OpenBSD::Pledge::PROMISES ),
        qr/\bproc\b/, 'proc is promised when removing accounts' );

    my @dirs = map { $_->[0] } @OpenBSD::Unveil::UNVEILS;
    ok( scalar( grep { $_ eq $dir } @dirs ), 'removal directory is unveiled' );
    ok( scalar( grep { $_ eq '/usr/sbin/userdel' } @dirs ),
        'userdel is unveiled' );
}

{
    my $sc  = new_sysclean();
    my $dir = tempdir( CLEANUP => 1 );

    @OpenBSD::Unveil::UNVEILS  = ();
    @OpenBSD::Pledge::PROMISES = ();

    $sc->prepare_apply( ["$dir/obsolete"], [], [] );

    unlike( join( ' ', @OpenBSD::Pledge::PROMISES ),
        qr/\bproc\b/, 'proc is not promised without account removal' );
    my @dirs = map { $_->[0] } @OpenBSD::Unveil::UNVEILS;
    ok(
        !scalar( grep { $_ eq '/usr/sbin/userdel' } @dirs ),
        'userdel is not unveiled without account removal'
    );
}

done_testing();
