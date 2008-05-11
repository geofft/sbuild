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
use Sbuild::ChrootInfo qw(find_chroot get_chroot_info);

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new);
}

sub new($$$);
sub _setup_options (\$\$);
sub begin_session (\$);
sub end_session (\$);
sub strip_chroot_path (\$$);
sub log_command (\$$$);
sub get_command_internal (\$$$$$);
sub get_command (\$$$$$$);
sub run_command (\$$$$$$);
sub exec_command (\$$$$$$);
sub get_apt_command_internal (\$$$);
sub get_apt_command (\$$$$$$);
sub run_apt_command (\$$$$$$);

sub new($$$) {
# TODO: specify distribution parameters here...
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;

    my $self  = {};
    bless($self);

    $self->set('Session ID', "");
    $self->set('Chroot ID', find_chroot($distribution, $chroot, $arch));

    if (!defined($self->get('Chroot ID'))) {
	return undef;
    }

    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->{$key} = $value;
}

sub _setup_options (\$\$) {
    my $self = shift;
    my $info = shift;

    if (defined($info) &&
	defined($info->{'Location'}) && -d $info->{'Location'}) {

	$self->set('Priority', $info->{'Priority'});
	$self->set('Location', $info->{'Location'});
	$self->set('Session Cloned', $info->{'Session Cloned'});
	$self->set('Build Location', $self->get('Location') . "/build");
	$self->set('Srcdep Lock Dir', $self->get('Location') . "/$Sbuild::Conf::srcdep_lock_dir");
	$self->set('Install Lock', $self->get('Srcdep Lock Dir') . "/install");

	my $aptconf = "/var/lib/sbuild/apt.conf";
	$self->set('APT Options', "");

	my $chroot_aptconf = $self->get('Location') . "/$aptconf";
	$ENV{'APT_CONFIG'} = $aptconf;

	# Always write out apt.conf, because it may become outdated.
	if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
				    DIR => $self->get('Location'),
				    UNLINK => 0) ) {

	    print $F "APT::Get::AllowUnauthenticated true;\n";
	    print $F "APT::Install-Recommends false;\n";

	    if (! rename $F->filename, $chroot_aptconf) {
		die "Can't rename $F->filename to $chroot_aptconf: $!\n";
	    }
	}
    } else {
	die $self->get('Chroot ID') . " chroot does not exist\n";
    }
}

sub begin_session (\$) {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    my $schroot_session=`$Sbuild::Conf::schroot -c $chroot --begin-session`;
    chomp($schroot_session);
    if ($?) {
	print STDERR "Chroot setup failed\n";

	# TODO: Remove after Lenny.
	if (-d "chroot-$chroot" || -l "chroot-$chroot") {
	    print STDERR "\nFound obsolete chroot: ${Sbuild::Conf::build_dir}/chroot-$chroot\n";
	    print STDERR "Chroot access via sudo has been replaced with schroot chroot management.\n";
	    print STDERR "To upgrade to schroot, add the following lines to /etc/schroot/schroot.conf:\n\n";
	    print STDERR "[$chroot]\n";
	    print STDERR "type=directory\n";
	    print STDERR "description=Debian $chroot autobuilder\n";
	    print STDERR "location=${Sbuild::Conf::build_dir}/chroot-$chroot\n";
	    print STDERR "priority=3\n";
	    print STDERR "groups=root,sbuild\n";
	    print STDERR "root-groups=root,sbuild\n";
	    print STDERR "aliases=$chroot-sbuild\n";
	    print STDERR "run-setup-scripts=true\n";
	    print STDERR "run-exec-scripts=true\n\n";
	    print STDERR "It is preferable to specify location as a directory, not a symbolic link\n\n"
	}
	return 0;
    }

    $self->set('Session ID', $schroot_session);
    print STDERR "Setting up chroot $chroot (session id $schroot_session)\n"
	if $Sbuild::Conf::debug;
    $self->_setup_options(get_chroot_info($schroot_session));
    return 1;
}

sub end_session (\$) {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
	if $Sbuild::Conf::debug;
    system("$Sbuild::Conf::schroot -c " . $self->get('Session ID') . " --end-session");
    $self->set('Session ID', "");
    if ($?) {
	print STDERR "Chroot cleanup failed\n";
	return 0;
    }
    return 1;
}

sub strip_chroot_path (\$$) {
    my $self = shift;
    my $path = shift;

    my $location = $self->get('Location');
    $path =~ s/^\Q$location\E//;

    return $path;
}

sub log_command (\$$$) {
    my $self = shift;
    my $msg = shift;      # Message to log
    my $priority = shift; # Priority of log message

    if ((defined($priority) && $priority >= 1) || $Sbuild::Conf::debug) {
	my $options = $self->get('APT Options');
	if ($options ne "") {
	    $msg =~ s/\Q$options\E/CHROOT_APT_OPTIONS/g;
	}
	print STDERR "$msg\n";
    }
}

sub get_command_internal (\$$$$$) {
    my $self = shift;
    my $command = shift; # Command to run
    my $user = shift;    # User to run command under
    my $chroot = shift;  # Run in chroot?
    my $dir = shift;     # Directory to use (optional)

    if (!defined $user || $user eq "") {
	$user = $Sbuild::Conf::username;
    }
    if (!defined $chroot) {
	$chroot = 1;
    }

    my $cmdline;
    if ($chroot != 0) { # Run command inside chroot
	# TODO: Allow user to set build location
	if (!defined($dir)) {
	    $dir = $self->strip_chroot_path($self->get('Build Location'));
	}
	$cmdline = "$Sbuild::Conf::schroot -d '$dir' -c " . $self->get('Session ID') . " --run-session $Sbuild::Conf::schroot_options -u $user -p -- /bin/sh -c '$command'";
    } else { # Run command outside chroot
	if ($user ne $Sbuild::Conf::username) {
	    print main::LOG "Command \"$command\" cannot be run as root or any other user on the host system\n";
	}
	$cmdline .= "/bin/sh -c '$command'";
    }

    return $cmdline;
}

sub get_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $chroot = shift;   # Run in chroot?
    my $priority = shift; # Priority of log message
    my $dir = shift;     # Directory to use (optional)
    my $cmdline = $self->get_command_internal($command, $user, $chroot, $dir);

    if ($Sbuild::Conf::debug) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
    }

    if ($chroot != 0) {
	chdir($Sbuild::Conf::cwd);
    }

    return $cmdline;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed.
sub run_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $chroot = shift;   # Run in chroot?
    my $priority = shift; # Priority of log message
    my $dir = shift;     # Directory to use (optional)
    my $cmdline = $self->get_command_internal($command, $user, $chroot, $dir);

    if ($Sbuild::Conf::debug) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
    }

    if ($chroot != 0) {
	chdir($Sbuild::Conf::cwd);
    }
    return system($cmdline);
}

sub exec_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $chroot = shift;   # Run in chroot?
    my $priority = shift; # Priority of log message
    my $dir = shift;     # Directory to use (optional)
    my $cmdline = $self->get_command_internal($command, $user, $chroot, $dir);

    if ($Sbuild::Conf::debug) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
    }

    if ($chroot != 0) {
	chdir($Sbuild::Conf::cwd);
    }
    exec $cmdline;
}

sub get_apt_command_internal (\$$$) {
    my $self = shift;
    my $aptcommand = shift; # Command to run
    my $options = shift;    # Command options
    $aptcommand .= ' ' . $self->get('APT Options') . " $options";

    return $aptcommand;
}

sub get_apt_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $options = shift;  # Command options
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message
    my $dir = shift;      # Directory to use (optional)

    my $aptcommand = $self->get_apt_command_internal($command, $options, $dir);

    my $cmdline = $self->get_command($aptcommand, $user, 1, $priority);

    chdir($Sbuild::Conf::cwd);
    return $cmdline;
}

sub run_apt_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $options = shift;  # Command options
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message
    my $dir = shift;      # Directory to use (optional)

    my $aptcommand = $self->get_apt_command_internal($command, $options);

    chdir($Sbuild::Conf::cwd);
    return $self->run_command($aptcommand, $user, 1, $priority, $dir);
}

1;
