#
# Chroot.pm: chroot library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package Sbuild::Chroot;

use Sbuild::Conf;
use Sbuild::Sysconfig;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(begin_session end_session strip_chroot_path
		 get_command run_command exec_command get_apt_command
		 run_apt_command current); }

my %chroots = ();
my $schroot_session = "";

our $current;

sub _get_schroot_info ($);
sub init ();
sub _setup_options ($);
sub begin_session ($$$);
sub end_session ();
sub strip_chroot_path ($);
sub log_command ($$);
sub get_command_internal ($$$);
sub get_command ($$$$);
sub run_command ($$$$);
sub exec_command ($$$$);
sub get_apt_command_internal ($$);
sub get_apt_command ($$$$);
sub run_apt_command ($$$$);

sub _get_schroot_info ($) {
    my $chroot = shift;
    my $chroot_type = "";
    my %tmp = ('Priority' => 0,
	       'Location' => "",
	       'Session Cloned' => 0);
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
	if (/^\s*Session Cloned\s+(.*)$/) {
	    if ($1 eq "true") {
		$tmp{'Session Cloned'} = 1;
	    }
	}
    }

    close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

    if ($Sbuild::Conf::debug) {
	print STDERR "Found schroot chroot: $chroot\n";
	foreach (sort keys %tmp) {
	    print STDERR "  $_ $tmp{$_}\n";
	}
    }

    $chroots{$chroot} = \%tmp;
}

sub init () {
    foreach (glob("${Sbuild::Conf::build_dir}/chroot-*")) {
	my %tmp = ('Priority' => 0,
		   'Location' => $_,
		   'Session Cloned' => 0);
	if (-d $tmp{'Location'}) {
	    my $name = $_;
	    $name =~ s/\Q${Sbuild::Conf::build_dir}\/chroot-\E//;
	    print STDERR "Found chroot $name\n"
		if $Sbuild::Conf::debug;
	    $chroots{$name} = \%tmp;
	}
    }

    # Pick up available chroots and dist_order from schroot
    %chroots = ();
    open CHROOTS, '-|', $Sbuild::Conf::schroot, '--list' or die "Can't run $Sbuild::Conf::schroot";
    while (<CHROOTS>) {
	chomp;
	my $chroot = $_;
	print STDERR "Getting info for $chroot chroot\n"
	    if $Sbuild::Conf::debug;
	_get_schroot_info($chroot);
    }
    close CHROOTS or die "Can't close schroot pipe";
}

sub _setup_options ($) {
    my $distribution = shift;

    if (defined($chroots{$distribution}) &&
	-d $chroots{"$distribution"}->{'Location'}) {
	my $chroot_dir = $chroots{"$distribution"}->{'Location'};
	$chroots{"$distribution"}->{'Build Location'} = "$chroot_dir/build";
	my $srcdep_lock_dir = "$chroot_dir/$Sbuild::Conf::srcdep_lock_dir";
	$chroots{"$distribution"}->{'Srcdep Lock Dir'} = $srcdep_lock_dir;
	$chroots{"$distribution"}->{'Install Lock'} = "$srcdep_lock_dir/install";

	my $aptconf = "/var/lib/sbuild/apt.conf";
	$chroots{"$distribution"}->{'APT Options'} = "";

	my $chroot_aptconf = "$chroot_dir/$aptconf";
	$ENV{'APT_CONFIG'} = $aptconf;

	# Always write out apt.conf, because it may become outdated.
	if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
				    DIR => $chroot_dir,
				    UNLINK => 0) ) {

	    print $F "APT::Get::AllowUnauthenticated true;\n";
	    print $F "APT::Install-Recommends false;\n";

	    if (! rename $F->filename, $chroot_aptconf) {
		die "Can't rename $F->filename to $chroot_aptconf: $!\n";
	    }
	}
    } else {
	die "$distribution chroot does not exist\n";
    }
}

sub begin_session ($$$) {
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;

    $arch = "" if !defined($arch);

    my $arch_found = 0;

    if (!defined $chroot) {
        if ($arch ne "" &&
            defined($chroots{"${distribution}-${arch}-sbuild"})) {
            $chroot = "${distribution}-${arch}-sbuild";
            $arch_found = 1;
        }
        elsif (defined($chroots{"${distribution}-sbuild"})) {
            $chroot = "${distribution}-sbuild";
        }
        elsif ($arch ne "" &&
               defined($chroots{"${distribution}-${arch}"})) {
            $chroot = "${distribution}-${arch}";
            $arch_found = 1;
        } elsif (defined($chroots{$distribution})) {
            $chroot = $distribution;
	}
    }

    if (!$arch_found && $arch ne "") {
	print STDERR "Chroot for architecture $arch not found\n";
	return 0;
    }

    if (!$chroot) {
	print STDERR "Chroot for distribution $distribution, architecture $arch not found\n";
	return 0;
    }

    $schroot_session=`$Sbuild::Conf::schroot -c $chroot --begin-session`;
    chomp($schroot_session);
    if ($?) {
	print STDERR "Chroot setup failed\n";

	if (-d "chroot-$chroot" || -l "chroot-$chroot") {
	    print STDERR "\nFound obsolete chroot: ${Sbuild::Conf::build_dir}/chroot-$chroot\n";
	    print STDERR "Chroot access via sudo has been replaced with schroot chroot management.\n";
	    print STDERR "To upgrade to schroot, add the following lines to /etc/schroot/schroot.conf:\n\n";
	    print STDERR "[$chroot]\n";
	    print STDERR "type=directory\n";
	    print STDERR "description=Debian $distribution autobuilder\n";
	    print STDERR "location=${Sbuild::Conf::build_dir}/chroot-$chroot\n";
	    print STDERR "priority=3\n";
	    print STDERR "groups=root,sbuild\n";
	    print STDERR "root-groups=root,sbuild\n";
	    print STDERR "aliases=$distribution-sbuild\n";
	    print STDERR "run-setup-scripts=true\n";
	    print STDERR "run-exec-scripts=true\n\n";
	    print STDERR "It is preferable to specify location as a directory, not a symbolic link\n\n"
	}
	return 0;
    }
    print STDERR "Setting up chroot $chroot (session id $schroot_session)\n"
	if $Sbuild::Conf::debug;
    _get_schroot_info($schroot_session);
    _setup_options($schroot_session);
    $current = $chroots{$schroot_session};
    return 1;
}

sub end_session () {
    $current = undef;
    return if $schroot_session eq "";
    print STDERR "Cleaning up chroot (session id $schroot_session)\n"
	if $Sbuild::Conf::debug;
    system("$Sbuild::Conf::schroot -c $schroot_session --end-session");
    $schroot_session = "";
    if ($?) {
	print STDERR "Chroot cleanup failed\n";
	return 0;
    }
    return 1;
}

sub strip_chroot_path ($) {
    my $path = shift;

    $path =~ s/^\Q$$current{'Location'}\E//;

    return $path;
}

sub log_command ($$) {
    my $msg = shift;      # Message to log
    my $priority = shift; # Priority of log message

    if ((defined($priority) && $priority >= 1) || $Sbuild::Conf::debug) {
	if ($$current{'APT Options'} ne "") {
	    $msg =~ s/\Q$$current{'APT Options'}\E/CHROOT_APT_OPTIONS/g;
	}
	print STDERR "$msg\n";
    }
}

sub get_command_internal ($$$) {
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
	# TODO: Allow user to set build location
	my $dir = strip_chroot_path($$current{'Build Location'});
	$cmdline = "$Sbuild::Conf::schroot -d '$dir' -c $schroot_session --run-session $Sbuild::Conf::schroot_options -u $user -p -- /bin/sh -c '$command'";
    } else { # Run command outside chroot
	if ($user ne $Sbuild::Conf::username) {
	    print main::LOG "Command \"$command\" cannot be run as root or any other user on the host system\n";
	}
	$cmdline .= "/bin/sh -c '$command'";
    }

    return $cmdline;
}

sub get_command ($$$$) {
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
	chdir($Sbuild::Conf::cwd);
    }

    return $cmdline;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed.
sub run_command ($$$$) {
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
	chdir($Sbuild::Conf::cwd);
    }
    return system($cmdline);
}

sub exec_command ($$$$) {
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
	chdir($Sbuild::Conf::cwd);
    }
    exec $cmdline;
}

sub get_apt_command_internal ($$) {
    my $aptcommand = shift; # Command to run
    my $options = shift;    # Command options
    $aptcommand .= " $$current{'APT Options'} $options";

    return $aptcommand;
}

sub get_apt_command ($$$$) {
    my $command = shift;  # Command to run
    my $options = shift;  # Command options
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message

    my $aptcommand = get_apt_command_internal($command, $options);

    my $cmdline = get_command($aptcommand, $user, 1, $priority);

    chdir($Sbuild::Conf::cwd);
    return $cmdline;
}

sub run_apt_command ($$$$) {
    my $command = shift;  # Command to run
    my $options = shift;  # Command options
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message

    my $aptcommand = get_apt_command_internal($command, $options);

    chdir($Sbuild::Conf::cwd);
    return run_command($aptcommand, $user, 1, $priority);
}

1;
