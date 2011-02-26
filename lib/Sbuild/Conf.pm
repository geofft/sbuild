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
	    DEFAULT => undef,
	    HELP => 'Default chroot (defaults to distribution[-arch][-sbuild])'
	},
	'BUILD_ARCH_ALL'			=> {
	    DEFAULT => 0,
	    HELP => 'Build architecture: all packages by default'
	},
	'NOLOG'					=> {
	    DEFAULT => 0,
	    HELP => 'Disable use of log file'
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
	    DEFAULT => 'sudo',
	    HELP => 'Path to sudo binary'
	},
	'SU'					=> {
	    CHECK => $validate_program,
	    DEFAULT => 'su',
	    HELP => 'Path to su binary'
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
	    DEFAULT => 'schroot',
	    HELP => 'Path to schroot binary'
	},
	'SCHROOT_OPTIONS'			=> {
	    DEFAULT => ['-q'],
	    HELP => 'Additional command-line options for schroot'
	},
	'FAKEROOT'				=> {
	    DEFAULT => 'fakeroot',
	    HELP => 'Path to fakeroot binary'
	},
	'APT_GET'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'apt-get',
	    HELP => 'Path to apt-get binary'
	},
	'APT_CACHE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'apt-cache',
	    HELP => 'Path to apt-cache binary'
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
	    DEFAULT => 'aptitude',
	    HELP => 'Path to aptitude binary'
	},
	'DPKG_BUILDPACKAGE_USER_OPTIONS'	=> {
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-buildpackage'
	},
	'DPKG_SOURCE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'dpkg-source',
	    HELP => 'Path to dpkg-source binary'
	},
	'DPKG_SOURCE_OPTIONS'			=> {
	    DEFAULT => [],
	    HELP => 'Additional command-line options for dpkg-source'
	},
	'DCMD'					=> {
	    CHECK => $validate_program,
	    DEFAULT => 'dcmd',
	    HELP => 'Path to dcmd binary'
	},
	'MD5SUM'				=> {
	    CHECK => $validate_program,
	    DEFAULT => 'md5sum',
	    HELP => 'Path to md5sum binary'
	},
	'AVG_TIME_DB'				=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/avg-build-times",
	    HELP => 'Name of a database for logging package build times (optional, no database is written if empty)'
	},
	'AVG_SPACE_DB'				=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/avg-build-space",
	    HELP => 'Name of a database for logging package space requirement (optional, no database is written if empty)'
	},
	'STATS_DIR'				=> {
	    DEFAULT => "$HOME/stats",
	    HELP => 'Directory for writing build statistics to'
	},
	'PACKAGE_CHECKLIST'			=> {
	    DEFAULT => "$Sbuild::Sysconfig::paths{'SBUILD_LOCALSTATE_DIR'}/package-checklist",
	    HELP => 'Where to store list currently installed packages inside chroot'
	},
	'BUILD_ENV_CMND'			=> {
	    DEFAULT => "",
	    HELP => 'This command is run with the dpkg-buildpackage command line passed to it (in the chroot, if doing a chrooted build).  It is used by the sparc buildd (which is sparc64) to call the wrapper script that sets the environment to sparc (32-bit).  It could be used for other build environment setup scripts.  Note that this is superceded by schroot\'s \'command-prefix\' option'
	},
	'PGP_OPTIONS'				=> {
	    DEFAULT => ['-us', '-uc'],
	    HELP => 'Additional signing options for dpkg-buildpackage'
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
	    DEFAULT => "$HOME/logs",
	    HELP => 'Directory for storing build logs'
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
	    DEFAULT => "",
	    HELP => 'email address to mail build logs to'
	},
	'MAILTO_FORCED_BY_CLI'			=> {
	    DEFAULT => 0
	},
	'MAILTO_HASH'				=> {
	    DEFAULT => {},
	    HELP => 'Like MAILTO, but per-distribution.  This is a hashref mapping distribution name to MAILTO.'
	},
	'MAILFROM'				=> {
	    DEFAULT => "Source Builder <sbuild>",
	    HELP => 'email address set in the From line of build logs'
	},
	'COMPRESS_BUILD_LOG_MAILS'              => {
	    DEFAULT => 0,
	    HELP => 'Should build log mail be compressed?'
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
	    DEFAULT => 'always',
	    HELP => 'When to purge the build dependencies after a build; possible values are "never", "successful", and "always"'
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
	    DEFAULT => 'always',
	    HELP => 'When to purge the build directory after a build; possible values are "never", "successful", and "always"'
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
		],
	    HELP => 'Regular expressions identifying toolchain packages.'
	},
	'STALLED_PKG_TIMEOUT'			=> {
	    DEFAULT => 150, # minutes
	    HELP => 'Time (in minutes) of inactivity after which a build is terminated. Activity is measured by output to the log file.'
	},
	'MAX_LOCK_TRYS'				=> {
	    DEFAULT => 120,
	    HELP => 'Number of times to try waiting for a lock.'
	},
	'LOCK_INTERVAL'				=> {
	    DEFAULT => 5,
	    HELP => 'Lock wait interval (seconds).  Maximum wait time is (max_lock_trys × lock_interval).'
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
	    DEFAULT => 'schroot',
	    HELP => 'Mechanism to use for chroot virtualisation.  Possible value are "schroot" (default) and "sudo".'
	},
	'CHROOT_SPLIT'				=> {
	    DEFAULT => 0,
	    HELP => 'Run in split mode?  In split mode, apt-get and dpkg are run on the host system, rather than inside the chroot.'
	},
	'APT_POLICY'				=> {
	    DEFAULT => 1,
	    HELP => 'APT policy.  1 to enable additional checking of package versions available in the APT cache, or 0 to disable.  0 is the traditional sbuild behaviour; 1 is needed to build from additional repositories such as sarge-backports or experimental, and has a small performance cost.  Note that this is only used by the internal resolver.'
	},
	'CHECK_SPACE'				=> {
	    DEFAULT => 1,
	    HELP => 'Check free disk space prior to starting a build.  sbuild requires the free space to be at least twice the size of the unpacked sources to allow a build to proceed.  Can be disabled to allow building if space is very limited, but the threshold to abort a build has been exceeded despite there being sufficient space for the build to complete.'
	},
	'CHECK_WATCHES'				=> {
	    DEFAULT => 1,
	    HELP => 'Check watched packages to discover missing build dependencies.  This can be disabled to increase the speed of builds.'
	},
	'IGNORE_WATCHES_NO_BUILD_DEPS'		=> {
	    DEFAULT => [],
	    HELP => 'Ignore watches on the following packages if the package doesn\'t have its own build dependencies in the .dsc'
	},
	'WATCHES'				=> {
	    DEFAULT => {},
	    HELP => 'Binaries for which the access time is controlled if they are not listed as source dependencies (note: /usr/bin is added if executable name does not start with \'/\').  Most buildds run with clean chroots at the moment, so the default list is now empty.'
	},
	'BUILD_DIR'				=> {
	    DEFAULT => cwd(),
	    CHECK => $validate_directory,
	    HELP => 'This option is deprecated.  Directory for chroot symlinks and sbuild logs.  Defaults to the current directory if unspecified.  It is used as the location of chroot symlinks (obsolete) and for current build log symlinks and some build logs.  There is no default; if unset, it defaults to the current working directory.  $HOME/build is another common configuration.'
	},
	'SBUILD_MODE'				=> {
	    DEFAULT => 'user',
	    HELP => 'sbuild behaviour; possible values are "user" (exit status reports build failures) and "buildd" (exit status does not report build failures) for use in a buildd setup.  "buildd" also currently implies enabling of "legacy features" such as chroot symlinks in the build directory and the creation of current symlinks in the build directory.'
	},
	'CHROOT_SETUP_SCRIPT'				=> {
	    DEFAULT => undef,
	    HELP => 'Script to run to perform custom setup tasks in the chroot.'
	},
	'FORCE_ORIG_SOURCE'			=> {
	    DEFAULT => 0,
	    HELP => 'By default, the -s option only includes the .orig.tar.gz when needed (i.e. when the Debian revision is 0 or 1).  By setting this option to 1, the .orig.tar.gz will always be included when -s is used.  This is equivalent to --force-orig-source.'
	},
	'INDIVIDUAL_STALLED_PKG_TIMEOUT'	=> {
	    DEFAULT => {},
	    HELP => 'Some packages may exceed the general timeout (e.g. redirecting output to a file) and need a different timeout.',
	    EXAMPLE =>
'%individual_stalled_pkg_timeout = (smalleiffel => 300,
				   jade => 300,
				   atlas => 300,
				   glibc => 1000,
				   \'gcc-3.3\' => 300,
				   kwave => 600);'
	},
	'ENVIRONMENT_FILTER'			=> {
	    DEFAULT => ['^PATH$',
			'^DEB(IAN|SIGN)?_[A-Z_]+$',
	    		'^(C(PP|XX)?|LD|F)FLAGS(_APPEND)?$'],
	    HELP => 'Only environment variables matching one of the regular expressions in this arrayref will be passed to dpkg-buildpackage and other programs run by sbuild.'
	},
	'LD_LIBRARY_PATH'			=> {
	    DEFAULT => undef,
	    HELP => 'Library search path to use inside the chroot.'
	},
	'MAINTAINER_NAME'			=> {
	    DEFAULT => undef,
	    HELP => 'Name to use as override in .changes files for the Maintainer field.  The Maintainer field will not be overridden unless set here.'
	},
	'UPLOADER_NAME'				=> {
	    DEFAULT => undef,
	    HELP => 'Name to use as override in .changes file for the Changed-By: field.'
	},
	'KEY_ID'				=> {
	    DEFAULT => undef,
	    HELP => 'Key ID to use in .changes for the current upload.  It overrides both $maintainer_name and $uploader_name.'
	},
	'SIGNING_OPTIONS'			=> {
	    DEFAULT => "",
	    HELP => 'PGP-related option to pass to dpkg-buildpackage. Usually neither .dsc nor .changes files are not signed automatically.'
	},
	'APT_CLEAN'				=> {
	    DEFAULT => 0,
	  HELP => 'APT clean.  1 to enable running "apt-get clean" at the start of each build, or 0 to disable.'
	},
	'APT_UPDATE'				=> {
	    DEFAULT => 1,
	    HELP => 'APT update.  1 to enable running "apt-get update" at the start of each build, or 0 to disable.'
	},
	'APT_UPDATE_ARCHIVE_ONLY'		=> {
	    DEFAULT => 1,
	    HELP => 'Update local temporary APT archive directly (1, the default) or set to 0 to disable and do a full apt update (not recommended in case the mirror content has changed since the build started).'
	},
	'APT_UPGRADE'				=> {
	    DEFAULT => 1,
	    HELP => 'APT upgrade.  1 to enable running "apt-get upgrade" at the start of each build, or 0 to disable.'
	},
	'APT_DISTUPGRADE'			=> {
	    DEFAULT => 0,
	    HELP => 'APT distupgrade.  1 to enable running "apt-get dist-upgrade" at the start of each build, or 0 to disable.'
	},
	'APT_ALLOW_UNAUTHENTICATED'		=> {
	    DEFAULT => 0,
	    HELP => 'Force APT to accept unauthenticated packages.  By default, unauthenticated packages are not allowed.  This is to keep the build environment secure, using apt-secure(8).  By setting this to 1, APT::Get::AllowUnauthenticated is set to "true" when running apt-get. This is disabled by default: only enable it if you know what you are doing.'
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
	    DEFAULT => 'first-only',
	    HELP => 'Algorithm for build dependency checks: possible values are "first_only" (used by Debian buildds) or "alternatives". Default: "first_only".  Note that this is only used by the internal resolver.'
	},
	'BATCH_MODE'				=> {
	    DEFAULT => 0,
	    HELP => 'Enable batch mode?'
	},
	'CORE_DEPENDS'				=> {
	    DEFAULT => ['build-essential', 'fakeroot'],
	    HELP => 'Packages which must be installed in the chroot for all builds.'
	},
	'MANUAL_DEPENDS'			=> {
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_CONFLICTS'			=> {
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_DEPENDS_INDEP'			=> {
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'MANUAL_CONFLICTS_INDEP'		=> {
	    DEFAULT => [],
	    HELP => 'Additional per-build dependencies.  Do not set by hand.'
	},
	'BUILD_SOURCE'				=> {
	    DEFAULT => 0,
	    CHECK => $validate_append_version,
	    HELP => 'By default, do not build a source package (binary only build).  Set to 1 to force creation of a source package, but note that this is inappropriate for binary NMUs, where the option will always be disabled.'
	},
	'ARCHIVE'				=> {
	    DEFAULT => undef,
	    HELP => 'Archive being built.  Only set in build log.  This might be useful for derivative distributions.'
	},
	'BIN_NMU'				=> {
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Binary NMU options.  Do not set by hand.'
	},
	'BIN_NMU_VERSION'			=> {
	    DEFAULT => undef,
	    HELP => 'Binary NMU options.  Do not set by hand.'
	},
	'APPEND_TO_VERSION'			=> {
	    DEFAULT => undef,
	    CHECK => $validate_append_version,
	    HELP => 'Suffix to append to version number.  May be useful for derivative distributions.'
	},
	'GCC_SNAPSHOT'				=> {
	    DEFAULT => 0,
	    HELP => 'Build using current GCC snapshot?'
	},
	'JOB_FILE'				=> {
	    DEFAULT => 'build-progress',
	    HELP => 'Job status file (only used in batch mode)'
	},
	'BUILD_DEP_RESOLVER'			=> {
	    DEFAULT => 'apt',
	    CHECK => sub {
		my $conf = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		warn "W: Build dependency resolver 'internal' is deprecated; please switch to 'apt'\n"
		    if $conf->get($key) eq 'internal';

		die '$key: Invalid build-dependency resolver \'' .
		    $conf->get($key) .
		    "'\nValid algorthms are 'internal', 'apt' and 'aptitude'\n"
		    if !isin($conf->get($key),
			     qw(internal apt aptitude));
	    },
	    HELP => 'Build dependency resolver.  The \'apt\' resolver is currently the default, and recommended for most users.  This resolver uses apt-get to resolve dependencies.  Alternative resolvers are \'apt\' and \'aptitude\', which use a built-in resolver module and aptitude to resolve build dependencies, respectively.  The internal resolver is not capable of resolving complex alternative and virtual package dependencies, but is otherwise equivalent to apt.  The aptitude resolver is similar to apt, but is useful in more complex situations, such as where multiple distributions are required, for example when building from experimental, where packages are needed from both unstable and experimental, but defaulting to unstable.'
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
	    DEFAULT => 'lintian',
	    HELP => 'Path to lintian binary'
	},
	'RUN_LINTIAN'				=> {
	    CHECK => sub {
		my $conf = shift;
		$conf->check('LINTIAN');
	    },
	    DEFAULT => 0,
	    HELP => 'Run lintian?'
	},
	'LINTIAN_OPTIONS'			=> {
	    DEFAULT => [],
	    HELP => 'Options to pass to lintian.  Each option is a separate arrayref element.  For example, [\'-i\', \'-v\'] to add -i and -v.'
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
	    DEFAULT => 'piuparts',
	    HELP => 'Path to piuparts binary'
	},
	'RUN_PIUPARTS'				=> {
	    CHECK => sub {
		my $conf = shift;
		$conf->check('PIUPARTS');
	    },
	    DEFAULT => 0,
	    HELP => 'Run piuparts'
	},
	'PIUPARTS_OPTIONS'			=> {
	    DEFAULT => [],
	    HELP => 'Options to pass to piuparts.  Each option is a separate arrayref element.  For example, [\'-b\', \'<chroot_tarball>\'] to add -b and <chroot_tarball>.'
	},
	'PIUPARTS_ROOT_ARGS'			=> {
	    DEFAULT => [],
	    HELP => 'Preceding arguments to launch piuparts as root. If no arguments are specified, piuparts will be launched via sudo.'
	},
	'EXTERNAL_COMMANDS'			=> {
	    DEFAULT => {
		"pre-build-commands" => [],
		"chroot-setup-commands" => [],
		"chroot-cleanup-commands" => [],
		"post-build-commands" => [],
	    },
	    HELP => 'External commands to run at various stages of a build. Commands are held in a hash of arrays of arrays data structure.',
	    EXAMPLE =>
'$external_commands = {
    "pre-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-setup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "chroot-cleanup-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
    "post-build-commands" => [
        [\'foo\', \'arg1\', \'arg2\'],
        [\'bar\', \'arg1\', \'arg2\', \'arg3\'],
    ],
};'
	},
	'LOG_EXTERNAL_COMMAND_OUTPUT'		=> {
	    DEFAULT => 1,
	    HELP => 'Log standard output of commands run by sbuild?'
	},
	'LOG_EXTERNAL_COMMAND_ERROR'		=> {
	    DEFAULT => 1,
	    HELP => 'Log standard output of commands run by sbuild?'
	},
	'RESOLVE_VIRTUAL'				=> {
	    DEFAULT => 0,
	    HELP => 'Attempt to resolve virtual dependencies?  This option is only used by the internal resolver.'
	},
	'RESOLVE_ALTERNATIVES'				=> {
	    DEFAULT => undef,
	    GET => sub {
		my $conf = shift;
		my $entry = shift;

		my $retval = $conf->_get_value($entry->{'NAME'});

		if (!defined($retval)) {
		    $retval = 0;
		    $retval = 1
			if ($conf->get('BUILD_DEP_RESOLVER') eq 'aptitude');
		}

		return $retval;
	    },
	    HELP => 'Should the dependency resolver use alternatives in Build-Depends and Build-Depends-Indep?  By default, only the first alternative will be used; all other alternatives will be removed.  Note that this does not include architecture-specific alternatives, which are reduced to the build architecture prior to alternatives removal.  This should be left disabled when building for unstable; it may be useful when building backports.'
	},
	'SBUILD_BUILD_DEPENDS_SECRET_KEY'		=> {
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.sec',
	    HELP => 'GPG secret key for temporary local apt archive.'
	},
	'SBUILD_BUILD_DEPENDS_PUBLIC_KEY'		=> {
	    DEFAULT => '/var/lib/sbuild/apt-keys/sbuild-key.pub',
	    HELP => 'GPG public key for temporary local apt archive.'
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
