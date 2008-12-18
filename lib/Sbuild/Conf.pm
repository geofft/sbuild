#
# Conf.pm: configuration library for sbuild
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

package Sbuild::Conf;

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

sub init_allowed_keys () {
    my $self = shift;

    $self->SUPER::init_allowed_keys();

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

    my %sbuild_keys = (
	'CHROOT'				=> {},
	'BUILD_ARCH_ALL'			=> {},
	'NOLOG'					=> {},
	'SOURCE_DEPENDENCIES'			=> {},
	'SUDO'					=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($self->get('CHROOT_MODE') eq 'split' ||
		    ($self->get('CHROOT_MODE') eq 'schroot' &&
		     $self->get('CHROOT_SPLIT'))) {
		    $validate_program->($self, $entry);

		    local (%ENV) = %ENV; # make local environment
		    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";
		    $ENV{'APT_CONFIG'} = "test_apt_config";
		    $ENV{'SHELL'} = "/bin/sh";

		    my $sudo = $self->get('SUDO');
		    chomp( my $test_df = `$sudo sh -c 'echo \$DEBIAN_FRONTEND'` );
		    chomp( my $test_ac = `$sudo sh -c 'echo \$APT_CONFIG'` );
		    chomp( my $test_sh = `$sudo sh -c 'echo \$SHELL'` );

		    if ($test_df ne "noninteractive" ||
			$test_ac ne "test_apt_config" ||
			$test_sh ne "/bin/sh") {
			print STDERR "$sudo is stripping APT_CONFIG, DEBIAN_FRONTEND and/or SHELL from the environment\n";
			print STDERR "'Defaults:" . $self->get('USERNAME') . " env_keep+=\"APT_CONFIG DEBIAN_FRONTEND SHELL\"' is not set in /etc/sudoers\n";
			die "$sudo is incorrectly configured"
		    }
		}
	    }
	},
	'SU'					=> {
	    CHECK => $validate_program
	},
	'SCHROOT'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($self->get('CHROOT_MODE') eq 'schroot') {
		    $validate_program->($self, $entry);
		}
	    }
	},
	'SCHROOT_OPTIONS'			=> {},
	'FAKEROOT'				=> {
	    CHECK => $validate_program
	},
	'APT_GET'				=> {
	    CHECK => $validate_program
	},
	'APT_CACHE'				=> {
	    CHECK => $validate_program
	},
	'DPKG_SOURCE'				=> {
	    CHECK => $validate_program
	},
	'DCMD'					=> {
	    CHECK => $validate_program
	},
	'MD5SUM'				=> {
	    CHECK => $validate_program
	},
	'AVG_TIME_DB'				=> {},
	'AVG_SPACE_DB'				=> {},
	'STATS_DIR'				=> {},
	'PACKAGE_CHECKLIST'			=> {},
	'BUILD_ENV_CMND'			=> {},
	'PGP_OPTIONS'				=> {},
	'LOG_DIR'				=> {},
	'LOG_DIR_AVAILABLE'			=> {},
	'MAILTO'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "mailto not set\n"
		    if !$self->get('MAILTO') &&
		    $self->get('SBUILD_MODE') eq "buildd";
	    }
	},
	'MAILTO_HASH'				=> {},
	'MAILFROM'				=> {},
	'PURGE_BUILD_DIRECTORY'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $self->get('PURGE_BUILD_DIRECTORY') . "\'"
		    if !isin($self->get('PURGE_BUILD_DIRECTORY'),
			     qw(always successful never));
	    }
	},
	'TOOLCHAIN_REGEX'			=> {},
	'STALLED_PKG_TIMEOUT'			=> {},
	'SRCDEP_LOCK_DIR'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die $self->get('SRCDEP_LOCK_DIR') . " is not a directory\n"
		    if ! -d $self->get('SRCDEP_LOCK_DIR');
	    }
	},
	'SRCDEP_LOCK_WAIT'			=> {},
	'MAX_LOCK_TRYS'				=> {},
	'LOCK_INTERVAL'				=> {},
	'CHROOT_ONLY'				=> {},
	'CHROOT_MODE'				=> {
	    DEFAULT => 'schroot',
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad chroot mode \'" . $self->get('CHROOT_MODE') . "\'"
		    if !isin($self->get('CHROOT_MODE'),
			     qw(schroot sudo));
	    }
	},
	'CHROOT_SPLIT'				=> {
	    DEFAULT => 0
	},
	'APT_POLICY'				=> {},
	'CHECK_WATCHES'				=> {},
	'IGNORE_WATCHES_NO_BUILD_DEPS'		=> {},
	'WATCHES'				=> {},
	'BUILD_DIR'				=> {
	    DEFAULT => cwd(),
	    CHECK => $validate_directory
	},
	'SBUILD_MODE'				=> {},
	'FORCE_ORIG_SOURCE'			=> {},
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> {},
	'PATH'					=> {},
	'LD_LIBRARY_PATH'			=> {},
	'MAINTAINER_NAME'			=> {},
	'UPLOADER_NAME'				=> {},
	'KEY_ID'				=> {},
	'SIGNING_OPTIONS'			=> {},
	'APT_UPDATE'				=> {},
	'APT_ALLOW_UNAUTHENTICATED'		=> {},
	'ALTERNATIVES'				=> {},
	'CHECK_DEPENDS_ALGORITHM'		=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die 'check_depends_algorithm: Invalid build-dependency checking algorithm \'' .
		    $self->get('CHECK_DEPENDS_ALGORITHM') .
		    "'\nValid algorthms are 'first-only' and 'alternatives'\n"
		    if !isin($self->get('CHECK_DEPENDS_ALGORITHM'),
			     qw(first-only alternatives));
	    }
	},
	'AUTO_GIVEBACK'				=> {},
	'AUTO_GIVEBACK_HOST'			=> {},
	'AUTO_GIVEBACK_SOCKET'			=> {},
	'AUTO_GIVEBACK_USER'			=> {},
	'AUTO_GIVEBACK_WANNABUILD_USER'		=> {},
	'WANNABUILD_DATABASE'			=> {},
	'BATCH_MODE'				=> {},
	'MANUAL_SRCDEPS'			=> {},
	'BUILD_SOURCE'				=> {},
	'ARCHIVE'				=> {},
	'BIN_NMU'				=> {},
	'BIN_NMU_VERSION'			=> {},
	'GCC_SNAPSHOT'				=> {}
    );

    $self->set_allowed_keys(\%sbuild_keys);
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

    require "/etc/sbuild/sbuild.conf" if -r "/etc/sbuild/sbuild.conf";
    require "$HOME/.sbuildrc" if -r "$HOME/.sbuildrc";
    # Modify defaults if needed.
    $maintainer_name = $ENV{'DEBEMAIL'}
	if (!defined($maintainer_name) && defined($ENV{'DEBEMAIL'}));


    $self->set('DISTRIBUTION', $distribution);
    $self->set('DEBUG', $debug);
    $self->set('DPKG', $dpkg);
    $self->set('MAILPROG', $mailprog);

    $self->set('ARCHIVE', $archive) if (defined $archive);
    $self->set('CHROOT', $chroot);
    $self->set('BUILD_ARCH_ALL', $build_arch_all);
    $self->set('SUDO',  $sudo);
    $self->set('SU', $su);
    $self->set('SCHROOT', $schroot);
    $self->set('SCHROOT_OPTIONS', $schroot_options);
    $self->set('FAKEROOT', $fakeroot);
    $self->set('APT_GET', $apt_get);
    $self->set('APT_CACHE', $apt_cache);
    $self->set('DPKG_SOURCE', $dpkg_source);
    $self->set('DCMD', $dcmd);
    $self->set('MD5SUM', $md5sum);
    $self->set('AVG_TIME_DB', $avg_time_db);
    $self->set('AVG_SPACE_DB', $avg_space_db);
    $self->set('STATS_DIR', $stats_dir);
    $self->set('PACKAGE_CHECKLIST', $package_checklist);
    $self->set('BUILD_ENV_CMND', $build_env_cmnd);
    $self->set('PGP_OPTIONS', $pgp_options);
    $self->set('LOG_DIR', $log_dir);

    my $log_dir_available = 1;
    if ($self->get('LOG_DIR') &&
	! -d $self->get('LOG_DIR') &&
	!mkdir $self->get('LOG_DIR')) {
	warn "Could not create " . $self->get('LOG_DIR') . ": $!\n";
	$log_dir_available = 0;
    }

    $self->set('LOG_DIR_AVAILABLE', $log_dir_available);
    $self->set('MAILTO', $mailto);
    $self->set('MAILTO_HASH', \%mailto);
    $self->set('MAILFROM', $mailfrom);
    $self->set('PURGE_BUILD_DIRECTORY', $purge_build_directory);
    $self->set('TOOLCHAIN_REGEX', \@toolchain_regex);
    $self->set('STALLED_PKG_TIMEOUT', $stalled_pkg_timeout);
    $self->set('SRCDEP_LOCK_DIR', $srcdep_lock_dir);
    $self->set('SRCDEP_LOCK_WAIT', $srcdep_lock_wait);
    $self->set('MAX_LOCK_TRYS', $max_lock_trys);
    $self->set('LOCK_INTERVAL', $lock_interval);
    $self->set('APT_POLICY', $apt_policy);
    $self->set('CHECK_WATCHES', $check_watches);
    $self->set('IGNORE_WATCHES_NO_BUILD_DEPS',
	       \@ignore_watches_no_build_deps);
    $self->set('WATCHES', \%watches);
    $self->set('CHROOT_MODE', $chroot_mode);
    $self->set('CHROOT_SPLIT', $chroot_split);
    $self->set('SBUILD_MODE', $sbuild_mode);
    $self->set('FORCE_ORIG_SOURCE', $force_orig_source);
    $self->set('INDIVIDUAL_STALLED_PKG_TIMEOUT',
	       \%individual_stalled_pkg_timeout);
    $self->set('PATH', $path);
    $self->set('LD_LIBRARY_PATH', $ld_library_path);
    $self->set('MAINTAINER_NAME', $maintainer_name);
    $self->set('UPLOADER_NAME', $uploader_name);
    $self->set('KEY_ID', $key_id);
    $self->set('APT_UPDATE', $apt_update);
    $self->set('APT_ALLOW_UNAUTHENTICATED', $apt_allow_unauthenticated);
    $self->set('ALTERNATIVES', \%alternatives);
    $self->set('CHECK_DEPENDS_ALGORITHM', $check_depends_algorithm);

    # Not user-settable.
    $self->set('NOLOG', 0);
    $self->set('AUTO_GIVEBACK', 0);
    $self->set('AUTO_GIVEBACK_HOST', 0);
    $self->set('AUTO_GIVEBACK_SOCKET', 0);
    $self->set('AUTO_GIVEBACK_USER', 0);
    $self->set('AUTO_GIVEBACK_WANNABUILD_USER', 0);
    $self->set('WANNABUILD_DATABASE', 0);
    $self->set('BATCH_MODE', 0);
    $self->set('MANUAL_SRCDEPS', []);
    $self->set('BUILD_SOURCE', 0);
    $self->set('BIN_NMU', undef);
    $self->set('GCC_SNAPSHOT', 0);
    $self->set('SIGNING_OPTIONS', "");
    $self->set('OVERRIDE_DISTRIBUTION', 1) if $self->get('DISTRIBUTION');

    # Not user-settable.
    chomp(our $host_arch = readpipe($self->get('DPKG') . " --print-installation-architecture")) if(!defined $host_arch);
    $self->set('HOST_ARCH', $host_arch);
    $self->set('ARCH', $arch);
    chomp(my $hostname = `hostname -f`);
    $self->set('HOSTNAME', $hostname);
}

1;
