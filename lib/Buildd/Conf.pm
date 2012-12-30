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

use Buildd::DistConf qw();
use Buildd::UploadQueueConf qw();
use Sbuild::ConfBase;
use Sbuild::Sysconfig;
use Buildd::ClientConf qw();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($reread_config new setup read);
}

our $reread_config = 0;

sub setup ($);
sub read ($);

sub new {
    my $conf = Sbuild::ConfBase->new(@_);
    Buildd::Conf::setup($conf);
    Buildd::Conf::read($conf);

    return $conf;
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
	my @paths = split(/:/, $conf->get('PATH'));
	# Also consider the empty path for absolute locations.
	push (@paths, '');
	my $found = 0;
	foreach my $path (@paths) {
	    $found = 1 if (-x File::Spec->catfile($path, $program));
	}

	die "$key binary '$program' does not exist or is not executable"
	    if !$found;
    };

    my $validate_directory = sub {
	my $conf = shift;
	my $entry = shift;
	my $key = $entry->{'NAME'};
	my $directory = $conf->get($key);

	die "$key directory is not defined"
	    if !defined($directory) || !$directory;

	die "$key directory '$directory' does not exist"
	    if !-d $directory;
    };

    our $HOME = $conf->get('HOME');
    $main::HOME = $HOME; # TODO: Remove once Buildd.pm uses $conf
    my $arch = $conf->get('ARCH');

    my %buildd_keys = (
	'ADMIN_MAIL'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'admin_mail',
	    GROUP => 'Mail',
	    DEFAULT => 'root',
	    HELP => 'email address for admin'
	},
	'APT_GET'				=> {
	    TYPE => 'STRING',
	    VARNAME => 'apt_get',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'apt-get',
	    HELP => 'Path to apt-get binary'
	},
	'BUILD_LOG_KEEP'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'build_log_keep',
	    GROUP => 'Watcher',
	    DEFAULT => 2,
	    HELP => 'Number of days until build logs are archived'
	},
	'DAEMON_LOG_FILE'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'daemon_log_file',
	    GROUP => 'Daemon',
	    DEFAULT => "$HOME/daemon.log",
	    HELP => 'Main buildd daemon log file'
	},
	'DAEMON_LOG_KEEP'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'daemon_log_keep',
	    GROUP => 'Watcher',
	    DEFAULT => 7,
	    HELP => 'Number of days until old daemon logs are archived in a .tar.gz file'
	},
	'DAEMON_LOG_ROTATE'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'daemon_log_rotate',
	    GROUP => 'Watcher',
	    DEFAULT => 1,
	    HELP => 'Number how many days until daemon logs are rotated (one is kept as daemon.log.old, others are moved to old-logs and gzipped)'
	},
	'DAEMON_LOG_SEND'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'daemon_log_send',
	    GROUP => 'Watcher',
	    DEFAULT => 1,
	    HELP => 'email rotated daemon logs to the admin?'
	},
	'DELAY_AFTER_GIVE_BACK'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'delay_after_give_back',
	    GROUP => 'Daemon',
	    DEFAULT => 8 * 60, # 8 hours
	    HELP => 'Time to avoid packages that have automatically been given back by sbuild (in minutes)'
	},
	'ERROR_MAIL_WINDOW'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'error_mail_window',
	    GROUP => 'Mail',
	    DEFAULT => 8*60*60,
	    HELP => 'If more than five error mails are received within the specified time (in seconds), do not forward (to avoid possible mail loops)'
	},
	'IDLE_SLEEP_TIME'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'idle_sleep_time',
	    GROUP => 'Daemon',
	    DEFAULT => 5*60,
	    HELP => 'Time to sleep when idle (in seconds) between wanna-build --list=needs-build calls)'
	},
	'LOG_QUEUED_MESSAGES'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'log_queued_messages',
	    GROUP => 'Mail',
	    DEFAULT => 0,
	    HELP => 'Log success messages from upload queue daemon?'
	},
	'MAX_SBUILD_FAILS'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'max_sbuild_fails',
	    GROUP => 'Daemon',
	    DEFAULT => 2,
	    HELP => 'Maximim number of times sbuild can fail before sleeping'
	},
	'MIN_FREE_SPACE'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'min_free_space',
	    GROUP => 'Daemon',
	    DEFAULT => 50*1024,
	    HELP => 'Minimum free space (in KiB) on build filesystem'
	},
	'NICE_LEVEL'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'nice_level',
	    GROUP => 'Build options',
	    DEFAULT => 10,
	    HELP => 'Nice level to run sbuild.  Dedicated build daemons should not be niced.'
	},
	'NO_DETACH'				=> {
	    TYPE => 'BOOL',
	    VARNAME => 'no_detach',
	    GROUP => 'Daemon',
	    DEFAULT => 0,
	    HELP => 'Disable becoming a daemon, for debugging purposes.  Set to 1 to stop daemonising, otherwise set to 0 to become a daemon.'
	},
	'NO_WARN_PATTERN'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'no_warn_pattern',
	    GROUP => 'Watcher',
	    DEFAULT => '^build/(SKIP|REDO|SBUILD-GIVEN-BACK|buildd\.pid|[^/]*.ssh|chroot-[^/]*|current-[^/]*)$',
	    HELP => 'Don\'t complain about old files if they match the regexp.'
	},
	'PIDFILE'                               => {
	    TYPE => 'STRING',
	    VARNAME => 'pidfile',
	    GROUP => 'Daemon',
# Set once running as a system service.
#          DEFAULT => "${Sbuild::Sysconfig::paths{'LOCALSTATEDIR'}/run/buildd.pid"
	    DEFAULT => "$HOME/build/buildd.pid",
	    HELP => 'PID file to identify running daemon.'
	},
	'PKG_LOG_KEEP'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'pkg_log_keep',
	    GROUP => 'Watcher',
	    DEFAULT => 7,
	    HELP => 'Number of days until to package logs are archived'
	},
	'SHOULD_BUILD_MSGS'			=> {
	    TYPE => 'BOOL',
	    VARNAME => 'should_build_msgs',
	    GROUP => 'Daemon',
	    DEFAULT => 1,
	    HELP => 'Should buildd send "Should I build" messages?'
	},
	'STATISTICS_MAIL'			=> {
	    TYPE => 'STRING',
	    VARNAME => 'statistics_mail',
	    GROUP => 'Watcher',
	    DEFAULT => 'root',
	    HELP => 'email address for statistics summaries'
	},
	'STATISTICS_PERIOD'			=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'statistics_period',
	    GROUP => 'Watcher',
	    DEFAULT => 7,
	    HELP => 'Period for statistic summaries (days)'
	},
	'SUDO'					=> {
	    TYPE => 'STRING',
	    VARNAME => 'sudo',
	    GROUP => 'Programs',
	    CHECK => $validate_program,
	    DEFAULT => 'sudo',
	    HELP => 'Path to sudo binary'
	},
	'WARNING_AGE'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'warning_age',
	    GROUP => 'Watcher',
	    DEFAULT => 7,
	    HELP => 'Age (in days) after which a warning is issued for files in upload and dirs in build'
	},
	'CONFIG_TIME'				=> {
	    TYPE => 'NUMERIC',
	    VARNAME => 'config_time',
	    GROUP => '__INTERNAL',
	    DEFAULT => {},
	    HELP => 'Time configuration was last read'
	},
	'DISTRIBUTIONS'                         => {
	    TYPE => 'ARRAY:HASH:SCALAR',
	    VARNAME => 'distributions',
	    GROUP => 'Build options',
	    DEFAULT => [],
	    IGNORE_DEFAULT => 1, # Don't dump class to config
	    HELP => 'List of distributions that buildd should take packages from',
	    EXAMPLE =>
'$distributions = [
	{
		# name of the suite to build (also used to query wanna-build)
		dist_name => ["unstable", "testing"],

		# architecture to be built (will be passed to sbuild and can be
		# used to compute wanna_build_db_name)
		built_architecture => undef,

		# host on which wanna-build is run
		wanna_build_ssh_host => "buildd.debian.org",

		# user as who we are going to connect to the host running wanna-build
		wanna_build_ssh_user => "buildd_arch",

		# SSH control socket path for ssh -S option
		wanna_build_ssh_socket => "",

		# Additional SSH options used when connecting
		wanna_build_ssh_options => [],

		# database used for wanna-build
		wanna_build_db_name => "arch/build-db",

		# Username to use for wanna-build.
		wanna_build_db_user => $Buildd::username,

		# Local queue directory where binaries are stored before uploaded
		# by dupload. You need to configure this directory in
		# @upload_queues to get packages uploaded from there.
		dupload_local_queue_dir => "upload",

		# list of packages which shouldn\'t be picked up by buildd
		no_auto_build => [],

		# list of packages which should only be taken if there absolutely
		# nothing else to do (probably packages included in no_auto_build
		# because they take too long)
		weak_no_auto_build => [],

		# regex used to filter out unwanted packages:
		#no_build_regex => "^(contrib/|non-free/)?non-US/",

		# regex used to filter packages to build:
		#build_regex => "",

		# mail addr of buildd admin handling packages from this distribution
		logs_mailed_to => $admin_mail,

		# schroot name (or alias) of the chrooted environment to use for
		# building (will be passed to sbuild). sbuild\'s default is
		# the first of $distribution-$arch-sbuild, $distribution-sbuild,
		# $distribution-$arch and $distribution.
		sbuild_chroot => undef,

	}
];'
	},
	'UPLOAD_QUEUES'                         => {
	    TYPE => 'ARRAY:HASH:SCALAR',
	    VARNAME => 'upload_queues',
	    GROUP => 'Uploader',
	    DEFAULT => [],
	    IGNORE_DEFAULT => 1, # Don't dump class to config
	    HELP => 'Package upload queues',
	    EXAMPLE =>
'$upload_queues = [
	{
		# Local queue directory where binaries are stored before uploaded
		# by dupload.
		dupload_local_queue_dir => "upload",

		# Upload site for buildd-upload to pass to dupload(1); see
		# /etc/dupload.conf for possible values.
		dupload_archive_name => "anonymous-ftp-master",
	},

	{
		# Local queue directory where binaries are stored before uploaded
		# by dupload.
		dupload_local_queue_dir => "upload-security",

		# Upload site for buildd-upload to pass to dupload(1); see
		# /etc/dupload.conf for possible values.
		dupload_archive_name => "security",
	}
];'
	});

    $conf->set_allowed_keys(\%buildd_keys);
    Buildd::ClientConf::setup($conf);
}

sub read ($) {
    my $conf = shift;

    my $HOME = $conf->get('HOME');

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
	    if (!defined($conf->get('CONFIG_TIME')->{$_}) ||
		$conf->get('CONFIG_TIME')->{$_} < $stat[ST_MTIME]) {
		$config_time{$_} = $stat[ST_MTIME];
		$reread = 1;
	    }
	}
    }

    # For compatibility only.  Non-scalars are deprecated.
    my $deprecated_init = <<END;
# Variables are undefined, so config will default to DEFAULT if unset.
my \$defaults;
my \@distributions;
undef \@distributions;
my \@upload_queues;
undef \@upload_queues;

#legacy fields:
my \@weak_no_auto_build;
undef \@weak_no_auto_build;
my \$build_regex = undef; # Should this be user settable?
my \@no_auto_build;
undef \@no_auto_build;
my \$no_build_regex = undef;
my \@take_from_dists;
undef \@take_from_dists;
my \$sshcmd = undef;
my \$sshsocket = undef;
my \$wanna_build_user = undef;
my \$wanna_build_dbbase = undef;
END

    my $deprecated_setup = '';

    my $custom_setup = <<END;
if (\$sshcmd && \$sshcmd =~ /^\\s*(\\S+)\\s+(.+)/) {
    my \$rest = \$2;
    \$conf->set('SSH', \$1);

    #Try to pry the user out:
    if (\$rest =~ /(-l\\s*(\\S+))\\s+/) {
	\$wanna_build_ssh_user = \$2;
	#purge this from the rest:
	\$rest =~ s/\\Q\$1//;
    } elsif (\$rest =~ /\\s+(\\S+)\@/) {
	\$wanna_build_ssh_user = \$1;
	\$rest =~ s/\\Q\$1\\E\@//;
    }

    #Hope that the last argument is the host:
    if (\$rest =~ /\\s+(\\S+)\\s*\$/) {
	\$wanna_build_ssh_host = \$1;
	\$rest =~ s/\\Q\$1//;
    }

    #rest should be options:
    if (\$rest !~ /\\s*/) {
	\$wanna_build_ssh_options = [split \$rest];
    }
}

if (\$sshsocket) {
    \$wanna_build_ssh_socket = \$sshsocket;
}

if (\$wanna_build_user) {
    \$wanna_build_db_user = \$wanna_build_user;
}

if (\$wanna_build_dbbase) {
    \$wanna_build_db_name = \$wanna_build_dbbase;
}

#Convert old config, if needed:
my \@distributions_info;
if (\@take_from_dists) {
    for my \$dist (\@take_from_dists) {
	my \%entry;

	\$entry{DIST_NAME} = \$dist;
	\$entry{SSH} = \$ssh;

	if (\$dist =~ /security/) {
	    \$entry{DUPLOAD_LOCAL_QUEUE_DIR} = 'upload-security';
	}
	if (\$build_regex) {
	    \$entry{BUILD_REGEX} = \$build_regex;
	}
	if (\$no_build_regex) {
	    \$entry{NO_BUILD_REGEX} = \$build_regex;
	}
	if (\@no_auto_build) {
	    \$entry{NO_AUTO_BUILD} = \\\@no_auto_build;
	}
	if (\@weak_no_auto_build) {
	    \$entry{WEAK_NO_AUTO_BUILD} = \\\@weak_no_auto_build;
	}

	\$entry{WANNA_BUILD_DB_NAME} = \$wanna_build_db_name;
	\$entry{WANNA_BUILD_DB_USER} = \$wanna_build_db_user;
	\$entry{WANNA_BUILD_SSH_HOST} = \$wanna_build_ssh_host;
	\$entry{WANNA_BUILD_SSH_USER} = \$wanna_build_ssh_user;
	\$entry{WANNA_BUILD_SSH_SOCKET} = \$wanna_build_ssh_socket;
	\$entry{WANNA_BUILD_SSH_OPTIONS} = \$wanna_build_ssh_options;
                \$entry{WANNA_BUILD_API} = 0;

	my \$dist_config = Buildd::DistConf::new_hash(CHECK=>$conf->{'CHECK'},
						      HASH=>\\\%entry);

	push \@distributions_info, \$dist_config;
    }
} else {
    for my \$raw_entry (\@distributions) {
	my \%entry;
	my \@dist_names;

	#Find out for which distributions this entry is intended:
	for my \$key (keys \%\$raw_entry) {
	    if (uc(\$key) eq "DIST_NAME") {
		if (ref(\$raw_entry->{\$key}) eq "ARRAY") {
		    push \@dist_names, \@{\$raw_entry->{\$key}};
		} else {
		    push \@dist_names, \$raw_entry->{\$key};
		}
	    }
	}

	for my \$key (keys \%\$raw_entry) {
	    if (uc(\$key) ne "DIST_NAME") {
		\$entry{uc(\$key)} = \$raw_entry->{\$key};
	    }
	}

                for my \$key (keys \%\$defaults) {
                    if (uc(\$key) ne "DIST_NAME" && not defined \$entry{uc(\$key)}) {
                        \$entry{uc(\$key)} = \$defaults->{\$key};
                    }
                }

                \$entry{WANNA_BUILD_API} //= 1;


	#We need this to pass this to Buildd::Client:
                \$entry{SSH} = \$ssh;

	#Make one entry per distribution, it's easier later on:
	for my \$dist (\@dist_names) {
	    \$entry{'DIST_NAME'} = \$dist;
                    my \$dist_config = Buildd::DistConf::new_hash(HASH=>\\\%entry);
                    push \@distributions_info, \$dist_config;
	}
    }
}

\$conf->set('DISTRIBUTIONS', \\\@distributions_info);

if (\@upload_queues) {
    my \@upload_queue_configs;
    for my \$raw_entry (\@upload_queues) {
	my \%entry;
	for my \$key (keys \%\$raw_entry) {
	    \$entry{uc(\$key)} = \$raw_entry->{\$key};
	}

	my \$queue_config = Buildd::UploadQueueConf::new_hash(CHECK=>$conf->{'CHECK'},
							      HASH=>\\\%entry);

	push \@upload_queue_configs, \$queue_config;
    }
    \$conf->set('UPLOAD_QUEUES', \\\@upload_queue_configs);
} else {
    push \@{\$conf->get('UPLOAD_QUEUES')},
	Buildd::UploadQueueConf::new_hash(CHECK=>$conf->{'CHECK'},
					  HASH=>
	    {
		DUPLOAD_LOCAL_QUEUE_DIR => 'upload',
		DUPLOAD_ARCHIVE_NAME    => 'anonymous-ftp-master'
	    }
	),
	Buildd::UploadQueueConf::new_hash(CHECK=>$conf->{'CHECK'},
					  HASH=>
	    {
		DUPLOAD_LOCAL_QUEUE_DIR => 'upload-security',
		DUPLOAD_ARCHIVE_NAME    => 'security'
	    }
	);
}

# Set here to allow user to override.
if (-t STDIN && -t STDOUT && \$conf->get('NO_DETACH')) {
    \$conf->_set_default('VERBOSE', 1);
} else {
    \$conf->_set_default('VERBOSE', 0);
}
END

    $conf->read(\@config_files, $deprecated_init, $deprecated_setup,
		$custom_setup);

    # Update times
    if ($reread) {
	foreach (@config_files) {
	    if (-r $_) {
		$conf->get('CONFIG_TIME')->{$_} = $config_time{$_};
	    }
	}
    }
}

1;
