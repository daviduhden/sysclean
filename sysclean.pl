#!/usr/bin/perl
#
# This file is part of a fork of sysclean adding an explicit apply (-x) mode.
# The canonical upstream repository is hosted on Codeberg:
#   https://codeberg.org/semarie/sysclean/
# Fork maintained at:
#   https://github.com/daviduhden/sysclean
#

use v5.36;

package sysclean;

use File::Basename qw(dirname);

# escape control characters so that a crafted filename cannot inject
# additional log lines into the administrator's terminal
sub sanitize_log {
    my $msg = join( ' ', @_ );
    $msg =~ s/([\x00-\x1f\x7f])/sprintf("\\x%02x", ord($1))/ge;
    return $msg;
}

# logging helpers (same convention as the other tools)
sub logi { print "[INFO] ", sanitize_log(@_), "\n" }
sub logw { print STDERR "[WARN] ", sanitize_log(@_), "\n" }

sub die_tool {
    my ( $exitcode, @msg ) = @_;
    print STDERR "[ERROR] ", sanitize_log(@msg), "\n";
    exit $exitcode;
}

# return subclass according to options
sub subclass( $self, $options ) {
    return 'sysclean::allfiles' if ( defined $$options{a} );
    return 'sysclean::packages' if ( defined $$options{p} );
    return 'sysclean::files';
}

# choose class for mode, depending on %options
sub create( $base, $options ) {
    my $apply      = defined $$options{x};
    my $mode_count = 0;

    $mode_count++   if ( defined $$options{a} );
    $mode_count++   if ( defined $$options{p} );
    sysclean->usage if ( $mode_count > 1 );

    # applying changes only makes sense for the file listings
    sysclean->err( 1, "-x is not compatible with package mode (-p)" )
      if ( $apply && defined $$options{p} );

    # in apply mode, -i selects whether the user ignore files are honored:
    #   -x -i  -> ignored files are respected and never removed
    #   -x     -> ignored files are removed like any other obsolete element
    my $with_ignored = $apply ? defined $$options{i} : !defined $$options{i};

    sysclean->warning(
        "-x: user ignore files are not protected, use -i to respect them")
      if ( $apply && !defined $$options{i} );

    sysclean->warning(
        "-x with -a: recognized used libraries are protected from removal" )
      if ( $apply && defined $$options{a} );

    return $base->subclass($options)->new( $with_ignored, $apply );
}

# constructor
sub new( $class, $with_ignored, $apply ) {
    my $self = bless {}, $class;

    $self->{apply}   = $apply ? 1 : 0;
    $self->{actions} = [];
    $self->{removed} = {
        files    => 0,
        dirs     => 0,
        users    => 0,
        groups   => 0,
        modified => 0,
        failed   => 0,
    };

    # initialise the inventories explicitly so that exists() checks do not
    # depend on autovivification and an empty inventory is unambiguous
    $self->{expected}            = {};
    $self->{ignored}             = {};
    $self->{ignore_loaded}       = {};
    $self->{users}               = {};
    $self->{groups}              = {};
    $self->{user_fields}         = {};
    $self->{group_fields}        = {};
    $self->{ignored_users}       = {};
    $self->{ignored_user_names}  = {};
    $self->{ignored_groups}      = {};
    $self->{ignored_group_names} = {};
    $self->{libs}                = {};
    $self->{used_libs}           = {};

    $self->init_ignored;
    $self->init;

    # /etc/sysclean.ignore is this tool's own configuration file and
    # /etc/changelist is the system file it implicitly includes.  Always
    # treat both as expected so that they are never reported as obsolete and
    # never removed in apply mode, even when -i is not given.
    $self->{expected}{'/etc/sysclean.ignore'} = 1;
    $self->{expected}{'/etc/changelist'}      = 1;

    if ($with_ignored) {
        $self->add_user_ignored("/etc/changelist");
        $self->add_user_ignored("/etc/sysclean.ignore");
    }

    return $self;
}

# print usage and exit
sub usage($self) {
    print "usage: $0 [ -a | -p ] [-i] [-x]\n";
    exit 1;
}

# print error and exit
sub err( $self, $exitcode, @rest ) {
    die_tool( $exitcode, @rest );
}

# print warning
sub warning( $self, @rest ) {
    logw("@rest");
}

# print an informational message
sub note( $self, @rest ) {
    logi("@rest");
}

# initial list of ignored files and directories
sub init_ignored($self) {
    $self->{ignored} = {
        '/home'                    => 1,
        '/root'                    => 1,
        '/tmp'                     => 1,
        '/usr/local'               => 1,    # remove ?
        '/usr/obj'                 => 1,
        '/usr/ports'               => 1,
        '/usr/share/relink/kernel' => 1,
        '/usr/src'                 => 1,
        '/usr/xenocara'            => 1,
        '/usr/xobj'                => 1,
        '/etc/ssl/cert.pem'        => 1,
        '/usr/share/zoneinfo'      => 1,
        '/var/backups'             => 1,
        '/var/cache'               => 1,
        '/var/cron'                => 1,
        '/var/db'                  => 1,
        '/var/dbupdate'            => 1,
        '/var/empty'               => 1,
        '/var/log'                 => 1,
        '/var/mail'                => 1,
        '/var/run'                 => 1,
        '/var/spool/smtpd'         => 1,
        '/var/sysmerge'            => 1,
        '/var/syspatch'            => 1,
        '/var/tmp'                 => 1,
        '/var/www/htdocs'          => 1,
        '/var/www/logs'            => 1,
        '/var/www/run'             => 1,
        '/var/www/tmp'             => 1,
    };

    # additionnal ignored files, using pattern
    foreach my $filename ( glob('/bsd.syspatch*') ) {
        $self->{ignored}{$filename} = 1;
    }
}

sub init($self) {
    use OpenBSD::PackageInfo;
    use OpenBSD::Pledge;
    use OpenBSD::Unveil;

    # The scan invokes helpers before a syscall ceiling can be installed.
    # Apply mode may also invoke account helpers later; keep it unpledged
    # during the scan and install the ceiling in prepare_apply().
    eval { lock_db(1) };
    $self->err( 1, "can't lock package database: $@" ) if $@;

    unveil( '/',               'r' ) || $self->err( 1, "unveil '/': $!" );
    unveil( '/dev/MAKEDEV',    'rx' )
      || $self->err( 1, "unveil '/dev/MAKEDEV': $!" );
    unveil( '/usr/bin/locate', 'rx' )
      || $self->err( 1, "unveil '/usr/bin/locate': $!" );
    unveil( '/usr/sbin/rcctl', 'rx' )
      || $self->err( 1, "unveil '/usr/sbin/rcctl': $!" );

    $self->add_expected_base;
    $self->add_expected_dev;
    $self->add_expected_rcctl;

    # Read-only mode has finished all external execution.
    pledge("rpath getpw") || $self->err( 1, "pledge" )
      unless $self->{apply};

    $self->add_expected_users;
    $self->add_expected_ports_info;
}

# add expected files from base. call `add_expected_base_one' overriden method.
# WARNING: `expected' attribute is overrided
sub add_expected_base($self) {

    # simple files expected (and not in locate databases)
    $self->{expected} = {
        '/'                                         => 1,
        '/boot'                                     => 1,
        '/ofwboot'                                  => 1,
        '/bsd'                                      => 1,
        '/bsd.booted'                               => 1,
        '/bsd.mp'                                   => 1,
        '/bsd.rd'                                   => 1,
        '/bsd.sp'                                   => 1,
        '/obsd'                                     => 1,
        '/dev/rootdisk'                             => 1,
        '/dev/rrootdisk'                            => 1,
        '/etc/acme/letsencrypt-privkey.pem'         => 1,
        '/etc/acme/letsencrypt-staging-privkey.pem' => 1,
        '/etc/fstab'                                => 1,
        '/etc/hosts'                                => 1,
        '/etc/installurl'                           => 1,
        '/etc/iked/local.pub'                       => 1,
        '/etc/iked/private/local.key'               => 1,
        '/etc/isakmpd/local.pub'                    => 1,
        '/etc/isakmpd/private/local.key'            => 1,
        '/etc/kbdtype'                              => 1,
        '/etc/ssh/ssh_host_rsa_key'                 => 1,
        '/etc/ssh/ssh_host_rsa_key.pub'             => 1,
        '/etc/ssh/ssh_host_ecdsa_key'               => 1,
        '/etc/ssh/ssh_host_ecdsa_key.pub'           => 1,
        '/etc/ssh/ssh_host_ed25519_key'             => 1,
        '/etc/ssh/ssh_host_ed25519_key.pub'         => 1,
        '/etc/myname'                               => 1,
        '/etc/random.seed'                          => 1,
        '/usr/libexec/ld.so.save'                   => 1,
        '/var/account/acct'                         => 1,
        '/var/account/acct.0'                       => 1,
        '/var/account/acct.1'                       => 1,
        '/var/account/acct.2'                       => 1,
        '/var/account/acct.3'                       => 1,
        '/var/account/savacct'                      => 1,
        '/var/account/usracct'                      => 1,
    };

    # additionnal expected files, using pattern
    foreach my $filename ( glob('/etc/hostname.*') ) {
        $self->{expected}{$filename} = 1;
    }

    # expected files, from locate databases
    use OpenBSD::Paths;

    my $srcdb = OpenBSD::Paths->srclocatedb;
    my $xdb   = OpenBSD::Paths->xlocatedb;

    $self->err( 1, "can't read base locatedb '$srcdb'" )
      if !defined($srcdb) || !length($srcdb) || !-e $srcdb;

    my @locate_args = ( '-d', $srcdb );

    # systems without X do not ship the X locate database; do not make
    # locate(1) fail merely because the optional database is absent
    push( @locate_args, '-d', $xdb )
      if defined($xdb) && length($xdb) && -e $xdb;

    open( my $cmd, '-|', 'locate', @locate_args, '*' )
      || $self->err( 1, "can't read base locatedb" );

    my $entries = 0;
    while (<$cmd>) {
        chomp;
        my ( undef, $filename ) = split( ':', $_, 2 );
        next if !defined($filename) || !length($filename);
        $filename =~ s{//+}{/}g;
        $filename =~ s{/+$}{} if $filename ne '/';
        next if $filename !~ m{^/};
        $self->add_expected_base_one($filename);
        $entries++;
    }

    my $closed = close($cmd);

    # an empty or failed inventory is a false-positive generator; apply mode
    # must refuse to continue rather than remove a file that is merely
    # missing from an incomplete reference set
    $self->err( 1, "can't read base locatedb" ) if $entries == 0;
    if ( !$closed ) {
        $self->err( 1, "locate failed; refusing to apply an incomplete base" )
          if $self->{apply};
        $self->warning("locate failed; base inventory may be incomplete");
    }
}

# default method for manipulated one expected filename of base.
sub add_expected_base_one( $self, $filename ) {
    $self->{expected}{$filename} = 1;
}

# add expected files from /dev
sub add_expected_dev($self) {

    # set 'eo=echo' in env, to run MAKEDEV(8) in echo mode.
    local $ENV{eo} = 'echo';

    chdir('/dev')
      || $self->err( 1, "can't chdir to /dev" );
    open( my $dev, '-|', './MAKEDEV', 'all' )
      || $self->err( 1, "can't execute /dev/MAKEDEV" );

    my $dev_entries = 0;

    while (<$dev>) {
        chomp;

        # simplify command separator
        s/\s*(?:;|&&|\|\|)\s*/;/g;

        # iterate on commands
        foreach my $commandline ( split(/;/) ) {

            $commandline =~ s/^\s+//;
            next if !length($commandline);

            # split $commandline in words
            my @args = split( /\s+/, $commandline );
            my $cmd  = shift(@args);
            next if !defined($cmd) || !length($cmd);

            # skip commands
            next if ( $cmd eq 'rm' );
            next if ( $cmd eq 'chown' );
            next if ( $cmd eq 'chgrp' );
            next if ( $cmd eq 'chmod' );
            next if ( $cmd eq '[' );

            if ( $cmd eq 'mkdir' ) {
                shift(@args) if ( @args && $args[0] eq '-p' );

                foreach my $dir (@args) {
                    next if !length($dir);
                    $self->{expected}{"/dev/$dir"} = 1;
                    $dev_entries++;
                }

            }
            elsif ( $cmd eq 'ln' ) {
                my $dest = pop(@args);
                if ( defined($dest) && length($dest) ) {
                    $self->{expected}{"/dev/$dest"} = 1;
                    $dev_entries++;
                }

            }
            elsif ( $cmd eq 'mknod' ) {
                my @mknod = @args;
                while (@mknod) {
                    my $arg = shift(@mknod);
                    if ( $arg eq '-m' ) {
                        shift(@mknod);    # mode
                        next;
                    }

                    if ( defined($arg) && length($arg) ) {
                        $self->{expected}{"/dev/$arg"} = 1;
                        $dev_entries++;
                    }
                    shift(@mknod);    # b|c
                    shift(@mknod);    # major
                    shift(@mknod);    # minor
                }

            }
            else {
                $self->err( 1, "unexpected command '$cmd' in MAKEDEV output" );
            }
        }
    }

    my $closed = close($dev);

    # restore the working directory, changed to /dev for MAKEDEV(8)
    chdir('/')
      || $self->err( 1, "can't chdir back to /: $!" );

    $self->err( 1, "can't execute /dev/MAKEDEV" ) if !$closed;

    $self->err( 1, "MAKEDEV(8) produced no expected /dev entries" )
      if $dev_entries == 0;
}

# add expected files from enabled daemons and services.
sub add_expected_rcctl($self) {
    open( my $cmd, '-|', 'rcctl', 'ls', 'on' )
      || $self->err( 1, "can't read enabled daemons and services" );
    while (<$cmd>) {
        chomp;
        if ( 'apmd' eq $_ ) {
            $self->{expected}{'/etc/apm'}           = 1;
            $self->{expected}{'/etc/apm/suspend'}   = 1;
            $self->{expected}{'/etc/apm/hibernate'} = 1;
            $self->{expected}{'/etc/apm/standby'}   = 1;
            $self->{expected}{'/etc/apm/resume'}    = 1;
            $self->{expected}{'/etc/apm/powerup'}   = 1;
            $self->{expected}{'/etc/apm/powerdown'} = 1;

        }
        elsif ( 'dhcp6leased' eq $_ ) {
            $self->{expected}{'/dev/dhcp6leased.lock'} = 1;
            $self->{expected}{'/dev/dhcp6leased.sock'} = 1;

        }
        elsif ( 'dhcpleased' eq $_ ) {
            $self->{expected}{'/dev/dhcpleased.lock'} = 1;
            $self->{expected}{'/dev/dhcpleased.sock'} = 1;

        }
        elsif ( 'hotplugd' eq $_ ) {
            $self->{expected}{'/etc/hotplug/attach'} = 1;
            $self->{expected}{'/etc/hotplug/detach'} = 1;

        }
        elsif ( 'iked' eq $_ ) {
            $self->{ignored}{'/etc/iked/pubkeys'} = 1;

        }
        elsif ( 'isakmpd' eq $_ ) {
            $self->{ignored}{'/etc/isakmpd/pubkeys'} = 1;

        }
        elsif ( 'lpd' eq $_ ) {
            $self->{expected}{'/etc/printcap'}        = 1;
            $self->{ignored}{'/var/spool/output/lpd'} = 1;

        }
        elsif ( 'nsd' eq $_ ) {
            $self->{ignored}{'/var/nsd/run'}   = 1;
            $self->{ignored}{'/var/nsd/zones'} = 1;

        }
        elsif ( 'resolvd' eq $_ ) {
            $self->{expected}{'/dev/resolvd.lock'} = 1;

        }
        elsif ( 'slaacd' eq $_ ) {
            $self->{expected}{'/dev/slaacd.lock'} = 1;
            $self->{expected}{'/dev/slaacd.sock'} = 1;

        }
        elsif ( 'syslogd' eq $_ ) {
            $self->{expected}{'/dev/log'} = 1;

        }
        elsif ( 'smtpd' eq $_ ) {
            $self->{expected}{'/etc/mail/aliases.db'} = 1;

        }
        elsif ( 'unbound' eq $_ ) {
            $self->{expected}{'/var/unbound/db/root.key'} = 1;

        }
        elsif ( 'unwind' eq $_ ) {
            $self->{expected}{'/dev/unwind.sock'}                 = 1;
            $self->{expected}{'/etc/unwind/trustanchor/root.key'} = 1;

        }
        elsif ( 'xenodm' eq $_ ) {
            $self->{ignored}{'/etc/X11/xenodm/authdir'} = 1;
        }
    }

    my $closed = close($cmd);
    if ( !$closed ) {
        $self->err( 1, "rcctl failed; refusing to apply an incomplete service list" )
          if $self->{apply};
        $self->warning("rcctl failed; service inventory may be incomplete");
    }
}

# add expected information for users/groups.
sub add_expected_users($self) {
    use Archive::Tar;

    my $tar = Archive::Tar->new();
    $tar->read( '/var/sysmerge/etc.tgz', COMPRESS_GZIP )
      || $self->err( 1, "can't read /var/sysmerge/etc.tgz" );

    # add groups (and keep track of gid -> gname association)
    my %groups        = ();
    my $group         = $tar->get_content('./etc/group');
    $group = $tar->get_content('etc/group') if !defined($group);
    my $group_entries = 0;
    $self->err( 1, "missing ./etc/group in /var/sysmerge/etc.tgz" )
      if !defined($group) || !length($group);

    foreach my $entry ( grep { length } split( /\n/, $group ) ) {
        my ( $name, $passwd, $gid, $members ) = split( /:/, $entry, -1 );
        next if !defined($name) || !length($name);
        next if !defined($gid) || !length($gid);
        $self->err( 1, "invalid gid for group '$name' in etc.tgz" )
          if $gid !~ m{^\d+$};
        my $group_key = join( ':', ( $name, $gid ) );

        $groups{$gid} = $name;
        $self->{groups}{$group_key}  = 1;
        $self->{group_fields}{$name} = $gid;
        $group_entries++;
    }
    $self->err( 1, "empty ./etc/group in /var/sysmerge/etc.tgz" )
      if $group_entries == 0;

    # add users
    my $passwd_content = $tar->get_content('./etc/master.passwd');
    $passwd_content = $tar->get_content('etc/master.passwd')
      if !defined($passwd_content);
    my $passwd_entries = 0;
    $self->err( 1, "missing ./etc/master.passwd in /var/sysmerge/etc.tgz" )
      if !defined($passwd_content) || !length($passwd_content);

    foreach my $entry ( grep { length } split( /\n/, $passwd_content ) ) {
        my (
            $name,   $passwd, $uid,   $gid,  $class,
            $change, $expire, $gecos, $home, $shell
        ) = split( /:/, $entry, -1 );
        next if !defined($name) || !length($name);
        next if !defined($uid) || !length($uid);
        $self->err( 1, "invalid uid for user '$name' in etc.tgz" )
          if $uid !~ m{^\d+$};
        $self->err( 1, "invalid gid for user '$name' in etc.tgz" )
          if !defined($gid) || $gid !~ m{^\d+$};
        my $gname =
          exists $groups{$gid}
          ? $groups{$gid}
          : $self->err( 1, "unknown gid $gid in passwd '$name' entry" );

        my $user = join( ':',
            map { defined($_) ? $_ : '' }
              ( $name, $uid, $gname, $class, $home, $shell ) );
        $self->{users}{$user} = 1;

        $self->{user_fields}{$name} = {
            uid   => $uid,
            gid   => $gid,
            group => $gname,
            class => $class,
            home  => $home,
            shell => $shell,
        };

        my $short = join( ':', ( $name, $uid ) );
        $self->{users}{$short} = 1;
        $passwd_entries++;
    }
    $self->err( 1, "empty ./etc/master.passwd in /var/sysmerge/etc.tgz" )
      if $passwd_entries == 0;

}

# add expected information from ports. the method will call `plist_reader'
# overriden method.
sub add_expected_ports_info($self) {
    use OpenBSD::PackageInfo;
    use OpenBSD::PackingList;

    my @packages = eval { installed_packages() };
    $self->err( 1, "can't read package database: $@" ) if $@;
    @packages = sort @packages;

    my @partial = grep { m/^partial-/ } @packages;

    if (@partial) {
        my $msg = "incomplete package installation: " . join( ', ', @partial );
        $self->err( 1, "$msg; refusing to apply" ) if $self->{apply};
        $self->warning("$msg; package inventory may be incomplete");
    }

    for my $pkgname (@packages) {
        next if $pkgname =~ m/^partial-/;

        my $ok = eval {
            my $plist = OpenBSD::PackingList->from_installation( $pkgname,
                $self->plist_reader );
            die "undefined packing list\n" if !defined($plist);
            $plist->walk_sysclean( $pkgname, $self );
            1;
        };

        $self->err( 1,
            "can't read packing list for '$pkgname': " . ( $@ || "unknown" ) )
          if !$ok;
    }
}

# default plist_reader sub. could be overrided.
sub plist_reader($self) {
    return sub ( $fh, $cont ) {
        while (<$fh>) {
            next
              if !
m/^\@(?:cwd|name|info|fontdir|man|mandir|file|dir|lib|shell|so|static-lib|extra|sample|bin|rcscript|wantlib|newuser|newgroup)\b/o
              && m/^\@/o;
            &$cont($_);
        }
    }
}

# add user-defined `ignored' elements.  top-level configuration files are
# optional (they may not exist), but a file named by @include must be
# readable: silently dropping an @include would remove a protection that the
# administrator explicitly configured.
sub add_user_ignored( $self, $conffile, $required = 0 ) {

    # guard against "@include" loops: a configuration file is processed only
    # once, further includes of the same file are silently ignored.
    return 1 if $self->{ignore_loaded}{$conffile};

    my $fh;
    if ( !open( $fh, "<", $conffile ) ) {
        return 0 if !$required && !-e $conffile && !-l $conffile;
        $self->err( 1, "open \"$conffile\": $!" );
    }
    $self->{ignore_loaded}{$conffile} = 1;

    while (<$fh>) {
        chomp;

        # strip starting '+' (compat with changelist(5) format)
        s/^\+//;

        # strip whole-line and whitespace-separated comments; a '#' without
        # preceding whitespace is part of the pathname
        s/^\s*#.*$//;
        s/\s+#.*$//;
        next if (m/^\s*$/o);

        if (m/^\@include\s+"(.*)"\s*$/) {

            # include another conffile; a missing include is a configuration
            # error, not an optional entry
            $self->add_user_ignored( $1, 1 );

        }
        elsif (m|^/|) {

            # absolute filename; File::Find reports directories without a
            # trailing slash, so normalize the key before storing it
            foreach my $filename ( glob qq("$_") ) {
                next if !defined($filename) || !length($filename);
                next if $filename !~ m{^/};
                $filename =~ s{//+}{/}g;
                $filename =~ s{/+$}{} if $filename ne '/';
                $self->{ignored}{$filename} = 1;
            }

        }
        elsif (s/^\@user\s+//) {

            # user entry
            s/\s+$//;
            $self->err( 1, "$conffile: empty \@user entry" )
              if !length($_);
            my ($name) = split( /:/, $_ );
            $self->err( 1, "$conffile: invalid \@user entry: $_" )
              if !defined($name) || !length($name);
            $self->{ignored_users}{$_}         = 1;
            $self->{ignored_user_names}{$name} = 1;

        }
        elsif (s/^\@group\s+//) {

            # group entry
            s/\s+$//;
            $self->err( 1, "$conffile: empty \@group entry" )
              if !length($_);
            my ($name) = split( /:/, $_ );
            $self->err( 1, "$conffile: invalid \@group entry: $_" )
              if !defined($name) || !length($name);
            $self->{ignored_groups}{$_}         = 1;
            $self->{ignored_group_names}{$name} = 1;

        }
        else {
            $self->err( 1, "$conffile: invalid entry: $_" );
        }
    }
    close($fh) || $self->err( 1, "close \"$conffile\": $!" );
    return 1;
}

# walk the filesystem. the method will call `find_sub' overriden method.
sub walk_filesystem($self) {
    use File::Find;

    find(
        {
            wanted => sub {
                if ( exists( $self->{ignored}{$_} ) ) {

                    # skip ignored files
                    $File::Find::prune = 1;

                }
                elsif ( !exists( $self->{expected}{$_} ) ) {

                    # not expected file

                    if ( -d $_ ) {

                        # don't descend in unknown directory
                        $File::Find::prune = 1;
                    }

                    # find_sub is defined per mode
                    $self->find_sub($_);
                }
            },
            follow   => 0,
            no_chdir => 1,
        },
        '/'
    );
}

# walk all users in the system.
sub walk_users($self) {

    # walk users
    while (
        my (
            $name,  $passwd, $uid,  $gid,   $quota,
            $class, $gecos,  $home, $shell, $expire
        )
        = getpwent()
      )
    {

        # only system users
        next if ( $uid >= 1000 );

        my $gname = getgrgid($gid);
        $gname = $gid if !defined($gname);
        my $user =
          join( ':',
            map { defined($_) ? $_ : '' }
              ( $name, $uid, $gname, $class, $home, $shell ) );
        my $user_gid =
          join( ':',
            map { defined($_) ? $_ : '' }
              ( $name, $uid, $gid, $class, $home, $shell ) );
        my $short = join( ':', ( $name, $uid ) );

        # an @user entry protects the account under every key form, even if a
        # field such as the group name or the shell changes later
        next
          if exists( $self->{ignored_users}{$user} )
          || exists( $self->{ignored_users}{$user_gid} )
          || exists( $self->{ignored_users}{$short} )
          || exists( $self->{ignored_user_names}{$name} );

        # expected as-is, checking both key forms used by @newuser
        next
          if exists( $self->{users}{$user} )
          || exists( $self->{users}{$user_gid} );

        if ( exists( $self->{users}{$short} ) ) {

            # user exists, but it seems modified, compare fields
            my @changed = ();
            my $uf      = $self->{user_fields}{$name} // {};
            push @changed, "gid is $gid, should be $uf->{gid}"
              if ( defined $uf->{gid} and $gid != $uf->{gid} );
            push @changed, "group is $gname, should be $uf->{group}"
              if ( defined $uf->{group} and $gname ne $uf->{group} );
            push @changed, "class is '$class', should be '$uf->{class}'"
              if ( defined $uf->{class} && $class ne $uf->{class} );
            push @changed, "homedir is $home, should be $uf->{home}"
              if ( defined $uf->{home} && $home ne $uf->{home} );
            push @changed, "shell is $shell, should be $uf->{shell}"
              if ( defined $uf->{shell} && $shell ne $uf->{shell} );

            if ( $self->{apply} ) {

                # apply the recommendations with usermod(8)
                $self->queue_user_mod(
                    $name, $uid,
                    $self->user_mod_args(
                        $uf, $gid, $gname, $class, $home, $shell
                    )
                );
            }
            elsif (@changed) {
                print( '@user ', $user,
                    " => ", join( ' / ', @changed ), "\n" );
            }
            next;
        }

        # The name is known to the reference but the uid differs.  Do not
        # delete or rewrite the account: it may be a different account that
        # reused an obsolete name.
        if ( exists( $self->{user_fields}{$name} ) ) {
            my $uf = $self->{user_fields}{$name};
            if ( !defined( $uf->{uid} ) || $uid != $uf->{uid} ) {
                if ( $self->{apply} ) {
                    $self->warning(
                        "not removing user '$name': uid $uid differs from reference"
                    );
                    $self->{removed}{failed}++;
                }
                else {
                    print( '@user ', $user, " => uid is $uid, should be ",
                        defined( $uf->{uid} ) ? $uf->{uid} : 'unknown', "\n" );
                }
                next;
            }

            # the name and uid match the reference; any remaining difference
            # is a key-format mismatch, not evidence of an obsolete account
            next;
        }

        # not expected user
        if ( $self->{apply} ) {
            $self->queue_user( $name, $uid );
        }
        else {
            print( '@user ', $user, "\n" );
        }
    }
    endpwent();
}

# walk all groups in the system.
sub walk_groups($self) {

    # walk groups
    while ( my ( $name, $passwd, $gid, $members ) = getgrent() ) {

        # only system groups
        next if ( $gid >= 1000 );

        my $group = join( ':', ( $name, $gid ) );

        next
          if exists( $self->{ignored_groups}{$group} )
          || exists( $self->{ignored_group_names}{$name} );

        next if exists( $self->{groups}{$group} );

        # A known group name with a different gid is not necessarily
        # obsolete.  Refuse to delete it; the administrator must resolve the
        # gid change explicitly.
        if ( exists( $self->{group_fields}{$name} ) ) {
            my $expected_gid = $self->{group_fields}{$name};
            if ( !defined($expected_gid) || $gid != $expected_gid ) {
                if ( $self->{apply} ) {
                    $self->warning(
                        "not removing group '$name': gid $gid differs from reference"
                    );
                    $self->{removed}{failed}++;
                }
                else {
                    print( '@group ', $group, " => gid is $gid, should be ",
                        defined($expected_gid) ? $expected_gid : 'unknown',
                        "\n" );
                }
                next;
            }

            # the name and gid match the reference; any remaining difference
            # is a key-format mismatch, not evidence of an obsolete group
            next;
        }

        # not expected group
        if ( $self->{apply} ) {
            $self->queue_group( $name, $gid );
        }
        else {
            print( '@group ', $group, "\n" );
        }
    }
    endgrent();
}

sub walk($self) {
    $self->walk_users;
    $self->walk_groups;
    $self->walk_filesystem;
}

#
# apply mode helpers
#

# record an element for later removal (only when apply mode is enabled)
sub queue_path( $self, $filename ) {
    return unless $self->{apply};
    push @{ $self->{actions} }, { type => 'path', name => $filename };
}

sub queue_user( $self, $name, $uid ) {
    return unless $self->{apply};
    push @{ $self->{actions} },
      { type => 'user', name => $name, uid => $uid };
}

sub queue_group( $self, $name, $gid ) {
    return unless $self->{apply};
    push @{ $self->{actions} },
      { type => 'group', name => $name, gid => $gid };
}

# record a modified user and the usermod(8) options to apply
sub queue_user_mod( $self, $name, $uid, @opts ) {
    return unless $self->{apply};
    return unless @opts;
    push @{ $self->{actions} },
      { type => 'user_mod', name => $name, uid => $uid, opts => [@opts] };
}

# build usermod(8) options restoring the expected fields of a modified user
sub user_mod_args( $self, $uf, $gid, $gname, $class, $home, $shell ) {
    my @opts = ();

    # primary group: prefer the expected group name over the numeric gid
    if (   ( defined $uf->{group} && $gname ne $uf->{group} )
        || ( defined $uf->{gid} && $gid != $uf->{gid} ) )
    {
        my $want = defined $uf->{group} ? $uf->{group} : $uf->{gid};
        push @opts, '-g', $want;
    }

    push @opts, '-L', $uf->{class}
      if ( defined $uf->{class} && $class ne $uf->{class} );
    push @opts, '-d', $uf->{home}
      if ( defined $uf->{home} && $home ne $uf->{home} );
    push @opts, '-s', $uf->{shell}
      if ( defined $uf->{shell} && $shell ne $uf->{shell} );

    return @opts;
}

# number of path separators, used to order removals deepest-first
sub path_depth($path) {
    my $depth = () = $path =~ m{/}g;
    return $depth;
}

sub sort_paths_deepest_first( $self, $paths ) {
    my @sorted =
      sort { path_depth($b) <=> path_depth($a) || $a cmp $b } @$paths;
    return @sorted;
}

# return true when an ancestor directory of $path is a symbolic link.
# unlinking the final component is safe, but following an attacker-controlled
# ancestor would redirect the operation outside the scanned tree.
sub path_has_symlink_ancestor( $self, $path ) {
    my $dir = dirname($path);
    while (1) {
        return 1 if -l $dir;
        last if $dir eq '/' || $dir eq '.';
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    return 0;
}

# return true when $path is inside an ignored directory.  walk_filesystem()
# already prunes those subtrees, but apply mode rechecks the property as a
# second line of defence.
sub path_has_ignored_ancestor( $self, $path ) {
    my $dir = dirname($path);
    while (1) {
        return 1 if exists $self->{ignored}{$dir};
        last if $dir eq '/' || $dir eq '.';
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    return 0;
}

# return a reason when $path must not be removed, undef otherwise
sub check_removable_path( $self, $path ) {
    return "empty pathname"           if ( !defined($path) || $path eq '' );
    return "not an absolute pathname" if ( $path !~ m{^/} );
    return "refusing to remove '/'"   if ( $path eq '/' );
    return "pathname contains a control character"
      if ( $path =~ /[\x00-\x1f\x7f]/ );
    return "pathname is not canonical"
      if ( $path =~ m{//|/\.(?:/|$)|/$} );
    return "pathname contains a '..' component"
      if ( $path =~ m{(?:^|/)\.\.(?:/|$)} );
    return "pathname is expected" if ( exists $self->{expected}{$path} );
    return "pathname is ignored"  if ( exists $self->{ignored}{$path} );
    return "pathname is inside an ignored directory"
      if $self->path_has_ignored_ancestor($path);
    return "pathname has a symbolic link component"
      if $self->path_has_symlink_ancestor($path);
    return;
}

# remove a single obsolete file, or an empty directory
sub remove_path( $self, $path ) {
    if ( my $reason = $self->check_removable_path($path) ) {
        $self->warning("not removing '$path': $reason");
        $self->{removed}{failed}++;
        return 0;
    }

    # use lstat(2) so that symbolic links are removed, not followed
    my @st = lstat($path);
    if ( !@st ) {
        $self->warning("lstat '$path': $!");
        $self->{removed}{failed}++;
        return 0;
    }

    if ( -d _ ) {

        # never recurse: only empty directories are removed
        if ( rmdir($path) ) {
            logi("rmdir $path");
            $self->{removed}{dirs}++;
            return 1;
        }
        $self->warning("rmdir '$path': $!");
        $self->{removed}{failed}++;
        return 0;
    }

    if ( unlink($path) ) {
        logi("unlink $path");
        $self->{removed}{files}++;
        return 1;
    }
    $self->warning("unlink '$path': $!");
    $self->{removed}{failed}++;
    return 0;
}

# a user/group name that is safe to pass to userdel(8)/groupdel(8)
sub valid_account_name($name) {

    # reject names starting with '-' to avoid option injection
    return defined($name) && $name =~ m{\A[A-Za-z0-9_][A-Za-z0-9._-]*\z};
}

# validate the option/value pairs produced by user_mod_args().  account
# metadata is trusted, but a malformed or compromised package must not be
# able to turn a value into an extra usermod(8) option.
sub valid_usermod_args {
    my (@opts) = @_;

    return 0 if @opts % 2;

    my %allowed = map { $_ => 1 } qw(-g -L -d -s);
    while (@opts) {
        my $opt = shift @opts;
        my $val = shift @opts;

        return 0 if !defined($opt) || !exists $allowed{$opt};
        return 0 if !defined($val);
        return 0 if $val =~ /[\x00-\x1f\x7f]/;
        return 0 if $val =~ /^-/;
        return 0 if $val eq '' && ( $opt eq '-g' || $opt eq '-d' );
    }
    return 1;
}

# re-read and re-check an account immediately before deleting it.  the scan
# and the helper invocation are separated by an arbitrary amount of time; a
# name could have been reused, or a reference file could have changed.
sub check_removable_user( $self, $name, $uid ) {
    return "invalid name" if !valid_account_name($name);

    my @pw = getpwnam($name);
    return "account no longer exists" if !@pw;

    my $current_uid = $pw[2];
    my $gid         = $pw[3];
    my $class       = $pw[5];
    my $home        = $pw[7];
    my $shell       = $pw[8];

    return "uid changed from $uid to $current_uid"
      if defined($uid) && $current_uid != $uid;

    my $gname = getgrgid($gid);
    $gname = $gid if !defined($gname);
    my $user =
      join( ':',
        map { defined($_) ? $_ : '' }
          ( $name, $current_uid, $gname, $class, $home, $shell ) );
    my $user_gid =
      join( ':',
        map { defined($_) ? $_ : '' }
          ( $name, $current_uid, $gid, $class, $home, $shell ) );
    my $short = join( ':', ( $name, $current_uid ) );

    return "user is expected"
      if exists $self->{users}{$user}
      || exists $self->{users}{$user_gid}
      || exists $self->{users}{$short}
      || exists $self->{user_fields}{$name};

    return "user is ignored"
      if exists $self->{ignored_users}{$user}
      || exists $self->{ignored_users}{$user_gid}
      || exists $self->{ignored_users}{$short}
      || exists $self->{ignored_user_names}{$name};

    return;
}

sub check_removable_group( $self, $name, $gid ) {
    return "invalid name" if !valid_account_name($name);

    my @gr = getgrnam($name);
    return "group no longer exists" if !@gr;

    my $current_gid = $gr[2];
    return "gid changed from $gid to $current_gid"
      if defined($gid) && $current_gid != $gid;

    my $group = join( ':', ( $name, $current_gid ) );

    return "group is expected"
      if exists $self->{groups}{$group}
      || exists $self->{group_fields}{$name};

    return "group is ignored"
      if exists $self->{ignored_groups}{$group}
      || exists $self->{ignored_group_names}{$name};

    return;
}

# remove an obsolete user with userdel(8); the home directory is preserved
sub remove_user( $self, $name, $uid ) {
    if ( my $reason = $self->check_removable_user( $name, $uid ) ) {
        $self->warning("not removing user '$name': $reason");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( !-x '/usr/sbin/userdel' ) {
        $self->warning("not removing user '$name': /usr/sbin/userdel missing");
        $self->{removed}{failed}++;
        return 0;
    }

    if ( system( '/usr/sbin/userdel', $name ) == 0 ) {
        logi("userdel $name");
        $self->{removed}{users}++;
        return 1;
    }
    $self->warning("userdel '$name' failed");
    $self->{removed}{failed}++;
    return 0;
}

# remove an obsolete group with groupdel(8)
sub remove_group( $self, $name, $gid ) {
    if ( my $reason = $self->check_removable_group( $name, $gid ) ) {
        $self->warning("not removing group '$name': $reason");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( !-x '/usr/sbin/groupdel' ) {
        $self->warning(
            "not removing group '$name': /usr/sbin/groupdel missing");
        $self->{removed}{failed}++;
        return 0;
    }

    if ( system( '/usr/sbin/groupdel', $name ) == 0 ) {
        logi("groupdel $name");
        $self->{removed}{groups}++;
        return 1;
    }
    $self->warning("groupdel '$name' failed");
    $self->{removed}{failed}++;
    return 0;
}

# apply the recommended changes to a modified system user with usermod(8)
sub modify_user( $self, $name, $opts, $uid ) {
    if ( !valid_account_name($name) ) {
        $self->warning("not modifying user '$name': invalid name");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( !valid_usermod_args(@$opts) ) {
        $self->warning("not modifying user '$name': invalid usermod arguments");
        $self->{removed}{failed}++;
        return 0;
    }

    my @pw = getpwnam($name);
    if ( !@pw ) {
        $self->warning("not modifying user '$name': account no longer exists");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( defined($uid) && $pw[2] != $uid ) {
        $self->warning(
            "not modifying user '$name': uid changed from $uid to $pw[2]");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( !exists $self->{user_fields}{$name} ) {
        $self->warning(
            "not modifying user '$name': no reference entry available");
        $self->{removed}{failed}++;
        return 0;
    }
    if ( !-x '/usr/sbin/usermod' ) {
        $self->warning("not modifying user '$name': /usr/sbin/usermod missing");
        $self->{removed}{failed}++;
        return 0;
    }

    if ( system( '/usr/sbin/usermod', @$opts, $name ) == 0 ) {
        logi("usermod $name");
        $self->{removed}{modified}++;
        return 1;
    }
    $self->warning("usermod '$name' failed");
    $self->{removed}{failed}++;
    return 0;
}

# tighten the sandbox just before applying changes
sub prepare_apply( $self, $paths, $users, $groups, $user_mods ) {

    # Validate every path before granting write access.  A path that is going
    # to be refused must not cause unveil(2) to open its parent directory.
    my @valid = ();
    for my $path (@$paths) {
        my $reason = $self->check_removable_path($path);
        if ( defined($reason) ) {
            $self->warning("not removing '$path': $reason");
            $self->{removed}{failed}++;
            next;
        }
        push( @valid, $path );
    }
    @$paths = @valid;

    # grant write access only to the directories holding targeted paths
    my %dirs = ();
    for my $path (@$paths) {
        $dirs{ dirname($path) } = 1;
    }
    for my $dir ( sort keys %dirs ) {
        unveil( $dir, 'rwc' )
          || $self->err( 1, "unveil '$dir': $!" );
    }

    my $promises = 'rpath wpath cpath getpw';
    my $accounts = scalar(@$users) + scalar(@$groups) + scalar(@$user_mods);

    if ( $accounts > 0 ) {
        $promises .= ' proc exec';

        # userdel(8), groupdel(8) and usermod(8) run as child processes.
        # Check that they exist before any path is removed, so that a missing
        # helper cannot leave the cleanup half-applied.
        if ( scalar(@$users) ) {
            $self->err( 1, "missing /usr/sbin/userdel" )
              if !-x '/usr/sbin/userdel';
            unveil( '/usr/sbin/userdel', 'rx' )
              || $self->err( 1, "unveil '/usr/sbin/userdel': $!" );
        }
        if ( scalar(@$groups) ) {
            $self->err( 1, "missing /usr/sbin/groupdel" )
              if !-x '/usr/sbin/groupdel';
            unveil( '/usr/sbin/groupdel', 'rx' )
              || $self->err( 1, "unveil '/usr/sbin/groupdel': $!" );
        }
        if ( scalar(@$user_mods) ) {
            $self->err( 1, "missing /usr/sbin/usermod" )
              if !-x '/usr/sbin/usermod';
            unveil( '/usr/sbin/usermod', 'rx' )
              || $self->err( 1, "unveil '/usr/sbin/usermod': $!" );
        }
    }

    # no further unveil(2) calls are allowed after this point
    unveil() || $self->err( 1, "unveil lock: $!" );
    pledge($promises) || $self->err( 1, "pledge" );
    return 1;
}

sub apply($self) {
    my @paths = map { $_->{name} }
      grep { $_->{type} eq 'path' } @{ $self->{actions} };
    my @users = grep { $_->{type} eq 'user' } @{ $self->{actions} };
    my @groups = grep { $_->{type} eq 'group' } @{ $self->{actions} };
    my @user_mods =
      grep { $_->{type} eq 'user_mod' } @{ $self->{actions} };

    # drop duplicate entries, preserving order
    my %seen = ();
    @paths = grep { !$seen{"p\0$_"}++ } @paths;
    %seen  = ();
    @users = grep {
        !$seen{ join( "\0", 'u', $_->{name}, $_->{uid} // '' ) }++
    } @users;
    %seen = ();
    @groups = grep {
        !$seen{ join( "\0", 'g', $_->{name}, $_->{gid} // '' ) }++
    } @groups;
    %seen = ();
    @user_mods = grep {
        !$seen{ join( "\0", 'm', $_->{name}, $_->{uid} // '' ) }++
    } @user_mods;

    $self->prepare_apply( \@paths, \@users, \@groups, \@user_mods );

    for my $path ( $self->sort_paths_deepest_first( \@paths ) ) {
        $self->remove_path($path);
    }
    for my $action (@users) {
        $self->remove_user( $action->{name}, $action->{uid} );
    }
    for my $action (@groups) {
        $self->remove_group( $action->{name}, $action->{gid} );
    }
    for my $m (@user_mods) {
        $self->modify_user( $m->{name}, $m->{opts}, $m->{uid} );
    }

    my $r = $self->{removed};
    $self->note(
        sprintf(
"removed %d file(s), %d director%s, %d user(s), %d group(s), %d modified user(s); %d failure(s)",
            $r->{files},                   $r->{dirs},
            $r->{dirs} == 1 ? "y" : "ies", $r->{users},
            $r->{groups},                  $r->{modified},
            $r->{failed}
        )
    );
    return $r->{failed} ? 1 : 0;
}

#
# specialized versions
#

package sysclean::allfiles;
use parent -norequire, qw(sysclean);

sub find_sub( $self, $filename ) {
    # -a is an all-files listing, but apply mode must not remove a library
    # that an installed package still uses.  Keep the listing behavior in
    # read-only mode and refuse the removal here.
    if ( $self->{apply}
        && $filename =~ m|/lib([^/]*)\.so(\.\d+\.\d+)$|
        && $self->{used_libs}
        && exists $self->{used_libs}{"$1$2"} )
    {
        $self->warning(
            "not removing library used by installed packages: $filename");
        return;
    }

    $self->queue_path($filename);
    print( $filename, "\n" ) unless $self->{apply};
}

package sysclean::files;
use parent -norequire, qw(sysclean);

use OpenBSD::LibSpec;

sub add_expected_base_one( $self, $filename ) {
    $self->SUPER::add_expected_base_one($filename);

    # track libraries (should not contains duplicate)
    if ( $filename =~ m|/lib([^/]+)\.so\.\d+\.\d+$|o ) {
        my $lib = OpenBSD::Library->from_string($filename);
        $self->{libs}{$1} = $lib if defined($lib);
    }
}

sub find_sub( $self, $filename ) {
    if ( $filename =~ m|/lib([^/]*)\.so(\.\d+\.\d+)$|o ) {

        if ( $self->{used_libs}
            && exists( $self->{used_libs}{"$1$2"} ) )
        {

            # skip used-libs (from ports)
            return;
        }

        if ( $self->{libs} && exists( $self->{libs}{$1} ) ) {

            # skip if file from expected is not better than current
            my $expectedlib = $self->{libs}{$1};
            my $currentlib  = OpenBSD::Library->from_string($filename);

            if ( defined($currentlib)
                && $currentlib->is_better($expectedlib) )
            {
                $self->warning("discard better version: $filename");
                return;
            }
        }
    }

    $self->queue_path($filename);
    print( $filename, "\n" ) unless $self->{apply};
}

package sysclean::packages;
use parent -norequire, qw(sysclean);

sub add_expected_rcctl($self) {

    # skip add_expected_rcctl: it shouldn't contain libraries
}

sub add_expected_users($self) {

    # skip add_expected_users
}

sub plist_reader($self) {
    return \&OpenBSD::PackingList::DependOnly;
}

sub walk($self) {
    $self->walk_filesystem;
}

sub find_sub( $self, $filename ) {
    if ( $filename =~ m|/lib([^/]*)\.so(\.\d+\.\d+)$|o ) {
        my $wantlib = "$1$2";

        for my $pkgname (
            @{ ( $self->{used_libs} // {} )->{$wantlib} // [] } )
        {
            print( $filename, "\t", $pkgname, "\n" );
        }
    }
}

#
# extent OpenBSD::PackingElement for walking
#

package OpenBSD::PackingElement;

sub walk_sysclean( $item, $pkgname, $sc ) {
}

# pkg_add(1) uses a leading '!' in PLIST account fields to mark a value that
# must not be changed.  Strip it so that the reference key matches the
# account database instead of creating a key that can never match.
sub pkg_account_value {
    my ($value) = @_;
    return undef if !defined($value);
    $value =~ s/^!//;
    return $value;
}

package OpenBSD::PackingElement::Cwd;

sub walk_sysclean( $item, $pkgname, $sc ) {
    use File::Basename;

    my $path = $item->name;
    $path =~ s{//+}{/}g if defined($path);
    $path =~ s{/+$}{} if defined($path) && $path ne '/';
    return if !defined($path) || !length($path) || $path !~ m{^/};

    do {
        $sc->{expected}{$path} = 1;
        $path = dirname($path);
    } while ( $path ne "/" );
}

package OpenBSD::PackingElement::FileObject;

sub walk_sysclean( $item, $pkgname, $sc ) {
    my $filename = $item->fullname;
    return if !defined($filename) || !length($filename);
    return if $filename !~ m{^/};

    # link: /usr/local/lib/X11/app-defaults/ -> /etc/X11/app-defaults/
    $filename =~ s|^/usr/local/lib/X11/app-defaults/|/etc/X11/app-defaults/|o;
    $filename =~ s{//+}{/}g;
    $filename =~ s{/+$}{} if $filename ne '/';

    $sc->{expected}{$filename} = 1;
}

package OpenBSD::PackingElement::NewGroup;

sub walk_sysclean( $item, $pkgname, $sc ) {
    my $name = OpenBSD::PackingElement::pkg_account_value( $item->{name} );
    my $gid  = OpenBSD::PackingElement::pkg_account_value( $item->{gid} );

    return if !defined($name) || !length($name);
    $gid = undef if defined($gid) && $gid !~ m{^\d+$};

    my $group = join( ':', $name, defined($gid) ? $gid : '' );

    $sc->{groups}{$group}      = 1;
    $sc->{group_fields}{$name} = $gid;
}

package OpenBSD::PackingElement::NewUser;

sub walk_sysclean( $item, $pkgname, $sc ) {
    my %field = ();
    for my $key (qw(name uid group class home shell)) {
        $field{$key} =
          OpenBSD::PackingElement::pkg_account_value( $item->{$key} );
    }

    return if !defined( $field{name} ) || !length( $field{name} );
    $field{uid} = undef
      if defined( $field{uid} ) && $field{uid} !~ m{^\d+$};

    my $user =
      join( ':', map { defined( $field{$_} ) ? $field{$_} : '' }
          qw(name uid group class home shell) );
    my $short =
      join( ':', map { defined( $field{$_} ) ? $field{$_} : '' }
          qw(name uid) );

    $sc->{users}{$user}  = 1;
    $sc->{users}{$short} = 1;
    $sc->{user_fields}{ $field{name} } = {
        uid   => $field{uid},
        class => $field{class},
        home  => $field{home},
        shell => $field{shell},
    };

    # sometimes, the group field in the PLIST is a gid, sometimes a groupname...
    if ( defined( $field{group} ) && $field{group} =~ m|^\d+$| ) {
        $sc->{user_fields}{ $field{name} }{gid} = $field{group};
    }
    else {
        $sc->{user_fields}{ $field{name} }{group} = $field{group};
    }
}

package OpenBSD::PackingElement::Sampledir;

sub walk_sysclean( $item, $pkgname, $sc ) {
    my $filename = $item->fullname;
    return if !defined($filename) || !length($filename);
    return if $filename !~ m{^/};
    $filename =~ s{//+}{/}g;
    $filename =~ s{/+$}{} if $filename ne '/';
    $sc->{ignored}{$filename} = 1;
}

package OpenBSD::PackingElement::Wantlib;

sub walk_sysclean( $item, $pkgname, $sc ) {
    push( @{ $sc->{used_libs}{ $item->name } }, $pkgname );
}

#
# main program
#
package main;

use Getopt::Std;

sub main {
    my %options = ();    # program flags

    getopts( "apihx", \%options ) || sysclean->usage;
    sysclean->usage if ( defined $options{h} || scalar(@ARGV) != 0 );

    sysclean->err( 1, "need root privileges" ) if ( $> != 0 );

    my $sysclean = sysclean->create( \%options );
    $sysclean->walk;

    if ( $sysclean->{apply} ) {
        my $failed = $sysclean->apply;
        exit 1 if $failed;
    }

    return 0;
}

# allow the script to be loaded by the regression tests without running the
# destructive main program
main() unless caller;

1;
