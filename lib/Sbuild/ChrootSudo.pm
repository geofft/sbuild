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

package Sbuild::ChrootSudo;

use Sbuild::Conf;
use Sbuild::ChrootInfoSudo;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new ($$$$$);
sub begin_session (\$);
sub end_session (\$);
sub get_command_internal (\$$$$$);

sub new ($$$$$) {
# TODO: specify distribution parameters here...
    my $class = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;
    my $conf = shift;

    my $info = Sbuild::ChrootInfoSudo->new($conf);

    my $self = $class->SUPER::new($distribution, $chroot, $arch, $conf, $info);
    bless($self, $class);

    return $self;
}

sub begin_session (\$) {
    my $self = shift;

    # TODO: Abstract by adding method to get specific chroot info from
    # ChrootInfo.
    my $chroot = $self->get('Chroots')->get('Chroots')->{$self->get('Chroot ID')};

    $self->set('Priority', $chroot->{'Priority'});
    $self->set('Location', $chroot->{'Location'});
    $self->set('Session Purged', $chroot->{'Session Purged'});

    $self->_setup_options();

    return 1;
}

sub end_session (\$) {
    my $self = shift;

    # No-op for sudo.

    return 1;
}

sub _setup_aptconf (\$$) {
    my $self = shift;
    my $aptconf = shift;

    $self->SUPER::_setup_aptconf($aptconf);

    my $chroot_dir = $self->get('Location');

    print $aptconf "Dir \"$chroot_dir\";\n";

# Set in 'APT Options'
#    print $aptconf "Dir::State::status \"$chroot_dir/var/lib/dpkg/status\";\n";
#    print $aptconf "DPkg::Options \"--root=$chroot_dir\";\n";
#    print $aptconf "DPkg::Run-Directory \"$chroot_dir\";\n";
}

sub _setup_options (\$\$) {
    my $self = shift;
    my $info = shift;

    $self->SUPER::_setup_options($info);

    my $chroot_dir = $self->get('Location');

    $self->set('APT Options',
	       "-o Dir::State::status=$chroot_dir/var/lib/dpkg/status".
	       " -o DPkg::Options::=--root=$chroot_dir".
	       " -o DPkg::Run-Directory=$chroot_dir");

    # TODO: Don't alter environment in parent process.
    # sudo uses an absolute path on the host system.
    $ENV{'APT_CONFIG'} = $self->get('Chroot APT Conf');
}

sub get_command_internal (\$$$$$) {
    my $self = shift;
    my $command = shift; # Command to run
    my $user = shift;    # User to run command under
    my $chroot = shift;  # Run in chroot?
    my $dir = shift;     # Directory to use (optional)

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
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

	$cmdline = $self->get_conf('SUDO') . " /usr/sbin/chroot " .
	    $self->get('Location') . ' ' . $self->get_conf('SU') .
	    " -p $user -s /bin/sh -c 'cd $dir && $command'";
    } else { # Run command outside chroot
	if ($user ne 'root' && $user ne $self->get_conf('USERNAME')) {
	    print main::LOG "Command \"$command\" cannot be run as user $user on the host system\n";
	} elsif ($user eq 'root') {
	    $cmdline = $self->get_conf('SUDO') . ' ';
#	    if ($user ne "root") {
#		$cmdline .= "-u $Sbuild::Conf::username ";
#	    }
	}
	my $chdir = "";
	if (defined($dir)) {
	    $chdir = "cd \"$dir\" && ";
	}
	$cmdline .= "/bin/sh -c '$chdir$command'";
    }

    return $cmdline;
}

sub _get_apt_command (\$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message

    return $self->get_command($command, $user, 0, $priority,
			      $self->get('Build Location'));
}

sub _run_apt_command (\$$$$$$) {
    my $self = shift;
    my $command = shift;  # Command to run
    my $user = shift;     # User to run command under
    my $priority = shift; # Priority of log message
    my $dir = shift;      # Directory to use (optional)

    return $self->run_command($command, $user, 0, $priority, $dir);
}

1;
