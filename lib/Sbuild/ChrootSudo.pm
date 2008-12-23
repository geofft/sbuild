#
# Chroot.pm: chroot library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
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

use strict;
use warnings;

use Sbuild::Sysconfig;

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
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    return $self;
}

sub begin_session (\$) {
    my $self = shift;
    my $chroot = $self->get('Chroot ID');

    my $info = $self->get('Chroots')->get_info($chroot);

    print STDERR "Setting up chroot $chroot\n"
	if $self->get_conf('DEBUG');

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

    # No-op for sudo.

    return 1;
}

sub get_command_internal (\$$$$$) {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'INTCOMMAND'}; # Command to run
    my $user = $options->{'USER'};          # User to run command under
    my $chroot = $options->{'CHROOT'};      # Run in chroot?
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
	defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }
    if (!defined $chroot) {
	$chroot = 1;
    }

    my @cmdline;
    my $chdir = undef;
    if ($chroot != 0) { # Run command inside chroot
	if (!defined($dir)) {
	    $dir = '/';
	}

	my $shellcommand;
	foreach (@$command) {
	    my $tmp = $_;
	    $tmp =~ s/'//g; # Strip any single quotes for security
	    if ($_ ne $tmp) {
		$self->log_warning("Stripped single quote from command for security: $_\n");
	    }
	    if ($shellcommand) {
		$shellcommand .= " '$tmp'";
	    } else {
		$shellcommand = "'$tmp'";
	    }
	}

	@cmdline = ($self->get_conf('SUDO'), '/usr/sbin/chroot', $self->get('Location'),
		    $self->get_conf('SU'), '-p', "$user", '-s',
		    $Sbuild::Sysconfig::programs{'SHELL'}, '-c',
		    "cd '$dir' && $shellcommand");
    } else { # Run command outside chroot
	if ($options->{'CHDIR_CHROOT'}) {
	    my $tmpdir = $self->get('Location');
	    $tmpdir = $tmpdir . $dir if defined($dir);
	    $dir = $tmpdir;
	}
	if ($user ne 'root' && $user ne $self->get_conf('USERNAME')) {
	    print main::LOG "Command \"$command\" cannot be run as user $user on the host system\n";
	} elsif ($user eq 'root') {
	    @cmdline = ($self->get_conf('SUDO'));
	}
	$chdir = $dir if defined($dir);
	push(@cmdline, @$command);
    }

    $options->{'CHROOT'} = $chroot;
    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = $chdir;
    $options->{'DIR'} = $dir;
}

1;
