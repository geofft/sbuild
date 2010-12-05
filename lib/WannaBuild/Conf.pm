#
# Conf.pm: configuration library for wanna-build
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

package WannaBuild::Conf;

use strict;
use warnings;

use Cwd qw(cwd);
use Sbuild qw(isin);
use Sbuild::ConfBase;
use Sbuild::Log;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new setup read);
}

sub new ();
sub setup ($);
sub read ($);

sub new () {
    my $conf = Sbuild::ConfBase->new();
    WannaBuild::Conf::setup($conf);
    WannaBuild::Conf::read($conf);

    return $conf;
}

sub setup ($) {
    my $conf = shift;

    my $validate_directory = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $conf->get($key);

	die "$key directory is not defined"
	    if !defined($directory);

	die "$key directory $directory does not exist"
	    if !-d $directory;
    };

    my %db_keys = (
	'DB_TYPE'				=> {
	    DEFAULT => 'mldbm'
	},
	'DB_BASE_DIR'				=> {
	    CHECK => $validate_directory,
	    DEFAULT => $Sbuild::Sysconfig::paths{'WANNA_BUILD_LOCALSTATE_DIR'}
	},
	'DB_BASE_NAME'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database base name is not defined"
		    if !defined($conf->get($key));
	    },
	    DEFAULT => 'build-db'
	},
	'DB_TRANSACTION_LOG'			=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database transaction log is not defined"
		    if !defined($conf->get($key));
	    },
	    DEFAULT => 'transactions.log'
	},
	'DB_DISTRIBUTIONS'			=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "No distributions are defined"
		    if !defined($conf->get($key));
	    },
	    DEFAULT => {
		'experimental' => { priority => 4 },
		'unstable' => { priority => 3 },
		'testing' => { priority => 2 },
		'testing-security' => { noadw => 1,
					hidden => 1,
					priority => 2  },
		'stable' => { priority => 1 },
		'stable-security' => { noadw => 1,
				       hidden => 1,
				       priority => 1 },
		'oldstable' => {  priority => 0 },
		'oldstable-security' => { noadw => 1,
					  hidden => 1,
					  priority => 0 },
	    }
	},
	'DB_SECTIONS'				=> {
	    DEFAULT => [
		'main',
		'contrib',
		'non-free'
		]
	},
	'DB_PACKAGES_SOURCE'			=> {
	    DEFAULT => 'ftp://ftp.debian.org/debian'
	},
	'DB_QUINN_SOURCE'			=> {
	    DEFAULT => 'http://buildd.debian.org/quinn-diff/output'
	},
	'DB_ADMIN_USERS'			=> {
	    DEFAULT => [
		'buildd'
		]
	},
	'DB_MAINTAINER_EMAIL'			=> {
	    DEFAULT => 'buildd'
	},
	'DB_NOTFORUS_MAINTAINER_EMAIL'		=> {
	    DEFAULT => 'buildd'
	},
	'DB_LOG_MAIL'				=> {
	    DEFAULT => undef
	},
	'DB_STAT_MAIL'				=> {
	    DEFAULT => undef
	},
	'DB_MAIL_DOMAIN'			=> {
	    DEFAULT => undef
	},
	'DB_WEB_STATS'				=> {
	    DEFAULT => undef
	},
	# Not settable in config file:
	'DB_BIN_NMU_VERSION'			=> {
	    DEFAULT => undef
	},
	'DB_BUILD_PRIORITY'			=> {
	    DEFAULT => 0
	},
	'DB_CATEGORY'				=> {
	    DEFAULT => undef
	},
	'DB_CREATE'				=> {
	    DEFAULT => 0
	},
	'DB_EXPORT_FILE'			=> {
	    DEFAULT => undef
	},
	'DB_FAIL_REASON'			=> {
	    DEFAULT => undef
	},
	'DB_IMPORT_FILE'			=> {
	    DEFAULT => undef
	},
	'DB_INFO_ALL_DISTS'			=> {
	    DEFAULT => 0
	},
	'DB_LIST_MIN_AGE'			=> {
	    DEFAULT => 0
	},
	'DB_LIST_ORDER'				=> {
	    DEFAULT => 'PScpsn'
	},
	'DB_LIST_STATE'				=> {
	    DEFAULT => undef
	},
	# TODO: Don't allow setting if already set.
	'DB_OPERATION'				=> {
	    DEFAULT => undef,
	    SET => sub {
		my $conf = shift;
		my $entry = shift;
		my $value = shift;
		my $key = $entry->{'NAME'};

		if (!$conf->_get_value($key)) {
		    $conf->_set_value($key, $value);
		} else {
		    die "Only one operation may be specified";
		}
	    }
	},
	'DB_OVERRIDE'				=> {
	    DEFAULT => 0
	},
	'DB_USER'				=> {
	    DEFAULT => $conf->get('USERNAME')
	}
    );

    $conf->set_allowed_keys(\%db_keys);
}

sub read ($) {
    my $conf = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT && $conf->get('VERBOSE') == 0) {
	$conf->set('VERBOSE', 1);
    }

    our $HOME = $conf->get('HOME');

    # Variables are undefined, so config will default to DEFAULT if unset.

    # New sbuild.conf format
    our $db_type = undef;
    our $db_base_dir = undef;
    our $db_base_name = undef;
    our $db_transaction_log = undef;
    our %db_distributions;
    undef %db_distributions;
    our @db_distributions;
    undef @db_distributions;
    our %db_distribution_order;
    undef %db_distribution_order;
    our @db_sections;
    undef @db_sections;
    our $db_packages_source = undef;
    our $db_quinn_source = undef;
    our @db_admin_users;
    undef @db_admin_users;
    our $db_maintainer_email = undef;
    our $db_notforus_maintainer_email = undef;
    our $db_log_mail = undef;
    our $db_stat_mail = undef;
    our $db_mail_domain = undef;
    our $db_web_stats = undef;

    # read conf files
    foreach ($Sbuild::Sysconfig::paths{'WANNA_BUILD_CONF'},
	     "$HOME/.wanna-buildrc") {
	if (-r $_) {
	    my $e = eval `cat "$_"`;
	    if (!defined($e)) {
		print STDERR "E: $_: Errors found in configuration file:\n$@";
		exit(1);
	    }
	}
    }

    $conf->set('DB_TYPE', $db_type);
    $conf->set('DB_BASE_DIR', $db_base_dir);
    $conf->set('DB_BASE_NAME', $db_base_name);
    $conf->set('DB_TRANSACTION_LOG', $db_transaction_log);
#	$conf->set('DB_DISTRIBUTIONS', \@db_distributions);
# TODO: Warn if using old value.  Obsolete old options.
    $conf->set('DB_DISTRIBUTIONS', \%db_distribution_order)
    	if (%db_distribution_order);
    $conf->set('DB_DISTRIBUTIONS', \%db_distributions)
    	if (%db_distributions);
    $conf->set('DB_SECTIONS', \@db_sections)
	if (@db_sections);
    $conf->set('DB_PACKAGES_SOURCE', $db_packages_source);
    $conf->set('DB_QUINN_SOURCE', $db_quinn_source);
    $conf->set('DB_ADMIN_USERS', \@db_admin_users)
	if (@db_admin_users);
    $conf->set('DB_MAINTAINER_EMAIL', $db_maintainer_email);
    $conf->set('DB_NOTFORUS_MAINTAINER_EMAIL', $db_notforus_maintainer_email);
    $conf->set('DB_LOG_MAIL', $db_log_mail);
    $conf->set('DB_STAT_MAIL', $db_stat_mail);
    $conf->set('DB_MAIL_DOMAIN', $db_mail_domain);
    $conf->set('DB_WEB_STATS', $db_web_stats);
}

1;
