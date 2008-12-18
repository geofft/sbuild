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
use Sbuild::Log;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ConfBase);

    @EXPORT = qw();
}

sub init_allowed_keys () {
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
	    CHECK => $validate_directory
	},
	'DB_BASE_NAME'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database base name is not defined"
		    if !defined($self->get($key));
	    }
	},
	'DB_TRANSACTION_LOG'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Database transaction log is not defined"
		    if !defined($self->get($key));
	    }
	},
	'DB_DISTRIBUTIONS'			=> {},
	'DB_DISTRIBUTION_ORDER'			=> {},
	'DB_SECTIONS'				=> {},
	'DB_PACKAGES_SOURCE'			=> {},
	'DB_QUINN_SOURCE'			=> {},
	'DB_ADMIN_USERS'			=> {},
	'DB_MAINTAINER_EMAIL'			=> {},
	'DB_NOTFORUS_MAINTAINER_EMAIL'		=> {},
	'DB_LOG_MAIL'				=> {},
	'DB_STAT_MAIL'				=> {},
	'DB_WEB_STATS'				=> {},
	# Not settable in config file:
	'DB_BIN_NMU_VERSION'			=> {},
	'DB_BUILD_PRIORITY'			=> {},
	'DB_CATEGORY'				=> {},
	'DB_CREATE'				=> {},
	'DB_EXPORT_FILE'			=> {},
	'DB_FAIL_REASON'			=> {},
	'DB_IMPORT_FILE'			=> {},
	'DB_INFO_ALL_DISTS'			=> {},
	'DB_LIST_MIN_AGE'			=> {},
	'DB_LIST_ORDER'				=> {},
	'DB_LIST_STATE'				=> {},
	'DB_NO_DOWN_PROPAGATION'		=> {},
	'DB_NO_PROPAGATION'			=> {},
	# TODO: Don't allow setting if already set.
	'DB_OPERATION'				=> {},
	'DB_OVERRIDE'				=> {},
	'DB_USER'				=> {}
    );

    $self->set_allowed_keys(\%db_keys);
}

sub read_config () {
    my $self = shift;

    ($self->set('HOME', $ENV{'HOME'}))
	or die "HOME not defined in environment!\n";
    $self->set('USERNAME',(getpwuid($<))[0] || $ENV{'LOGNAME'} || $ENV{'USER'});
    $self->set('CWD', cwd());
    $self->set('VERBOSE', 0);

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT && $self->get('VERBOSE') == 0) {
	$self->set('VERBOSE', 1);
    }

    my $HOME = $self->get('HOME');

    # Defaults.
    our $mailprog = "/usr/sbin/sendmail";
    our $dpkg = "/usr/bin/dpkg";
    our $sudo = "/usr/bin/sudo";
    our $su = "/bin/su";
    our $schroot = "/usr/bin/schroot";
    our $schroot_options = ['-q'];
    our $fakeroot = "/usr/bin/fakeroot";
    our $apt_get = "/usr/bin/apt-get";
    our $apt_cache = "/usr/bin/apt-cache";
    our $dpkg_source = "/usr/bin/dpkg-source";
    our $dcmd = "/usr/bin/dcmd";
    our $md5sum = "/usr/bin/md5sum";
    our $avg_time_db = "/var/lib/sbuild/avg-build-times";
    our $avg_space_db = "/var/lib/sbuild/avg-build-space";
    our $stats_dir = "$HOME/stats";
    our $package_checklist = "/var/lib/sbuild/package-checklist";
    our $build_env_cmnd = "";
    our $pgp_options = ['-us', '-uc'];
    our $log_dir = "$HOME/logs";
    our $mailto = "";
    our %mailto = ();
    our $mailfrom = "Source Builder <sbuild>";
    our $purge_build_directory = "successful";
    our @toolchain_regex = (
	'binutils$',
	'gcc-[\d.]+$',
	'g\+\+-[\d.]+$',
	'libstdc\+\+',
	'libc[\d.]+-dev$',
	'linux-kernel-headers$',
	'linux-libc-dev$',
	'gnumach-dev$',
	'hurd-dev$',
	'kfreebsd-kernel-headers$'
	);
    our $stalled_pkg_timeout = 150; # minutes
    our $srcdep_lock_dir = "/var/lib/sbuild/srcdep-lock";
    our $srcdep_lock_wait = 1; # minutes
    our $max_lock_trys = 120;
our $lock_interval = 5;
    our $apt_policy = 1;
    our $check_watches = 1;
    our @ignore_watches_no_build_deps = qw();
    our %watches;
    our $chroot_mode = 'schroot';
    our $chroot_split = 0;
    our $sbuild_mode = "user";
    our $debug = 0;
    our $force_orig_source = 0;
    our %individual_stalled_pkg_timeout = ();
    our $path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/X11R6/bin:/usr/games";
    our $ld_library_path = "";
    our $maintainer_name;
    our $uploader_name;
    our $key_id;
    our $apt_update = 0;
    our $apt_allow_unauthenticated = 0;
    our %alternatives = (
	"info-browser"		=> "info",
	"httpd"			=> "apache",
	"postscript-viewer"	=> "ghostview",
	"postscript-preview"	=> "psutils",
	"www-browser"		=> "lynx",
	"awk"			=> "gawk",
	"c-shell"		=> "tcsh",
	"wordlist"		=> "wenglish",
	"tclsh"			=> "tcl8.4",
	"wish"			=> "tk8.4",
	"c-compiler"		=> "gcc",
	"fortran77-compiler"	=> "g77",
	"java-compiler"		=> "jikes",
	"libc-dev"		=> "libc6-dev",
	"libgl-dev"		=> "xlibmesa-gl-dev",
	"libglu-dev"		=> "xlibmesa-glu-dev",
	"libncurses-dev"	=> "libncurses5-dev",
	"libz-dev"		=> "zlib1g-dev",
	"libg++-dev"		=> "libstdc++6-4.0-dev",
	"emacsen"		=> "emacs21",
	"mail-transport-agent"	=> "ssmtp",
	"mail-reader"		=> "mailx",
	"news-transport-system"	=> "inn",
	"news-reader"		=> "nn",
	"xserver"		=> "xvfb",
	"mysql-dev"		=> "libmysqlclient-dev",
	"giflib-dev"		=> "libungif4-dev",
	"freetype2-dev"		=> "libttf-dev"
	);
    our $check_depends_algorithm = "first-only";
    our $distribution = 'unstable';
    our $archive = undef;
    our $chroot = undef;
    our $build_arch_all = 0;
    our $arch = undef;

    # NOTE: For legacy wanna-build.conf format parsing
    our $basedir = '/var/lib/wanna-build';
    our $dbbase = 'build-db';
    our $transactlog = 'transactions.log';
    our @distributions = qw(oldstable-security stable testing unstable
                            stable-security testing-security);
    our %dist_order = ('oldstable-security' => 0,
		       'stable' => 1,
		       'stable-security' => 1,
		       'testing' => 2,
		       'testing-security' => 2,
		       'unstable' => 3);
    our @sections = qw(main contrib non-free);
    our $pkgs_source = "ftp://ftp.debian.org/debian";
    our $quinn_source = "http://buildd.debian.org/quinn-diff/output";
    our @admin_users = qw(buildd);
    our $maint = "buildd";
    our $notforus_maint = "buildd";
    our $log_mail = undef;
    our $stat_mail = undef;
    our $web_stats = undef;

    # New sbuild.conf format
    our $db_base_dir = '/var/lib/wanna-build';
    our $db_base_name = 'build-db';
    our $db_transaction_log = 'transactions.log';
    our @db_distributions = qw(oldstable-security stable testing
                               unstable stable-security
                               testing-security);
    our %db_distribution_order = ('oldstable-security' => 0,
				  'stable' => 1,
				  'stable-security' => 1,
				  'testing' => 2,
				  'testing-security' => 2,
				  'unstable' => 3);
    our @db_sections = qw(main contrib non-free);
    our $db_packages_source = "ftp://ftp.debian.org/debian";
    our $db_quinn_source = "http://buildd.debian.org/quinn-diff/output";
    our @db_admin_users = qw(buildd);
    our $db_maintainer_email = "buildd";
    our $db_notforus_maintainer_email = "buildd";
    our $db_log_mail = undef;
    our $db_stat_mail = undef;
    our $db_web_stats = undef;

    # read conf files
    my $legacy_db = 0;
    if (-r "/etc/buildd/wanna-build.conf") {
	warn "W: Reading obsolete configuration file /etc/buildd/wanna-build.conf";
	warn "I: This file has been merged with /etc/sbuildrc";
	$legacy_db = 1;
	require "/etc/buildd/wanna-build.conf" if -r "/etc/buildd/wanna-build.conf";
    }
    if (-r "$HOME/.wanna-buildrc") {
	warn "W: Reading obsolete configuration file $HOME/.wanna-buildrc";
	warn "W: This file has been merged with $HOME/.sbuildrc";
	$legacy_db = 1;
	require "$HOME/.wanna-buildrc" if -r "$HOME/.wanna-buildrc";
    }
    require "/etc/sbuild/sbuild.conf" if -r "/etc/sbuild/sbuild.conf";
    require "$HOME/.sbuildrc" if -r "$HOME/.sbuildrc";
    # Modify defaults if needed.
    $maintainer_name = $ENV{'DEBEMAIL'}
	if (!defined($maintainer_name) && defined($ENV{'DEBEMAIL'}));

    $self->set('DISTRIBUTION', $distribution);
    $self->set('DEBUG', $debug);
    $self->set('DPKG', $dpkg);
    $self->set('MAILPROG', $mailprog);

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

    # Not settable in config file:
    $self->set('DB_BIN_NMU_VERSION', undef);
    $self->set('DB_BUILD_PRIORITY', 0);
    $self->set('DB_CATEGORY', undef);
    $self->set('DB_CREATE', 0);
    $self->set('DB_EXPORT_FILE', undef);
    $self->set('DB_FAIL_REASON', undef);
    $self->set('DB_IMPORT_FILE', undef);
    $self->set('DB_INFO_ALL_DISTS', 0);
    $self->set('DB_LIST_MIN_AGE', 0);
    $self->set('DB_LIST_ORDER', 'PScpsn');
    $self->set('DB_LIST_STATE', undef);
    $self->set('DB_NO_DOWN_PROPAGATION', 0);
    $self->set('DB_NO_PROPAGATION', 0);
    $self->set('DB_OPERATION', undef);
    $self->set('DB_OVERRIDE', 0);
    $self->set('DB_USER', $self->get('USERNAME'));

    # Not user-settable.
    chomp(our $host_arch = readpipe($self->get('DPKG') . " --print-installation-architecture")) if(!defined $host_arch);
    $self->set('HOST_ARCH', $host_arch);
    $self->set('ARCH', $arch);
    chomp(my $hostname = `hostname -f`);
    $self->set('HOSTNAME', $hostname);
}

1;
