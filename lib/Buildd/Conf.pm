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
use Sbuild::DB::ClientConf qw();

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
	'DAEMON_LOG_FILE'			=> {
	    DEFAULT => "$HOME/daemon.log"
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
	'NO_DETACH'				=> {
	    DEFAULT => 0
	},
	'NO_WARN_PATTERN'			=> {
	    DEFAULT => '^build/(SKIP|REDO|SBUILD-GIVEN-BACK|buildd\.pid|[^/]*.ssh|chroot-[^/]*)$'
	},
	'PIDFILE'                               => {
# Set once running as a system service.
#          DEFAULT => "${Sbuild::Sysconfig::paths{'LOCALSTATEDIR'}/run/buildd.pid"
	    DEFAULT => "$HOME/build/buildd.pid"
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
	'WARNING_AGE'				=> {
	    DEFAULT => 7
	},
	'WEAK_NO_AUTO_BUILD'			=> {
	    DEFAULT => []
	},
	'CONFIG_TIME'				=> {
	    DEFAULT => {}
	});

    $self->set_allowed_keys(\%buildd_keys);
    Sbuild::DB::ClientConf::add_keys($self);
}

sub read_config {
    my $self = shift;

    my $HOME = $self->get('HOME');

    # Variables are undefined, so config will default to DEFAULT if unset.
    my $admin_mail = undef;
    my $apt_get = undef;
    my $arch = undef;
    my $autoclean_interval = undef;
    my $build_log_keep = undef;
    my $build_regex = undef; # Should this be user settable?
    my $daemon_log_file = undef;
    my $daemon_log_keep = undef;
    my $daemon_log_rotate = undef;
    my $daemon_log_send = undef;
    my $delay_after_give_back = undef;
    my $dupload_to = undef;
    my $dupload_to_non_us = undef;
    my $dupload_to_security = undef;
    my $error_mail_window = undef;
    my $idle_sleep_time = undef;
    my $log_queued_messages = undef;
    my $max_build = undef;
    my $min_free_space = undef;
    my $nice_level = undef;
    my @no_auto_build;
    my $no_build_regex = undef;
    my $no_detach = undef;
    my $no_warn_pattern = undef;
    my $pidfile = undef;
    my $pkg_log_keep = undef;
    my $secondary_daemon_threshold = undef;
    my $should_build_msgs = undef;
    my $ssh = undef;
    my $statistics_mail = undef;
    my $statistics_period = undef;
    my $sudo = undef;
    my @take_from_dists;
    my $wanna_build_db_name = undef;
    my $wanna_build_db_user = undef;
    my $wanna_build_ssh_user = undef;
    my $wanna_build_ssh_host = undef;
    my $wanna_build_ssh_socket = undef;
    my $wanna_build_ssh_options = undef;
    my $warning_age = undef;
    my @weak_no_auto_build;

    #legacy fields:
    my $sshcmd;
    my $sshsocket;
    my $wanna_build_user;
    my $wanna_build_dbbase;

    my $global = $Sbuild::Sysconfig::paths{'BUILDD_CONF'};
    my $user = "$HOME/.builddrc";
    my %config_time = ();
    my $user_time = 0;

    my $reread = 0;

    sub ST_MTIME () { 9 }

    my @config_files = ($global, $user);

    $reread = 1 if $reread_config;

    foreach (@config_files) {
	if (-r $_) {
	    $config_time{$_} = 0;
	    my @stat = stat($_);
	    if (!defined($self->get('CONFIG_TIME')->{$_}) ||
		$self->get('CONFIG_TIME')->{$_} < $stat[ST_MTIME]) {
		$config_time{$_} = $stat[ST_MTIME];
		$reread = 1;
	    }
	}
    }

    # Need to reread all config files, even if one is updated.
    if ($reread) {
	foreach (@config_files) {
	    if (-r $_) {
		my $e = eval `cat "$_"`;
		if (!defined($e)) {
		    print STDERR "E: $_: Errors found in configuration file:\n$@";
		    exit(1);
		}
		$self->get('CONFIG_TIME')->{$_} = $config_time{$_};
	    }
	}

	$self->set('ADMIN_MAIL', $admin_mail);
	$self->set('APT_GET', $apt_get);
	$self->set('ARCH', $arch);
	$self->set('AUTOCLEAN_INTERVAL', $autoclean_interval);
	$self->set('BUILD_LOG_KEEP', $build_log_keep);
	$self->set('BUILD_REGEX', $build_regex);
	$self->set('DAEMON_LOG_FILE', $daemon_log_file);
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
	$self->set('NO_AUTO_BUILD', \@no_auto_build)
	    if (@no_auto_build);
	$self->set('NO_BUILD_REGEX', $no_build_regex);
	$self->set('NO_DETACH', $no_detach);
	$self->set('BUILD_REGEX', $build_regex);
	$self->set('NO_WARN_PATTERN', $no_warn_pattern);
	$self->set('PIDFILE', $pidfile);
	$self->set('PKG_LOG_KEEP', $pkg_log_keep);
	$self->set('SECONDARY_DAEMON_THRESHOLD', $secondary_daemon_threshold);
	$self->set('SHOULD_BUILD_MSGS', $should_build_msgs);
	$self->set('SSH', $ssh);
	$self->set('STATISTICS_MAIL', $statistics_mail);
	$self->set('STATISTICS_PERIOD', $statistics_period);
	$self->set('SUDO', $sudo);
	$self->set('TAKE_FROM_DISTS', \@take_from_dists)
	    if (@take_from_dists);

	#some heuristics to translate from the old config names to the new
	#ones:
	if ($sshcmd && $sshcmd =~ /^\s*(\S+)\s+(.+)/) {
	    my $rest = $2;
	    $self->set('SSH', $1);

	    #Try to pry the user out:
	    if ($rest =~ /(-l\s+(\S+))\s+/) {
		$wanna_build_ssh_user = $2;
		#purge this from the rest:
		$rest =~ s/\Q$1//;
	    } elsif ($rest =~ /\s+(\S+)\@/) {
		$wanna_build_ssh_user = $1;
		$rest =~ s/\Q$1\E\@//;
	    }

	    #Hope that the last argument is the host:
	    if ($rest =~ /\s+(\S+)\s*$/) {
		$wanna_build_ssh_host = $1;
		$rest =~ s/\Q$1//;
	    }

	    #rest should be options:
	    if ($rest !~ /\s*/) {
		$wanna_build_ssh_options = [split $rest];
	    }
	}

	if ($sshsocket) {
	    $wanna_build_ssh_socket = $sshsocket;
	}

	if ($wanna_build_user) {
	    $wanna_build_db_user = $wanna_build_user;
	}

	if ($wanna_build_dbbase) {
	    $wanna_build_db_name = $wanna_build_dbbase;
	}

	$self->set('WANNA_BUILD_DB_NAME', $wanna_build_db_name);
	$self->set('WANNA_BUILD_DB_USER', $wanna_build_db_user);
	$self->set('WANNA_BUILD_SSH_USER', $wanna_build_ssh_user);
	$self->set('WANNA_BUILD_SSH_HOST', $wanna_build_ssh_host);
	$self->set('WANNA_BUILD_SSH_SOCKET', $wanna_build_ssh_socket);
	$self->set('WANNA_BUILD_SSH_OPTIONS', $wanna_build_ssh_options);

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
