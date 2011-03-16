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

package Sbuild::ChrootPlain;

use strict;
use warnings;

use POSIX;
use FileHandle;
use File::Temp ();

use Sbuild::Log;
use Sbuild::Sysconfig;

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    # Only run split, because plain makes no guarantee that networking
    # works inside the chroot.
    $self->set('Split', 1);

    return $self;
}

sub begin_session {
    my $self = shift;

    $self->set('Priority', 0);
    $self->set('Location', $self->get('Chroot ID'));
    $self->set('Session Purged', 0);

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    # No-op for sudo.

    return 1;
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'INTCOMMAND'}; # Command to run
    my $user = $options->{'USER'};          # User to run command under
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
	(defined($self->get('Defaults')) &&
	 defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
	defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }

    my @cmdline;

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

    my $need_chroot = 0;
    $need_chroot = 1
	if ($self->get('Location') ne '/');

    my $need_su = 0;
    $need_su = 1
	if (($need_chroot && $user ne 'root') ||
	    (!$need_chroot && $user ne $self->get_conf('USERNAME')));

    push(@cmdline, $self->get_conf('SUDO'))
	if (($need_chroot || $need_su) && $user ne 'root');
    push(@cmdline, '/usr/sbin/chroot', $self->get('Location'))
	if ($need_chroot);
    push(@cmdline, $self->get_conf('SU'), "$user", '-s')
	if ($need_su);
    push(@cmdline, '/bin/sh', '-c', "cd '$dir' && $shellcommand");

    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = undef;
    $options->{'DIR'} = $dir;
}

1;
