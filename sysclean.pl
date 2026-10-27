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

# Join log arguments and escape terminal control characters. This keeps a
# filename containing newlines or escape bytes from forging additional log
# output; it does not change the pathname used by filesystem operations.
sub sanitize_log {
    my $msg = join( ' ', @_ );
    $msg =~ s/([\x00-\x1f\x7f])/sprintf("\\x%02x", ord($1))/ge;
    return $msg;
}

# Keep informational and warning messages on their established output
# streams, and pass all message text through the same terminal-safe formatter.
sub logi { print "[INFO] ", sanitize_log(@_), "\n" }
sub logw { print STDERR "[WARN] ", sanitize_log(@_), "\n" }

# Emit one sanitized fatal diagnostic and terminate with the caller's status.
sub die_tool {
    my ( $exitcode, @msg ) = @_;
    print STDERR "[ERROR] ", sanitize_log(@msg), "\n";
    exit $exitcode;
}

# Select the scanner policy: -a includes every unexpected path, -p reports
# obsolete libraries with package consumers, and the default filters libraries.
sub subclass( $self, $options ) {
    return 'sysclean::allfiles' if ( defined $$options{a} );
    return 'sysclean::packages' if ( defined $$options{p} );
    return 'sysclean::files';
}

# Validate incompatible mode combinations, derive whether user ignore files
# participate, and construct the selected scanner. In apply mode, -i means
# honor those files; in read-only mode it means omit them.
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
        "-x with -a: recognized used libraries are protected from removal")
      if ( $apply && defined $$options{a} );

    return $base->subclass($options)->new( $with_ignored, $apply );
}

# Initialize all inventories and apply counters before loading references.
# The hashes are sets keyed by exact path/account forms; actions are deferred
# until the scan has completed so discovery remains separate from mutation.
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

# Print the accepted option shape and exit with a usage failure.
sub usage($self) {
    print "usage: $0 [ -a | -p ] [-i] [-x]\n";
    exit 1;
}

# Route fatal scanner errors through the common sanitized diagnostic helper.
sub err( $self, $exitcode, @rest ) {
    die_tool( $exitcode, @rest );
}

# Report a recoverable issue on stderr without changing the failure count.
sub warning( $self, @rest ) {
    logw("@rest");
}

# Report progress on stdout using the common sanitized formatter.
sub note( $self, @rest ) {
    logi("@rest");
}

# Seed exact protected paths and subtrees that are local, writable, generated,
# or otherwise outside the reference inventory. Directory entries also prune
# their descendants during File::Find traversal.
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

# Load OpenBSD interfaces, establish the initial filesystem view, and build
# reference inventories. Read-only mode installs its syscall ceiling only
# after external helpers have completed; apply mode tightens it later.
sub init($self) {
    use OpenBSD::PackageInfo;
    use OpenBSD::Pledge;
    use OpenBSD::Unveil;

    # The scan invokes helpers before a syscall ceiling can be installed.
    # Apply mode may also invoke account helpers later; keep it unpledged
    # during the scan and install the ceiling in prepare_apply().
    eval { lock_db(1) };
    $self->err( 1, "can't lock package database: $@" ) if $@;

    unveil( '/',            'r' ) || $self->err( 1, "unveil '/': $!" );
    unveil( '/dev/MAKEDEV', 'rx' )
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

# Build the base expected-path set from fixed paths, hostnames, and locate
# data. Initialization adds device, service, account, and package references
# afterward; subclasses may specialize individual source methods.
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

    # The source database is required; the X database is optional on systems
    # without X. Locate output is normalized before it becomes an exact key.
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

        # Collapse repeated separators and remove a trailing slash so locate
        # results use the same exact-path form as File::Find.
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

# Add one normalized base path. The files-mode subclass also records reference
# shared-library versions here, so callers must use this dispatch point.
sub add_expected_base_one( $self, $filename ) {
    $self->{expected}{$filename} = 1;
}

# Ask MAKEDEV to print its planned commands, then interpret only the command
# forms needed to discover device names. The helper is run with eo=echo, so its
# output is parsed rather than executed by this method.
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

        # Normalize the shell-style separators emitted by MAKEDEV to a single
        # delimiter before splitting; this code parses names and runs no output.
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

# Map enabled rcctl service names to their known generated files or protected
# runtime trees. Unknown service names add nothing; a failed listing is fatal
# in apply mode because it would make the expected inventory incomplete.
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
        $self->err( 1,
            "rcctl failed; refusing to apply an incomplete service list" )
          if $self->{apply};
        $self->warning("rcctl failed; service inventory may be incomplete");
    }
}

# Read the reference master.passwd and group files from sysmerge's archive.
# The resulting sets support exact account matching, while field hashes retain
# the reference values needed to identify modified accounts and uid/gid reuse.
sub add_expected_users($self) {
    use Archive::Tar;

    my $tar = Archive::Tar->new();
    $tar->read( '/var/sysmerge/etc.tgz', COMPRESS_GZIP )
      || $self->err( 1, "can't read /var/sysmerge/etc.tgz" );

    # Build both the expected group keys and the gid-to-name lookup needed to
    # turn master.passwd primary gids into comparable group names.
    my %groups = ();
    my $group  = $tar->get_content('./etc/group');
    $group = $tar->get_content('etc/group') if !defined($group);
    my $group_entries = 0;
    $self->err( 1, "missing ./etc/group in /var/sysmerge/etc.tgz" )
      if !defined($group) || !length($group);

    foreach my $entry ( grep { length } split( /\n/, $group ) ) {
        my ( $name, $passwd, $gid, $members ) = split( /:/, $entry, -1 );
        next if !defined($name) || !length($name);
        next if !defined($gid)  || !length($gid);
        $self->err( 1, "invalid gid for group '$name' in etc.tgz" )
          if $gid !~ m{^\d+$};
        my $group_key = join( ':', ( $name, $gid ) );

        $groups{$gid}                = $name;
        $self->{groups}{$group_key}  = 1;
        $self->{group_fields}{$name} = $gid;
        $group_entries++;
    }
    $self->err( 1, "empty ./etc/group in /var/sysmerge/etc.tgz" )
      if $group_entries == 0;

    # Store a full comparison key plus name:uid. The short key distinguishes a
    # modified account from an account absent from the reference altogether.
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
        next if !defined($uid)  || !length($uid);
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

# Walk installed package packing lists through mode-specific readers and
# element handlers. Partial packages and unreadable lists make the reference
# incomplete, so apply mode stops instead of treating missing entries as stale.
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
# Return the base PLIST line filter. It forwards recognized annotations and
# ordinary entries to the parser callback, while dropping unsupported
# annotation lines before the PackingList walker sees them.
sub plist_reader($self) {
    return sub ( $fh, $cont ) {
        while (<$fh>) {

            # Keep ordinary PLIST lines and only the annotations recognized by
            # the walker; the second match distinguishes annotations from files.
            next
              if !
m/^\@(?:cwd|name|info|fontdir|man|mandir|file|dir|lib|shell|so|static-lib|extra|sample|bin|rcscript|wantlib|newuser|newgroup)\b/o
              && m/^\@/o;
            &$cont($_);
        }
    }
}

# Load path and account exclusions from changelist-compatible configuration.
# Top-level files may be absent, but included files are required: ignoring a
# failed include could silently remove an administrator-configured safeguard.
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

        # Strip whole-line comments and comments preceded by whitespace. A '#'
        # attached directly to a path remains part of that path.
        s/^\s*#.*$//;
        s/\s+#.*$//;
        next if (m/^\s*$/o);

        # Capture the quoted include path as one argument; the anchored match
        # rejects trailing non-whitespace text after the closing quote.
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

# Traverse from / without following symlinks or changing the process directory.
# Ignored paths prune immediately; unexpected directories are reported as one
# candidate and pruned, so the expected set must include legitimate ancestors.
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

# Compare system accounts below uid 1000 with the reference and ignore sets.
# Matching name:uid accounts can produce field recommendations; a reused name
# with a different uid is reported/refused instead of being treated as stale.
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
        my $user = join( ':',
            map { defined($_) ? $_ : '' }
              ( $name, $uid, $gname, $class, $home, $shell ) );
        my $user_gid = join( ':',
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
                print( '@user ', $user, " => ", join( ' / ', @changed ), "\n" );
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
                    print(
                        '@user ', $user,
                        " => uid is $uid, should be ",
                        defined( $uf->{uid} ) ? $uf->{uid} : 'unknown', "\n"
                    );
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

# Compare groups below gid 1000 with reference keys. A familiar name with a
# different gid is protected from deletion because it may identify a new group.
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
                    print(
                        '@group ', $group,
                        " => gid is $gid, should be ",
                        defined($expected_gid) ? $expected_gid : 'unknown',
                        "\n"
                    );
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

# Run account checks before filesystem traversal; in apply mode this only
# records candidates and does not invoke account helpers or remove paths.
sub walk($self) {
    $self->walk_users;
    $self->walk_groups;
    $self->walk_filesystem;
}

#
# apply mode helpers
#

# Record exact candidates for the later apply phase. These helpers are inert
# in read-only mode, keeping the scanner's listing behavior non-mutating.
sub queue_path( $self, $filename ) {
    return unless $self->{apply};
    push @{ $self->{actions} }, { type => 'path', name => $filename };
}

# Preserve the observed uid/gid alongside the name so apply can detect account
# reuse between scanning and helper invocation.
sub queue_user( $self, $name, $uid ) {
    return unless $self->{apply};
    push @{ $self->{actions} }, { type => 'user', name => $name, uid => $uid };
}

# Preserve the observed group id for the same revalidation performed before
# groupdel(8).
sub queue_group( $self, $name, $gid ) {
    return unless $self->{apply};
    push @{ $self->{actions} }, { type => 'group', name => $name, gid => $gid };
}

# Queue a changed user only when there is at least one concrete option pair;
# the copied array reference keeps the action independent of the local list.
sub queue_user_mod( $self, $name, $uid, @opts ) {
    return unless $self->{apply};
    return unless @opts;
    push @{ $self->{actions} },
      { type => 'user_mod', name => $name, uid => $uid, opts => [@opts] };
}

# Translate differing reference fields into the supported usermod option/value
# pairs. Undefined reference fields are left untouched rather than guessed.
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

# Count separators as a simple depth measure for ordering paths from the
# deepest candidate to its ancestors.
sub path_depth($path) {
    my $depth = () = $path =~ m{/}g;
    return $depth;
}

# Return a sorted copy rather than mutating the caller's action list; equal
# depths use lexical order for deterministic processing.
sub sort_paths_deepest_first( $self, $paths ) {
    my @sorted =
      sort { path_depth($b) <=> path_depth($a) || $a cmp $b } @$paths;
    return @sorted;
}

# Check every parent component, excluding the final component. The final
# component is handled with lstat/unlink, while a symlinked ancestor could
# redirect an operation to a different tree.
sub path_has_symlink_ancestor( $self, $path ) {
    my $dir = dirname($path);
    while (1) {
        return 1 if -l $dir;
        last     if $dir eq '/' || $dir eq '.';
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    return 0;
}

# Check parent directories against the ignored set. Traversal already prunes
# these trees, but apply mode repeats the check on queued exact paths.
sub path_has_ignored_ancestor( $self, $path ) {
    my $dir = dirname($path);
    while (1) {
        return 1 if exists $self->{ignored}{$dir};
        last     if $dir eq '/' || $dir eq '.';
        my $parent = dirname($dir);
        last if $parent eq $dir;
        $dir = $parent;
    }
    return 0;
}

# Validate the exact candidate before any write permission is granted and
# again before removal. The returned reason is used for both diagnostics and
# failure accounting; undef means only that these checks passed.
sub check_removable_path( $self, $path ) {

    # These whole-path patterns reject duplicate separators, dot components,
    # and trailing separators before the path can be used as an action key.
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

# Remove one non-directory entry or one empty directory. lstat and the cached
# stat buffer distinguish a symlink-to-directory from a directory; no branch
# recursively descends, and every failed check or syscall increments failures.
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

# Accept only account names whose first character cannot be an option prefix
# and whose remaining characters match the account-name allowlist.
sub valid_account_name($name) {

    # reject names starting with '-' to avoid option injection
    return defined($name) && $name =~ m{\A[A-Za-z0-9_][A-Za-z0-9._-]*\z};
}

# Validate even package-derived option pairs at the helper boundary. Values
# beginning with '-' could otherwise be parsed as additional usermod options.
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

# Re-read the account immediately before deletion, then compare its current
# identity and all reference/ignore key forms. This narrows the scan-to-helper
# race but does not make the check and external command atomic.
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
    my $user = join( ':',
        map { defined($_) ? $_ : '' }
          ( $name, $current_uid, $gname, $class, $home, $shell ) );
    my $user_gid = join( ':',
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

# Re-read and validate the group name and gid immediately before groupdel(8),
# refusing current reference or ignore matches.
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

# Revalidate and invoke userdel in list form. Omitting -r preserves the home
# directory; helper failure is recorded for the final apply status.
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

# Revalidate and invoke groupdel in list form, recording any refusal or failure.
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

# Validate identity and option pairs, confirm the account still has its queued
# uid and a reference record, then apply the list-form usermod command.
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

# Validate paths before granting parent-directory write access, unveil only
# required account helpers, lock the view, and install the apply syscall set.
# Helper children are not confined by this parent's pledge/unveil state.
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
    unveil()          || $self->err( 1, "unveil lock: $!" );
    pledge($promises) || $self->err( 1, "pledge" );
    return 1;
}

# Split and deduplicate the recorded actions, prepare the sandbox, then perform
# paths, users, groups, and user modifications in that order. There is no
# rollback: a later failure can follow earlier successful changes.
sub apply($self) {
    my @paths = map { $_->{name} }
      grep { $_->{type} eq 'path' } @{ $self->{actions} };
    my @users  = grep { $_->{type} eq 'user' } @{ $self->{actions} };
    my @groups = grep { $_->{type} eq 'group' } @{ $self->{actions} };
    my @user_mods =
      grep { $_->{type} eq 'user_mod' } @{ $self->{actions} };

    # drop duplicate entries, preserving order
    my %seen = ();
    @paths = grep { !$seen{"p\0$_"}++ } @paths;
    %seen  = ();
    @users = grep { !$seen{ join( "\0", 'u', $_->{name}, $_->{uid} // '' ) }++ }
      @users;
    %seen = ();
    @groups =
      grep { !$seen{ join( "\0", 'g', $_->{name}, $_->{gid} // '' ) }++ }
      @groups;
    %seen = ();
    @user_mods =
      grep { !$seen{ join( "\0", 'm', $_->{name}, $_->{uid} // '' ) }++ }
      @user_mods;

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

# List every unexpected path in read-only mode. Apply mode adds one narrow
# library-name check so recognized package-used libraries are not queued.
sub find_sub( $self, $filename ) {

    # -a is an all-files listing, but apply mode must not remove a library
    # that an installed package still uses.  Keep the listing behavior in
    # read-only mode and refuse the removal here.
    if (   $self->{apply}
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

# Record base shared-library objects by stem so find_sub can compare an
# unexpected version with the reference version using OpenBSD::Library.
sub add_expected_base_one( $self, $filename ) {
    $self->SUPER::add_expected_base_one($filename);

    # Capture the library stem from base filenames ending in numeric
    # major/minor components; the suffix is not part of the stem key.
    if ( $filename =~ m|/lib([^/]+)\.so\.\d+\.\d+$|o ) {
        my $lib = OpenBSD::Library->from_string($filename);
        $self->{libs}{$1} = $lib if defined($lib);
    }
}

# Filter unexpected library paths in two stages: package consumers first,
# then a newer local ABI version. The pattern captures the library stem and
# numeric major/minor suffix used as the {used_libs} key.
sub find_sub( $self, $filename ) {

    # Capture the stem and the complete .so.major.minor suffix so this key
    # matches the format stored by Wantlib elements.
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

# Package mode omits service-generated paths because this mode only reports
# obsolete libraries and their package consumers.
sub add_expected_rcctl($self) {

    # skip add_expected_rcctl: it shouldn't contain libraries
}

# Package mode does not compare system accounts.
sub add_expected_users($self) {

    # skip add_expected_users
}

# DependOnly limits package parsing to dependency annotations such as wantlib.
sub plist_reader($self) {
    return \&OpenBSD::PackingList::DependOnly;
}

# Package mode needs the filesystem candidates but does not walk accounts.
sub walk($self) {
    $self->walk_filesystem;
}

# Match shared-library filenames, derive the same stem/version key populated
# by Wantlib elements, and emit one filename/package row per recorded consumer.
sub find_sub( $self, $filename ) {

    # Use the same stem/suffix split as default mode to look up package users.
    if ( $filename =~ m|/lib([^/]*)\.so(\.\d+\.\d+)$|o ) {
        my $wantlib = "$1$2";

        for my $pkgname ( @{ ( $self->{used_libs} // {} )->{$wantlib} // [] } )
        {
            print( $filename, "\t", $pkgname, "\n" );
        }
    }
}

#
# extent OpenBSD::PackingElement for walking
#

package OpenBSD::PackingElement;

# Base dispatch hook for PLIST element classes with no sysclean inventory data.
sub walk_sysclean( $item, $pkgname, $sc ) {
}

# pkg_add(1) uses a leading '!' in PLIST account fields to mark a value that
# must not be changed.  Strip it so that the reference key matches the
# account database instead of creating a key that can never match.
# Remove the package-format marker that means a field is not to be changed;
# undefined values remain undefined for later partial-field comparisons.
sub pkg_account_value {
    my ($value) = @_;
    return undef if !defined($value);    ## no critic (Subroutines::ProhibitExplicitReturnUndef)
    $value =~ s/^!//;
    return $value;
}

package OpenBSD::PackingElement::Cwd;

# Add a package working directory and every ancestor up to /, since the
# filesystem walk prunes unknown directories rather than descending into them.
sub walk_sysclean( $item, $pkgname, $sc ) {
    use File::Basename;

    my $path = $item->name;
    $path =~ s{//+}{/}g if defined($path);
    $path =~ s{/+$}{}   if defined($path) && $path ne '/';
    return if !defined($path) || !length($path) || $path !~ m{^/};

    do {
        $sc->{expected}{$path} = 1;
        $path = dirname($path);
    } while ( $path ne "/" );
}

package OpenBSD::PackingElement::FileObject;

# Add one absolute package path to the expected set. Normalize path separators
# and map the historical X11 app-defaults location to its system destination.
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

# Store package-provided group keys and reference gids. Non-numeric gids are
# retained as unknown rather than used as numeric identity data.
sub walk_sysclean( $item, $pkgname, $sc ) {
    my $name = OpenBSD::PackingElement::pkg_account_value( $item->{name} );
    my $gid  = OpenBSD::PackingElement::pkg_account_value( $item->{gid} );

    return       if !defined($name) || !length($name);
    $gid = undef if defined($gid) && $gid !~ m{^\d+$};

    my $group = join( ':', $name, defined($gid) ? $gid : '' );

    $sc->{groups}{$group}      = 1;
    $sc->{group_fields}{$name} = $gid;
}

package OpenBSD::PackingElement::NewUser;

# Store both full and name:uid keys, plus individually available reference
# fields. PLIST group values may be either names or numeric gids.
sub walk_sysclean( $item, $pkgname, $sc ) {
    my %field = ();
    for my $key (qw(name uid group class home shell)) {
        $field{$key} =
          OpenBSD::PackingElement::pkg_account_value( $item->{$key} );
    }

    return if !defined( $field{name} ) || !length( $field{name} );
    $field{uid} = undef
      if defined( $field{uid} ) && $field{uid} !~ m{^\d+$};

    my $user = join( ':',
        map { defined( $field{$_} ) ? $field{$_} : '' }
          qw(name uid group class home shell) );
    my $short =
      join( ':', map { defined( $field{$_} ) ? $field{$_} : '' } qw(name uid) );

    $sc->{users}{$user}                = 1;
    $sc->{users}{$short}               = 1;
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

# Protect the package's sample directory from both traversal and later apply
# validation; sample contents are intended for local administrator use.
sub walk_sysclean( $item, $pkgname, $sc ) {
    my $filename = $item->fullname;
    return if !defined($filename) || !length($filename);
    return if $filename !~ m{^/};
    $filename =~ s{//+}{/}g;
    $filename =~ s{/+$}{} if $filename ne '/';
    $sc->{ignored}{$filename} = 1;
}

package OpenBSD::PackingElement::Wantlib;

# Record the package consumer under the exact library key used by the scanner's
# filename matching logic; multiple packages may append to the same array.
sub walk_sysclean( $item, $pkgname, $sc ) {
    push( @{ $sc->{used_libs}{ $item->name } }, $pkgname );
}

#
# main program
#
package main;

use Getopt::Std;

# Parse flags, require root, build the selected scanner, and run its inventory.
# Only an explicit -x reaches apply(); its nonzero failure result becomes the
# process exit status.
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
