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

    @ISA = qw(Exporter Sbuild::ConfBase);

    @EXPORT = qw();
}

sub init_allowed_keys {
    my $self = shift;

    $self->SUPER::init_allowed_keys();

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

    my %db_keys = (
	'DB_BASE_DIR'				=> {
	    CHECK => $validate_directory,
	    DEFAULT => $Sbuild::Sysconfig::paths{'WANNA_BUILD_LOCALSTATE_DIR'}
	},
	'DB_BASE_NAME'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database base name is not defined"
		    if !defined($self->get($key));
	    },
	    DEFAULT => 'build-db'
	},
	'DB_TRANSACTION_LOG'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database transaction log is not defined"
		    if !defined($self->get($key));
	    },
	    DEFAULT => 'transactions.log'
	},
	'DB_DISTRIBUTIONS'			=> {
	    DEFAULT => [
		'oldstable-security',
		'stable',
		'testing',
		'unstable',
		'stable-security',
		'testing-security'
		]
	},
	'DB_DISTRIBUTION_ORDER'			=> {
	    DEFAULT => {
		'oldstable-security'	=> 0,
		'stable'		=> 1,
		'stable-security'	=> 1,
		'testing'		=> 2,
		'testing-security'	=> 2,
		'unstable'		=> 3
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
	'DB_NO_DOWN_PROPAGATION'		=> {
	    DEFAULT => 0
	},
	'DB_NO_PROPAGATION'			=> {
	    DEFAULT => 0
	},
	# TODO: Don't allow setting if already set.
	'DB_OPERATION'				=> {
	    DEFAULT => undef,
	    SET => sub {
		my $self = shift;
		my $entry = shift;
		my $value = shift;
		my $key = $entry->{'NAME'};

		if (!$self->_get_value($key)) {
		    $self->_set_value($key, $value);
		} else {
		    die "Only one operation may be specified";
		}
	    }
	},
	'DB_OVERRIDE'				=> {
	    DEFAULT => 0
	},
	'DB_USER'				=> {
	    DEFAULT => $self->get('USERNAME')
	}
    );

    $self->set_allowed_keys(\%db_keys);
}

sub read_config {
    my $self = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT && $self->get('VERBOSE') == 0) {
	$self->set('VERBOSE', 1);
    }

    my $HOME = $self->get('HOME');

    # Variables are undefined, so config will default to DEFAULT if unset.

    # NOTE: For legacy wanna-build.conf format parsing
    our $basedir = undef;
    our $dbbase = undef;
    our $transactlog = undef;
    our @distributions;
    undef @distributions;
    our %dist_order;
    undef %dist_order;
    our @sections;
    undef @sections;
    our $pkgs_source = undef;
    our $quinn_source = undef;
    our @admin_users;
    undef @admin_users;
    our $maint = undef;
    our $notforus_maint = undef;
    our $log_mail = undef;
    our $stat_mail = undef;
    our $web_stats = undef;

    # New sbuild.conf format
    our $db_base_dir = undef;
    our $db_base_name = undef;
    our $db_transaction_log = undef;
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
    our $db_web_stats = undef;

    # read conf files
    my $legacy_db = 0;
    if (-r $Sbuild::Sysconfig::paths{'WANNA_BUILD_CONF'}) {
	warn "W: Reading obsolete configuration file $Sbuild::Sysconfig::paths{'WANNA_BUILD_CONF'}";
	warn "I: This file has been merged with $Sbuild::Sysconfig::paths{'SBUILD_CONF'}";
	$legacy_db = 1;
	require $Sbuild::Sysconfig::paths{'WANNA_BUILD_CONF'};
    }
    if (-r "$HOME/.wanna-buildrc") {
	warn "W: Reading obsolete configuration file $HOME/.wanna-buildrc";
	warn "W: This file has been merged with $HOME/.sbuildrc";
	$legacy_db = 1;
	require "$HOME/.wanna-buildrc";
    }
    require $Sbuild::Sysconfig::paths{'SBUILD_CONF'}
        if -r $Sbuild::Sysconfig::paths{'SBUILD_CONF'};
    require "$HOME/.sbuildrc" if -r "$HOME/.sbuildrc";

    if ($legacy_db) { # Using old wanna-build.conf
	$self->set('DB_BASE_DIR', $basedir);
	# TODO: Don't allow slash in name
	$self->set('DB_BASE_NAME', $dbbase);
	$self->set('DB_TRANSACTION_LOG', $transactlog);
	$self->set('DB_DISTRIBUTIONS', \@distributions);
	$self->set('DB_DISTRIBUTION_ORDER', \%dist_order);
	$self->set('DB_SECTIONS', \@sections);
	$self->set('DB_PACKAGES_SOURCE', $pkgs_source);
	$self->set('DB_QUINN_SOURCE', $quinn_source);
	$self->set('DB_ADMIN_USERS', \@admin_users);
	$self->set('DB_MAINTAINER_EMAIL', $maint);
	$self->set('DB_NOTFORUS_MAINTAINER_EMAIL', $notforus_maint);
	$self->set('DB_LOG_MAIL', $log_mail);
	$self->set('DB_STAT_MAIL', $stat_mail);
	$self->set('DB_WEB_STATS', $web_stats);
    } else { # Using sbuild.conf
	$self->set('DB_BASE_DIR', $db_base_dir);
	$self->set('DB_BASE_NAME', $db_base_name);
	$self->set('DB_TRANSACTION_LOG', $db_transaction_log);
	$self->set('DB_DISTRIBUTIONS', \@db_distributions);
	$self->set('DB_DISTRIBUTION_ORDER', \%db_distribution_order);
	$self->set('DB_SECTIONS', \@db_sections);
	$self->set('DB_PACKAGES_SOURCE', $db_packages_source);
	$self->set('DB_QUINN_SOURCE', $db_quinn_source);
	$self->set('DB_ADMIN_USERS', \@db_admin_users);
	$self->set('DB_MAINTAINER_EMAIL', $db_maintainer_email);
	$self->set('DB_NOTFORUS_MAINTAINER_EMAIL', $db_notforus_maintainer_email);
	$self->set('DB_LOG_MAIL', $db_log_mail);
	$self->set('DB_STAT_MAIL', $db_stat_mail);
	$self->set('DB_WEB_STATS', $db_web_stats);
    }
}

1;
