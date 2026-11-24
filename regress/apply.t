#!/usr/bin/perl
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

# Install optional account fixture readers before compiling sysclean.pl.
# Tests using these readers never query or modify host account records.
our ( $fixture_users, $fixture_user_index, $fixture_groups );

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::getpwent = sub {
        return CORE::getpwent() unless defined $fixture_users;
        return () if $fixture_user_index >= @$fixture_users;
        return @{ $fixture_users->[ $fixture_user_index++ ] };
    };
    *CORE::GLOBAL::setpwent = sub {
        return CORE::setpwent() unless defined $fixture_users;
        $fixture_user_index = 0;
    };
    *CORE::GLOBAL::endpwent = sub {
        return CORE::endpwent() unless defined $fixture_users;
        $fixture_user_index = 0;
    };
    *CORE::GLOBAL::getpwnam = sub {
        return CORE::getpwnam( $_[0] ) unless defined $fixture_users;
        my ($entry) = grep { $_->[0] eq $_[0] } @$fixture_users;
        return $entry ? @$entry : ();
    };
    *CORE::GLOBAL::getgrnam = sub {
        return CORE::getgrnam( $_[0] ) unless defined $fixture_groups;
        my ($entry) = grep { $_->[0] eq $_[0] } @$fixture_groups;
        return $entry ? @$entry : ();
    };
    *CORE::GLOBAL::getgrgid = sub {
        return CORE::getgrgid( $_[0] ) unless defined $fixture_groups;
        my ($entry) = grep { $_->[2] == $_[0] } @$fixture_groups;
        return () unless $entry;
        return wantarray ? @$entry : $entry->[0];
    };
}

# loading the script must not execute the main program
## no critic (Modules::RequireBarewordIncludes) -- FindBin keeps this isolated test independent of the caller's working directory.
require "$FindBin::Bin/../sysclean.pl";

pass('sysclean.pl loaded without running the main program');

sub new_sysclean {
    my (%args) = @_;

    return bless {
        apply               => $args{apply}        // 1,
        expected            => $args{expected}     // {},
        ignored             => $args{ignored}      // {},
        users               => $args{users}        // {},
        groups              => $args{groups}       // {},
        user_fields         => $args{user_fields}  // {},
        group_fields        => $args{group_fields} // {},
        ignored_users       => {},
        ignored_user_names  => {},
        ignored_groups      => {},
        ignored_group_names => {},
        actions             => [],
        removed             => {
            files    => 0,
            dirs     => 0,
            users    => 0,
            groups   => 0,
            modified => 0,
            failed   => 0,
        },
      },
      'sysclean';
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

    is( $sc->check_removable_path('/var/obsolete'),
        undef, 'canonical absolute path is removable' );
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
    like(
        $sc->check_removable_path('/var//obsolete'),
        qr/not canonical/,
        'double slash is refused'
    );
    like(
        $sc->check_removable_path('/var/./obsolete'),
        qr/not canonical/,
        "'.' component is refused"
    );
    like(
        $sc->check_removable_path('/var/obsolete/'),
        qr/not canonical/,
        'trailing slash is refused'
    );
    like(
        $sc->check_removable_path("/var/obsolete\n"),
        qr/control character/,
        'control character is refused'
    );
    like( $sc->check_removable_path('/var/expected'),
        qr/expected/, 'expected path is refused' );
    like( $sc->check_removable_path('/var/ignored'),
        qr/ignored/, 'ignored path is refused' );
    like(
        $sc->check_removable_path('/var/ignored/file'),
        qr/inside an ignored directory/,
        'path inside an ignored directory is refused'
    );
};

subtest 'symlinked ancestor' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $real = "$dir/real";
    my $link = "$dir/link";
    my $sc   = new_sysclean();

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor("$dir/obsolete");

    mkdir($real)            or die "mkdir $real: $!";
    symlink( $real, $link ) or die "symlink $link: $!";

    like(
        $sc->check_removable_path("$link/obsolete"),
        qr/symbolic link component/,
        'path with a symlinked ancestor is refused'
    );
};

subtest 'sort_paths_deepest_first' => sub {
    my $sc = new_sysclean();
    my @sorted =
      $sc->sort_paths_deepest_first( [ '/a', '/a/b', '/a/b/c', '/x' ] );

    is_deeply(
        \@sorted,
        [ '/a/b/c', '/a/b', '/a', '/x' ],
        'paths are sorted deepest-first'
    );
};

subtest 'account and usermod argument validation' => sub {
    ok( sysclean::valid_account_name('_foo'),      '_foo is valid' );
    ok( sysclean::valid_account_name('foo.bar-1'), 'foo.bar-1 is valid' );
    ok( !sysclean::valid_account_name('a b'),      'space is invalid' );
    ok( !sysclean::valid_account_name('-x'),       'leading dash is invalid' );
    ok( !sysclean::valid_account_name(''),         'empty name is invalid' );
    ok( !sysclean::valid_account_name(undef),      'undef name is invalid' );
    ok( !sysclean::valid_account_name("foo\n"), 'trailing newline is invalid' );

    ok( sysclean::valid_usermod_args( '-g', '_foo', '-s', '/sbin/nologin' ),
        'valid usermod options are accepted' );
    ok(
        sysclean::valid_usermod_args( '-L', '' ),
        'empty login class is accepted'
    );
    ok( !sysclean::valid_usermod_args('-g'), 'dangling option is refused' );
    ok( !sysclean::valid_usermod_args( '-g', '-x' ),
        'option injection is refused' );
    ok( !sysclean::valid_usermod_args( '-x', 'foo' ),
        'unknown option is refused' );
    ok(
        !sysclean::valid_usermod_args( '-d', '' ),
        'empty home directory is refused'
    );
};

subtest 'log sanitization' => sub {
    is( sysclean::sanitize_log("a\nb"),
        'a\x0ab', 'newline is escaped in log messages' );
    is( sysclean::sanitize_log('plain'), 'plain', 'plain text is unchanged' );
};

subtest 'remove_path' => sub {
    my $sc  = new_sysclean();
    my $dir = tempdir( CLEANUP => 1 );

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
};

subtest 'expected and ignored paths are preserved' => sub {
    my $dir   = tempdir( CLEANUP => 1 );
    my $keep  = "$dir/keep";
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
        used_libs => {
            c => [
                [
                    OpenBSD::LibSpec->from_string('c.1.2'), '/usr/local',
                    'some-package'
                ]
            ],
            foo => [
                [
                    OpenBSD::LibSpec->from_string('lib/extra/foo.1.2'),
                    '/usr/local', 'other-package'
                ]
            ],
        },
        actions => [],
      },
      'sysclean::allfiles';

    capture_both( sub { $sc->find_sub('/usr/lib/libc.so.1.3') } );
    is( scalar( @{ $sc->{actions} } ),
        0, 'used library is not queued in apply mode' );

    my $dir    = tempdir( CLEANUP => 1 );
    my $unused = "$dir/libfoo.so.1.2";
    open( my $fh, '>', $unused ) or die "open $unused: $!";
    close($fh)                   or die "close $unused: $!";
    capture_both( sub { $sc->find_sub($unused) } );
    is( scalar( @{ $sc->{actions} } ),
        1, 'unused library is queued in apply mode' );

    is_deeply( [ $sc->library_consumers('/usr/local/lib/extra/libfoo.so.1.3') ],
        ['other-package'],
        'qualified requirement matches the package directory' );
    is( scalar( $sc->library_consumers('/usr/lib/libc.so.2.0') ),
        0, 'an incompatible major version is not matched' );
    is(
        $sc->check_removable_path('/usr/lib/libc.so.1.3'),
        'pathname is required by installed packages',
        'apply rechecks library protection for exact queued paths'
    );
};

subtest 'ignore includes and patterns' => sub {
    my $dir    = tempdir( CLEANUP => 1 );
    my $config = "$dir/ignore";
    my $alias  = "$dir/alias";
    open( my $fh, '>', $config ) or die "open $config: $!";
    print {$fh} "\@include \"$alias\"\n$dir/with spaces\n$dir/absent/*\n";
    close($fh)              or die "close $config: $!";
    link( $config, $alias ) or die "link $alias: $!";

    my $sc = new_sysclean( apply => 1 );
    ok( $sc->add_user_ignored($config), 'load a regular ignore file' );
    is_deeply( [ keys %{ $sc->{ignored} } ],
        ["$dir/with spaces"],
        'literal spaces survive and an optional unmatched pattern is empty' );
    is( scalar( keys %{ $sc->{ignore_loaded} } ),
        1, 'the opened file and its hard-link alias have one identity' );
};

subtest 'queue helpers' => sub {
    my $ro = new_sysclean( apply => 0 );
    $ro->queue_path('/x');
    $ro->queue_user( 'foo', 500 );
    $ro->queue_group( 'foo', 500 );
    $ro->queue_user_mod( 'foo', 500, 500, 'foo', '', '/var/empty', '/bin/ksh' );
    is( scalar( @{ $ro->{actions} } ),
        0, 'no action queued outside apply mode' );

    my $rw = new_sysclean(
        apply       => 1,
        user_fields => { foo => { uid => 500, shell => '/sbin/nologin' } }
    );
    $rw->queue_path($0);
    $rw->queue_user( 'foo', 500 );
    $rw->queue_group( 'foo', 500 );
    $rw->queue_user_mod( 'foo', 500, 500, 'foo', '', '/var/empty', '/bin/ksh' );

    is( scalar( @{ $rw->{actions} } ), 4,   'actions queued in apply mode' );
    is( $rw->{actions}[1]{uid},        500, 'user uid is recorded' );
    is( $rw->{actions}[2]{gid},        500, 'group gid is recorded' );
    is_deeply(
        $rw->{actions}[3]{opts},
        [ '-s', '/sbin/nologin' ],
        'usermod options are recorded'
    );
};

subtest 'prepare_apply path-only policy' => sub {
    my $sc   = new_sysclean();
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/obsolete";

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    @OpenBSD::Unveil::UNVEILS  = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my @paths  = ($file);
    my @users  = ();
    my @groups = ();
    my @mods   = ();
    $sc->prepare_apply( \@paths, \@users, \@groups, \@mods );

    ok( $OpenBSD::Unveil::LOCKED, 'unveil is locked' );
    is_deeply( \@paths, [$file], 'valid path is retained' );

    my $promise = join( ' ', @{ $OpenBSD::Pledge::PROMISES[-1] } );
    like( $promise, qr/\bcpath\b/, 'cpath is promised' );
    unlike( $promise, qr/\bproc\b/,
        'proc is not promised without account operations' );

    my @unveiled = map { $_->[0] } @OpenBSD::Unveil::UNVEILS;
    ok(
        scalar( grep { $_ eq $dir } @unveiled ),
        'removal directory is unveiled'
    );
};

subtest 'apply integration' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/obsolete";
    my $sc   = new_sysclean();

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    $sc->queue_path($file);

    @OpenBSD::Unveil::UNVEILS  = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my ( $out, $err ) = capture_both( sub { $sc->apply } );

    ok( !-e $file, 'obsolete file removed by apply' );
    is( $sc->{removed}{files},  1, 'file removal counted' );
    is( $sc->{removed}{failed}, 0, 'no failure counted' );
    like( $out, qr/unlink/, 'removal is reported' );
};

subtest 'apply refuses an expected path' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/keep";
    my $sc   = new_sysclean( expected => {} );

    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);

    open( my $fh, '>', $file ) or die "open $file: $!";
    close($fh);

    $sc->{expected}{$file} = 1;
    $sc->queue_path($file);

    @OpenBSD::Unveil::UNVEILS  = ();
    $OpenBSD::Unveil::LOCKED   = 0;
    @OpenBSD::Pledge::PROMISES = ();

    my $rc;
    capture_both( sub { $rc = $sc->apply } );

    ok( -e $file, 'expected file is preserved' );
    is( $rc,                    1, 'apply reports failure' );
    is( $sc->{removed}{failed}, 1, 'refusal is counted' );
};

subtest 'preview leaves the sandbox and filesystem unchanged' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/obsolete";
    my $sc   = new_sysclean();
    $sc->{preview} = 1;
    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);
    open my $fh, '>', $file or die "open $file: $!";
    close $fh or die "close $file: $!";
    $sc->queue_path($file);
    local @OpenBSD::Unveil::UNVEILS;
    local @OpenBSD::Pledge::PROMISES;
    my $status;
    my ($out) = capture_both( sub { $status = $sc->apply } );
    is( $status, 0, 'clean preview' );
    like( $out, qr/planned removal/, 'reports apply candidate' );
    ok( -f $file, 'preview keeps candidate' );
    is( scalar @OpenBSD::Unveil::UNVEILS,
        0, 'preview requests no unveil grants' );
    is( scalar @OpenBSD::Pledge::PROMISES,
        0, 'preview requests no apply promises' );
};

subtest 'path identity is rechecked' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = "$dir/obsolete";
    my $sc   = new_sysclean();
    plan skip_all => 'temporary directory has a symlinked ancestor'
      if $sc->path_has_symlink_ancestor($file);
    open my $fh, '>', $file or die "open $file: $!";
    close $fh or die "close $file: $!";
    $sc->queue_path($file);
    rename $file, "$dir/original" or die "rename $file: $!";
    open $fh, '>', $file or die "open $file: $!";
    close $fh or die "close $file: $!";
    my ( $rc, $err );
    ( undef, $err ) = capture_both( sub { $rc = $sc->apply } );
    is( $rc, 1, 'drift reported' );
    like( $err, qr/identity changed/, 'diagnoses replacement' );
    ok( -f $file && -f "$dir/original", 'both identities remain' );
};

subtest 'top-level preflight never reaches write grants' => sub {
    my $sc = new_sysclean();
    my $error;
    {
        no warnings qw(redefine once);
        local *sysclean::err = sub { die $_[2] };
        eval { $sc->preflight_paths( [ { name => '/fixture' } ] ); };
        $error = $@;
    }
    like( $error, qr/top-level candidate/, 'top-level path aborts preflight' );
};

subtest 'package account defaults and enforced fields' => sub {
    my $sc    = new_sysclean();
    my $entry = bless {
        name  => '_fixture',
        uid   => '!550',
        group => '123',
        class => 'local-default',
        home  => '!/var/empty',
        shell => '/bin/ksh',
      },
      'OpenBSD::PackingElement::NewUser';
    $entry->walk_sysclean( 'package-a', $sc );
    my $ref = $sc->{user_fields}{_fixture};
    is( $ref->{uid},  550,          'reference uid retained' );
    is( $ref->{home}, '/var/empty', 'enforced field retained' );
    ok( !exists $ref->{gid} && !exists $ref->{shell} && !exists $ref->{class},
        'unmarked defaults do not authorize correction' );
    $sc->register_user_reference( '_fixture', { uid => 551 }, 'package-b' );
    ok( $ref->{ambiguous}, 'conflicting reference is ambiguous' );
    is_deeply(
        $ref->{sources},
        [ 'package-a', 'package-b' ],
        'sources retained'
    );
};

subtest 'group dependency checks include non-system users' => sub {
    local $fixture_users =
      [ [ 'root', '*', 0, 0 ], [ 'retained', '*', 1001, 550 ], ];
    like(
        sysclean::primary_group_dependency(550),
        qr/primary group of 'retained'/,
        'retained user blocks group deletion'
    );
    is( scalar sysclean::primary_group_dependency(551),
        undef, 'unused gid passes' );
    local $fixture_users = [];
    like(
        sysclean::primary_group_dependency(551),
        qr/root account missing/,
        'empty enumeration cannot establish safety'
    );
};

subtest 'usermod refuses drift and changed group resolution' => sub {
    local $fixture_users =
      [ [ 'fixture', '*', 550, 550, undef, '', '', '/var/empty', '/bin/ksh' ],
      ];
    local $fixture_groups =
      [ [ 'original', '*', 550, '' ], [ 'destination', '*', 551, '' ], ];
    my $sc = new_sysclean(
        user_fields => { fixture => { uid => 550, group => 'destination' } } );
    $sc->queue_user_mod( 'fixture', 550, 550, 'original', '', '/var/empty',
        '/bin/ksh' );
    my $action = $sc->{actions}[0];
    is( scalar $sc->user_mod_refusal($action),
        undef, 'matching snapshot is eligible' );
    $fixture_users->[0][8] = '/sbin/nologin';
    like(
        $sc->user_mod_refusal($action),
        qr/account fields changed/,
        'local drift refused'
    );
    $fixture_users->[0][8]  = '/bin/ksh';
    $fixture_groups->[1][2] = 552;
    like(
        $sc->user_mod_refusal($action),
        qr/destination group changed/,
        'target drift refused'
    );
    $sc->{user_fields}{fixture}{gid} = 551;
    like(
        $sc->user_mod_refusal($action),
        qr/group name and gid disagree/,
        'contradictory references refused'
    );
    ok(
        !sysclean::valid_usermod_args( '-g', '=uid' ),
        'special group creation form refused'
    );
};

done_testing();
