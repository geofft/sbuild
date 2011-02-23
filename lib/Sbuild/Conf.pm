#
# Conf.pm: configuration library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2006-2010 Roger Leigh <rleigh@debian.org>
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
use POSIX qw(getgroups getgid);
use Sbuild qw(isin);
use Sbuild::ConfBase;
use Sbuild::Sysconfig;
use Sbuild::Log;
use Sbuild::DB::ClientConf qw();

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
    Sbuild::Conf::setup($conf);
    Sbuild::Conf::read($conf);

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

    my $validate_append_version = sub {
	my $conf = shift;
	my $entry = shift;

	if (defined($conf->get('APPEND_TO_VERSION')) &&
	    $conf->get('APPEND_TO_VERSION') &&
	    $conf->get('BUILD_SOURCE') != 0) {
	    # See <http://bugs.debian.org/475777> for details
	    die "The --append-to-version option is incompatible with a source upload\n";
	}

	if ($conf->get('BUILD_SOURCE') &&
	    $conf->get('BIN_NMU')) {
	    print STDERR "Not building source package for binNMU\n";
	    $conf->_set_value('BUILD_SOURCE', 0);
	}
    };

    our $HOME = $conf->get('HOME');

    my %sbuild_keys = (
	'CHROOT'				=> {
	    DEFAULT => undef
	},
	'BUILD_ARCH_ALL'			=> {
	    DEFAULT => 0
	},
	'NOLOG'					=> {
	    DEFAULT => 0
	},
	'SUDO'					=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'split' ||
		    ($conf->get('CHROOT_MODE') eq 'schroot' &&
		     $conf->get('CHROOT_SPLIT'))) {
		    $validate_program->($conf, $entry);

		    local (%ENV) = %ENV; # make local environment
		    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";
		    $ENV{'APT_CONFIG'} = "test_apt_config";
		    $ENV{'SHELL'} = '/bin/sh';

		    my $sudo = $conf->get('SUDO');
		    chomp( my $test_df = `$sudo sh -c 'echo \$DEBIAN_FRONTEND'` );
		    chomp( my $test_ac = `$sudo sh -c 'echo \$APT_CONFIG'` );
		    chomp( my $test_sh = `$sudo sh -c 'echo \$SHELL'` );

		    if ($test_df ne "noninteractive" ||
			$test_ac ne "test_apt_config" ||
			$test_sh ne '/bin/sh') {
			print STDERR "$sudo is stripping APT_CONFIG, DEBIAN_FRONTEND and/or SHELL from the environment\n";
			print STDERR "'Defaults:" . $conf->get('USERNAME') . " env_keep+=\"APT_CONFIG DEBIAN_FRONTEND SHELL\"' is not set in /etc/sudoers\n";
			die "$sudo is incorrectly configured"
		    }
		}
	    },
	    DEFAULT => 'sudo'
	},
	'SU'					=> {
	    CHECK => $validate_program,
	    DEFAULT => 'su'
	},
	'SCHROOT'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('CHROOT_MODE') eq 'schroot') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'schroot'
	},
	'SCHROOT_OPTIONS'			=> {
	    DEFAULT => ['-q']
	},
	'FAKEROOT'				=> {
	    DEFAULT => 'fakeroot'
	},
	'APT_GET'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'apt-get'
	},
	'APT_CACHE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'apt-cache'
	},
	'APTITUDE'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude') {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'aptitude'
	},
	'DPKG_BUILDPACKAGE_USER_OPTIONS'	=> {
	    DEFAULT => []
	},
	'DPKG_SOURCE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'dpkg-source'
	},
	'DPKG_SOURCE_OPTIONS'			=> {
	    DEFAULT => []
	},
	'DCMD'					=> {
	    CHECK => $validate_program,
	    DEFAULT => 'dcmd'
	},
	'MD5SUM'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'md5sum'
	},
	'AVG_TIME_DB'				=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/avg-build-times"
	},
	'AVG_SPACE_DB'				=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/avg-build-space"
	},
	'STATS_DIR'				=> {
	    DEFAULT => "$HOME/stats"
	},
	'PACKAGE_CHECKLIST'			=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/package-checklist"
	},
	'BUILD_ENV_CMND'			=> {
	    DEFAULT => ""
	},
	'PGP_OPTIONS'				=> {
	    DEFAULT => ['-us', '-uc']
	},
	'LOG_DIR'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		my $directory = $conf->get($key);

		my $log_dir_available = 1;
		if ($directory && ! -d $directory &&
		    !mkdir $directory) {
		    warn "Could not create '$directory': $!\n";
		    $log_dir_available = 0;
		}

		$conf->set('LOG_DIR_AVAILABLE', $log_dir_available);
	    },
	    DEFAULT => "$HOME/logs"
	},
	'LOG_DIR_AVAILABLE'			=> {},
	'MAILTO'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "mailto not set\n"
		    if !$conf->get('MAILTO') &&
		    $conf->get('SBUILD_MODE') eq "buildd";
	    },
	    DEFAULT => ""
	},
	'MAILTO_FORCED_BY_CLI'			=> {
	    DEFAULT => 0
	},
	'MAILTO_HASH'				=> {
	    DEFAULT => {}
	},
	'MAILFROM'				=> {
	    DEFAULT => "Source Builder <sbuild>"
	},
	'COMPRESS_BUILD_LOG_MAILS'              => {
	    DEFAULT => 0
	},
	'PURGE_BUILD_DEPS'			=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DEPS') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DEPS'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always'
	},
	'PURGE_BUILD_DIRECTORY'			=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $conf->get('PURGE_BUILD_DIRECTORY') . "\'"
		    if !isin($conf->get('PURGE_BUILD_DIRECTORY'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always'
	},
	'TOOLCHAIN_REGEX'			=> {
	    DEFAULT => ['binutils$',
			'dpkg-dev$',
			'gcc-[\d.]+$',
			'g\+\+-[\d.]+$',
			'libstdc\+\+',
			'libc[\d.]+-dev$',
			'linux-kernel-headers$',
			'linux-libc-dev$',
			'gnumach-dev$',
			'hurd-dev$',
			'kfreebsd-kernel-headers$'
		]
	},
	'STALLED_PKG_TIMEOUT'			=> {
	    DEFAULT => 150 # minutes
	},
	'MAX_LOCK_TRYS'				=> {
	    DEFAULT => 120
	},
	'LOCK_INTERVAL'				=> {
	    DEFAULT => 5
	},
	'CHROOT_MODE'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad chroot mode \'" . $conf->get('CHROOT_MODE') . "\'"
		    if !isin($conf->get('CHROOT_MODE'),
			     qw(schroot sudo));
	    },
	    DEFAULT => 'schroot'
	},
	'CHROOT_SPLIT'				=> {
	    DEFAULT => 0
	},
	'APT_POLICY'				=> {
	    DEFAULT => 1
	},
	'CHECK_SPACE'				=> {
	    DEFAULT => 1
	},
	'CHECK_WATCHES'				=> {
	    DEFAULT => 1
	},
	'IGNORE_WATCHES_NO_BUILD_DEPS'		=> {
	    DEFAULT => []
	},
	'WATCHES'				=> {
	    DEFAULT => {}
	},
	'BUILD_DIR'				=> {
	    DEFAULT => cwd(),
	    CHECK => $validate_directory
	},
	'SBUILD_MODE'				=> {
	    DEFAULT => 'user'
	},
	'CHROOT_SETUP_SCRIPT'				=> {
	    DEFAULT => undef
	},
	'FORCE_ORIG_SOURCE'			=> {
	    DEFAULT => 0
	},
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> {
	    DEFAULT => {}
	},
	'ENVIRONMENT_FILTER'			=> {
	    DEFAULT => ['^PATH$',
			'^DEB(IAN|SIGN)?_[A-Z_]+$',
	    		'^(C(PP|XX)?|LD|F)FLAGS(_APPEND)?$']
	},
	'LD_LIBRARY_PATH'			=> {
	    DEFAULT => undef
	},
	'MAINTAINER_NAME'			=> {
	    DEFAULT => undef
	},
	'UPLOADER_NAME'				=> {
	    DEFAULT => undef
	},
	'KEY_ID'				=> {
	    DEFAULT => undef
	},
	'SIGNING_OPTIONS'			=> {
	    DEFAULT => ""
	},
	'APT_CLEAN'				=> {
	    DEFAULT => 0
	},
	'APT_UPDATE'				=> {
	    DEFAULT => 1
	},
	'APT_UPDATE_ARCHIVE_ONLY'		=> {
	    DEFAULT => 1
	},
	'APT_UPGRADE'				=> {
	    DEFAULT => 1
	},
	'APT_DISTUPGRADE'			=> {
	    DEFAULT => 0
	},
	'APT_ALLOW_UNAUTHENTICATED'		=> {
	    DEFAULT => 0
	},
	'CHECK_DEPENDS_ALGORITHM'		=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die '$key: Invalid build-dependency checking algorithm \'' .
		    $conf->get($key) .
		    "'\nValid algorthms are 'first-only' and 'alternatives'\n"
		    if !isin($conf->get($key),
			     qw(first-only alternatives));
	    },
	    DEFAULT => 'first-only'
	},
	'AUTO_GIVEBACK'				=> {
	    DEFAULT => 0
	},
	'BATCH_MODE'				=> {
	    DEFAULT => 0
	},
	'CORE_DEPENDS'				=> {
	    DEFAULT => ['build-essential', 'fakeroot']
	},
	'MANUAL_DEPENDS'			=> {
	    DEFAULT => []
	},
	'MANUAL_CONFLICTS'			=> {
	    DEFAULT => []
	},
	'MANUAL_DEPENDS_INDEP'			=> {
	    DEFAULT => []
	},
	'MANUAL_CONFLICTS_INDEP'		=> {
	    DEFAULT => []
	},
	'BUILD_SOURCE'				=> {
	    DEFAULT => 0,
	    CHECK => $validate_append_version,
	},
	'ARCHIVE'				=> {
	    DEFAULT => undef
	},
	'BIN_NMU'				=> {
	    DEFAULT => undef,
	    CHECK => $validate_append_version
	},
	'BIN_NMU_VERSION'			=> {
	    DEFAULT => undef
	},
	'APPEND_TO_VERSION'			=> {
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	},
	'GCC_SNAPSHOT'				=> {
	    DEFAULT => 0
	},
	'JOB_FILE'				=> {
	    DEFAULT => 'build-progress'
	},
	'BUILD_DEP_RESOLVER'			=> {
	    DEFAULT => 'apt',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		warn "W: Build dependency resolver 'internal' is deprecatedr; please switch to 'apt'\n"
		    if $conf->get($key) eq 'internal';


		die '$key: Invalid build-dependency resolver \'' .
		    $conf->get($key) .
		    "'\nValid algorthms are 'internal', 'apt' and 'aptitude'\n"
		    if !isin($conf->get($key),
			     qw(internal apt aptitude));
	    },
	},
	'LINTIAN'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_LINTIAN')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'lintian'
	},
	'RUN_LINTIAN'				=> {
	    CHECK => sub {
		my $conf = shift;
		$conf->check('LINTIAN');
	    },
	    DEFAULT => 0
	},
	'LINTIAN_OPTIONS'			=> {
	    DEFAULT => []
	},
	'PIUPARTS'				=> {
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		# Only validate if needed.
		if ($conf->get('RUN_PIUPARTS')) {
		    $validate_program->($conf, $entry);
		}
	    },
	    DEFAULT => 'piuparts'
	},
	'RUN_PIUPARTS'				=> {
	    CHECK => sub {
		my $conf = shift;
		$conf->check('PIUPARTS');
	    },
	    DEFAULT => 0
	},
	'PIUPARTS_OPTIONS'			=> {
	    DEFAULT => []
	},
	'PIUPARTS_ROOT_ARGS'			=> {
	    DEFAULT => []
	},
	'EXTERNAL_COMMANDS'			=> {
	    DEFAULT => {
		"pre-build-commands" => [],
		"chroot-setup-commands" => [],
		"chroot-cleanup-commands" => [],
		"post-build-commands" => [],
	    },
	},
	'LOG_EXTERNAL_COMMAND_OUTPUT'		=> {
	    DEFAULT => 1
	},
	'LOG_EXTERNAL_COMMAND_ERROR'		=> {
	    DEFAULT => 1
	},
	'RESOLVE_VIRTUAL'				=> {
	    DEFAULT => 0
	},
	'RESOLVE_ALTERNATIVES'				=> {
	    DEFAULT => 0
	},
	'SBUILD_BUILD_DEPENDS_SECRET_KEY'		=> {
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.sec'
	},
	'SBUILD_BUILD_DEPENDS_PUBLIC_KEY'		=> {
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.pub'
	},
    );

    $conf->set_allowed_keys(\%sbuild_keys);
    Sbuild::DB::ClientConf::setup($conf);
}

sub read ($) {
    my $conf = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT && $conf->get('VERBOSE') == 0) {
	$conf->set('VERBOSE', 1);
    }

    my $HOME = $conf->get('HOME');

    # Variables are undefined, so config will default to DEFAULT if unset.
    my $mailprog = undef;
    my $dpkg = undef;
    my $sudo = undef;
    my $su = undef;
    my $schroot = undef;
    my $schroot_options = undef;
    my $fakeroot = undef;
    my $apt_get = undef;
    my $apt_cache = undef;
    my $aptitude = undef;
    my $dpkg_source = undef;
    my $dpkg_source_opts = undef;
    my $dcmd = undef;
    my $md5sum = undef;
    my $avg_time_db = undef;
    my $avg_space_db = undef;
    my $stats_dir = undef;
    my $package_checklist = undef;
    my $build_env_cmnd = undef;
    my $pgp_options = undef;
    my $log_dir = undef;
    my $mailto = undef;
    my %mailto;
    undef %mailto;
    my $mailfrom = undef;
    my $compress_build_log_mails = undef;
    my $purge_build_deps = undef;
    my $purge_build_directory = undef;
    my @toolchain_regex;
    undef @toolchain_regex;
    my $stalled_pkg_timeout = undef;
    my $max_lock_trys = undef;
    my $lock_interval = undef;
    my $apt_policy = undef;
    my $check_space = undef;
    my $check_watches = undef;
    my @ignore_watches_no_build_deps;
    undef @ignore_watches_no_build_deps;
    my %watches;
    undef %watches;
    my $chroot_mode = undef;
    my $chroot_split = undef;
    my $sbuild_mode = undef;
    my $debug = undef;
    my $build_source = undef;
    my $force_orig_source = undef;
    my $chroot_setup_script = undef;
    my %individual_stalled_pkg_timeout;
    undef %individual_stalled_pkg_timeout;
    my $path = undef;
    my $environment_filter = undef;
    my $ld_library_path = undef;
    my $maintainer_name = undef;
    my $uploader_name = undef;
    my $key_id = undef;
    my $apt_clean = undef;
    my $apt_update = undef;
    my $apt_update_archive_only = undef;
    my $apt_upgrade = undef;
    my $apt_distupgrade = undef;
    my $apt_allow_unauthenticated = undef;
    my $check_depends_algorithm = undef;
    my $distribution = undef;
    my $archive = undef;
    my $chroot = undef;
    my $build_arch_all = undef;
    my $arch = undef;
    my $job_file = undef;
    my $build_dir = undef;
    my $build_dep_resolver = undef;
    my $lintian = undef;
    my $run_lintian = undef;
    my $lintian_opts = undef;
    my $piuparts = undef;
    my $run_piuparts = undef;
    my $piuparts_opts = undef;
    my $piuparts_root_args = undef;
    my $external_commands = undef;
    my $log_external_command_output = undef;
    my $log_external_command_error = undef;
    my $resolve_virtual = undef;
    my $resolve_alternatives = undef;
    my $core_depends = undef;

    foreach ($Sbuild::Sysconfig::paths{'SBUILD_CONF'}, "$HOME/.sbuildrc") {
	if (-r $_) {
	    my $e = eval `cat "$_"`;
	    if (!defined($e)) {
		print STDERR "E: $_: Errors found in configuration file:\n$@";
		exit(1);
	    }
	}
    }

    # Needed before any program validation.
    $conf->set('PATH', $path);
    # Set before APT_GET or APTITUDE to allow correct validation.
    $conf->set('BUILD_DEP_RESOLVER', $build_dep_resolver);
    $conf->set('RESOLVE_VIRTUAL', $resolve_virtual);
    $conf->set('RESOLVE_ALTERNATIVES', $resolve_alternatives);
    $conf->set('CORE_DEPENDS', $core_depends);
    $conf->set('ARCH', $arch);
    $conf->set('DISTRIBUTION', $distribution);
    $conf->set('DEBUG', $debug);
    $conf->set('MAILPROG', $mailprog);
    $conf->set('ARCHIVE', $archive);
    $conf->set('CHROOT', $chroot);
    $conf->set('BUILD_ARCH_ALL', $build_arch_all);
    $conf->set('SUDO',  $sudo);
    $conf->set('SU', $su);
    $conf->set('SCHROOT', $schroot);
    $conf->set('SCHROOT_OPTIONS', $schroot_options);
    $conf->set('FAKEROOT', $fakeroot);
    $conf->set('APT_GET', $apt_get);
    $conf->set('APT_CACHE', $apt_cache);
    $conf->set('APTITUDE', $aptitude);
    $conf->set('DPKG_SOURCE', $dpkg_source);
    $conf->set('DPKG_SOURCE_OPTIONS', $dpkg_source_opts);
    $conf->set('DCMD', $dcmd);
    $conf->set('MD5SUM', $md5sum);
    $conf->set('AVG_TIME_DB', $avg_time_db);
    $conf->set('AVG_SPACE_DB', $avg_space_db);
    $conf->set('STATS_DIR', $stats_dir);
    $conf->set('PACKAGE_CHECKLIST', $package_checklist);
    $conf->set('BUILD_ENV_CMND', $build_env_cmnd);
    $conf->set('PGP_OPTIONS', $pgp_options);
    $conf->set('LOG_DIR', $log_dir);
    $conf->set('MAILTO', $mailto);
    $conf->set('MAILTO_HASH', \%mailto)
	if (%mailto);
    $conf->set('MAILFROM', $mailfrom);
    $conf->set('COMPRESS_BUILD_LOG_MAILS', $compress_build_log_mails);
    $conf->set('PURGE_BUILD_DEPS', $purge_build_deps);
    $conf->set('PURGE_BUILD_DIRECTORY', $purge_build_directory);
    $conf->set('TOOLCHAIN_REGEX', \@toolchain_regex)
	if (@toolchain_regex);
    $conf->set('STALLED_PKG_TIMEOUT', $stalled_pkg_timeout);
    $conf->set('MAX_LOCK_TRYS', $max_lock_trys);
    $conf->set('LOCK_INTERVAL', $lock_interval);
    $conf->set('APT_POLICY', $apt_policy);
    $conf->set('CHECK_WATCHES', $check_watches);
    $conf->set('CHECK_SPACE', $check_space);
    $conf->set('IGNORE_WATCHES_NO_BUILD_DEPS',
	       \@ignore_watches_no_build_deps)
	if (@ignore_watches_no_build_deps);
    $conf->set('WATCHES', \%watches)
	if (%watches);
    $conf->set('CHROOT_MODE', $chroot_mode);
    $conf->set('CHROOT_SPLIT', $chroot_split);
    $conf->set('SBUILD_MODE', $sbuild_mode);
    $conf->set('FORCE_ORIG_SOURCE', $force_orig_source);
    $conf->set('BUILD_SOURCE', $build_source);
    $conf->set('CHROOT_SETUP_SCRIPT', $chroot_setup_script);
    $conf->set('INDIVIDUAL_STALLED_PKG_TIMEOUT',
	       \%individual_stalled_pkg_timeout)
	if (%individual_stalled_pkg_timeout);
    $conf->set('ENVIRONMENT_FILTER', $environment_filter);
    $conf->set('LD_LIBRARY_PATH', $ld_library_path);
    $conf->set('MAINTAINER_NAME', $maintainer_name);
    $conf->set('UPLOADER_NAME', $uploader_name);
    $conf->set('KEY_ID', $key_id);
    $conf->set('APT_CLEAN', $apt_clean);
    $conf->set('APT_UPDATE', $apt_update);
    $conf->set('APT_UPDATE_ARCHIVE_ONLY', $apt_update_archive_only);
    $conf->set('APT_UPGRADE', $apt_upgrade);
    $conf->set('APT_DISTUPGRADE', $apt_distupgrade);
    $conf->set('APT_ALLOW_UNAUTHENTICATED', $apt_allow_unauthenticated);
    $conf->set('CHECK_DEPENDS_ALGORITHM', $check_depends_algorithm);
    $conf->set('JOB_FILE', $job_file);

    $conf->set('MAILTO',
	       $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')})
	if defined($conf->get('DISTRIBUTION')) &&
	   $conf->get('DISTRIBUTION') &&
	   $conf->get('MAILTO_HASH')->{$conf->get('DISTRIBUTION')};

    $conf->set('SIGNING_OPTIONS',
	       "-m".$conf->get('MAINTAINER_NAME')."")
	if defined $conf->get('MAINTAINER_NAME');
    $conf->set('SIGNING_OPTIONS',
	       "-e".$conf->get('UPLOADER_NAME')."")
	if defined $conf->get('UPLOADER_NAME');
    $conf->set('SIGNING_OPTIONS',
	       "-k".$conf->get('KEY_ID')."")
	if defined $conf->get('KEY_ID');
    $conf->set('MAINTAINER_NAME', $conf->get('UPLOADER_NAME')) if defined $conf->get('UPLOADER_NAME');
    $conf->set('MAINTAINER_NAME', $conf->get('KEY_ID')) if defined $conf->get('KEY_ID');
    $conf->set('BUILD_DIR', $build_dir);

    if (!defined($conf->get('MAINTAINER_NAME')) &&
	$conf->get('BIN_NMU')) {
	die "A maintainer name, uploader name or key ID must be specified in .sbuildrc,\nor use -m, -e or -k, when performing a binNMU\n";
    }
    $conf->set('RUN_LINTIAN', $run_lintian);
    $conf->set('LINTIAN', $lintian);
    $conf->set('LINTIAN_OPTIONS', $lintian_opts);
    $conf->set('RUN_PIUPARTS', $run_piuparts);
    $conf->set('PIUPARTS', $piuparts);
    $conf->set('PIUPARTS_OPTIONS', $piuparts_opts);
    $conf->set('PIUPARTS_ROOT_ARGS', $piuparts_root_args);
    $conf->set('EXTERNAL_COMMANDS', $external_commands);
    push(@{${$conf->get('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
        $chroot_setup_script) if ($chroot_setup_script);
    $conf->set('LOG_EXTERNAL_COMMAND_OUTPUT', $log_external_command_output);
    $conf->set('LOG_EXTERNAL_COMMAND_ERROR', $log_external_command_error);
}

1;
