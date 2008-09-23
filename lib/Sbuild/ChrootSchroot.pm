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

package Sbuild::ChrootSchroot;

use Sbuild::Conf;
use Sbuild::ChrootInfoSchroot;

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

    my $info = Sbuild::ChrootInfoSchroot->new($conf);

    my $self = $class->SUPER::new($distribution, $chroot, $arch, $conf, $info);
    bless($self, $class);

    return $self;
}

sub begin_session (\$) {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    my $schroot_session=readpipe($self->get_conf('SCHROOT') . " -c $chroot --begin-session");
    chomp($schroot_session);
    if ($?) {
	print STDERR "Chroot setup failed\n";
	return 0;
    }

    $self->set('Session ID', $schroot_session);
    print STDERR "Setting up chroot $chroot (session id $schroot_session)\n"
	if $self->get_conf('DEBUG');

    my $info = $self->get('Chroots')->get_info($schroot_session);
	if (defined($info) &&
	    defined($info->{'Location'}) && -d $info->{'Location'}) {
	    $self->set('Priority', $info->{'Priority'});
	    $self->set('Location', $info->{'Location'});
	    $self->set('Session Purged', $info->{'Session Purged'});
    } else {
	die $self->get('Chroot ID') . " chroot does not exist\n";
    }

    $self->_setup_options();
    return 1;
}

sub end_session (\$) {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
	if $self->get_conf('DEBUG');
    system($self->get_conf('SCHROOT') . ' -c ' . $self->get('Session ID') . ' --end-session');
    $self->set('Session ID', "");
    if ($?) {
	print STDERR "Chroot cleanup failed\n";
	return 0;
    }
    return 1;
}

sub _setup_options (\$\$) {
    my $self = shift;
    my $info = shift;

    $self->SUPER::_setup_options($info);

    $self->set('APT Options', "");

    # TODO: Don't alter environment in parent process.
    # schroot uses an absolute path inside the chroot, rather than on
    # the host system.
    $ENV{'APT_CONFIG'} = $self->get('APT Conf');
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
	$cmdline = $self->get_conf('SCHROOT') . " -d '$dir' -c " . $self->get('Session ID') .
	    " --run-session " . $self->get_conf('SCHROOT_OPTIONS')  .
	    " -u $user -p -- /bin/sh -c '$command'";
    } else { # Run command outside chroot
	if (!defined($dir)) {
	    $dir = $self->get('Build Location');
	}
	if ($user ne $self->get_conf('USERNAME')) {
	    print main::LOG "Command \"$command\" cannot be run as root or any other user on the host system\n";
	}
	my $chdir = "";
	if (defined($dir)) {
	    $chdir = "cd \"$dir\" && ";
	}
	$cmdline .= "/bin/sh -c '$chdir$command'";
    }

    return $cmdline;
}

sub apt_chroot (\$) {
    my $self = shift;

    return 1;
}

1;
