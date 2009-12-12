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

package Sbuild::ChrootSchroot;

use strict;
use warnings;

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

    return $self;
}

sub begin_session {
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

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
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

    my @cmdline = ();
    if (!defined($dir)) {
	$dir = '/';
    }
    @cmdline = ($self->get_conf('SCHROOT'),
		'-d', $dir,
		'-c', $self->get('Session ID'),
		'--run-session',
		@{$self->get_conf('SCHROOT_OPTIONS')},
		'-u', "$user", '-p', '--',
		@$command);

    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'DIR'} = $dir;
}

1;
