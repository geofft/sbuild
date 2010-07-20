#
# ChrootRoot.pm: Run commands on the root filesystem
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootRoot;

use strict;
use warnings;

use Sbuild qw(debug);
use Sbuild::Conf;
use Sbuild::ChrootPlain;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf, '/');
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

    # No-op.

    return 1;
}

sub exec_chdir {
    my $self = shift;
    my $dir = shift;

    if (defined($dir) && $dir) {
	debug("Changing to directory: $dir\n");
	chdir($dir) or die "Can't change directory to $dir: $!";
    }
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
    if ($user ne $self->get_conf('USERNAME')) {
	$self->log_warning("Command \"$command\" cannot be run as user $user on the host system\n");
    }
    push(@cmdline, @$command);

    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'DIR'} = $dir;
}

1;
