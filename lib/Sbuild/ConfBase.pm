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

sub init_allowed_keys {
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

    my $home = $ENV{'HOME'}
        or die "HOME not defined in environment!\n";
    my @pwinfo = getpwuid($<);
    my $username = $pwinfo[0] || $ENV{'LOGNAME'} || $ENV{'USER'};
    my $fullname = $pwinfo[6];
    $fullname =~ s/,.*$//;

    chomp(my $hostname = `$Sbuild::Sysconfig::programs{'HOSTNAME'} -f`);

    # Not user-settable.
    chomp(my $host_arch =
	  readpipe("$Sbuild::Sysconfig::programs{'DPKG'} --print-architecture"));

    my %common_keys = (
	'DISTRIBUTION'				=> {
	    SET => sub {
		my $self = shift;
		my $entry = shift;
		my $value = shift;
		my $key = $entry->{'NAME'};

		$self->_set_value($key, $value);

		my $override = ($self->get($key)) ? 1 : 0;
		$self->set('OVERRIDE_DISTRIBUTION', $override);

		#Now, we might need to adjust the MAILTO based on the
		#config data. We shouldn't do this if it was already
		#explicitly set by the command line option:
		if (!$self->get('MAILTO_FORCED_BY_CLI') 
		    && defined($self->get('DISTRIBUTION')) 
		    && $self->get('DISTRIBUTION') 
		    && $self->get('MAILTO_HASH')->{$self->get('DISTRIBUTION')}) {
		    $self->set('MAILTO',
		        $self->get('MAILTO_HASH')->{$self->get('DISTRIBUTION')});
		}
	    }
	},
	'OVERRIDE_DISTRIBUTION'			=> {
	    DEFAULT => 0
	},
	'MAILPROG'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'SENDMAIL'}
	},
	# TODO: Check if defaulted in code assuming undef
	'ARCH'					=> {
	    DEFAULT => $host_arch
	},
	'HOST_ARCH'				=> {
	    DEFAULT => $host_arch
	},
	'HOSTNAME'				=> {
	    DEFAULT => $hostname
	},
	'HOME'					=> {
	    DEFAULT => $home
	},
	'USERNAME'				=> {
	    DEFAULT => $username
	},
	'FULLNAME'				=> {
	    DEFAULT => $fullname
	},
	'CWD'					=> {
	    DEFAULT => cwd()
	},
	'VERBOSE'				=> {
	    DEFAULT => 0
	},
	'DEBUG'					=> {
	    DEFAULT => 0
	},
	'DPKG'					=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'DPKG'}
	},
    );

    $self->set_allowed_keys(\%common_keys);
}

sub new {
    my $class = shift;

    my $self  = {};
    $self->{'config'} = {};
    bless($self, $class);

    $self->init_allowed_keys();
    $self->read_config();

    return $self;
}

sub is_default {
    my $self = shift;
    my $key = shift;

    return ($self->_get_value($key) == undef);
}

sub _get_property_value {
    my $self = shift;
    my $key = shift;
    my $property = shift;

    my $entry = $self->{'KEYS'}->{$key};

    return $entry->{$property};
}

sub _get_value {
    my $self = shift;
    my $key = shift;

    return $self->_get_property_value($key, 'VALUE');
}

sub _get_default {
    my $self = shift;
    my $key = shift;

    return $self->_get_property_value($key, 'DEFAULT');
}

sub get {
    my $self = shift;
    my $key = shift;

    my $entry = $self->{'KEYS'}->{$key};

    my $value = undef;
    if ($entry) {
	if (defined($entry->{'GET'})) {
	    $value = $entry->{'GET'}->($self, $entry);
	} else {
	    $value = $self->_get_value($key);
	    $value = $self->_get_default($key)
		if (!defined($value));
	}
    }

    return $value;
}

sub _set_property_value {
    my $self = shift;
    my $key = shift;
    my $property = shift;
    my $value = shift;

    my $entry = $self->{'KEYS'}->{$key};

    return $entry->{$property} = $value;
}

sub _set_value {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->_set_property_value($key, 'VALUE', $value);
}

sub _set_default {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->_set_property_value($key, 'DEFAULT', $value);
}

sub set {
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
	    $value = $self->_set_value($key, $value);
	}
	if (defined($entry->{'CHECK'})) {
	    $entry->{'CHECK'}->($self, $entry);
	}
	$entry->{'NAME'} = $key;
	return $value;
    } else {
	warn "W: key \"$key\" is not allowed in configuration";
	return undef;
    }
}

sub set_allowed_keys {
    my $self = shift;
    my $allowed_keys = shift;

    foreach (keys %{$allowed_keys}) {
	$allowed_keys->{$_}->{'NAME'} = $_;
	$self->{'KEYS'}->{$_} = $allowed_keys->{$_}
    }

}

sub warn_deprecated {
    my $oldtype = shift;
    my $oldopt = shift;
    my $newtype = shift;
    my $newopt = shift;

    warn "W: Obsolete $oldtype option '$oldopt' used in configuration";
    warn "I: The replacement is $newtype option '$newopt'"
}

1;
