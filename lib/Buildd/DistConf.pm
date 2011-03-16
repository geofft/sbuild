#
# Conf.pm: configuration library for buildd
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

package Buildd::DistConf;

use strict;
use warnings;

use Sbuild::ConfBase;
use Sbuild::Sysconfig;
use Buildd::ClientConf qw();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new_hash setup read_hash);
}

sub new_hash (@);
sub setup ($);
sub read_hash ($$);

sub new_hash (@) {
    my %opts = @_;

    my $queue_config = Sbuild::ConfBase->new(%opts);

    Buildd::DistConf::setup($queue_config);
    Buildd::DistConf::read_hash($queue_config, $opts{'HASH'});

    return $queue_config;
}

sub setup ($) {
    my $conf = shift;

    my $validate_directory_in_home = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $conf->get($key);
	my $home_directory = $conf->get('HOME');

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$home_directory/$directory' does not exist"
	    if !-d $home_directory . "/" . $directory;
    };

    my $arch = $conf->get('ARCH');

    my %buildd_dist_keys = (
	'DIST_NAME'				=> {
	    DEFAULT => 'unstable'
	},
	'BUILT_ARCHITECTURE'			=> {
	    DEFAULT => undef,
	},
	'SBUILD_CHROOT'                         => {
	    DEFAULT => undef,
	},
	'WANNA_BUILD_SSH_HOST'			=> {
	    DEFAULT => 'buildd.debian.org'
	},
	'WANNA_BUILD_SSH_USER'			=> {
	    DEFAULT => 'buildd_' . $arch
	},
	'WANNA_BUILD_SSH_SOCKET'		=> {
	    DEFAULT => undef
	},
	'WANNA_BUILD_SSH_OPTIONS'		=> {
	    DEFAULT => []
	},
	'WANNA_BUILD_DB_NAME'			=> {
	    DEFAULT => undef,
	},
	'WANNA_BUILD_DB_USER'			=> {
	    DEFAULT => $Buildd::username
	},
	'WANNA_BUILD_API'			=> {
	    DEFAULT => undef,
	},
	'DUPLOAD_LOCAL_QUEUE_DIR'		=> {
	    CHECK => $validate_directory_in_home,
	    DEFAULT => 'upload'
	},
	'NO_AUTO_BUILD'				=> {
	    DEFAULT => []
	},
	'WEAK_NO_AUTO_BUILD'			=> {
	    DEFAULT => []
	},
	'NO_BUILD_REGEX'			=> {
	    DEFAULT => undef
	},
	'BUILD_REGEX'				=> {
	    DEFAULT => undef
	},
	'LOGS_MAILED_TO'			=> {
	    DEFAULT => undef
	},
	'BUILD_DEP_RESOLVER'			=> {
	    DEFAULT => undef
	},);

    $conf->set_allowed_keys(\%buildd_dist_keys);

    Buildd::ClientConf::setup($conf);
}

sub read_hash($$) {
    my $conf = shift;
    my $data = shift;

    for my $key (keys %$data) {
	$conf->set($key, $data->{$key});
    }
}

1;
