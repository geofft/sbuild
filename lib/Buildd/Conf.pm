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

package Buildd::Conf;

use strict;
use warnings;

use Sbuild::ConfBase;
use Sbuild::Sysconfig;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ConfBase);

    @EXPORT = qw($reread_config);
}

my $reread_config = 0;

sub init_allowed_keys {
    my $self = shift;

    $self->SUPER::init_allowed_keys();

    my $validate_program = sub {
	my $self = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $program = $self->get($key);

	die "$key binary is not defined"
	    if !defined($program) || !$program;

	die "$key binary '$program' does not exist or is not executable"
	    if !-x $program;
    };

    my $validate_directory = sub {
	my $self = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $self->get($key);

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$directory' does not exist"
	    if !-d $directory;
    };

    my $validate_ssh = sub {
	my $self = shift;
	my $entry = shift;

	my $sshcmd = $self->get('SSH_CMD');
	my $sshuser;
	my $sshhost;

	if ($sshcmd) {
	    if ($sshcmd =~ /-l\s*(\S+)\s+(\S+)/) {
		($sshuser, $sshhost) = ($1, $2);
	    } elsif ($sshcmd =~ /(\S+)\@(\S+)/) {
		($sshuser, $sshhost) = ($1, $2);
	    } else {
		$sshcmd =~ /(\S+)\s*$/;
		($sshuser, $sshhost) = ("", $1);
	    }
	    $self->set('SSH_USER', $sshuser);
	    $self->set('SSH_HOST', $sshhost);
	}
    };

    my $validate_ssh_socket = sub {
	my $self = shift;
	my $entry = shift;

	my $sshcmd = $self->get('SSH_CMD');
	my $sshsocket = $self->get('SSH_SOCKET');

	if ($sshcmd) {
	    if ($sshsocket) {
		# TODO: This is NOT idempotent!  RL 13/04/09
		$sshcmd .= " -S $sshsocket";
		$self->set('SSH_CMD', $sshcmd);
	    }
	}
    };

    our $HOME = $self->get('HOME');
    $main::HOME = $HOME; # TODO: Remove once Buildd.pm uses $conf
    my $arch = $self->get('ARCH');

    my %buildd_keys = (
	'ADMIN_MAIL'				=> {
	    DEFAULT => 'root'
	},
	'APT_GET'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'APT_GET'}
	},
	'AUTOCLEAN_INTERVAL'			=> {
	    DEFAULT => 86400
	},
	'BUILD_LOG_KEEP'			=> {
	    DEFAULT => 2
	},
	'BUILD_LOG_REGEX'			=> {
	    DEFAULT => undef
	},
	'DAEMON_LOG_KEEP'			=> {
	    DEFAULT => 7
	},
	'DAEMON_LOG_ROTATE'			=> {
	    DEFAULT => 1
	},
	'DAEMON_LOG_SEND'			=> {
	    DEFAULT => 1
	},
	'DELAY_AFTER_GIVE_BACK'			=> {
	    DEFAULT => 8 * 60 # 8 hours
	},
	'DUPLOAD_TO'				=> {
	    DEFAULT => 'anonymous-ftp-master'
	},
	'DUPLOAD_TO_NON_US'			=> {
	    DEFAULT => 'anonymous-non-us'
	},
	'DUPLOAD_TO_SECURITY'			=> {
	    DEFAULT => 'security'
	},
	'ERROR_MAIL_WINDOW'			=> {
	    DEFAULT => 8*60*60
	},
	'IDLE_SLEEP_TIME'			=> {
	    DEFAULT => 5*60
	},
	'LOG_QUEUED_MESSAGES'			=> {
	    DEFAULT => 0
	},
	'MAX_BUILD'				=> {
	    DEFAULT => 10
	},
	'MIN_FREE_SPACE'			=> {
	    DEFAULT => 50*1024
	},
	'NICE_LEVEL'				=> {
	    DEFAULT => 10
	},
	'NO_AUTO_BUILD'				=> {
	    DEFAULT => []
	},
	'BUILD_REGEX'				=> {
	    DEFAULT => ''
	},
	'NO_BUILD_REGEX'			=> {
	    DEFAULT => '^(contrib/|non-free/)?non-US/'
	},
	'NO_WARN_PATTERN'			=> {
	    DEFAULT => '^build/(SKIP|REDO|SBUILD-GIVEN-BACK|buildd\.pid|[^/]*.ssh|chroot-[^/]*)$'
	},
	'PKG_LOG_KEEP'				=> {
	    DEFAULT => 7
	},
	'SECONDARY_DAEMON_THRESHOLD'		=> {
	    DEFAULT => 70
	},
	'SHOULD_BUILD_MSGS'			=> {
	    DEFAULT => 1
	},
	'SSH_CMD'				=> {
	    DEFAULT => '',
	    CHECK => $validate_ssh,
	},
	'SSH_USER'				=> {
	    DEFAULT => ''
	},
	'SSH_HOST'				=> {
	    DEFAULT => ''
	},
	'SSH_SOCKET'				=> {
	    DEFAULT => '',
	    CHECK => $validate_ssh_socket,
	},
	'STATISTICS_MAIL'			=> {
	    DEFAULT => 'root'
	},
	'STATISTICS_PERIOD'			=> {
	    DEFAULT => 7
	},
	'SUDO'					=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'SUDO'}
	},
	'TAKE_FROM_DISTS'			=> {
	    DEFAULT => []
	},
	'WANNA_BUILD_DBBASE'			=> {
	    DEFAULT => "$arch/build-db"
	},
	'WANNA_BUILD_USER'			=> {
	    DEFAULT => $Buildd::username
	},
	'WARNING_AGE'				=> {
	    DEFAULT => 7
	},
	'WEAK_NO_AUTO_BUILD'			=> {
	    DEFAULT => []
	},
	'CONFIG_GLOBAL_TIME'			=> {
	    DEFAULT => 0
	},
	'CONFIG_USER_TIME'			=> {
	    DEFAULT => 0
	});

    $self->set_allowed_keys(\%buildd_keys);
}

sub read_config {
    my $self = shift;

    my $HOME = $self->get('HOME');

    # Variables are undefined, so config will default to DEFAULT if unset.
    our $admin_mail = undef;
    our $apt_get = undef;
    our $arch = undef;
    our $autoclean_interval = undef;
    our $build_log_keep = undef;
    our $build_regex = undef; # Should this be user settable?
    our $daemon_log_keep = undef;
    our $daemon_log_rotate = undef;
    our $daemon_log_send = undef;
    our $delay_after_give_back = undef;
    our $dupload_to = undef;
    our $dupload_to_non_us = undef;
    our $dupload_to_security = undef;
    our $error_mail_window = undef;
    our $idle_sleep_time = undef;
    our $log_queued_messages = undef;
    our $max_build = undef;
    our $min_free_space = undef;
    our $nice_level = undef;
    our @no_auto_build;
    our $no_build_regex = undef;
    our $no_warn_pattern = undef;
    our $pkg_log_keep = undef;
    our $secondary_daemon_threshold = undef;
    our $should_build_msgs = undef;
    our $sshcmd = undef;
    our $statistics_mail = undef;
    our $statistics_period = undef;
    our $sudo = undef;
    our @take_from_dists;
    our $wanna_build_dbbase = undef;
    our $wanna_build_user = undef;
    our $warning_age = undef;
    our @weak_no_auto_build;

    my $global = $Sbuild::Sysconfig::paths{'BUILDD_CONF'};
    my $user = "$HOME/.builddrc";
    my $global_time = 0;
    my $user_time = 0;

    my $reread = 0;

    sub ST_MTIME () { 9 }

    if (-r $global) {
        my @stat = stat($global);
	if ($self->get('CONFIG_GLOBAL_TIME') < $stat[ST_MTIME]) {
	    $global_time = $stat[ST_MTIME];
	}
    }

    if (-r $user) {
        my @stat = stat($user);
	if ($self->get('CONFIG_USER_TIME') < $stat[ST_MTIME]) {
	    $user_time = $stat[ST_MTIME];
	}
    }

    $reread = 1 if ($reread_config || $global_time || $user_time);
    $reread_config = 0;

    # Need to reread all config files, even if one is updated.

    if ($reread && -r $global) {
	delete $INC{$global};
	require $global;
	$self->set('CONFIG_GLOBAL_TIME', $global_time);
    }

    if ($reread && -r $user) {
	delete $INC{$user};
	require $user;
	$self->set('CONFIG_USER_TIME', $user_time);
    }

    # Set configuration if updated.
    if ($reread) {
	$self->set('ADMIN_MAIL', $admin_mail);
	$self->set('APT_GET', $apt_get);
	$self->set('ARCH', $arch);
	$self->set('AUTOCLEAN_INTERVAL', $autoclean_interval);
	$self->set('BUILD_LOG_KEEP', $build_log_keep);
	$self->set('BUILD_REGEX', $build_regex);
	$self->set('DAEMON_LOG_KEEP', $daemon_log_keep);
	$self->set('DAEMON_LOG_ROTATE', $daemon_log_rotate);
	$self->set('DAEMON_LOG_SEND', $daemon_log_send);
	$self->set('DELAY_AFTER_GIVE_BACK', $delay_after_give_back);
	$self->set('DUPLOAD_TO', $dupload_to);
	$self->set('DUPLOAD_TO_NON_US', $dupload_to_non_us);
	$self->set('DUPLOAD_TO_SECURITY', $dupload_to_security);
	$self->set('ERROR_MAIL_WINDOW', $error_mail_window);
	$self->set('IDLE_SLEEP_TIME', $idle_sleep_time);
	$self->set('LOG_QUEUED_MESSAGES', $log_queued_messages);
	$self->set('MAX_BUILD', $max_build);
	$self->set('MIN_FREE_SPACE', $min_free_space);
	$self->set('NICE_LEVEL', $nice_level);
	$self->set('NO_AUTO_BUILD', \@no_auto_build);
	$self->set('NO_BUILD_REGEX', $no_build_regex);
	$self->set('BUILD_REGEX', $build_regex);
	$self->set('NO_WARN_PATTERN', $no_warn_pattern);
	$self->set('PKG_LOG_KEEP', $pkg_log_keep);
	$self->set('SECONDARY_DAEMON_THRESHOLD', $secondary_daemon_threshold);
	$self->set('SHOULD_BUILD_MSGS', $should_build_msgs);
	$self->set('SSH_CMD', $sshcmd);
	$self->set('STATISTICS_MAIL', $statistics_mail);
	$self->set('STATISTICS_PERIOD', $statistics_period);
	$self->set('SUDO', $sudo);
	$self->set('TAKE_FROM_DISTS', \@take_from_dists);
	$self->set('WANNA_BUILD_DBBASE', $wanna_build_dbbase);
	$self->set('WANNA_BUILD_USER', $wanna_build_user);
	$self->set('WARNING_AGE', $warning_age);
	$self->set('WEAK_NO_AUTO_BUILD', \@weak_no_auto_build)
	    if (@weak_no_auto_build);

	# Set here to allow user to override.
	if (-t STDIN && -t STDOUT && $self->get('NO_DETACH')) {
	    $self->set('VERBOSE', 1);
	}
    }

}

1;
