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

package Buildd::UploadQueueConf;

use strict;
use warnings;

use Sbuild::ConfBase;
use Sbuild::Sysconfig;

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

    Buildd::UploadQueueConf::setup($queue_config);
    Buildd::UploadQueueConf::read_hash($queue_config, $opts{'HASH'});

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

    my %dupload_queue_keys = (
	'DUPLOAD_LOCAL_QUEUE_DIR'		=> {
	    CHECK => $validate_directory_in_home,
	    DEFAULT => 'upload'
	},
	'DUPLOAD_ARCHIVE_NAME'		=> {
	    DEFAULT => 'anonymous-ftp-master'
	},
    );

    $conf->set_allowed_keys(\%dupload_queue_keys);

    Buildd::ClientConf::setup($conf);
}

sub read_hash ($$) {
    my $conf = shift;
    my $data = shift;

    for my $key (keys %$data) {
	$conf->set($key, $data->{$key});
    }
}

1;
