# buildd: daemon to automatically build packages
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Buildd::Daemon;

use strict;
use warnings;

use POSIX;
use Buildd qw(isin lock_file unlock_file send_mail exitstatus);
use Buildd::Conf qw();
use Buildd::Base;
use Sbuild qw($devnull df);
use Sbuild::Sysconfig;
use Sbuild::ChrootRoot;
use Buildd::Client;
use Cwd;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Buildd::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Daemon', 0);

    return $self;
}

sub ST_MTIME () { 9 }

sub run {
    my $self = shift;

    my $host = Sbuild::ChrootRoot->new($self->get('Config'));
    $host->set('Log Stream', $self->get('Log Stream'));
    $self->set('Host', $host);
    $host->begin_session() or die "Can't begin session\n";

    my $my_binary = $0;
    $my_binary = cwd . "/" . $my_binary if $my_binary !~ m,^/,;
    $self->set('MY_BINARY', $my_binary);

    my @bin_stats = stat( $my_binary );
    die "Cannot stat $my_binary: $!\n" if !@bin_stats;
    $self->set('MY_BINARY_TIME', $bin_stats[ST_MTIME]);

    chdir( $self->get_conf('HOME') . "/build" )
	or die "Can't cd to " . $self->get_conf('HOME') . "/build: $!\n";

    open( STDIN, "</dev/null" )
	or die "$0: can't redirect stdin to /dev/null: $!\n";

    if (open( PID, "<" . $self->get_conf('PIDFILE') )) {
	my $pid = <PID>;
	close( PID );
	$pid =~ /^[[:space:]]*(\d+)/; $pid = $1;
	if (!$pid || (kill( 0, $pid ) == 0 && $! == ESRCH)) {
	    warn "Removing stale pid file (process $pid dead)\n";
	}
	else {
	    die "Another buildd (pid $pid) is already running.\n";
	}
    }

    if (!@{$self->get_conf('DISTRIBUTIONS')}) {
	die "distribution list is empty, aborting.";
    }

    if (!$self->get_conf('NO_DETACH')) {
	defined(my $pid = fork) or die "can't fork: $!\n";
	exit if $pid; # parent exits
	setsid or die "can't start a new session: $!\n";
    }

    $self->set('PID', $$); # Needed for cleanup
    $self->set('Daemon', 1);

    open( PID, ">" . $self->get_conf('PIDFILE') )
	or die "can't create " . $self->get_conf('PIDFILE') . ": $!\n";
    printf PID "%5d\n", $self->get('PID');
    close( PID );

    $self->log("Daemon started. (pid=$$)\n");

    undef $ENV{'DISPLAY'};

# the main loop
  MAINLOOP:
    while( 1 ) {
	$self->check_restart();

        my ( $dist_config, $pkg_ver) = get_next_REDO($self);
        $self->do_build( $dist_config, $pkg_ver) if $pkg_ver;
        next MAINLOOP if $pkg_ver;

        ( $dist_config, $pkg_ver) = get_next_WANNABUILD($self);
        $self->do_build( $dist_config, $pkg_ver) if $pkg_ver;
        next MAINLOOP if $pkg_ver;

	# sleep a little bit if there was nothing to do this time
	    $self->log("Nothing to do -- sleeping " .
		       $self->get_conf('IDLE_SLEEP_TIME') . " seconds\n");
	    my $idle_start_time = time;
	    sleep( $self->get_conf('IDLE_SLEEP_TIME') );
	    my $idle_end_time = time;
	    $self->write_stats("idle-time", $idle_end_time - $idle_start_time);
    }

    return 0;
}

sub get_next_WANNABUILD {
    my $self = shift;
	foreach my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	    $self->check_ssh_master($dist_config);
	    my $dist_name = $dist_config->get('DIST_NAME');
	    my %givenback = $self->read_givenback();
		my $db = $self->get_db_handle($dist_config);
	    my $pipe = $db->pipe_query(
                ($dist_config->get('WANNA_BUILD_API') ? '--api '.$dist_config->get('WANNA_BUILD_API') : ''),
		'--list=needs-build',
		'--dist=' . $dist_name);
	    if (!$pipe) {
		$self->log("Can't spawn wanna-build --list=needs-build: $!\n");
		next MAINLOOP;
	    }

	    my($pkg_ver, $total, $nonex, $lowprio_pkg_ver);
	    while( <$pipe> ) {
		my $socket = $dist_config->get('WANNA_BUILD_SSH_SOCKET');
		if ($socket &&
		    (/^Couldn't connect to $socket: Connection refused[\r]?$/ ||
		     /^Control socket connect\($socket\): Connection refused[\r]?$/)) {
		    unlink($socket);
		    $self->check_ssh_master($dist_config);
		}
		elsif (/^Total (\d+) package/) {
		    $total = $1;
		    next;
		}
		elsif (/^Database for \S+ doesn.t exist/) {
		    $nonex = 1;
		}
		next if $nonex;
		next if defined($pkg_ver); #we only want one!
		my @line = (split( /\s+/, $_));
		my $pv = $line[0];
		my $no_build_regex = $dist_config->get('NO_BUILD_REGEX');
		my $build_regex = $dist_config->get('BUILD_REGEX');
		next if $no_build_regex && $pv =~ m,$no_build_regex,;
		next if $build_regex && $pv !~ m,$build_regex,;
		$pv =~ s,^.*/,,;
		my $p;
		($p = $pv) =~ s/_.*$//;
		next if isin( $p, @{$dist_config->get('NO_AUTO_BUILD')} );
		next if $givenback{$pv};
		if (isin( $p, @{$dist_config->get('WEAK_NO_AUTO_BUILD')} )) {
		    # only consider the first lowprio item if there are
		    # multiple ones
		    next if defined($lowprio_pkg_ver);
		    $lowprio_pkg_ver = $pv;
		    next;
		}
		$pkg_ver = $pv;
	    }
	    close( $pipe );
	    next if $nonex;
	    if ($?) {
		$self->log("wanna-build --list=needs-build --dist=${dist_name} failed; status ",
			   exitstatus($?), "\n");
		next;
	    }
	    $self->log("${dist_name}: total $total packages to build.\n") if defined($total);

	    # Build weak_no_auto packages before the next dist
	    if (!defined($pkg_ver) && defined($lowprio_pkg_ver)) {
		$pkg_ver = $lowprio_pkg_ver;
	    }

	    next if !defined($pkg_ver);
	    my $todo = $self->do_wanna_build( $dist_config, $pkg_ver );
	    last if !$todo;
	    return ( $dist_config, $todo );
	}
}

sub get_next_REDO {
    my $self = shift;
    my ( $dist_config, $pkg_ver);
    foreach my $current_dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	$pkg_ver = $self->get_from_REDO( $current_dist_config );
        $dist_config = $current_dist_config;
        last if defined($pkg_ver);
    }
    return ( $dist_config, $pkg_ver);
}


sub get_from_REDO {
    my $self = shift;
    my $wanted_dist_config = shift;
    my $ret = undef;
    local( *F );

    lock_file( "REDO" );
    goto end if ! -f "REDO";
    if (!open( F, "<REDO" )) {
	$self->log("File REDO exists, but can't open it: $!\n");
	goto end;
    }
    my @lines = <F>;
    close( F );

    $self->block_signals();
    if (!open( F, ">REDO" )) {
	$self->log("Can't open REDO for writing: $!\n",
		   "Raw contents:\n@lines\n");
	goto end;
    }
    foreach (@lines) {
	if (!/^(\S+)\s+(\S+)(?:\s*|\s+(\d+)\s+(\S.*))?$/) {
	    $self->log("Ignoring/deleting bad line in REDO: $_");
	    next;
	}
	my($pkg, $dist, $binNMUver, $changelog) = ($1, $2, $3, $4);
	if ($dist eq $wanted_dist_config->get('DIST_NAME') && !defined($ret)) {
            $ret = {'pv' => $pkg };
	    if (defined $binNMUver) {
		$ret->{'changelog'} = $changelog;
		$ret->{'binNMU'} = $binNMUver;
	    }
	} else {
	    print F $_;
	}
    }
    close( F );

  end:
    unlock_file( "REDO" );
    $self->unblock_signals();
    return $ret;
}

sub add_given_back ($$) {
    my $self = shift;
    my $pkg_ver = shift;

    local( *F );
    lock_file("SBUILD-GIVEN-BACK", 0);

    if (open( F, ">>SBUILD-GIVEN-BACK" )) {
	print F $pkg_ver . " " . time() . "\n";
	close( F );
    } else {
	$self->log("Can't open SBUILD-GIVEN-BACK: $!\n");
    }

    unlock_file("SBUILD-GIVEN-BACK");
}

sub read_givenback {
    my $self = shift;

    my %gb;
    my $now = time;
    local( *F );

    lock_file( "SBUILD-GIVEN-BACK" );

    if (open( F, "<SBUILD-GIVEN-BACK" )) {
	%gb = map { split } <F>;
	close( F );
    }

    if (open( F, ">SBUILD-GIVEN-BACK" )) {
	foreach (keys %gb) {
	    if ($now - $gb{$_} > $self->get_conf('DELAY_AFTER_GIVE_BACK') *60) {
		delete $gb{$_};
	    }
	    else {
		print F "$_ $gb{$_}\n";
	    }
	}
	close( F );
    }
    else {
	$self->log("Can't open SBUILD-GIVEN-BACK: $!\n");
    }

  unlock:
    unlock_file( "SBUILD-GIVEN-BACK" );
    return %gb;
}

sub do_wanna_build {
    my $self = shift;

    my $dist_config = shift;
    my $pkgver = shift;
    my @output = ();
    my $ret = undef;
    my $n = 0;

    $self->block_signals();

    my $db = $self->get_db_handle($dist_config);
    if ($dist_config->get('WANNA_BUILD_API') >= 1) {
        use YAML::Tiny;
        my $pipe = $db->pipe_query(
	'--api '.$dist_config->get('WANNA_BUILD_API'),
	'--dist=' . $dist_config->get('DIST_NAME'),
       	$pkgver);
        unless ($pipe) {
            $self->unblock_signals();
            $self->log("Can't spawn wanna-build: $!\n");
            return undef;
        }
        local $/ = undef;
        my $yaml = <$pipe>;
        $yaml =~ s,^update transactions:.*$,,m; # get rid of simulate output in case simulate is specified above
        $self->log($yaml);
        $yaml = YAML::Tiny->read_string($yaml);
        $yaml = $yaml->[0];
        foreach my $pkgv (@$yaml) {
            my $pkg = (keys %$pkgv)[0];
            my $pkgd;
            foreach my $k (@{$pkgv->{$pkg}}) {
                foreach my $l (keys %$k) { 
                    $pkgd->{$l} = $k->{$l}; 
                } 
            };
            if ($pkgd->{'status'} ne 'ok') {
                $self->log("Can't take $pkg: $pkgd->{'status'}\n");
                next;
            }
            $ret = { 'pv' => $pkgver };
            # fix SHOULD_BUILD_MSGS
#              if ($self->get_conf('SHOULD_BUILD_MSGS')) {
#                  $self->handle_prevfailed( $dist_config, grep( /^\Q$pkg\E_/, @_ ) );
#              } else {
#                  push( @output, grep( /^\Q$pkg\E_/, @_ ) );
            my $fields = { 'changelog' => 'extra-changelog', 'binNMU' => 'binNMU', 'extra-depends' => 'extra-depends', 'extra-conflicts' => 'extra-conflicts', 'build_dep_resolver' => 'build_dep_resolver' };
            for my $f (keys %$fields) {
                $ret->{$f} = $pkgd->{$fields->{$f}} if $pkgd->{$fields->{$f}};
            }
            last;
        }
        close( $pipe );
        $self->unblock_signals();
        $self->write_stats("taken", $n) if $n;
        return $ret;
    }
    my $pipe = $db->pipe_query(
	'-v', 
	'--dist=' . $dist_config->get('DIST_NAME'),
       	$pkgver);
    if ($pipe) {
	while( <$pipe> ) {
	    next if /^wanna-build Revision/;
	    if (/^(\S+):\s*ok/) {
                $ret = { 'pv' => $pkgver };
		++$n;
	    }
	    elsif (/^(\S+):.*NOT OK/) {
		my $pkg = $1;
		my $nextline = <$pipe>;
		chomp( $nextline );
		$nextline =~ s/^\s+//;
		$self->log("Can't take $pkg: $nextline\n");
	    }
	    elsif (/^(\S+):.*previous version failed/i) {
		my $pkg = $1;
		++$n;
		if ($self->get_conf('SHOULD_BUILD_MSGS')) {
		    $self->handle_prevfailed( $dist_config, $pkgver );
		} else {
                    $ret = { 'pv' => $pkgver };
		}
		# skip until ok line
		while( <$pipe> ) {
		    last if /^\Q$pkg\E:\s*ok/;
		}
	    }
	    elsif (/^(\S+):.*needs binary NMU (\d+)/) {
		my $pkg = $1;
		my $binNMUver = $2;
		chop (my $changelog = <$pipe>);
		my $newpkg;
		++$n;

		push( @output, grep( /^\Q$pkg\E_/, @_ ) );
                $ret = { 'pv' => $pkgver };
                $ret->{'changelog'} = $changelog;
                $ret->{'binNMU'} = $binNMUver;
		# skip until ok line
		while( <$pipe> ) {
		    last if /^\Q$pkg\E:\s*aok/;
		}
	    }
	}
	close( $pipe );
	$self->unblock_signals();
	$self->write_stats("taken", $n) if $n;
	return $ret;
    }
    else {
	$self->unblock_signals();
	$self->log("Can't spawn wanna-build: $!\n");
	return undef;
    }
}

sub should_skip {
    my $self = shift;
    my $pkgv = shift;

    my $found = 0;

    $self->lock_file("SKIP", 0);
    goto unlock if !open( F, "SKIP" );
    my @pkgs = <F>;
    close(F);

    if (!open( F, ">SKIP" )) {
	$self->log("Can't open SKIP for writing: $!\n",
		   "Would write: @pkgs\nminus $pkgv\n");
	goto unlock;
    }
    foreach (@pkgs) {
	if (/^\Q$pkgv\E$/) {
	    ++$found;
	    $self->log("$pkgv found in SKIP file -- skipping building it\n");
	}
	else {
	    print F $_;
	}
    }
    close( F );
  unlock:
    $self->unlock_file("SKIP");
    return $found;
}

sub do_build {
    my $self = shift;
    my $dist_config = shift;
    my $todo = shift;
    # $todo = { 'pv' => $pkg_ver, 'changelog' => $binNMUlog->{$pkg_ver}, 'binNMU' => $binNMUver; };

    # If the package to build is in SKIP, then skip.
    if ($self->should_skip($todo->{'pv'})) {
	return;
    }

    my $free_space;

    while (($free_space = df(".")) < $self->get_conf('MIN_FREE_SPACE')) {
	$self->log("Delaying build, because free space is low ($free_space KB)\n");
	my $idle_start_time = time;
	sleep( 10*60 );
	my $idle_end_time = time;
	$self->write_stats("idle-time", $idle_end_time - $idle_start_time);
    }

    $self->log("Starting build (dist=" . $dist_config->get('DIST_NAME') . ") of "
        .($todo->{'binNMU'} ? "!".$todo->{'binNMU'}."!" : "")
        ."$todo->{'pv'}\n");
    $self->write_stats("builds", 1);

    my @sbuild_args = ();
    if ($self->get_conf('NICE_LEVEL') != 0) {
	@sbuild_args = ( 'nice', '-n', $self->get_conf('NICE_LEVEL') );
    }

    push @sbuild_args, 'sbuild',
			'--apt-update',
			'--no-apt-upgrade',
			'--no-apt-distupgrade',
			'--batch',
			"--stats-dir=" . $self->get_conf('HOME') . "/stats",
			"--dist=" . $dist_config->get('DIST_NAME');

    #multi-archive-buildd keeps the mailto configuration in the builddrc, so
    #this needs to be passed over to sbuild. If the buildd config doesn't have
    #it, we hope that the address is configured in .sbuildrc and the right one:
    if ($dist_config->get('LOGS_MAILED_TO')) {
	push @sbuild_args, '--mail-log-to=' . $dist_config->get('LOGS_MAILED_TO');
    }
    #Some distributions (bpo, experimental) require a more complex dep resolver.
    #Ask sbuild to use another build-dep resolver if the config says so:
    if ($dist_config->get('BUILD_DEP_RESOLVER') || $todo->{'build_dep_resolver'}) {
	push @sbuild_args, '--build-dep-resolver=' . ($dist_config->get('BUILD_DEP_RESOLVER') || $todo->{'build_dep_resolver'});
    }
    push ( @sbuild_args, "--arch=" . $dist_config->get('BUILT_ARCHITECTURE') )
	if $dist_config->get('BUILT_ARCHITECTURE');
    push ( @sbuild_args, "--chroot=" . $dist_config->get('SBUILD_CHROOT') )
	if $dist_config->get('SBUILD_CHROOT');


    push ( @sbuild_args, "--binNMU=$todo->{'binNMU'}") if $todo->{'binNMU'};
    push ( @sbuild_args, "--make-binNMU=$todo->{'changelog'}") if $todo->{'changelog'};
    push ( @sbuild_args, "--add-conflicts=$todo->{'extra-conflicts'}") if $todo->{'extra-conflicts'};
    push ( @sbuild_args, "--add-depends=$todo->{'extra-depends'}") if $todo->{'extra-depends'};
    push @sbuild_args, $todo->{'pv'};
    $self->log("command line: @sbuild_args\n");

    $main::sbuild_pid = open(SBUILD_OUT, "-|");

    #We're childish, so call sbuild:
    if ($main::sbuild_pid == 0) {
	{ exec (@sbuild_args) };
	$self->log("Cannot execute sbuild: $!\n");
	exit(64);
    }

    if (!defined $main::sbuild_pid) {
	$self->log("Cannot fork for sbuild: $!\n");
	goto failed;
    }

    #We want to collect the first few lines of sbuild output:
    my ($sbuild_output_line_count, @sbuild_output_buffer) = (0, ());
    while (<SBUILD_OUT>) {
	#5 lines are enough:
	if (++$sbuild_output_line_count < 5) {
	    push @sbuild_output_buffer, $_;
	}
    }

    #We got enough output, now just wait for sbuild to die:
    my $rc;
    while (($rc = wait) != $main::sbuild_pid) {
	if ($rc == -1) {
	    last if $! == ECHILD;
	    next if $! == EINTR;
	    $self->log("wait for sbuild: $!; continuing to wait\n");
	} elsif ($rc != $main::sbuild_pid) {
	    $self->log("wait for sbuild: returned unexpected pid $rc\n");
	}
    }
    my $sbuild_exit_code = $?;
    undef $main::sbuild_pid;
    close(SBUILD_OUT);

    #Process sbuild's results:
    my $db = $self->get_db_handle($dist_config);
    my $failed = 1;
    my $giveback = 1;

    if (WIFEXITED($sbuild_exit_code)) {
	my $status = WEXITSTATUS($sbuild_exit_code);

	if ($status == 0) {
	    $failed = 0;
	    $giveback = 0;
	    $self->log("sbuild of $todo->{'pv'} succeeded -- marking as built in wanna-build\n");
	    $db->run_query('--built', '--dist=' . $dist_config->get('DIST_NAME'), $todo->{'pv'});
	} elsif ($status ==  2) {
	    $giveback = 0;
	    $self->log("sbuild of $todo->{'pv'} failed with status $status (build failed) -- marking as attempted in wanna-build\n");
	    $db->run_query('--attempted', '--dist=' . $dist_config->get('DIST_NAME'), $todo->{'pv'});
	    $self->write_stats("failed", 1);
	} else {
	    $self->log("sbuild of $todo->{'pv'} failed with status $status (local problem) -- giving back\n");
	}
    } elsif (WIFSIGNALED($sbuild_exit_code)) {
	my $sig = WTERMSIG($sbuild_exit_code);
	$self->log("sbuild of $todo->{'pv'} failed with signal $sig (local problem) -- giving back\n");
    } else {
	$self->log("sbuild of $todo->{'pv'} failed with unknown reason (local problem) -- giving back\n");
    }

    if ($giveback) {
	$db->run_query('--give-back', '--dist=' . $dist_config->get('DIST_NAME'), $todo->{'pv'});
	$self->add_given_back($todo->{'pv'});
	$self->write_stats("give-back", 1);
    }

    # Check if we encountered some local error to stop further building
    if ($giveback) {
	if (!defined $main::sbuild_fails) {
	    $main::sbuild_fails = 0;
	}

	$main::sbuild_fails++;

	if ($main::sbuild_fails > 2) {
	    $self->log("sbuild now failed $main::sbuild_fails times in ".
		       "a row; going to sleep\n");
	    send_mail( $self->get_conf('ADMIN_MAIL'),
		       "Repeated mess with sbuild",
		       <<EOF );
The execution of sbuild now failed for $main::sbuild_fails times.
These are the first $sbuild_output_line_count lines of the last failed sbuild call:
@sbuild_output_buffer

The daemon is going to sleep for 1 hour, or can be restarted with SIGUSR2.
EOF
            my $oldsig;
	    eval <<'EOF';
$oldsig = $SIG{'USR2'};
$SIG{'USR2'} = sub ($) { die "signal\n" };
my $idle_start_time = time;
sleep( 60*60 );
my $idle_end_time = time;
$SIG{'USR2'} = $oldsig;
$self->write_stats("idle-time", $idle_end_time - $idle_start_time);
EOF
	}
    }
    else {
	# Either a build success or an attempted build will cause the
	# counter to reset.
	$main::sbuild_fails = 0;
    }
    $self->log("Build finished.\n");
}

sub handle_prevfailed {
    my $self = shift;
    my $dist_config = shift;
    my $pkgv = shift;

    my $dist_name = $dist_config->get('DIST_NAME');
    my( $pkg, $fail_msg, $changelog);

    $self->log("$pkgv previously failed -- asking admin first\n");
    ($pkg = $pkgv) =~ s/_.*$//;

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query(
	'--info',
       	'--dist=' . $dist_name,
       	$pkg);
    if (!$pipe) {
	$self->log("Can't run wanna-build: $!\n");
	return;
    }

    $fail_msg = "";
    while (<$pipe>) {
      $fail_msg .= $_;
    }

    close($pipe);
    if ($?) {
	$self->log("wanna-build exited with error $?\n");
	return;
    }

    send_mail( $self->get_conf('ADMIN_MAIL'),
	       "Should I build $pkgv (dist=${dist_name})?",
	       "The package $pkg failed to build in a previous version. ".
	       "The fail\n".
	       "messages are:\n\n$fail_msg\n".
	       "Should buildd try to build the new version, or should it ".
	       "fail with the\n".
	       "same messages again.? Please answer with 'build' (or 'ok'), ".
	       "or 'fail'.\n" );
}

sub get_changelog {
    # This method is currently broken.  It makes some assumptions about source
    # layout that are no longer true.  Furthermore it tries fetching through
    # the host instead of creating a session (which is necessary for snapshot-
    # based chroots) and work in the chroot.

    my $self = shift;
    my $dist_config = shift;
    my $pkg = shift;

    my $dist_name = $dist_config->get('DIST_NAME');
    my $changelog = "";
    my $analyze = "";
    my $chroot_apt_options;
    my $file;
    my $retried = 0;

    $pkg =~ /^([\w\d.+-]+)_([\w\d:.~+-]+)/;
    my ($n, $v) = ($1, $2);
    (my $v_ne = $v) =~ s/^\d+://;
    my $pkg_ne = "${n}_${v_ne}";

retry:
    my @schroot = ($self->get_conf('SCHROOT'), '-c',
		   $dist_name . '-' . $self->get_conf('ARCH') . '-sbuild', '--');
    my @schroot_root = ($self->get_conf('SCHROOT'), '-c',
			$dist_name . '-' . $self->get_conf('ARCH') . '-sbuild',
			'-u', 'root', '--');
    my $apt_get = $self->get_conf('APT_GET');

    my $pipe = $self->get('Host')->pipe_command(
	{ COMMAND => [@schroot,
		      "$apt_get", '-q', '-d',
		      '--diff-only', 'source', "$n=$v"],
	  USER => $self->get_conf('USERNAME'),
	  PRIORITY => 0,
	});
    if (!$pipe) {
	$self->log("Can't run schroot: $!\n");
	return;
    }

    my $msg = "";
    while (<$pipe>) {
      $msg .= $_;
    }

    close($pipe);

    if ($? == 0 && $msg !~ /get 0B/) {
	$analyze = "diff";
	$file = "${n}_${v_ne}.diff.gz";
    }

    if (!$analyze) {
	my $pipe2 = $self->get('Host')->pipe_command(
	    { COMMAND => [@schroot,
			  "$apt_get", '-q', '-d',
			  '--tar-only', 'source', "$n=$v"],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	    });
	if (!$pipe2) {
	    $self->log("Can't run schroot: $!\n");
	    return;
	}

	my $msg = <$pipe2>;

	close($pipe2);

	if ($? == 0 && $msg !~ /get 0B/) {
	    $analyze = "tar";
	    $file = "${n}_${v_ne}.tar.gz";
	}
    }

    if (!$analyze && !$retried) {
	$self->get('Host')->run_command(
	    { COMMAND => [@schroot_root,
			  $apt_get, '-qq',
			  'update'],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      STREAMOUT => $devnull
	    });

	$retried = 1;
	goto retry;
    }

    return "ERROR: cannot find any source" if !$analyze;

    if ($analyze eq "diff") {
	if (!open( F, "gzip -dc '$file' 2>/dev/null |" )) {
	    return "ERROR: Cannot spawn gzip to zcat $file: $!";
	}
	while( <F> ) {
	    # look for header line of a file */debian/changelog
	    last if m,^\+\+\+\s+[^/]+/debian/changelog(\s+|$),;
	}
	while( <F> ) {
	    last if /^---/; # end of control changelog patch
	    next if /^\@\@/;
	    $changelog .= "$1\n" if /^\+(.*)$/;
	    last if /^\+\s+--\s+/;
	}
	while( <F> ) { } # read to end of file to avoid broken pipe
	close( F );
	if ($?) {
	    return "ERROR: error status ".exitstatus($?)." from gzip on $file";
	}
	unlink( $file );
    }
    elsif ($analyze eq "tar") {
	if (!open( F, "tar -xzOf '$file' '*/debian/changelog' ".
		   "2>/dev/null |" )) {
	    return "ERROR: Cannot spawn tar for $file: $!";
	}
	while( <F> ) {
	    $changelog .= $_;
	    last if /^\s+--\s+/;
	}
	while( <F> ) { } # read to end of file to avoid broken pipe
	close( F );
	if ($?) {
	    return "ERROR: error status ".exitstatus($?)." from tar on $file";
	}
	unlink( $file );
    }

    return $changelog;
}

sub check_restart {
    my $self = shift;
    my @stats = stat( $self->get('MY_BINARY') );

    if (@stats && $self->get('MY_BINARY_TIME') != $stats[ST_MTIME]) {
	$self->log("My binary has been updated -- restarting myself (pid=$$)\n");
	unlink( $self->get_conf('PIDFILE') );
	kill ( 15, $main::ssh_pid ) if $main::ssh_pid;
	exec $self->get('MY_BINARY');
    }

    if ( -f $self->get_conf('HOME') . "/EXIT-DAEMON-PLEASE" ) {
	unlink($self->get_conf('HOME') . "/EXIT-DAEMON-PLEASE");
	$self->shutdown("NONE (flag file exit)");
    }
}

sub block_signals {
    my $self = shift;

    POSIX::sigprocmask( SIG_BLOCK, $main::block_sigset );
}

sub unblock_signals {
    my $self = shift;

    POSIX::sigprocmask( SIG_UNBLOCK, $main::block_sigset );
}

sub check_ssh_master {
    my $self = shift;
    my $dist_config = shift;

    my $ssh_socket = $dist_config->get('WANNA_BUILD_SSH_SOCKET');

    return 1 if (!$ssh_socket);
    return 1 if ( -S $ssh_socket );

    my $ssh_master_pids = {};
    if ($self->get('SSH_MASTER_PIDS')) {
	$ssh_master_pids = $self->get('SSH_MASTER_PIDS');
    } else {
	$self->set('SSH_MASTER_PIDS', $ssh_master_pids);
    }

    if ($ssh_master_pids->{$ssh_socket})
    {
	my $wpid = waitpid ( $ssh_master_pids->{$ssh_socket}, WNOHANG );
	return 1 if ($wpid != -1 and $wpid != $ssh_master_pids->{$ssh_socket});
    }

    my $new_master_pid = fork;

    #We are in the newly forked child:
    if (defined($new_master_pid) && $new_master_pid == 0) {
	exec (@{$dist_config->get('WANNA_BUILD_SSH_CMD')}, "-MN");
    }

    #We are the parent:
    if (!defined $new_master_pid) {
	$self->log("Cannot fork for ssh master: $!\n");
	return 0;
    }

    $ssh_master_pids->{$ssh_socket} = $new_master_pid;

    while ( ! -S $ssh_socket )
    {
	sleep 1;
	my $wpid = waitpid ( $new_master_pid, WNOHANG );
	return 0 if ($wpid == -1 or $wpid == $new_master_pid);
    }
    return 1;
}

sub read_config {
    my $self = shift;

    $self->get('Config')->read_config();
}

sub shutdown {
    my $self = shift;
    my $signame = shift;

    $self->log("buildd ($$) received SIG$signame -- shutting down\n");

    if ($self->get('SSH_MASTER_PIDS')) {
	my $ssh_master_pids = $self->get('SSH_MASTER_PIDS');
	for my $ssh_socket (keys %{$ssh_master_pids}) {
	    my $master_pid = $ssh_master_pids->{$ssh_socket};
	    kill ( 15, $master_pid );
	    delete ( $ssh_master_pids->{$ssh_socket} );
	}
    }

    if (defined $main::sbuild_pid) {
	$self->log("Killing sbuild (pid=$main::sbuild_pid)\n");
	kill( 15, $main::sbuild_pid );
	$self->log("Waiting max. 2 minutes for sbuild to finish\n");
	$SIG{'ALRM'} = sub ($) { die "timeout\n"; };
	alarm( 120 );
	eval "waitpid( $main::sbuild_pid, 0 )";
	alarm( 0 );
	if ($@) {
	    $self->log("sbuild did not die!");
	}
	else {
	    $self->log("sbuild died normally");
	}
	unlink( "SBUILD-REDO-DUMPED" );
    }
    unlink( $self->get('Config')->get('PIDFILE') );
    $self->log("exiting now\n");
    $self->close_log();
    exit 1;
}

1;
