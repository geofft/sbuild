#
# ClientConf.pm: configuration library for wanna-build clients
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::DB::ClientConf;

use strict;
use warnings;

use Sbuild::Sysconfig;
use File::Spec;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(setup);
}

sub setup ($) {
    my $conf = shift;

    my $validate_program = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $program = $conf->get($key);

	die "$key binary is not defined"
	    if !defined($program) || !$program;

	# Emulate execvp behaviour by searching the binary in the PATH.
	my @paths = split(/:/, $ENV{'PATH'});
	# Also consider the empty path for absolute locations.
	push (@paths, '');
	my $found = 0;
	foreach my $path (@paths) {
	    $found = 1 if (-x File::Spec->catfile($path, $program));
	}

	die "$key binary '$program' does not exist or is not executable"
	    if !$found;
    };

    my $validate_ssh = sub {
	my $conf = shift;
	my $entry = shift;

# TODO: Provide self, config and entry contexts, which functions to
# get at needed data.  Provide generic configuration functions.
#
	$validate_program->($conf, $conf->{'KEYS'}->{'SSH'});

	my $ssh = $conf->get('SSH');
	my $sshuser = $conf->get('WANNA_BUILD_SSH_USER');
	my $sshhost = $conf->get('WANNA_BUILD_SSH_HOST');
	my @sshoptions = @{$conf->get('WANNA_BUILD_SSH_OPTIONS')};
	my $sshsocket = $conf->get('WANNA_BUILD_SSH_SOCKET');

	my @command = ();

	if ($sshhost) {
	    push (@command, $ssh);
	    push (@command, '-l', $sshuser) if $sshuser;
	    push (@command, '-S', $sshsocket) if $sshsocket;
	    push (@command, @sshoptions) if @sshoptions;
	    push (@command, $sshhost);
	}

	$conf->set('WANNA_BUILD_SSH_CMD', \@command);
    };

    our $HOME = $conf->get('HOME');
    my $arch = $conf->get('ARCH');

    my %db_keys = (
	'SSH'					=> {
	    DEFAULT => 'ssh',
	    CHECK => $validate_ssh,
	},
	'WANNA_BUILD_SSH_CMD'			=> {
	    DEFAULT => ''
	},
	'WANNA_BUILD_SSH_USER'			=> {
	    DEFAULT => '',
	    CHECK => $validate_ssh,
	},
	'WANNA_BUILD_SSH_HOST'			=> {
	    DEFAULT => '',
	    CHECK => $validate_ssh,
	},
	'WANNA_BUILD_SSH_SOCKET'		=> {
	    DEFAULT => '',
	    CHECK => $validate_ssh,
	},
	'WANNA_BUILD_SSH_OPTIONS'		=> {
	    DEFAULT => [],
	    CHECK => $validate_ssh,
	},
	'WANNA_BUILD_DB_NAME'			=> {
	    DEFAULT => undef,
	},
	'WANNA_BUILD_DB_USER'			=> {
	    DEFAULT => $conf->get('USERNAME')
	},
	'BUILT_ARCHITECTURE'			=> {
	    DEFAULT => $arch,
	},);

    $conf->set_allowed_keys(\%db_keys);
}

1;
