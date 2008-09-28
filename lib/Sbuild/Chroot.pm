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

use Sbuild::Base;
use Sbuild::Conf;
use Sbuild::ChrootInfo;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new ($$$$$$);
sub _setup_options (\$\$);
sub strip_chroot_path (\$$);
sub log_command (\$$$);
sub get_command (\$$$$$$);
sub run_command (\$$$$$$);
sub exec_command (\$$$$$$);
sub get_apt_command_internal (\$$$);
sub get_apt_command (\$$$$$$);
sub run_apt_command (\$$$$$$);

sub new ($$$$$$) {
# TODO: specify distribution parameters here...
    my $class = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;
    my $conf = shift;
    my $info = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Chroots', $info);
    $self->set('Session ID', "");
    $self->set('Chroot ID', $self->get('Chroots')->find($distribution, $chroot, $arch));

    if (!defined($self->get('Chroot ID'))) {
	return undef;
    }

    return $self;
}

sub _setup_aptconf (\$$) {
    my $self = shift;
    my $aptconf = shift;

    if ($self->get_conf('APT_ALLOW_UNAUTHENTICATED')) {
	print $aptconf "APT::Get::AllowUnauthenticated true;\n";
    }
    print $aptconf "APT::Install-Recommends false;\n";

    if ($self->get_conf('CHROOT_SPLIT')) {
	my $chroot_dir = $self->get('Location');
	print $aptconf "Dir \"$chroot_dir\";\n";
    }
}

sub _setup_options (\$\$) {
    my $self = shift;

    $self->set('Build Location', $self->get('Location') . "/build");
    $self->set('Srcdep Lock Dir', $self->get('Location') . '/' . $self->get_conf('SRCDEP_LOCK_DIR'));
    $self->set('Install Lock', $self->get('Srcdep Lock Dir') . "/install");

    my $aptconf = "/var/lib/sbuild/apt.conf";
    $self->set('APT Conf', $aptconf);

    my $chroot_aptconf = $self->get('Location') . "/$aptconf";
    $self->set('Chroot APT Conf', $chroot_aptconf);

    # Always write out apt.conf, because it may become outdated.
    if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
				DIR => $self->get('Location'),
				UNLINK => 0) ) {
	$self->_setup_aptconf($F);

	if (! rename $F->filename, $chroot_aptconf) {
	    die "Can't rename $F->filename to $chroot_aptconf: $!\n";
	}
    } else {
	die "Can't create $chroot_aptconf: $!";
    }

    # TODO: Don't alter environment in parent process.
    # unsplit mode uses an absolute path inside the chroot, rather
    # than on the host system.
    if ($self->get_conf('CHROOT_SPLIT')) {
	my $chroot_dir = $self->get('Location');

	$self->set('APT Options',
		   "-o Dir::State::status=$chroot_dir/var/lib/dpkg/status".
		   " -o DPkg::Options::=--root=$chroot_dir".
		   " -o DPkg::Run-Directory=$chroot_dir");

	# TODO: Don't alter environment in parent process.
	# sudo uses an absolute path on the host system.
	$ENV{'APT_CONFIG'} = $self->get('Chroot APT Conf');
    } else { # no split
	$self->set('APT Options', "");
	$ENV{'APT_CONFIG'} = $self->get('APT Conf');
    }
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

    if ((defined($priority) && $priority >= 1) || $self->get_conf('DEBUG')) {
	my $options = $self->get('APT Options');
	if ($options ne "" && !$self->get_conf('DEBUG')) {
	    $msg =~ s/\Q$options\E/CHROOT_APT_OPTIONS/g;
	}
	print STDERR "$msg\n";
    }
}

sub get_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $chroot = shift;   # Run in chroot?
    my $priority = shift; # Priority of log message
    my $dir = shift;     # Directory to use (optional)
    my $cmdline = $self->get_command_internal($command, $user, $chroot, $dir);

    if ($self->get_conf('DEBUG')) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
    }

    return $cmdline;
}

# Note, do not run with $user="root", and $chroot=0, because root
# access to the host system is not allowed by schroot, nor required
# via sudo.
sub run_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $chroot = shift;   # Run in chroot?
    my $priority = shift; # Priority of log message
    my $dir = shift;     # Directory to use (optional)
    my $cmdline = $self->get_command_internal($command, $user, $chroot, $dir);

    if ($self->get_conf('DEBUG')) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
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

    if ($self->get_conf('DEBUG')) {
	$self->log_command($cmdline, $priority);
    } else {
	$self->log_command($command, $priority);
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

    my $aptcommand = $self->get_apt_command_internal($command, $options);

    my $cmdline = $self->get_command($aptcommand, $user,
				     $self->apt_chroot(), $priority, $dir);

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

    return $self->run_command($aptcommand, $user,
			      $self->apt_chroot(), $priority, $dir);
}

sub apt_chroot (\$) {
    my $self = shift;

    my $chroot =  $self->get_conf('CHROOT_SPLIT') ? 0 : 1;

    return $chroot
}

1;
