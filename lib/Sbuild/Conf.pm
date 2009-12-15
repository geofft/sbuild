#
# Conf.pm: configuration library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
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

    @ISA = qw(Exporter Sbuild::ConfBase);

    @EXPORT = qw();
}

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

    my $validate_append_version = sub {
	my $self = shift;
	my $entry = shift;

	if (defined($self->get('APPEND_TO_VERSION')) &&
	    $self->get('APPEND_TO_VERSION') &&
	    $self->get('BUILD_SOURCE') != 0) {
	    # See <http://bugs.debian.org/475777> for details
	    die "The --append-to-version option is incompatible with a source upload\n";
	}
    };

    our $HOME = $self->get('HOME');

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
		    $ENV{'SHELL'} = $Sbuild::Sysconfig::programs{'SHELL'};

		    my $sudo = $self->get('SUDO');
		    chomp( my $test_df = `$sudo sh -c 'echo \$DEBIAN_FRONTEND'` );
		    chomp( my $test_ac = `$sudo sh -c 'echo \$APT_CONFIG'` );
		    chomp( my $test_sh = `$sudo sh -c 'echo \$SHELL'` );

		    if ($test_df ne "noninteractive" ||
			$test_ac ne "test_apt_config" ||
			$test_sh ne $Sbuild::Sysconfig::programs{'SHELL'}) {
			print STDERR "$sudo is stripping APT_CONFIG, DEBIAN_FRONTEND and/or SHELL from the environment\n";
			print STDERR "'Defaults:" . $self->get('USERNAME') . " env_keep+=\"APT_CONFIG DEBIAN_FRONTEND SHELL\"' is not set in /etc/sudoers\n";
			die "$sudo is incorrectly configured"
		    }
		}
	    },
	    DEFAULT => $Sbuild::Sysconfig::programs{'SUDO'}
	},
	'SU'					=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'SU'}
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
	    },
	    DEFAULT => $Sbuild::Sysconfig::programs{'SCHROOT'}
	},
	'SCHROOT_OPTIONS'			=> {
	    DEFAULT => ['-q']
	},
	'FAKEROOT'				=> {
	    DEFAULT => $Sbuild::Sysconfig::programs{'FAKEROOT'}
	},
	'APT_GET'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'APT_GET'}
	},
	'APT_CACHE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'APT_CACHE'}
	},
	'DPKG_BUILDPACKAGE_USER_OPTIONS'	=> {
	    DEFAULT => []
	},
	'DPKG_SOURCE'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'DPKG_SOURCE'}
	},
	'DCMD'					=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'DCMD'}
	},
	'MD5SUM'				=> {
	    CHECK => $validate_program,
	    DEFAULT => $Sbuild::Sysconfig::programs{'MD5SUM'}
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
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};
		my $directory = $self->get($key);

		my $log_dir_available = 1;
		if ($directory && ! -d $directory &&
		    !mkdir $directory) {
		    warn "Could not create '$directory': $!\n";
		    $log_dir_available = 0;
		}

		$self->set('LOG_DIR_AVAILABLE', $log_dir_available);
	    },
	    DEFAULT => "$HOME/logs"
	},
	'LOG_DIR_AVAILABLE'			=> {},
	'MAILTO'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "mailto not set\n"
		    if !$self->get('MAILTO') &&
		    $self->get('SBUILD_MODE') eq "buildd";
	    },
	    DEFAULT => ""
	},
	'MAILTO_FORCED_BY_CLI'			=> {
	    DEFAULT => {}
	},
	'MAILTO_HASH'				=> {
	    DEFAULT => {}
	},
	'MAILFROM'				=> {
	    DEFAULT => "Source Builder <sbuild>"
	},
	'PURGE_BUILD_DEPS'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $self->get('PURGE_BUILD_DEPS') . "\'"
		    if !isin($self->get('PURGE_BUILD_DEPS'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always'
	},
	'PURGE_BUILD_DIRECTORY'			=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad purge mode \'" .
		    $self->get('PURGE_BUILD_DIRECTORY') . "\'"
		    if !isin($self->get('PURGE_BUILD_DIRECTORY'),
			     qw(always successful never));
	    },
	    DEFAULT => 'always'
	},
	'TOOLCHAIN_REGEX'			=> {
	    DEFAULT => ['binutils$',
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
	'SRCDEP_LOCK_DIR'			=> {
	    # Note: inside chroot only
	    DEFAULT => "/var/lib/sbuild/srcdep-lock"
	},
	'SRCDEP_LOCK_WAIT'			=> {
	    DEFAULT => 1 # minutes
	},
	'MAX_LOCK_TRYS'				=> {
	    DEFAULT => 120
	},
	'LOCK_INTERVAL'				=> {
	    DEFAULT => 5
	},
	'CHROOT_MODE'				=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die "Bad chroot mode \'" . $self->get('CHROOT_MODE') . "\'"
		    if !isin($self->get('CHROOT_MODE'),
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
	'PATH'					=> {
	    DEFAULT => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/X11R6/bin:/usr/games"
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
	    DEFAULT => 0
	},
	'APT_UPGRADE'				=> {
	    DEFAULT => 0
	},
	'APT_DISTUPGRADE'			=> {
	    DEFAULT => 0
	},
	'APT_ALLOW_UNAUTHENTICATED'		=> {
	    DEFAULT => 0
	},
	'ALTERNATIVES'				=> {
	    DEFAULT => {
		'info-browser'		=> 'info',
		'httpd'			=> 'apache',
		'postscript-viewer'	=> 'ghostview',
		'postscript-preview'	=> 'psutils',
		'www-browser'		=> 'lynx',
		'awk'			=> 'gawk',
		'c-shell'		=> 'tcsh',
		'wordlist'		=> 'wenglish',
		'tclsh'			=> 'tcl8.4',
		'wish'			=> 'tk8.4',
		'c-compiler'		=> 'gcc',
		'fortran77-compiler'	=> 'g77',
		'java-compiler'		=> 'jikes',
		'libc-dev'		=> 'libc6-dev',
		'libgl-dev'		=> 'xlibmesa-gl-dev',
		'libglu-dev'		=> 'xlibmesa-glu-dev',
		'libncurses-dev'	=> 'libncurses5-dev',
		'libz-dev'		=> 'zlib1g-dev',
		'libg++-dev'		=> 'libstdc++6-4.0-dev',
		'emacsen'		=> 'emacs21',
		'mail-transport-agent'	=> 'ssmtp',
		'mail-reader'		=> 'mailx',
		'news-transport-system'	=> 'inn',
		'news-reader'		=> 'nn',
		'xserver'		=> 'xvfb',
		'mysql-dev'		=> 'libmysqlclient-dev',
		'giflib-dev'		=> 'libungif4-dev',
		'freetype2-dev'		=> 'libttf-dev'
	    }
	},
	'CHECK_DEPENDS_ALGORITHM'		=> {
	    CHECK => sub {
		my $self = shift;
		my $entry = shift;
		my $key = $entry->{'NAME'};

		die '$key: Invalid build-dependency checking algorithm \'' .
		    $self->get($key) .
		    "'\nValid algorthms are 'first-only' and 'alternatives'\n"
		    if !isin($self->get($key),
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
	    DEFAULT => undef
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
	}
    );

    $self->set_allowed_keys(\%sbuild_keys);
    Sbuild::DB::ClientConf::add_keys($self);
}

sub read_config {
    my $self = shift;

    # Set here to allow user to override.
    if (-t STDIN && -t STDOUT && $self->get('VERBOSE') == 0) {
	$self->set('VERBOSE', 1);
    }

    my $HOME = $self->get('HOME');

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
    my $dpkg_source = undef;
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
    my $purge_build_deps = undef;
    my $purge_build_directory = undef;
    my @toolchain_regex;
    undef @toolchain_regex;
    my $stalled_pkg_timeout = undef;
    my $srcdep_lock_dir = undef;
    my $srcdep_lock_wait = undef;
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
    my $force_orig_source = undef;
    my $chroot_setup_script = undef;
    my %individual_stalled_pkg_timeout;
    undef %individual_stalled_pkg_timeout;
    my $path = undef;
    my $ld_library_path = undef;
    my $maintainer_name = undef;
    my $uploader_name = undef;
    my $key_id = undef;
    my $apt_clean = undef;
    my $apt_update = undef;
    my $apt_upgrade = undef;
    my $apt_distupgrade = undef;
    my $apt_allow_unauthenticated = undef;
    my %alternatives;
    undef %alternatives;
    my $check_depends_algorithm = undef;
    my $distribution = undef;
    my $archive = undef;
    my $chroot = undef;
    my $build_arch_all = undef;
    my $arch = undef;
    my $job_file = undef;
    my $build_dir = undef;

    foreach ($Sbuild::Sysconfig::paths{'SBUILD_CONF'}, "$HOME/.sbuildrc") {
	if (-r $_) {
	    my $e = eval `cat "$_"`;
	    if (!defined($e)) {
		print STDERR "E: $_: Errors found in configuration file:\n$@";
		exit(1);
	    }
	}
    }

    $self->set('ARCH', $arch);
    $self->set('DISTRIBUTION', $distribution);
    $self->set('DEBUG', $debug);
    $self->set('DPKG', $dpkg);
    $self->set('MAILPROG', $mailprog);
    $self->set('ARCHIVE', $archive);
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
    $self->set('MAILTO', $mailto);
    $self->set('MAILTO_HASH', \%mailto)
	if (%mailto);
    $self->set('MAILFROM', $mailfrom);
    $self->set('PURGE_BUILD_DEPS', $purge_build_deps);
    $self->set('PURGE_BUILD_DIRECTORY', $purge_build_directory);
    $self->set('TOOLCHAIN_REGEX', \@toolchain_regex)
	if (@toolchain_regex);
    $self->set('STALLED_PKG_TIMEOUT', $stalled_pkg_timeout);
    $self->set('SRCDEP_LOCK_DIR', $srcdep_lock_dir);
    $self->set('SRCDEP_LOCK_WAIT', $srcdep_lock_wait);
    $self->set('MAX_LOCK_TRYS', $max_lock_trys);
    $self->set('LOCK_INTERVAL', $lock_interval);
    $self->set('APT_POLICY', $apt_policy);
    $self->set('CHECK_WATCHES', $check_watches);
    $self->set('CHECK_SPACE', $check_space);
    $self->set('IGNORE_WATCHES_NO_BUILD_DEPS',
	       \@ignore_watches_no_build_deps)
	if (@ignore_watches_no_build_deps);
    $self->set('WATCHES', \%watches)
	if (%watches);
    $self->set('CHROOT_MODE', $chroot_mode);
    $self->set('CHROOT_SPLIT', $chroot_split);
    $self->set('SBUILD_MODE', $sbuild_mode);
    $self->set('FORCE_ORIG_SOURCE', $force_orig_source);
    $self->set('CHROOT_SETUP_SCRIPT', $chroot_setup_script);
    $self->set('INDIVIDUAL_STALLED_PKG_TIMEOUT',
	       \%individual_stalled_pkg_timeout)
	if (%individual_stalled_pkg_timeout);
    $self->set('PATH', $path);
    $self->set('LD_LIBRARY_PATH', $ld_library_path);
    $self->set('MAINTAINER_NAME', $maintainer_name);
    $self->set('UPLOADER_NAME', $uploader_name);
    $self->set('KEY_ID', $key_id);
    $self->set('APT_CLEAN', $apt_clean);
    $self->set('APT_UPDATE', $apt_update);
    $self->set('APT_UPGRADE', $apt_upgrade);
    $self->set('APT_DISTUPGRADE', $apt_distupgrade);
    $self->set('APT_ALLOW_UNAUTHENTICATED', $apt_allow_unauthenticated);
    $self->set('ALTERNATIVES', \%alternatives)
	if (%alternatives);
    $self->set('CHECK_DEPENDS_ALGORITHM', $check_depends_algorithm);
    $self->set('JOB_FILE', $job_file);

    $self->set('MAILTO',
	       $self->get('MAILTO_HASH')->{$self->get('DISTRIBUTION')})
	if defined($self->get('DISTRIBUTION')) &&
	   $self->get('DISTRIBUTION') &&
	   $self->get('MAILTO_HASH')->{$self->get('DISTRIBUTION')};

    $self->set('SIGNING_OPTIONS',
	       "-m".$self->get('MAINTAINER_NAME')."")
	if defined $self->get('MAINTAINER_NAME');
    $self->set('SIGNING_OPTIONS',
	       "-e".$self->get('UPLOADER_NAME')."")
	if defined $self->get('UPLOADER_NAME');
    $self->set('SIGNING_OPTIONS',
	       "-k".$self->get('KEY_ID')."")
	if defined $self->get('KEY_ID');
    $self->set('MAINTAINER_NAME', $self->get('UPLOADER_NAME')) if defined $self->get('UPLOADER_NAME');
    $self->set('MAINTAINER_NAME', $self->get('KEY_ID')) if defined $self->get('KEY_ID');
    $self->set('BUILD_DIR', $build_dir);

    if (!defined($self->get('MAINTAINER_NAME')) &&
	$self->get('BIN_NMU')) {
	die "A maintainer name, uploader name or key ID must be specified in .sbuildrc,\nor use -m, -e or -k, when performing a binNMU\n";
    }

}

sub check_group_membership ($) {
    my $self = shift;

    # Skip for root
    return if ($< == 0);

    my $user = getpwuid($<);
    my ($name,$passwd,$gid,$members) = getgrnam("sbuild");

    if (!$gid) {
	die "Group sbuild does not exist";
    }

    my $in_group = 0;
    foreach (split(' ', $members)) {
	$in_group = 1 if $_ eq $self->get('USERNAME');
    }

    if (!$in_group) {
	print STDERR "User $user is not a member of group $name in the system group database\n";
	print STDERR "See \"User Setup\" in sbuild-setup(7)\n";
	exit(1);
    }

    $in_group = 0;
    my @groups = getgroups();
    push @groups, getgid();
    foreach (@groups) {
	($name, $passwd, $gid, $members) = getgrgid($_);
	$in_group = 1 if defined($name) && $name eq 'sbuild';
    }

    if (!$in_group) {
	print STDERR "User $user is not currently a member of group sbuild, but is in the system group database\n";
	print STDERR "You need to log in again to gain sbuild group priveleges\n";
	exit(1);
    }

    return;
}

1;
