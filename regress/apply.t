#!/usr/bin/perl
#
# $OpenBSD$
#
# Unit tests for the apply (-x) mode helpers.
#
# These tests only touch directories created by File::Temp.  They never run
# sysclean against the host, never remove system files, and never modify
# accounts.  Stub modules for the OpenBSD::* interfaces live in
# regress/stubs.

use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/stubs";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# loading the script must not execute the main program
require "$FindBin::Bin/../sysclean.pl";

pass('sysclean.pl loaded without running the main program');

sub new_sysclean {
    my (%args) = @_;

    return bless {
        apply              => $args{apply} // 1,
        expected           => $args{expected} // {},
        ignored            => $args{ignored} // {},
        users              => $args{users} // {},
        groups             => $args{groups} // {},
        user_fields        => $args{user_fields} // {},
        group_fields       => $args{group_fields} // {},
        ignored_users      => {},
        ignored_user_names => {},
        ignored_groups     => {},
        ignored_group_names => {},
        actions            => [],
        removed            => {
            files    => 0,
            dirs     => 0,
            users    => 0,
            groups   => 0,
            modified => 0,
            failed   => 0,
        },
    }, 'sysclean';
}

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

subtest 'path validation' => sub {
    my $sc = new_sysclean(
        expected => { '/var/expected' => 1 },
        ignored  => { '/var/ignored'  => 1 },
    );

    is( $sc->check_removable_path('/var/obsolete'), undef,
        'canonical absolute path is removable' );
    like( $sc->check_removable_path('relative'), qr/not an absolute/,
        'relative path is refused' );
    like( $sc->check_removable_path(''), qr/empty/,
        'empty path is refused' );
    like( $sc->check_removable_path('/'), qr/refusing to remove/,
        'the root directory is refused' );
    like( $sc->check_removable_path('/var/../etc/obsolete'), qr/\.\./,
        "'..' component is refused" );
    like( $sc->check_removable_path('/var//obsolete'), qr/not canonical/,
        'double slash is refused' );
    like( $sc->check_removable_path('/var/./obsolete'), qr/not canonical/,
        "'.' component is refused" );
    like( $sc->check_removable_path('/var/obsolete/'), qr/not canonical/,
        'trailing slash is refused' );
    like( $sc->check_removable_path("/var/obsolete\n"), qr/control character/,
        'control character is refused' );
    like( $sc->check_removable_path('/var/expected'), qr/expected/,
        'expected path is refused' );
    like( $sc->check_removable_path('/var/ignored'), qr/ignored/,
        'ignored path is refused' );
    like( $sc->check_removable_path('/var/ignored/file'),
        qr/inside an ignored directory/,
        'path inside an ignored directory is refused' );
};

subtest 'symlinked ancestor' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $real = "$dir/real";
    my $link = "$dir/link";
    my $sc   = new_sysclean();

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor("$dir/obsolete");

    mkdir($real) or die "mkdir $real: $!";
    symlink( $real, $link ) or die "symlink $link: $!";

    like( $sc->check_removable_path("$link/obsolete"),
        qr/symbolic link component/,
        'path with a symlinked ancestor is refused' );
};

subtest 'sort_paths_deepest_first' => sub {
    my $sc = new_sysclean();
    my @sorted = $sc->sort_paths_deepest_first(
        [ '/a', '/a/b', '/a/b/c', '/x' ] );

    is_deeply( \@sorted, [ '/a/b/c', '/a/b', '/a', '/x' ],
        'paths are sorted deepest-first' );
};

subtest 'account and usermod argument validation' => sub {
    ok( sysclean::valid_account_name('_foo'), '_foo is valid' );
    ok( sysclean::valid_account_name('foo.bar-1'), 'foo.bar-1 is valid' );
    ok( !sysclean::valid_account_name('a b'), 'space is invalid' );
    ok( !sysclean::valid_account_name('-x'), 'leading dash is invalid' );
    ok( !sysclean::valid_account_name(''), 'empty name is invalid' );
    ok( !sysclean::valid_account_name(undef), 'undef name is invalid' );
    ok( !sysclean::valid_account_name("foo\n"), 'trailing newline is invalid' );

    ok( sysclean::valid_usermod_args( '-g', '_foo', '-s', '/sbin/nologin' ),
        'valid usermod options are accepted' );
    ok( sysclean::valid_usermod_args( '-L', '' ),
        'empty login class is accepted' );
    ok( !sysclean::valid_usermod_args('-g'), 'dangling option is refused' );
    ok( !sysclean::valid_usermod_args( '-g', '-x' ),
        'option injection is refused' );
    ok( !sysclean::valid_usermod_args( '-x', 'foo' ),
        'unknown option is refused' );
    ok( !sysclean::valid_usermod_args( '-d', '' ),
        'empty home directory is refused' );
};

subtest 'log sanitization' => sub {
    is( sysclean::sanitize_log("a\nb"), 'a\x0ab',
        'newline is escaped in log messages' );
    is( sysclean::sanitize_log('plain'), 'plain',
        'plain text is unchanged' );
};

subtest 'remove_path' => sub {
    my $sc  = new_sysclean();
    my $dir = tempdir(CLEANUP => 1);

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor("$dir/obsolete");

    # regular file
    my $file = "$dir/obsolete";
    open( my $fh, '>', $file ) or die "open $file: $!";
    print {$fh} "data\n";
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
    symlink( $target, $link ) or die "symlink $link: $!";

    my $link_ok;
    capture_both( sub { $link_ok = $sc->remove_path($link) } );
    ok( $link_ok, 'symlink removed' );
    ok( !-l $link, 'symlink is gone' );
    ok( -f $target, 'symlink target is preserved' );

    # empty directory is removed
    my $empty = "$dir/empty";
    mkdir($empty) or die "mkdir $empty: $!";
    my $empty_ok;
    capture_both( sub { $empty_ok = $sc->remove_path($empty) } );
    ok( $empty_ok, 'empty directory removed' );
    ok( !-e $empty, 'empty directory is gone' );
    is( $sc->{removed}{dirs}, 1, 'directory removal counted' );

    # non-empty directory is not removed
    my $full = "$dir/full";
    make_path($full);
    open( $fh, '>', "$full/child" ) or die "open child: $!";
    close($fh);

    my ( $out, $err ) = capture_both( sub { $sc->remove_path($full) } );
    ok( -d $full, 'non-empty directory is preserved' );
    like( $err, qr/rmdir/, 'failure is warned about' );
};

subtest 'expected and ignored paths are preserved' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $keep = "$dir/keep";
    my $probe = new_sysclean();

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $probe->path_has_symlink_ancestor($keep);

    open( my $fh, '>', $keep ) or die "open $keep: $!";
    close($fh);

    my $sc = new_sysclean( expected => { $keep => 1 } );
    my ( $out, $err ) = capture_both( sub { $sc->remove_path($keep) } );
    ok( -e $keep, 'expected file is preserved' );
    like( $err, qr/expected/, 'refusal is warned about' );
};

subtest 'allfiles apply protects used libraries' => sub {
    my $sc = bless {
        apply     => 1,
        used_libs => { 'c.so.1.2' => ['some-package'] },
        actions   => [],
    }, 'sysclean::allfiles';

    capture_both( sub { $sc->find_sub('/usr/lib/libc.so.1.2') } );
    is( scalar( @{ $sc->{actions} } ), 0,
        'used library is not queued in apply mode' );

    capture_both( sub { $sc->find_sub('/usr/lib/libfoo.so.1.2') } );
    is( scalar( @{ $sc->{actions} } ), 1,
        'unused library is queued in apply mode' );
};

subtest 'queue helpers' => sub {
    my $ro = new_sysclean( apply => 0 );
    $ro->queue_path('/x');
    $ro->queue_user( 'foo', 500 );
    $ro->queue_group( 'foo', 500 );
    $ro->queue_user_mod( 'foo', 500, '-s', '/sbin/nologin' );
    is( scalar( @{ $ro->{actions} } ), 0,
        'no action queued outside apply mode' );

    my $rw = new_sysclean( apply => 1 );
    $rw->queue_path('/x');
    $rw->queue_user( 'foo', 500 );
    $rw->queue_group( 'foo', 500 );
    $rw->queue_user_mod( 'foo', 500, '-s', '/sbin/nologin' );

    is( scalar( @{ $rw->{actions} } ), 4, 'actions queued in apply mode' );
    is( $rw->{actions}[1]{uid}, 500, 'user uid is recorded' );
    is( $rw->{actions}[2]{gid}, 500, 'group gid is recorded' );
    is_deeply( $rw->{actions}[3]{opts}, [ '-s', '/sbin/nologin' ],
        'usermod options are recorded' );
};

subtest 'prepare_apply path-only policy' => sub {
    my $sc  = new_sysclean();
    my $dir = tempdir(CLEANUP => 1);
    my $file = "$dir/obsolete";

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    @OpenBSD::Unveil::UNVEILS = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my @paths = ($file);
    my @users = ();
    my @groups = ();
    my @mods = ();
    $sc->prepare_apply( \@paths, \@users, \@groups, \@mods );

    ok( $OpenBSD::Unveil::LOCKED, 'unveil is locked' );
    is_deeply( \@paths, [$file], 'valid path is retained' );

    my $promise = join( ' ', @{ $OpenBSD::Pledge::PROMISES[-1] } );
    like( $promise, qr/\bcpath\b/, 'cpath is promised' );
    unlike( $promise, qr/\bproc\b/,
        'proc is not promised without account operations' );

    my @unveiled = map { $_->[0] } @OpenBSD::Unveil::UNVEILS;
    ok( scalar( grep { $_ eq $dir } @unveiled ),
        'removal directory is unveiled' );
};

subtest 'apply integration' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/obsolete";
    my $sc   = new_sysclean();

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    $sc->{actions} = [ { type => 'path', name => $file } ];

    @OpenBSD::Unveil::UNVEILS = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my ( $out, $err ) = capture_both( sub { $sc->apply } );

    ok( !-e $file, 'obsolete file removed by apply' );
    is( $sc->{removed}{files}, 1, 'file removal counted' );
    is( $sc->{removed}{failed}, 0, 'no failure counted' );
    like( $out, qr/unlink/, 'removal is reported' );
};

subtest 'apply refuses an expected path' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/keep";
    my $sc   = new_sysclean( expected => {} );

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    $sc->{expected}{$file} = 1;
    $sc->{actions} = [ { type => 'path', name => $file } ];

    @OpenBSD::Unveil::UNVEILS = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my $rc;
    capture_both( sub { $rc = $sc->apply } );

    ok( -e $file, 'expected file is preserved' );
    is( $rc, 1, 'apply reports failure' );
    is( $sc->{removed}{failed}, 1, 'refusal is counted' );
};

done_testing();
