#
# Chroot.pm: chroot library for sbuild
# Copyright (C) 2005      Ryan Murray <rmurray@debian.org>
# Copyright (C) 2005-2006 Roger Leigh <rleigh@debian.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
# $Id: Sbuild.pm,v 1.2 2006/03/07 16:58:12 rleigh Exp $
#

package Sbuild::Chroot;

use Sbuild::Conf;

use strict;
use POSIX;
use FileHandle;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(begin_session end_session get_command_internal
		 get_command run_command exec_command
		 get_apt_command_internal get_apt_command
		 run_apt_command current);
}

my %chroots = ();
my $schroot_session = "";

our $current;

sub _get_schroot_info {
	my $chroot = shift;
	my $chroot_type = "";
	my %tmp = ('Priority' => 0,
		   'Location' => "",
		   'Session Managed' => 0);
	open CHROOT_DATA, '-|', $Sbuild::Conf::schroot, '--info', '--chroot', $chroot or die "Can't run $Sbuild::Conf::schroot to get chroot data";
	while (<CHROOT_DATA>) {
		chomp;
		if (/^\s*Type:?\s+(.*)$/) {
		    $chroot_type = $1;
		}
		if (/^\s*Location:?\s+(.*)$/ &&
		    $tmp{'Location'} eq "") {
			$tmp{'Location'} = $1;
		}
		if (/^\s*Mount Location:?\s+(.*)$/ &&
		    $tmp{'Location'} eq "") {
			$tmp{'Location'} = $1;
		}
		# Path takes priority over Location and Mount Location.
		if (/^\s*Path:?\s+(.*)$/) {
			$tmp{'Location'} = $1;
		}
		if (/^\s*Priority:?\s+(\d+)$/) {
			$tmp{'Priority'} = $1;
		}
		if (/^\s*Session Managed\s+(.*)$/) {
			if ($1 eq "true") {
				$tmp{'Session Managed'} = 1;
			}
		}
	}

	close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

	# "plain" chroots are never session-capable, even if they say
	# they are.
	if ($chroot_type eq "plain") {
		$tmp{'Session Managed'} = 0;
	}

	if ($Sbuild::Conf::debug) {
		print STDERR "Found schroot chroot: $chroot\n";
		foreach (sort keys %tmp) {
			print STDERR "  $_ $tmp{$_}\n";
		}
	}

	$chroots{$chroot} = \%tmp;
}

sub init {
	foreach (glob("${Sbuild::Conf::build_dir}/chroot-*")) {
		my %tmp = ('Priority' => 0,
			   'Location' => $_,
			   'Session Managed' => 0);
		if (-d $tmp{'Location'}) {
			my $name = $_;
			$name =~ s/\Q${Sbuild::Conf::build_dir}\/chroot-\E//;
			print STDERR "Found chroot $name\n"
				if $Sbuild::Conf::debug;
			$chroots{$name} = \%tmp;
		}
	}

	# Pick up available chroots and dist_order from schroot
	if ($Sbuild::Conf::chroot_mode eq "schroot") {
		%chroots = ();
		open CHROOTS, '-|', $Sbuild::Conf::schroot, '--list' or die "Can't run $Sbuild::Conf::schroot";
		while (<CHROOTS>) {
			chomp;
			my $chroot = $_;
			print STDERR "Getting info for $chroot chroot"
				if $Sbuild::Conf::debug;
			_get_schroot_info($chroot);
		}
		close CHROOTS or die "Can't close schroot pipe";
	}
}

sub _setup_options {
	my $distribution = shift;

	if (defined($chroots{$distribution}) &&
	    -d $chroots{"$distribution"}->{'Location'}) {
		my $chroot_dir = $chroots{"$distribution"}->{'Location'};
		$chroots{"$distribution"}->{'Build Location'} = "$chroot_dir/build/$Sbuild::Conf::username/";
		my $srcdep_lock_dir = "$chroot_dir/$Sbuild::Conf::srcdep_lock_dir";
		$chroots{"$distribution"}->{'Srcdep Lock Dir'} = $srcdep_lock_dir;
		$chroots{"$distribution"}->{'Install Lock'} = "$srcdep_lock_dir/install";

		my $aptconf = "/var/lib/sbuild/apt.conf";
		if ($Sbuild::Conf::chroot_mode ne "schroot") {
			$chroots{"$distribution"}->{'APT Options'} =
				"-o Dir::State::status=$chroot_dir/var/lib/dpkg/status".
				" -o DPkg::Options::=--root=$chroot_dir".
				" -o DPkg::Run-Directory=$chroot_dir";
		}

		# schroot uses an absolute path inside the chroot,
		# rather than on the host system.
		my $chroot_aptconf = "$chroot_dir/$aptconf";
		if ($Sbuild::Conf::chroot_mode eq "schroot") {
			$ENV{'APT_CONFIG'} = $aptconf;
		} else {
			$ENV{'APT_CONFIG'} = $chroot_aptconf;
		}

		# Always write out apt.conf, because it gets outdated
		# if the chroot_mode is changed...
		if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
					    DIR => $chroot_dir,
					    UNLINK => 0) ) {

			if ($Sbuild::Conf::chroot_mode ne "schroot") {
				print $F "Dir \"$chroot_dir\";\n";
			}
			print $F "APT::Get::AllowUnauthenticated true;\n";

			if (! rename $F->filename, $chroot_aptconf) {
				die "Can't rename $F->filename to $chroot_aptconf: $!\n";
			}

		} else {
			if ($Sbuild::Conf::chroot_mode ne "schroot") {
				$chroots{"$distribution"}->{'APT Options'} =
					" -o Dir::State=$chroot_dir/var/lib/apt".
					" -o Dir::Cache=$chroot_dir/var/cache/apt".
					" -o Dir::Etc=$chroot_dir/etc/apt";
			}
		}
	} elsif ($Sbuild::Conf::chroot_only) {
		die "$distribution chroot does not exist and in chroot only mode -- exiting\n";
	}
}

sub begin_session {
	my $distribution = shift;

	if ($Sbuild::Conf::chroot_mode eq "schroot") {
		if (defined($chroots{"${distribution}-sbuild"})) {
			$distribution = "${distribution}-sbuild";
		}
        	$schroot_session=`$Sbuild::Conf::schroot -c $distribution --begin-session`;
		chomp($schroot_session);
		if ($?) {
			print STDERR "Chroot setup failed\n";
			return 0;
		}
		print STDERR "Setting up chroot $distribution (session id $schroot_session)\n"
			if $Sbuild::Conf::debug;
		_get_schroot_info($schroot_session);
		_setup_options($schroot_session);
		$current = $chroots{$schroot_session};
	} else {
		_setup_options($distribution);
		$current = $chroots{$distribution};
	}
	return 1;
}

sub end_session {
	$current = undef;
	if ($Sbuild::Conf::chroot_mode eq "schroot" && $schroot_session ne "") {
        	system("$Sbuild::Conf::schroot -c $schroot_session --end-session");
		if ($?) {
			print STDERR "Chroot cleanup failed\n";
			return 0;
		}
	}
	return 1;
}

sub log_command {
	my $msg = shift;      # Message to log
	my $priority = shift; # Priority of log message

	if ((defined($priority) && $priority >= 1) || $Sbuild::Conf::debug) {
		$msg =~ s/\Q$$current{'APT Options'}\E/CHROOT_APT_OPTIONS/g;
		print STDERR "$msg\n";
	}
}

sub get_command_internal {
	my $command = shift; # Command to run
	my $user = shift;    # User to run command under
	if (!defined $user || $user eq "") {
		$user = $Sbuild::Conf::username;
	}
	my $chroot = shift;  # Run in chroot?
	if (!defined $chroot) {
		$chroot = 1;
	}

	my $cmdline;
	if ($chroot != 0) { # Run command inside chroot
		if ($Sbuild::Conf::chroot_mode eq "schroot") {
			$cmdline = "$Sbuild::Conf::schroot -c $schroot_session --run-session $Sbuild::Conf::schroot_options -u $user -p -- ";
		} else {
			$cmdline = "$Sbuild::Conf::sudo /usr/sbin/chroot $$current{'Location'} $Sbuild::Conf::sudo ";
			if ($user ne "root") {
				$cmdline .= "-u $Sbuild::Conf::username ";
			}
			$cmdline .= "-H ";
		}
	} else { # Run command outside chroot
		if ($user ne $Sbuild::Conf::username) {
			$cmdline = "$Sbuild::Conf::sudo ";
			if ($user ne "root") {
				$cmdline .= "-u $Sbuild::Conf::username ";
			}
		}
	}
	$cmdline .= "/bin/sh -c '$command'";

	return $cmdline;
}

sub get_command {
	my $command = shift;  # Command to run
	my $user = shift;     # User to run command under
	my $chroot = shift;   # Run in chroot?
	my $priority = shift; # Priority of log message
	my $cmdline = get_command_internal($command, $user, $chroot);

	if ($Sbuild::Conf::debug) {
		log_command($cmdline, $priority);
	} else {
		log_command($command, $priority);
	}

	if ($chroot != 0) {
		chdir($main::cwd);
	}
	return $cmdline;
}

# Note, do not run with $user="root", and $chroot=0, because sudo
# access to the host system is not required.
sub run_command {
	my $command = shift;  # Command to run
	my $user = shift;     # User to run command under
	my $chroot = shift;   # Run in chroot?
	my $priority = shift; # Priority of log message
	my $cmdline = get_command_internal($command, $user, $chroot);

	if ($Sbuild::Conf::debug) {
		log_command($cmdline, $priority);
	} else {
		log_command($command, $priority);
	}

	if ($chroot != 0) {
		chdir($main::cwd);
	}
	return system($cmdline);
}

sub exec_command {
	my $command = shift;  # Command to run
	my $user = shift;     # User to run command under
	my $chroot = shift;   # Run in chroot?
	my $priority = shift; # Priority of log message
	my $cmdline = get_command_internal($command, $user, $chroot);

	if ($Sbuild::Conf::debug) {
		log_command($cmdline, $priority);
	} else {
		log_command($command, $priority);
	}

	if ($chroot != 0) {
		chdir($main::cwd);
	}
	exec $cmdline;
}

sub get_apt_command_internal {
	my $aptcommand = shift; # Command to run
	my $options = shift;    # Command options
	$aptcommand .= " $$current{'APT Options'} $options";

	return $aptcommand;
}

sub get_apt_command {
	my $command = shift;  # Command to run
	my $options = shift;  # Command options
	my $user = shift;     # User to run command under
	my $priority = shift; # Priority of log message

	my $aptcommand = get_apt_command_internal($command, $options);

	my $chroot = 0;
	if ($Sbuild::Conf::chroot_mode eq "schroot") {
		$chroot = 1;
	}

	my $cmdline = get_command($aptcommand, $user, $chroot, $priority);

	chdir($main::cwd);
	return $cmdline;
}

sub run_apt_command {
	my $command = shift;  # Command to run
	my $options = shift;  # Command options
	my $user = shift;     # User to run command under
	my $priority = shift; # Priority of log message

	my $aptcommand = get_apt_command_internal($command, $options);

	my $chroot = 0;
	if ($Sbuild::Conf::chroot_mode eq "schroot") {
		$chroot = 1;
	}

	chdir($main::cwd);
	return run_command($aptcommand, $user, $chroot, $priority);
}

1;
