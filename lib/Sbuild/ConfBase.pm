#
# ConfBase.pm: configuration library (base functionality) for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ConfBase;

use strict;
use warnings;

use Cwd qw(cwd);
use Sbuild qw(isin);
use Sbuild::Log;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub init_allowed_keys (\%$) {
    my $self = shift;

    my $validate_program = sub {
	my $self = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $program = $self->get($key);

	die "$key binary is not defined"
	    if !defined($program);

	die "$key binary $program does not exist or is not executable"
	    if !-x $program;
    };

    my $validate_directory = sub {
	my $self = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $self->get($key);

	die "$key directory is not defined"
	    if !defined($directory);

	die "$key directory $directory does not exist"
	    if !-d $directory;
    };

    my %common_keys = (
	'DISTRIBUTION'				=> {},
	'OVERRIDE_DISTRIBUTION'			=> {},
	'MAILPROG'				=> {
	    CHECK => $validate_program
	},
	'ARCH'					=> {},
	'HOST_ARCH'				=> {},
	'HOSTNAME'				=> {},
	'HOME'					=> {},
	'USERNAME'				=> {},
	'CWD'					=> {},
	'VERBOSE'				=> {},
	'DEBUG'					=> {},
	'DPKG'					=> {
	    CHECK => $validate_program
	},
    );

    $self->set_allowed_keys(\%common_keys);
}

sub new ($$) {
    my $class = shift;

    my $self  = {};
    $self->{'config'} = {};
    bless($self, $class);

    $self->init_allowed_keys();
    $self->read_config();

    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    my $entry = $self->{'KEYS'}->{$key};

    my $value = undef;
    if ($entry) {
	if (defined($entry->{'GET'})) {
	    $value = $entry->{'GET'}->($self, $entry);
	} else {
	    if (defined($entry->{'VALUE'})) {
		$value = $entry->{'VALUE'};
	    } elsif (defined($entry->{'DEFAULT'})) {
		$value = $entry->{'DEFAULT'};
	    }
	}
    }

    return $value;
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    # Set global debug level.
    $Sbuild::debug_level = $value
	if ($key eq 'DEBUG');

    my $entry = $self->{'KEYS'}->{$key};

    if (defined($entry)) {
	if (defined($entry->{'SET'})) {
	    $value = $entry->{'SET'}->($self, $entry, $value);
	} else {
	    $entry->{'VALUE'} = $value;
	}
	if (defined($entry->{'CHECK'})) {
	    $entry->{'CHECK'}->($self, $entry);
	}
	$entry->{'NAME'} = $key;
	return $value;
    } else {
	warn "W: key \"$key\" is not allowed in sbuild configuration";
	return undef;
    }
}

sub set_allowed_keys (\%\%) {
    my $self = shift;
    my $allowed_keys = shift;

    foreach (keys %{$allowed_keys}) {
	$allowed_keys->{$_}->{'NAME'} = $_;
	$self->{'KEYS'}->{$_} = $allowed_keys->{$_}
    }

}

1;
