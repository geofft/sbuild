#
# Client.pm: client library for wanna-build
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::DB::Client;

use strict;
use warnings;

use Sbuild qw($devnull);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('SETUP', 0);

    return $self;
}

sub setup {
    my $self = shift;

    if (!$self->get('SETUP')) {
	my $host = Sbuild::ChrootRoot->new($self->get('Config'));
	$host->set('Log Stream', $self->get('Log Stream'));
	$self->set('Host', $host);
	$self->set('SETUP', 1);
    }
}

sub get_query {
    my $self = shift;

    my @command = ($self->get_conf('WANNA_BUILD_SSH_CMD'), 'wanna-build');
    push(@command, "--database=" . $self->get_conf('WANNA_BUILD_DB_NAME'))
	if $self->get_conf('WANNA_BUILD_DB_NAME');
    push(@command, "--user=" . $self->get_conf('WANNA_BUILD_DB_USER'))
	if $self->get_conf('WANNA_BUILD_DB_USER');
    push(@command, @_);

    return @command;
}

sub run_query {
    my $self = shift;

    my @command = $self->get_query(@_);

    $self->setup();

    my $pipe = $self->get('Host')->run_command(
	{ COMMAND => [@command],
	  USER => $self->get_conf('USERNAME'),
	  CHROOT => 1,
	  PRIORITY => 0,
	});
}

sub pipe_query {
    my $self = shift;

    my @command = $self->get_query(@_);

    $self->setup();

    my $pipe = $self->get('Host')->pipe_command(
	{ COMMAND => [@command],
	  USER => $self->get_conf('USERNAME'),
	  CHROOT => 1,
	  PRIORITY => 0,
	});

    return $pipe;
}

sub pipe_query_out {
    my $self = shift;

    my @command = $self->get_query(@_);

    $self->setup();

    my $pipe = $self->get('Host')->pipe_command(
	{ COMMAND => [@command],
	  USER => $self->get_conf('USERNAME'),
	  PIPE => 'out',
	  STREAMOUT => $devnull,
	  CHROOT => 1,
	  PRIORITY => 0,
	});

    return $pipe;
}

1;
