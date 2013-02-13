#
# Build.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2010 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package Sbuild::Build;

use strict;
use warnings;

use English;
use POSIX;
use Errno qw(:POSIX);
use Fcntl;
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir);
use FileHandle;
use File::Copy qw(); # copy is already exported from Sbuild, so don't export
		     # anything.
use Dpkg::Arch;
use Dpkg::Control;
use Dpkg::Version;
use MIME::Lite;
use Term::ANSIColor;

use Sbuild qw($devnull binNMU_version copy isin debug df send_mail
              dsc_files dsc_pkgver);
use Sbuild::Base;
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoSudo;
use Sbuild::ChrootRoot;
use Sbuild::Sysconfig qw($version $release_date);
use Sbuild::Sysconfig;
use Sbuild::Resolver qw(get_resolver);
use Sbuild::Exception;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

our $saved_stdout = undef;
our $saved_stderr = undef;

sub new {
    my $class = shift;
    my $dsc = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('ABORT', undef);
    $self->set('Job', $dsc);
    $self->set('Chroot Dir', '');
    $self->set('Chroot Build Dir', '');
    $self->set('Build Dir', '');
    $self->set('Max Lock Trys', 120);
    $self->set('Lock Interval', 5);
    $self->set('Pkg Status', 'pending');
    $self->set('Pkg Status Trigger', undef);
    $self->set('Pkg Start Time', 0);
    $self->set('Pkg End Time', 0);
    $self->set('Pkg Fail Stage', 'init');
    $self->set('Build Start Time', 0);
    $self->set('Build End Time', 0);
    $self->set('Install Start Time', 0);
    $self->set('Install End Time', 0);
    $self->set('This Time', 0);
    $self->set('This Space', 0);
    $self->set('Sub Task', 'initialisation');
    $self->set('Host', Sbuild::ChrootRoot->new($self->get('Config')));
    # Host execution defaults
    my $host_defaults = $self->get('Host')->get('Defaults');
    $host_defaults->{'USER'} = $self->get_conf('USERNAME');
    $host_defaults->{'DIR'} = $self->get_conf('HOME');
    $host_defaults->{'STREAMIN'} = $devnull;
    $host_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
    $host_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
    $host_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');
    # Note, this should never fail.  But, we should handle failure anyway.
    $self->get('Host')->begin_session();

    $self->set('Session', undef);
    $self->set('Dependency Resolver', undef);
    $self->set('Log File', undef);
    $self->set('Log Stream', undef);
    $self->set('Summary Stats', {});

    # DSC, package and version information:
    $self->set_dsc($dsc);
    # Note, will be overwritten by Version: in DSC.
    $self->set_version($dsc);

    # Can sources be obtained?
    $self->set('Invalid Source', 0);
    $self->set('Invalid Source', 1)
	if (!defined $self->get('Version'));

    debug("Invalid Source = " . $self->get('Invalid Source') . "\n");

    return $self;
}

sub request_abort {
    my $self = shift;
    my $reason = shift;

    $self->log_error("ABORT: $reason (requesting cleanup and shutdown)\n");
    $self->set('ABORT', $reason);
}

sub check_abort {
    my $self = shift;

    if ($self->get('ABORT')) {
	Sbuild::Exception::Build->throw(error => "Aborting build: " .
					$self->get('ABORT'),
					failstage => "abort");
    }
}

sub set_dsc {
    my $self = shift;
    my $dsc = shift;

    debug("Setting DSC: $dsc\n");

    $self->set('DSC', $dsc);
    $self->set('Source Dir', dirname($dsc));
    $self->set('DSC Base', basename($dsc));

    debug("DSC = " . $self->get('DSC') . "\n");
    debug("Source Dir = " . $self->get('Source Dir') . "\n");
    debug("DSC Base = " . $self->get('DSC Base') . "\n");
}

sub set_version {
    my $self = shift;
    my $pkgv = shift;

    debug("Setting package version: $pkgv\n");

    my ($pkg, $version);
    if (-f $pkgv && -r $pkgv) {
	($pkg, $version) = dsc_pkgver($pkgv);
    } else {
	($pkg, $version) = split /_/, $pkgv;
    }
    my $pver = Dpkg::Version->new($version, check => 1);
    return if (!defined($pkg) || !defined($version) || !defined($pver));
    my ($o_version);
    $o_version = $pver->version();

    # Original version (no binNMU or other addition)
    my $oversion = $version;
    # Original version with stripped epoch
    my $osversion = $o_version;
    $osversion .= '-' . $pver->revision() unless $pver->{'no_revision'};

    # Add binNMU to version if needed.
    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	$version = binNMU_version($version, $self->get_conf('BIN_NMU_VERSION'),
	    $self->get_conf('APPEND_TO_VERSION'));
    }

    my $bver = Dpkg::Version->new($version, check => 1);
    return if (!defined($bver));
    my ($b_epoch, $b_version, $b_revision);
    $b_epoch = $bver->epoch();
    $b_epoch = "" if $bver->{'no_epoch'};
    $b_version = $bver->version();
    $b_revision = $bver->revision();
    $b_revision = "" if $bver->{'no_revision'};

    # Version with binNMU or other additions and stripped epoch
    my $sversion = $b_version;
    $sversion .= '-' . $b_revision if $b_revision;

    $self->set('Package', $pkg);
    $self->set('Version', $version);
    $self->set('Package_Version', "${pkg}_$version");
    $self->set('Package_OVersion', "${pkg}_$oversion");
    $self->set('Package_OSVersion', "${pkg}_$osversion");
    $self->set('Package_SVersion', "${pkg}_$sversion");
    $self->set('OVersion', $oversion);
    $self->set('OSVersion', $osversion);
    $self->set('SVersion', $sversion);
    $self->set('VersionEpoch', $b_epoch);
    $self->set('VersionUpstream', $b_version);
    $self->set('VersionDebian', $b_revision);
    $self->set('DSC File', "${pkg}_${osversion}.dsc");
    $self->set('DSC Dir', "${pkg}-${b_version}");

    debug("Package = " . $self->get('Package') . "\n");
    debug("Version = " . $self->get('Version') . "\n");
    debug("Package_Version = " . $self->get('Package_Version') . "\n");
    debug("Package_OVersion = " . $self->get('Package_OVersion') . "\n");
    debug("Package_OSVersion = " . $self->get('Package_OSVersion') . "\n");
    debug("Package_SVersion = " . $self->get('Package_SVersion') . "\n");
    debug("OVersion = " . $self->get('OVersion') . "\n");
    debug("OSVersion = " . $self->get('OSVersion') . "\n");
    debug("SVersion = " . $self->get('SVersion') . "\n");
    debug("VersionEpoch = " . $self->get('VersionEpoch') . "\n");
    debug("VersionUpstream = " . $self->get('VersionUpstream') . "\n");
    debug("VersionDebian = " . $self->get('VersionDebian') . "\n");
    debug("DSC File = " . $self->get('DSC File') . "\n");
    debug("DSC Dir = " . $self->get('DSC Dir') . "\n");
}

sub set_status {
    my $self = shift;
    my $status = shift;

    $self->set('Pkg Status', $status);
    if (defined($self->get('Pkg Status Trigger'))) {
	$self->get('Pkg Status Trigger')->($self, $status);
    }
}

sub get_status {
    my $self = shift;

    return $self->get('Pkg Status');
}

# This function is the main entry point into the package build.  It
# provides a top-level exception handler and does the initial setup
# including initiating logging and creating host chroot.  The nested
# run_ functions it calls are separate in order to permit running
# cleanup tasks in a strict order.
sub run {
    my $self = shift;

    eval {
	$self->check_abort();

	$self->set_status('building');

	$self->set('Pkg Start Time', time);
	$self->set('Pkg End Time', $self->get('Pkg Start Time'));

	# Acquire the architectures we're building for and on.
	$self->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$self->set('Build Arch', $self->get_conf('BUILD_ARCH'));

	my $dist = $self->get_conf('DISTRIBUTION');
	if (!defined($dist) || !$dist) {
	    Sbuild::Exception::Build->throw(error => "No distribution defined",
					    failstage => "init");
	}

	if ($self->get('Invalid Source')) {
	    Sbuild::Exception::Build->throw(error => "Invalid source " . $self->get('DSC'),
					    failstage => "init");
	}

	# TODO: Get package name from build object
	if (!$self->open_build_log()) {
	    Sbuild::Exception::Build->throw(error => "Failed to open build log",
					    failstage => "init");
	}

	# Set a chroot to run commands in host
	my $host = $self->get('Host');

	# Host execution defaults (set streams)
	my $host_defaults = $host->get('Defaults');
	$host_defaults->{'STREAMIN'} = $devnull;
	$host_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$host_defaults->{'STREAMERR'} = $self->get('Log Stream');

	$self->check_abort();
	$self->run_chroot();
    };

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
	$e->rethrow();
    }
}

# Pack up source if needed and then run the main chroot session.
# Close log during return/failure.
sub run_chroot {
    my $self = shift;

    eval {
	$self->check_abort();
	$self->run_chroot_session();
    };

    # Log exception info and set status and fail stage prior to
    # closing build log.
    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$self->log_error("$e\n");
	$self->log_info($e->info."\n")
	    if ($e->info);
	if ($e->status) {
	    $self->set_status($e->status);
	} else {
	    $self->set_status("failed");
	}
	$self->set('Pkg Fail Stage', $e->failstage);
    }

    $self->close_build_log();

    if ($e) {
	$e->rethrow();
    }
}

# Create main chroot session and package resolver.  Creates a lock in
# the chroot to prevent concurrent chroot usage (only important for
# non-snapshot chroots).  Ends chroot session on return/failure.
sub run_chroot_session {
    my $self=shift;

    eval {
	$self->check_abort();
	my $chroot_info;
	if ($self->get_conf('CHROOT_MODE') eq 'schroot') {
	    $chroot_info = Sbuild::ChrootInfoSchroot->new($self->get('Config'));
	} else {
	    $chroot_info = Sbuild::ChrootInfoSudo->new($self->get('Config'));
	}

	my $host = $self->get('Host');

	my $session = $chroot_info->create('chroot',
					   $self->get_conf('DISTRIBUTION'),
					   $self->get_conf('CHROOT'),
					   $self->get_conf('HOST_ARCH'));

	# Run pre build external commands
	$self->check_abort();
	$self->run_external_commands("pre-build-commands",
				     $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				     $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

	$self->check_abort();
	if (!$session->begin_session()) {
	    Sbuild::Exception::Build->throw(error => "Error creating chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "create-session");
	}

	$self->set('Session', $session);

	$self->check_abort();
	my $chroot_arch =  $self->chroot_arch();
	if ($self->get_conf('BUILD_ARCH') ne $chroot_arch) {
	    Sbuild::Exception::Build->throw(
		error => "Requested build architecture (" .
		$self->get_conf('BUILD_ARCH') .
		") and chroot architecture (" . $chroot_arch .
		") do not match.  Skipping build.",
		info => "Please specify the correct architecture with --build-arch, or use a chroot of the correct architecture",
		failstage => "create-session");
	}

	$self->set('Chroot Dir', $session->get('Location'));
	# TODO: Don't hack the build location in; add a means to customise
	# the chroot directly.  i.e. allow changing of /build location.
	$self->set('Chroot Build Dir',
		   tempdir($self->get('Package') . '-XXXXXX',
			   DIR =>  $session->get('Location') . "/build"));

	$self->set('Build Dir', $session->strip_chroot_path($self->get('Chroot Build Dir')));

	# Log colouring
	$self->build_log_colour('red', '^E: ');
	$self->build_log_colour('yellow', '^W: ');
	$self->build_log_colour('green', '^I: ');
	$self->build_log_colour('red', '^Status:');
	$self->build_log_colour('green', '^Status: successful$');
	$self->build_log_colour('yellow', '^Keeping session: ');
	$self->build_log_colour('red', '^Lintian:');
	$self->build_log_colour('green', '^Lintian: pass$');

	# Log filtering
	my $filter;
	$filter = $self->get('Build Dir') . '/' . $self->get('DSC Dir');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter, 'PKGBUILDDIR');
	$filter = $self->get('Build Dir');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter, 'BUILDDIR');
	$filter = $session->get('Location');
	$filter =~ s;^/;;;
	$self->build_log_filter($filter , 'CHROOT');

	# Need tempdir to be writable and readable by sbuild group.
	$self->check_abort();
	$session->run_command(
	    { COMMAND => ['chown', $self->get_conf('BUILD_USER') . ':sbuild',
			  $self->get('Build Dir')],
	      USER => 'root',
	      DIR => '/' });
	if ($?) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}
	$self->check_abort();
	$session->run_command(
	    { COMMAND => ['chmod', '0770', $self->get('Build Dir')],
	      USER => 'root',
	      DIR => '/' });
	if ($?) {
	    Sbuild::Exception::Build->throw(error => "Failed to set sbuild group ownership on chroot build dir",
					    failstage => "create-build-dir");
	}

	$self->check_abort();
	# Needed so chroot commands log to build log
	$session->set('Log Stream', $self->get('Log Stream'));
	$host->set('Log Stream', $self->get('Log Stream'));

	# Chroot execution defaults
	my $chroot_defaults = $session->get('Defaults');
	$chroot_defaults->{'DIR'} = $self->get('Build Dir');
	$chroot_defaults->{'STREAMIN'} = $devnull;
	$chroot_defaults->{'STREAMOUT'} = $self->get('Log Stream');
	$chroot_defaults->{'STREAMERR'} = $self->get('Log Stream');
	$chroot_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
	$chroot_defaults->{'ENV'}->{'SHELL'} = '/bin/sh';
	$chroot_defaults->{'ENV'}->{'HOME'} = '/sbuild-nonexistent';
	$chroot_defaults->{'ENV_FILTER'} = $self->get_conf('ENVIRONMENT_FILTER');

	my $resolver = get_resolver($self->get('Config'), $session, $host);
	$resolver->set('Log Stream', $self->get('Log Stream'));
	$resolver->set('Arch', $self->get_conf('ARCH'));
	$resolver->set('Host Arch', $self->get_conf('HOST_ARCH'));
	$resolver->set('Build Arch', $self->get_conf('BUILD_ARCH'));
	$resolver->set('Chroot Build Dir', $self->get('Chroot Build Dir'));
	$self->set('Dependency Resolver', $resolver);

	# Lock chroot so it won't be tampered with during the build.
	$self->check_abort();
	if (!$session->lock_chroot($self->get('Package_SVersion'), $$, $self->get_conf('USERNAME'))) {
	    Sbuild::Exception::Build->throw(error => "Error locking chroot session: skipping " .
					    $self->get('Package'),
					    failstage => "lock-session");
	}

	$self->check_abort();
	$self->run_chroot_session_locked();
    };

    # End chroot session
    my $session = $self->get('Session');
    my $end_session =
	($self->get_conf('PURGE_SESSION') eq 'always' ||
	 ($self->get_conf('PURGE_SESSION') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    if ($end_session) {
	$session->end_session();
    } else {
	$self->log("Keeping session: " . $session->get('Session ID') . "\n");
    }
    $session = undef;
    $self->set('Session', $session);

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

# Run tasks in a *locked* chroot.  Update and upgrade packages.
# Unlocks chroot on return/failure.
sub run_chroot_session_locked {
    my $self = shift;

    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	$self->check_abort();
	$resolver->setup();

	$self->check_abort();
	$self->run_chroot_update();

	$self->check_abort();
	$self->run_fetch_install_packages();
    };

    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    $resolver->cleanup();
    # Unlock chroot now it's cleaned up and ready for other users.
    $session->unlock_chroot();

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

sub run_chroot_update {
    my $self = shift;
    my $resolver = $self->get('Dependency Resolver');

    if ($self->get_conf('APT_CLEAN') || $self->get_conf('APT_UPDATE') ||
	$self->get_conf('APT_DISTUPGRADE') || $self->get_conf('APT_UPGRADE')) {
	$self->log_subsection('Update chroot');
    }

    # Clean APT cache.
    $self->check_abort();
    if ($self->get_conf('APT_CLEAN')) {
	if ($resolver->clean()) {
	    # Since apt-clean was requested specifically, fail on
	    # error when not in buildd mode.
	    $self->log("apt-get clean failed\n");
	    if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		Sbuild::Exception::Build->throw(error => "apt-get clean failed",
						failstage => "apt-get-clean");
	    }
	}
    }

    # Update APT cache.
    $self->check_abort();
    if ($self->get_conf('APT_UPDATE')) {
	if ($resolver->update()) {
	    # Since apt-update was requested specifically, fail on
	    # error when not in buildd mode.
	    if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		Sbuild::Exception::Build->throw(error => "apt-get update failed",
						failstage => "apt-get-update");
	    }
	}
    }

    # Upgrade using APT.
    $self->check_abort();
    if ($self->get_conf('APT_DISTUPGRADE')) {
	if ($resolver->distupgrade()) {
	    # Since apt-distupgrade was requested specifically, fail on
	    # error when not in buildd mode.
	    if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		Sbuild::Exception::Build->throw(error => "apt-get dist-upgrade failed",
						failstage => "apt-get-dist-upgrade");
	    }
	}
    } elsif ($self->get_conf('APT_UPGRADE')) {
	if ($resolver->upgrade()) {
	    # Since apt-upgrade was requested specifically, fail on
	    # error when not in buildd mode.
	    if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		Sbuild::Exception::Build->throw(error => "apt-get upgrade failed",
						failstage => "apt-get-upgrade");
	    }
	}
    }
}

# Fetch sources, run setup, fetch and install core and package build
# deps, then run build.  Cleans up build directory and uninstalls
# build depends on return/failure.
sub run_fetch_install_packages {
    my $self = shift;

    $self->check_abort();
    eval {
	my $session = $self->get('Session');
	my $resolver = $self->get('Dependency Resolver');

	$self->check_abort();
	if (!$self->fetch_source_files()) {
	    Sbuild::Exception::Build->throw(error => "Failed to fetch source files",
					    failstage => "fetch-src");
	}

	# Display message about chroot setup script option use being deprecated
	if ($self->get_conf('CHROOT_SETUP_SCRIPT')) {
	    my $msg = "setup-hook option is deprecated. It has been superceded by ";
	    $msg .= "the chroot-setup-commands feature. setup-hook script will be ";
	    $msg .= "run via chroot-setup-commands.\n";
	    $self->log_warning($msg);
	}

	# Run specified chroot setup commands
	$self->check_abort();
	$self->run_external_commands("chroot-setup-commands",
				     $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				     $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

	$self->check_abort();
	$self->set('Install Start Time', time);
	$self->set('Install End Time', $self->get('Install Start Time'));
	my @coredeps = @{$self->get_conf('CORE_DEPENDS')};
	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    my $crosscoredeps = $self->get_conf('CROSSBUILD_CORE_DEPENDS');
	    push(@coredeps, @{$crosscoredeps->{$self->get('Host Arch')}})
		if defined($crosscoredeps->{$self->get('Host Arch')});
	}
	$resolver->add_dependencies('CORE', join(", ", @coredeps) , "", "", "", "", "");

	if (!$resolver->install_core_deps('core', 'CORE')) {
	    Sbuild::Exception::Build->throw(error => "Core build dependencies not satisfied; skipping",
					    failstage => "install-deps");
	}

	$resolver->add_dependencies('ESSENTIAL', $self->read_build_essential(), "", "", "", "", "");

	my $snapshot = "";
	$snapshot = "gcc-snapshot" if ($self->get_conf('GCC_SNAPSHOT'));
	$resolver->add_dependencies('GCC_SNAPSHOT', $snapshot , "", "", "", "", "");

	# Add additional build dependencies specified on the command-line.
	# TODO: Split dependencies into an array from the start to save
	# lots of joining.
	$resolver->add_dependencies('MANUAL',
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS')}),
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS_ARCH')}),
				    join(", ", @{$self->get_conf('MANUAL_DEPENDS_INDEP')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS_ARCH')}),
				    join(", ", @{$self->get_conf('MANUAL_CONFLICTS_INDEP')}));

	$resolver->add_dependencies($self->get('Package'),
				    $self->get('Build Depends'),
				    $self->get('Build Depends Arch'),
				    $self->get('Build Depends Indep'),
				    $self->get('Build Conflicts'),
				    $self->get('Build Conflicts Arch'),
				    $self->get('Build Conflicts Indep'));

	my @build_deps;
	if ($self->get('Host Arch') eq $self->get('Build Arch')) {
	    @build_deps = ('ESSENTIAL', 'GCC_SNAPSHOT', 'MANUAL',
			   $self->get('Package'));
	} else {
	    $self->check_abort();
	    if (!$resolver->install_core_deps('essential',
					      'ESSENTIAL', 'GCC_SNAPSHOT')) {
		Sbuild::Exception::Build->throw(error => "Essential dependencies not satisfied; skipping",
						failstage => "install-essential");
	    }
	    @build_deps = ('MANUAL', $self->get('Package'));
	}

	$self->check_abort();
	if (!$resolver->install_main_deps($self->get('Package'),
					  @build_deps)) {
	    Sbuild::Exception::Build->throw(error => "Package build dependencies not satisfied; skipping",
					    failstage => "install-deps");
	}
	$self->set('Install End Time', time);

	$self->check_abort();
	$resolver->dump_build_environment();

	$self->check_abort();
	if ($self->build()) {
	    $self->set_status('successful');
	} else {
	    $self->set('Pkg Fail Stage', "build");
	    $self->set_status('failed');
	}

	# Run specified chroot cleanup commands
	$self->check_abort();
	$self->run_external_commands("chroot-cleanup-commands",
				     $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				     $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

	if ($self->get('Pkg Status') eq "successful") {
	    $self->log_subsection("Post Build");

	    # Run lintian.
	    $self->check_abort();
	    $self->run_lintian();

	    # Run piuparts.
	    $self->check_abort();
	    $self->run_piuparts();

	    # Run post build external commands
	    $self->check_abort();
	    $self->run_external_commands("post-build-commands",
					 $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
					 $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

	}
    };

    $self->log_subsection("Cleanup");
    my $session = $self->get('Session');
    my $resolver = $self->get('Dependency Resolver');

    my $purge_build_directory =
	($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $purge_build_deps =
	($self->get_conf('PURGE_BUILD_DEPS') eq 'always' ||
	 ($self->get_conf('PURGE_BUILD_DEPS') eq 'successful' &&
	  $self->get_status() eq 'successful')) ? 1 : 0;
    my $is_cloned_session = (defined ($session->get('Session Purged')) &&
			     $session->get('Session Purged') == 1) ? 1 : 0;

    if ($purge_build_directory) {
	# Purge package build directory
	$self->log("Purging " . $self->get('Build Dir') . "\n");
	$self->get('Session')->run_command(
	    { COMMAND => ['rm', '-rf', $self->get('Build Dir')],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });
    }

    # Purge non-cloned session
    if ($is_cloned_session) {
	$self->log("Not cleaning session: cloned chroot in use\n");
    } else {
	if ($purge_build_deps) {
	    # Removing dependencies
	    $resolver->uninstall_deps();
	} else {
	    $self->log("Not removing build depends: as requested\n");
	}
    }

    my $e;
    if ($e = Exception::Class->caught('Sbuild::Exception::Build')) {
	$e->rethrow();
    }
}

sub copy_to_chroot {
    my $self = shift;
    my $source = shift;
    my $dest = shift;

    $self->check_abort();
    if (! File::Copy::copy($source, $dest)) {
	$self->log_error("E: Failed to copy '$source' to '$dest': $!\n");
	exit (1);
	return 0;
    }

    $self->get('Session')->run_command(
	{ COMMAND => ['chown', $self->get_conf('BUILD_USER') . ':sbuild',
		      $self->get('Session')->strip_chroot_path($dest)],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	$self->log_error("E: Failed to set sbuild group ownership on $dest\n");
	return 0;
    }
    $self->get('Session')->run_command(
	{ COMMAND => ['chmod', '0664',
		      $self->get('Session')->strip_chroot_path($dest)],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	$self->log_error("E: Failed to set 0644 permissions on $dest\n");
	return 0;
    }

    return 1;
}
sub fetch_source_files {
    my $self = shift;

    my $dir = $self->get('Source Dir');
    my $dsc = $self->get('DSC File');
    my $build_dir = $self->get('Chroot Build Dir');
    my $pkg = $self->get('Package');
    my $ver = $self->get('OVersion');
    my $host_arch = $self->get('Host Arch');

    my ($dscarchs, $dscpkg, $dscver, @fetched);

    my $build_depends = "";
    my $build_depends_arch = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_arch = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->log_subsection("Fetch source files");

    if (!defined($self->get('Package')) ||
	!defined($self->get('OVersion')) ||
	!defined($self->get('Source Dir'))) {
	$self->log("Invalid source: $self->get('DSC')\n");
	return 0;
    }

    $self->check_abort();
    if ($self->get('DSC Base') =~ m/\.dsc$/) {
	# Work with a .dsc file.
	my $file = $self->get('DSC');
	if (! -f $file || ! -r $file) {
	    $self->log_error("Could not find $file\n");
	    return 0;
	}
	my @cwd_files = dsc_files($file);

	# Copy the local source files into the build directory.
	$self->log_subsubsection("Local sources");
	$self->log("$file exists in $dir; copying to chroot\n");
	if (! $self->copy_to_chroot("$file", "$build_dir/$dsc")) {
	    return 0;
	}
	push(@fetched, "$build_dir/$dsc");
	foreach (@cwd_files) {
	    if (! $self->copy_to_chroot("$dir/$_", "$build_dir/$_")) {
		return 0;
	    }
	    push(@fetched, "$build_dir/$_");
	}
    } else {
	# Use apt to download the source files
	$self->log_subsubsection("Check APT");
	my %entries = ();
	my $retried = $self->get_conf('APT_UPDATE'); # Already updated if set
      retry:
	$self->log("Checking available source versions...\n");

	my $pipe = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'),
			  '-q', 'showsrc', "$pkg"],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => '/'});
	if (!$pipe) {
	    $self->log("Can't open pipe to ".$self->get_conf('APT_UPDATE').": $!\n");
	    return 0;
	}

	{
	    local($/) = "";
	    my $package;
	    my $ver;
	    my $tfile;
	    while( <$pipe> ) {
		$package = $1 if /^Package:\s+(\S+)\s*$/mi;
		$ver = $1 if /^Version:\s+(\S+)\s*$/mi;
		$tfile = $1 if /^Files:\s*\n((\s+.*\s*\n)+)/mi;
		if (defined $package && defined $ver && defined $tfile) {
		    @{$entries{"$package $ver"}} = map { (split( /\s+/, $_ ))[3] }
		    split( "\n", $tfile );
		    undef($package);
		    undef($ver);
		    undef($tfile);
		}
	    }

	    if (! scalar keys %entries) {
		$self->log($self->get_conf('APT_CACHE') .
			   " returned no information about $pkg source\n");
		$self->log("Are there any deb-src lines in your /etc/apt/sources.list?\n");
		return 0;

	    }
	}
	close($pipe);

	if ($?) {
	    $self->log($self->get_conf('APT_CACHE') . " exit status $?: $!\n");
	    return 0;
	}

	if (!defined($entries{"$pkg $ver"})) {
	    if (!$retried) {
		$self->log_subsubsection("Update APT");
		# try to update apt's cache if nothing found
		$self->get('Dependency Resolver')->update();
		$retried = 1;
		goto retry;
	    }
	    $self->log("Can't find source for " .
		       $self->get('Package_OVersion') . "\n");
	    $self->log("(only different version(s) ",
	    join( ", ", sort keys %entries), " found)\n")
		if %entries;
	    return 0;
	}

	$self->log_subsubsection("Download source files with APT");

	foreach (@{$entries{"$pkg $ver"}}) {
	    push(@fetched, "$build_dir/$_");
	}

	my $pipe2 = $self->get('Dependency Resolver')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), '--only-source', '-q', '-d', 'source', "$pkg=$ver"],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0}) || return 0;

	while(<$pipe2>) {
	    $self->log($_);
	}
	close($pipe2);
	if ($?) {
	    $self->log($self->get_conf('APT_GET') . " for sources failed\n");
	    return 0;
	}
	$self->set_dsc((grep { /\.dsc$/ } @fetched)[0]);
    }

    my $pdsc = Dpkg::Control->new(type => CTRL_PKG_SRC);
    $pdsc->set_options(allow_pgp => 1);
    if (!$pdsc->load("$build_dir/$dsc")) {
	$self->log("Error parsing $build_dir/$dsc");
	return 0;
    }

    $build_depends = $pdsc->{'Build-Depends'};
    $build_depends_arch = $pdsc->{'Build-Depends-Arch'};
    $build_depends_indep = $pdsc->{'Build-Depends-Indep'};
    $build_conflicts = $pdsc->{'Build-Conflicts'};
    $build_conflicts_arch = $pdsc->{'Build-Conflicts-Arch'};
    $build_conflicts_indep = $pdsc->{'Build-Conflicts-Indep'};
    $dscarchs = $pdsc->{'Architecture'};
    $dscpkg = $pdsc->{'Source'};
    $dscver = $pdsc->{'Version'};

    $self->set_version("${dscpkg}_${dscver}");

    $build_depends =~ s/\n\s+/ /g if defined $build_depends;
    $build_depends_arch =~ s/\n\s+/ /g if defined $build_depends_arch;
    $build_depends_indep =~ s/\n\s+/ /g if defined $build_depends_indep;
    $build_conflicts =~ s/\n\s+/ /g if defined $build_conflicts;
    $build_conflicts_arch =~ s/\n\s+/ /g if defined $build_conflicts_arch;
    $build_conflicts_indep =~ s/\n\s+/ /g if defined $build_conflicts_indep;

    $self->log_subsubsection("Check arch");
    if (!$dscarchs) {
	$self->log("$dsc has no Architecture: field -- skipping arch check!\n");
    } else {
	my $valid_arch;
	for my $a (split(/\s+/, $dscarchs)) {
	    if (Dpkg::Arch::debarch_is($host_arch, $a)) {
		$valid_arch = 1;
		last;
	    }
	}
	if ($dscarchs ne "any" && !($valid_arch) &&
	    !($dscarchs eq "all" && $self->get_conf('BUILD_ARCH_ALL')) )  {
	    my $msg = "$dsc: $host_arch not in arch list or does not match any arch wildcards: $dscarchs -- skipping\n";
	    $self->log($msg);
	    Sbuild::Exception::Build->throw(error => "$dsc: $host_arch not in arch list or does not match any arch wildcards: $dscarchs -- skipping",
					    status => "skipped",
					    failstage => "arch-check");
	    return 0;
	}
    }

    debug("Arch check ok ($host_arch included in $dscarchs)\n");

    $self->set('Build Depends', $build_depends);
    $self->set('Build Depends Arch', $build_depends_arch);
    $self->set('Build Depends Indep', $build_depends_indep);
    $self->set('Build Conflicts', $build_conflicts);
    $self->set('Build Conflicts Arch', $build_conflicts_arch);
    $self->set('Build Conflicts Indep', $build_conflicts_indep);

    return 1;
}

# Subroutine that runs any command through the system (i.e. not through the
# chroot. It takes a string of a command with arguments to run along with
# arguments whether to save STDOUT and/or STDERR to the log stream
sub run_command {
    my $self = shift;
    my $command = shift;
    my $log_output = shift;
    my $log_error = shift;
    my $chroot = shift;

    # Used to determine if we are to log from commands
    my ($out, $err, $defaults);

    # Run the command and save the exit status
	if (!$chroot)
	{
	    $defaults = $self->get('Host')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);
	    $self->get('Host')->run_command(
		{ COMMAND => \@{$command},
		    PRIORITY => 0,
		    STREAMOUT => $out,
		    STREAMERR => $err,
		});
	} else {
	    $defaults = $self->get('Session')->{'Defaults'};
	    $out = $defaults->{'STREAMOUT'} if ($log_output);
	    $err = $defaults->{'STREAMERR'} if ($log_error);
	    $self->get('Session')->run_command(
		{ COMMAND => \@{$command},
		    USER => $self->get_conf('BUILD_USER'),
		    PRIORITY => 0,
		    STREAMOUT => $out,
		    STREAMERR => $err,
		});
	}
    my $status = $?;

    # Check if the command failed
    if ($status != 0) {
	return 0;
    }
    return 1;
}

# Subroutine that processes external commands to be run during various stages of
# an sbuild run. We also ask if we want to log any output from the commands
sub run_external_commands {
    my $self = shift;
    my $stage = shift;
    my $log_output = shift;
    my $log_error = shift;

    # Return success now unless there are commands to run
    return 1 unless (${$self->get_conf('EXTERNAL_COMMANDS')}{$stage});

    # Determine which set of commands to run based on the parameter $stage
    my @commands = @{${$self->get_conf('EXTERNAL_COMMANDS')}{$stage}};
    return 1 if !(@commands);

    # Create appropriate log message and determine if the commands are to be
    # run inside the chroot or not.
    my $chroot = 0;
    if ($stage eq "pre-build-commands") {
	$self->log_subsection("Pre Build Commands");
    } elsif ($stage eq "chroot-setup-commands") {
	$self->log_subsection("Chroot Setup Commands");
	$chroot = 1;
    } elsif ($stage eq "chroot-cleanup-commands") {
	$self->log_subsection("Chroot Cleanup Commands");
	$chroot = 1;
    } elsif ($stage eq "post-build-commands") {
	$self->log_subsection("Post Build Commands");
    }

    # Run each command, substituting the various percent escapes (like
    # %SBUILD_DSC) from the commands to run with the appropriate subsitutions.
    my $dsc = $self->get('DSC');
    my $changes;
    $changes = $self->get('Changes File') if ($self->get('Changes File'));
    my %percent = (
	"%" => "%",
	"d" => $dsc, "SBUILD_DSC" => $dsc,
	"c" => $changes, "SBUILD_CHANGES" => $changes,
    );
    # Our escapes pattern, with longer escapes first, then sorted lexically.
    my $keyword_pat = join("|",
	sort {length $b <=> length $a || $a cmp $b} keys %percent);
    my $returnval = 1;
    foreach my $command (@commands) {
	foreach my $arg (@{$command}) {
	  $arg =~ s{
	      # Match a percent followed by a valid keyword
	     \%($keyword_pat)
	  }{
	      # Substitute with the appropriate value only if it's defined
	      $percent{$1} || $&
	  }msxge;
	}
  my $command_str = join(" ", @{$command});
	$self->log_subsubsection("$command_str");
	$returnval = $self->run_command($command, $log_output, $log_error, $chroot);
	$self->log("\n");
	if (!$returnval) {
	    $self->log_error("Command '$command_str' failed to run.\n");
	} else {
	    $self->log_info("Finished running '$command_str'.\n");
	}
    }
    $self->log("\nFinished processing commands.\n");
    $self->log_sep();
    return $returnval;
}

sub run_lintian {
    my $self = shift;

    return 1 unless ($self->get_conf('RUN_LINTIAN'));

    $self->log_subsubsection("lintian");

    my $lintian = $self->get_conf('LINTIAN');
    my @lintian_command = ($lintian);
    push @lintian_command, @{$self->get_conf('LINTIAN_OPTIONS')} if
        ($self->get_conf('LINTIAN_OPTIONS'));
    push @lintian_command, $self->get('Changes File');
    $self->get('Host')->run_command(
        { COMMAND => \@lintian_command,
          PRIORITY => 0,
        });
    my $status = $? >> 8;
    $self->set('Lintian Reason', 'pass');

    $self->log("\n");
    if ($?) {
        my $why = "unknown reason";
	$self->set('Lintian Reason', 'error');
	$self->set('Lintian Reason', 'fail') if ($status == 1);
        $why = "runtime error" if ($status == 2);
        $why = "policy violation" if ($status == 1);
        $why = "received signal " . $? & 127 if ($? & 127);
        $self->log_error("Lintian run failed ($why)\n");

        return 0;
    }

    $self->log_info("Lintian run was successful.\n");
    return 1;
}

sub run_piuparts {
    my $self = shift;

    return 1 unless ($self->get_conf('RUN_PIUPARTS'));

    $self->log_subsubsection("piuparts");

    my $piuparts = $self->get_conf('PIUPARTS');
    my @piuparts_command;
    if (scalar(@{$self->get_conf('PIUPARTS_ROOT_ARGS')})) {
	push @piuparts_command, @{$self->get_conf('PIUPARTS_ROOT_ARGS')};
    } else {
	push @piuparts_command, 'sudo', '--';
    }
    push @piuparts_command, $piuparts;
    push @piuparts_command, @{$self->get_conf('PIUPARTS_OPTIONS')} if
        ($self->get_conf('PIUPARTS_OPTIONS'));
    push @piuparts_command, $self->get('Changes File');
    $self->get('Host')->run_command(
        { COMMAND => \@piuparts_command,
          PRIORITY => 0,
        });
    my $status = $? >> 8;
    $self->set('Piuparts Reason', 'pass');

    $self->log("\n");
    if ($?) {
        $self->log_error("Piuparts run failed.\n");
	$self->set('Piuparts Reason', 'fail');
        return 0;
    }

    $self->log_info("Piuparts run was successful.\n");
    return 1;
}

sub build {
    my $self = shift;

    my $dscfile = $self->get('DSC File');
    my $dscdir = $self->get('DSC Dir');
    my $pkg = $self->get('Package');
    my $build_dir = $self->get('Chroot Build Dir');
    my $host_arch = $self->get('Host Arch');
    my $build_arch = $self->get('Build Arch');

    my( $rv, $changes );
    local( *PIPE, *F, *F2 );

    $self->log_subsection("Build");
    $self->set('This Space', 0);

    my $tmpunpackdir = $dscdir;
    $tmpunpackdir =~ s/-.*$/.orig.tmp-nest/;
    $tmpunpackdir =~ s/_/-/;
    $tmpunpackdir = "$build_dir/$tmpunpackdir";

    $self->log_subsubsection("Unpack source");
    if (-d "$build_dir/$dscdir" && -l "$build_dir/$dscdir") {
	# if the package dir already exists but is a symlink, complain
	$self->log("Cannot unpack source: a symlink to a directory with the\n".
		   "same name already exists.\n");
	return 0;
    }
    if (! -d "$build_dir/$dscdir") {
	$self->set('Sub Task', "dpkg-source");
	$self->get('Session')->run_command(
		    { COMMAND => [$self->get_conf('DPKG_SOURCE'),
				  '-x', $dscfile, $dscdir],
		      USER => $self->get_conf('BUILD_USER'),
		      PRIORITY => 0});
	if ($?) {
	    $self->log("FAILED [dpkg-source died]\n");
	    Sbuild::Exception::Build->throw(error => "FAILED [dpkg-source died]",
					    failstage => "unpack");
	}

	$self->get('Session')->run_command(
	    { COMMAND => ['chmod', '-R', 'g-s,go+rX', $dscdir],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0});
	if ($?) {
	    $self->log("chmod -R g-s,go+rX $dscdir failed.\n");
	    Sbuild::Exception::Build->throw(error => "chmod -R g-s,go+rX $dscdir failed",
					    failstage => "unpack");
	}

	$dscdir = "$build_dir/$dscdir"
    }
    else {
	$dscdir = "$build_dir/$dscdir";

	$self->log_subsubsection("Check unpacked source");
	# check if the unpacked tree is really the version we need
	$dscdir = $self->get('Session')->strip_chroot_path($dscdir);
	my $pipe = $self->get('Session')->pipe_command(
	    { COMMAND => ['dpkg-parsechangelog'],
	      USER => $self->get_conf('BUILD_USER'),
	      PRIORITY => 0,
	      DIR => $dscdir});
	$self->set('Sub Task', "dpkg-parsechangelog");

	my $clog = "";
	while(<$pipe>) {
	    $clog .= $_;
	}
	close($pipe);
	if ($?) {
	    $self->log("FAILED [dpkg-parsechangelog died]\n");
	    Sbuild::Exception::Build->throw(error => "FAILED [dpkg-parsechangelog died]",
					    failstage => "check-unpacked-version");
	}
	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    $self->log("dpkg-parsechangelog didn't print Version:\n");
	    Sbuild::Exception::Build->throw(error => "dpkg-parsechangelog didn't print Version:",
					    failstage => "check-unpacked-version");
	}
    }

    $self->log_subsubsection("Check disc space");
    my $current_usage = `du -k -s "$dscdir"`;
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $free = df($dscdir);
	if ($free < 2*$current_usage && $self->get_conf('CHECK_SPACE')) {
	    Sbuild::Exception::Build->throw(error => "Disc space is probably not sufficient for building.",
					    info => "Source needs $current_usage KiB, while $free KiB is free.)",
					    failstage => "check-space");
	} else {
	    $self->log("Sufficient free space for build\n");
	}
    }

    my $cpipe = $self->get('Session')->pipe_command(
	{ COMMAND => ['dpkg-parsechangelog'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => $self->get('Session')->strip_chroot_path($dscdir) });
    my $clog = do { local $/; <$cpipe> };
    close($cpipe);
    if ($?) {
	$self->log("FAILED [dpkg-parsechangelog died]\n");
	return 0;
    }

    my ($name) = $clog =~ /^Source:\s*(.*)$/m;
    my ($version) = $clog =~ /^Version:\s*(.*)$/m;
    my ($dists) = $clog =~ /^Distribution:\s*(.*)$/m;
    my ($urgency) = $clog =~ /^Urgency:\s*(.*)$/m;
    my ($date) = $clog =~ /^Date:\s*(.*)$/m;
    if ($dists ne $self->get_conf('DISTRIBUTION')) {
	$self->build_log_colour('yellow',
				"^Distribution: " . $self->get_conf('DISTRIBUTION') . "\$");
    }

    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	if (!$self->get_conf('MAINTAINER_NAME')) {
	    Sbuild::Exception::Build->throw(error => "No maintainer specified.",
					    info => 'When making changelog additions for a binNMU or appending a version suffix, a maintainer must be specified for the changelog entry e.g. using $maintainer_name, $uploader_name or $key_id, (or the equivalent command-line options)',
					    failstage => "check-space");
	}

	$self->log_subsubsection("Hack binNMU version");
	if (open( F, "<$dscdir/debian/changelog" )) {
	    my $text = do { local $/; <F> };
	    close( F );


	    my $NMUversion = $self->get('Version');
	    if (!open( F, ">$dscdir/debian/changelog" )) {
		$self->log("Can't open debian/changelog for binNMU hack: $!\n");
		Sbuild::Exception::Build->throw(error => "Can't open debian/changelog for binNMU hack: $!",
						failstage => "hack-binNMU");
	    }
	    $dists = $self->get_conf('DISTRIBUTION');

	    print F "$name ($NMUversion) $dists; urgency=low, binary-only=yes\n\n";
	    if ($self->get_conf('APPEND_TO_VERSION')) {
		print F "  * Append ", $self->get_conf('APPEND_TO_VERSION'),
		    " to version number; no source changes\n";
	    }
	    if ($self->get_conf('BIN_NMU')) {
		print F "  * Binary-only non-maintainer upload for $host_arch; ",
		    "no source changes.\n";
		print F "  * ", join( "    ", split( "\n", $self->get_conf('BIN_NMU') )), "\n";
	    }
	    print F "\n";

	    print F " -- " . $self->get_conf('MAINTAINER_NAME') . "  $date\n\n";
	    print F $text;
	    close( F );
	    $self->log("Created changelog entry for binNMU version $NMUversion\n");
	}
	else {
	    $self->log("Can't open debian/changelog -- no binNMU hack!\n");
	    Sbuild::Exception::Build->throw(error => "Can't open debian/changelog -- no binNMU hack: $!!",
					    failstage => "hack-binNMU");
	}
    }

    if (-f "$dscdir/debian/files") {
	local( *FILES );
	my @lines;
	open( FILES, "<$dscdir/debian/files" );
	chomp( @lines = <FILES> );
	close( FILES );

	$self->log_warning("After unpacking, there exists a file debian/files with the contents:\n");

	$self->log_sep();
	foreach (@lines) {
	    $self->log($_);
	}
	$self->log_sep();
	$self->log("\n");

	$self->log_info("This should be reported as a bug.\n");
	$self->log_info("The file has been removed to avoid dpkg-genchanges errors.\n");

	unlink "$dscdir/debian/files";
    }

    # Build tree not writable during build (except for the sbuild
    # user performing the build).
    $self->get('Session')->run_command(
	{ COMMAND => ['chmod', '-R', 'go-w', $self->get('Build Dir')],
	  USER => 'root',
	  PRIORITY => 0});
    if ($?) {
	$self->log("chmod og-w " . $self->get('Build Dir') . " failed.\n");
	return 0;
    }

    $self->set('Build Start Time', time);
    $self->set('Build End Time', $self->get('Build Start Time'));

    my $binopt = $self->get_conf('BUILD_SOURCE') ?
	$self->get_conf('FORCE_ORIG_SOURCE') ? "-sa" : "" :
	$self->get_conf('BUILD_ARCH_ALL') ?	"-b" : "-B";

    my $bdir = $self->get('Session')->strip_chroot_path($dscdir);
    if (-f "$self->{'Chroot Dir'}/etc/ld.so.conf" &&
	! -r "$self->{'Chroot Dir'}/etc/ld.so.conf") {
	$self->get('Session')->run_command(
	    { COMMAND => ['chmod', 'a+r', '/etc/ld.so.conf'],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

	$self->log_subsubsection("Fix ld.so");
	$self->log("ld.so.conf was not readable! Fixed.\n");
    }

    my $buildcmd = [];
    push (@{$buildcmd}, $self->get_conf('BUILD_ENV_CMND'))
	if (defined($self->get_conf('BUILD_ENV_CMND')) &&
	    $self->get_conf('BUILD_ENV_CMND'));
    push (@{$buildcmd}, 'dpkg-buildpackage');

    if ($host_arch ne $build_arch) {
	push (@{$buildcmd}, '-a' . $host_arch);
    }

    if (defined($self->get_conf('PGP_OPTIONS')) &&
	$self->get_conf('PGP_OPTIONS')) {
	if (ref($self->get_conf('PGP_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('PGP_OPTIONS')});
        } else {
	    push (@{$buildcmd}, $self->get_conf('PGP_OPTIONS'));
	}
    }

    if (defined($self->get_conf('SIGNING_OPTIONS')) &&
	$self->get_conf('SIGNING_OPTIONS')) {
	if (ref($self->get_conf('SIGNING_OPTIONS')) eq 'ARRAY') {
	    push (@{$buildcmd}, @{$self->get_conf('SIGNING_OPTIONS')});
        } else {
	    push (@{$buildcmd}, $self->get_conf('SIGNING_OPTIONS'));
	}
    }

    push (@{$buildcmd}, $binopt) if $binopt;
    push (@{$buildcmd}, "-r" . $self->get_conf('FAKEROOT'));

    if (defined($self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')) &&
	$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')) {
	push (@{$buildcmd}, @{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')});
    }

    # Set up additional build environment variables.
    my %buildenv = %{$self->get_conf('BUILD_ENVIRONMENT')};
    $buildenv{'PATH'} = $self->get_conf('PATH');
    $buildenv{'LD_LIBRARY_PATH'} = $self->get_conf('LD_LIBRARY_PATH')
	if defined($self->get_conf('LD_LIBRARY_PATH'));

	# Add cross environment config
	if ($host_arch ne $build_arch) {
		$buildenv{'CONFIG_SITE'} = "/etc/dpkg-cross/cross-config." . $host_arch;
		if (defined($buildenv{'DEB_BUILD_OPTIONS'})) {
			$buildenv{'DEB_BUILD_OPTIONS'} .= " nocheck";
		} else {
			$buildenv{'DEB_BUILD_OPTIONS'} = "nocheck";
		}
	}

    # Explicitly add any needed environment to the environment filter
    # temporarily for dpkg-buildpackage.
    my @env_filter;
    foreach my $envvar (keys %buildenv) {
	push(@env_filter, "^$envvar\$");
    }

    # Dump build environment
    $self->log_subsubsection("User Environment");
    {
	my $pipe = $self->get('Session')->pipe_command(
	    { COMMAND => ['env'],
	      ENV => \%buildenv,
	      ENV_FILTER => \@env_filter,
	      USER => $self->get_conf('BUILD_USER'),
	      SETSID => 1,
	      PRIORITY => 0,
	      DIR => $bdir
	    });

	my (@lines) = <$pipe>;
	close($pipe);

	@lines=sort(@lines);
	foreach my $line (@lines) {
	    # $line contains a trailing newline, so don't add one.
	    $self->log($line);
	}
    }

    $self->log_subsubsection("dpkg-buildpackage");

    my $command = {
	COMMAND => $buildcmd,
	ENV => \%buildenv,
	ENV_FILTER => \@env_filter,
	USER => $self->get_conf('BUILD_USER'),
	SETSID => 1,
	PRIORITY => 0,
	DIR => $bdir
    };

    my $pipe = $self->get('Session')->pipe_command($command);

    $self->set('Sub Task', "dpkg-buildpackage");

    # We must send the signal as root, because some subprocesses of
    # dpkg-buildpackage could run as root. So we have to use a shell
    # command to send the signal... but /bin/kill can't send to
    # process groups :-( So start another Perl :-)
    my $timeout = $self->get_conf('INDIVIDUAL_STALLED_PKG_TIMEOUT')->{$pkg} ||
	$self->get_conf('STALLED_PKG_TIMEOUT');
    $timeout *= 60;
    my $timed_out = 0;
    my(@timeout_times, @timeout_sigs, $last_time);

    local $SIG{'ALRM'} = sub {
	my $pid = $command->{'PID'};
	my $signal = ($timed_out > 0) ? "KILL" : "TERM";
	$self->get('Session')->run_command(
	    { COMMAND => ['perl',
			  '-e',
			  "kill( \"$signal\", -$pid )"],
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

	$timeout_times[$timed_out] = time - $last_time;
	$timeout_sigs[$timed_out] = $signal;
	$timed_out++;
	$timeout = 5*60; # only wait 5 minutes until next signal
    };

    alarm($timeout);
    while(<$pipe>) {
	alarm($timeout);
	$last_time = time;
	if ($self->get('ABORT')) {
	    my $pid = $command->{'PID'};
	    $self->get('Session')->run_command(
		{ COMMAND => ['perl',
			      '-e',
			      "kill( \"TERM\", -$pid )"],
		  USER => 'root',
		  PRIORITY => 0,
		  DIR => '/' });
	}
	$self->log($_);
    }
    close($pipe);
    alarm(0);
    $rv = $?;

    my $i;
    for( $i = 0; $i < $timed_out; ++$i ) {
	$self->log("Build killed with signal " . $timeout_sigs[$i] .
	           " after " . int($timeout_times[$i]/60) .
	           " minutes of inactivity\n");
    }
    $self->set('Build End Time', time);
    $self->set('Pkg End Time', time);
    $self->write_stats('build-time',
		       $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->write_stats('install-download-time',
		       $self->get('Install End Time')-$self->get('Install Start Time'));
    my $finish_date = strftime("%Y%m%d-%H%M",localtime($self->get('Build End Time')));
    $self->log_sep();
    $self->log("Build finished at $finish_date\n");

    my @space_files = ("$dscdir");

    $self->log_subsubsection("Finished");
    if ($rv) {
	$self->log_error("Build failure (dpkg-buildpackage died)\n");
    } else {
	$self->log_info("Built successfully\n");

	if (-r "$dscdir/debian/files" && $self->get('Chroot Build Dir')) {
	    my @files = $self->debian_files_list("$dscdir/debian/files");

	    foreach (@files) {
		if (! -f "$build_dir/$_") {
		    $self->log_error("Package claims to have built ".basename($_).", but did not.  This is a bug in the packaging.\n");
		    next;
		}
		if (/_all.u?deb$/ and not $self->get_conf('BUILD_ARCH_ALL')) {
		    $self->log_error("Package builds ".basename($_)." when binary-indep target is not called.  This is a bug in the packaging.\n");
		    unlink("$build_dir/$_");
		    next;
		}
	    }
	}

	# Restore write access to build tree now build is complete.
	$self->get('Session')->run_command(
	    { COMMAND => ['chmod', '-R', 'g+w', $self->get('Build Dir')],
	      USER => 'root',
	      PRIORITY => 0});
	if ($?) {
	    $self->log("chmod g+w " . $self->get('Build Dir') . " failed.\n");
	    return 0;
	}

	$self->log_subsection("Changes");
	$changes = $self->get_changes();
	my @cfiles;
	if (-r "$build_dir/$changes") {
	    my(@do_dists, @saved_dists);
	    $self->log_subsubsection("$changes:");
	    open( F, "<$build_dir/$changes" );
	    my $sys_build_dir = $self->get_conf('BUILD_DIR');
	    if (open( F2, ">$sys_build_dir/$changes.new" )) {
		while( <F> ) {
		    if (/^Distribution:\s*(.*)\s*$/ and $self->get_conf('OVERRIDE_DISTRIBUTION')) {
			$self->log("Distribution: " . $self->get_conf('DISTRIBUTION') . "\n");
			print F2 "Distribution: " . $self->get_conf('DISTRIBUTION') . "\n";
		    }
		    else {
			print F2 $_;
			while (length $_ > 989)
			{
			    my $index = rindex($_,' ',989);
			    $self->log(substr ($_,0,$index) . "\n");
			    $_ = '        ' . substr ($_,$index+1);
			}
			$self->log($_);
			if (/^ [a-z0-9]{32}/) {
			    push(@cfiles, (split( /\s+/, $_ ))[5] );
			}
		    }
		}
		close( F2 );
		rename("$sys_build_dir/$changes.new", "$sys_build_dir/$changes")
		    or $self->log("$sys_build_dir/$changes.new could not be " .
		    "renamed to $sys_build_dir/$changes: $!\n");
		$self->set('Changes File', "$sys_build_dir/$changes");
		unlink("$build_dir/$changes")
		    if $build_dir;
	    }
	    else {
		$self->log("Cannot create $sys_build_dir/$changes.new: $!\n");
		$self->log("Distribution field may be wrong!!!\n");
		if ($build_dir) {
		    system "mv", "-f", "$build_dir/$changes", "."
			and $self->log_error("Could not move ".basename($_)." to .\n");
		}
	    }
	    close( F );
	}
	else {
	    $self->log("Can't find $changes -- can't dump info\n");
	}

	$self->log_subsection("Package contents");

	my @debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$build_dir/$_";
	    next if $deb !~ /(\Q$host_arch\E|all)\.[\w\d.-]*$/;

	    $self->log_subsubsection("$_");
	    if (!open( PIPE, "dpkg --info $deb 2>&1 |" )) {
		$self->log("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($_) while( <PIPE> );
		close( PIPE );
	    }
	    $self->log("\n");
	    if (!open( PIPE, "dpkg --contents $deb 2>&1 |" )) {
		$self->log("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($_) while( <PIPE> );
		close( PIPE );
	    }
	    $self->log("\n");
	}

	foreach (@cfiles) {
	    push( @space_files, $self->get_conf('BUILD_DIR') . "/$_");
	    system "mv", "-f", "$build_dir/$_", $self->get_conf('BUILD_DIR')
		and $self->log_error("Could not move $_ to .\n");
	}
    }

    $self->check_space(@space_files);

    return $rv == 0 ? 1 : 0;
}

# Produce a hash suitable for ENV export
sub get_env ($$) {
    my $self = shift;
    my $prefix = shift;

    sub _env_loop ($$$$) {
	my ($env,$ref,$keysref,$prefix) = @_;

	foreach my $key (keys( %{ $keysref } )) {
	    my $value = $ref->get($key);
	    next if (!defined($value));
	    next if (ref($value));
	    my $name = "${prefix}${key}";
	    $name =~ s/ /_/g;
	    $env->{$name} = $value;
        }
    }

    my $envlist = {};
    _env_loop($envlist, $self, $self, $prefix);
    _env_loop($envlist, $self->get('Config'), $self->get('Config')->{'KEYS'}, "${prefix}CONF_");
    return $envlist;
}

sub get_changes {
    my $self=shift;
    my $changes;

    if ( (grep {$_ eq "-A"} @{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')})
	 && -r $self->get('Chroot Build Dir') . '/' . $self->get('Package_SVersion') . $self->get('Package_SVersion') . "_all.changes") {
	$changes = $self->get('Package_SVersion') . "_all.changes";
    }
    else {
	$changes = $self->get('Package_SVersion') . '_' . $self->get('Host Arch') . '.changes';
    }
    return $changes;
}

sub read_build_essential {
    my $self = shift;
    my @essential;
    local (*F);

    if (open( F, "$self->{'Chroot Dir'}/usr/share/doc/build-essential/essential-packages-list" )) {
	while( <F> ) {
	    last if $_ eq "\n";
	}
	while( <F> ) {
	    chomp;
	    push( @essential, $_ ) if $_ !~ /^\s*$/;
	}
	close( F );
    }
    else {
	warn "Cannot open $self->{'Chroot Dir'}/usr/share/doc/build-essential/essential-packages-list: $!\n";
    }

    if (open( F, "$self->{'Chroot Dir'}/usr/share/doc/build-essential/list" )) {
	while( <F> ) {
	    last if $_ eq "BEGIN LIST OF PACKAGES\n";
	}
	while( <F> ) {
	    chomp;
	    last if $_ eq "END LIST OF PACKAGES";
	    next if /^\s/ || /^$/;
	    push( @essential, $_ );
	}
	close( F );
    }
    else {
	warn "Cannot open $self->{'Chroot Dir'}/usr/share/doc/build-essential/list: $!\n";
    }

    # Workaround http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=602571
    # Also works around Ubuntu Lucid shipping with "diff" instead of
    # "diffutils": https://bugs.launchpad.net/ubuntu/+source/sbuild/+bug/741897
    if (open( F, "$self->{'Chroot Dir'}/etc/lsb-release" )) {
        while( <F> ) {
            if ($_ eq "DISTRIB_ID=Ubuntu\n") {
                @essential = grep(!/^sysvinit$/, @essential);
            }
            if ($_ eq "DISTRIB_CODENAME=lucid\n") {
                s/^diff$/diffutils/ for (@essential);
            }
        }
        close( F );
    }

    return join( ", ", @essential );
}

sub check_space {
    my $self = shift;
    my @files = @_;
    my $sum = 0;

    foreach (@files) {
	my $pipe = $self->get('Host')->pipe_command(
	    { COMMAND => ['du', '-k', '-s', $_],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      DIR => '/'});

	if (!$pipe) {
	    $self->log("Cannot determine space needed (du failed): $!\n");
	    return;
	}
	while(<$pipe>) {
	    next if !/^(\d+)/;
	    $sum += $1;
	}
	close($pipe);
    }

    $self->set('This Time', $self->get('Pkg End Time') - $self->get('Pkg Start Time'));
    $self->get('This Time') = 0 if $self->get('This Time') < 0;
    $self->set('This Space', $sum);
}

sub lock_file {
    my $self = shift;
    my $file = shift;
    my $for_srcdep = shift;
    my $lockfile = "$file.lock";
    my $try = 0;

  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<$lockfile" );
	    my $line = <F>;
	    my ($pid, $user);
	    close( F );
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		$self->log_warning("Bad lock file contents ($lockfile) -- still trying\n");
	    }
	    else {
		($pid, $user) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    $self->log_warning("Removing stale lock file $lockfile ".
				       "(pid $pid, user $user)\n");
		    unlink( $lockfile );
		    goto repeat;
		}
	    }
	    ++$try;
	    if (!$for_srcdep && $try > $self->get_conf('MAX_LOCK_TRYS')) {
		$self->log_warning("Lockfile $lockfile still present after " .
				   $self->get_conf('MAX_LOCK_TRYS') *
				   $self->get_conf('LOCK_INTERVAL') .
				   " seconds -- giving up\n");
		return;
	    }
	    $self->log("Another sbuild process ($pid by $user) is currently installing or removing packages -- waiting...\n")
		if $for_srcdep && $try == 1;
	    sleep $self->get_conf('LOCK_INTERVAL');
	    goto repeat;
	}
	$self->log_warning("Can't create lock file $lockfile: $!\n");
    }

    my $username = $self->get_conf('USERNAME');
    F->print("$$ $username\n");
    F->close();
}

sub unlock_file {
    my $self = shift;
    my $file = shift;
    my $lockfile = "$file.lock";

    unlink( $lockfile );
}

sub add_stat {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    $self->get('Summary Stats')->{$key} = $value;
}

sub generate_stats {
    my $self = shift;

    $self->add_stat('Job', $self->get('Job'));
    $self->add_stat('Package', $self->get('Package'));
    $self->add_stat('Version', $self->get('Version'));
    $self->add_stat('Source-Version', $self->get('OVersion'));
    $self->add_stat('Machine Architecture', $self->get_conf('ARCH'));
    $self->add_stat('Host Architecture', $self->get('Host Arch'));
    $self->add_stat('Build Architecture', $self->get('Build Arch'));
    $self->add_stat('Distribution', $self->get_conf('DISTRIBUTION'));
    $self->add_stat('Space', $self->get('This Space'));
    $self->add_stat('Build-Time',
		    $self->get('Build End Time')-$self->get('Build Start Time'));
    $self->add_stat('Install-Time',
		    $self->get('Install End Time')-$self->get('Install Start Time'));
    $self->add_stat('Package-Time',
		    $self->get('Pkg End Time')-$self->get('Pkg Start Time'));
    $self->add_stat('Build-Space', $self->get('This Space'));
    $self->add_stat('Status', $self->get_status());
    $self->add_stat('Fail-Stage', $self->get('Pkg Fail Stage'))
	if ($self->get_status() ne "successful");
    $self->add_stat('Lintian', $self->get('Lintian Reason'))
	if $self->get('Lintian Reason');
    $self->add_stat('Piuparts', $self->get('Piuparts Reason'))
	if $self->get('Piuparts Reason');
}

sub log_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$self->log("${stat}: " . $self->get('Summary Stats')->{$stat} . "\n");
    }
}

sub print_stats {
    my $self = shift;
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	print STDOUT "${stat}: " . $self->get('Summary Stats')->{$stat} . "\n";
    }
}

sub write_stats {
    my $self = shift;

    return if (!$self->get_conf('BATCH_MODE'));

    my $stats_dir = $self->get_conf('STATS_DIR');

    return if not defined $stats_dir;

    if (! -d $stats_dir &&
	!mkdir $stats_dir) {
	$self->log_warning("Could not create $stats_dir: $!\n");
	return;
    }

    my ($cat, $val) = @_;
    local( *F );

    $self->lock_file($stats_dir, 0);
    open( F, ">>$stats_dir/$cat" );
    print F "$val\n";
    close( F );
    $self->unlock_file($stats_dir);
}

sub debian_files_list {
    my $self = shift;
    my $files = shift;

    my @list;

    debug("Parsing $files\n");

    if (-r $files && open( FILES, "<$files" )) {
	while (<FILES>) {
	    chomp;
	    my $f = (split( /\s+/, $_ ))[0];
	    push( @list, "$f" );
	    debug("  $f\n");
	}
	close( FILES ) or $self->log("Failed to close $files\n") && return 1;
    }

    return @list;
}

# Figure out chroot architecture
sub chroot_arch {
    my $self = shift;

    my $pipe = $self->get('Session')->pipe_command(
	{ COMMAND => ['dpkg', '--print-architecture'],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0,
	  DIR => '/' }) || return undef;

    chomp(my $chroot_arch = <$pipe>);
    close($pipe);

    Sbuild::Exception::Build->throw(error => "Can't determine architecture of chroot: $!",
				    failstage => "chroot-arch")
	if ($? || !defined($chroot_arch));

    return $chroot_arch;
}

sub build_log_filter {
    my $self = shift;
    my $text = shift;
    my $replacement = shift;

    if ($self->get_conf('LOG_FILTER')) {
	$self->log($self->get('FILTER_PREFIX') . $text . ':' . $replacement . "\n");
    }
}

sub build_log_colour {
    my $self = shift;
    my $regex = shift;
    my $colour = shift;

    if ($self->get_conf('LOG_COLOUR')) {
	$self->log($self->get('COLOUR_PREFIX') . $colour . ':' . $regex . "\n");
    }
}

sub open_build_log {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time')));

    my $filter_prefix = '__SBUILD_FILTER_' . $$ . ':';
    $self->set('FILTER_PREFIX', $filter_prefix);
    my $colour_prefix = '__SBUILD_COLOUR_' . $$ . ':';
    $self->set('COLOUR_PREFIX', $colour_prefix);

    my $filename = $self->get_conf('LOG_DIR') . '/' .
	$self->get('Package_SVersion') . '_' .
	$self->get('Host Arch') . "-$date";
    $filename .= ".build" if $self->get_conf('SBUILD_MODE') ne 'buildd';

    open($saved_stdout, ">&STDOUT") or warn "Can't redirect stdout\n";
    open($saved_stderr, ">&STDERR") or warn "Can't redirect stderr\n";

    my $PLOG;

    my $pid;
    ($pid = open($PLOG, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to '$filename': $!\n";
    } elsif ($pid == 0) {
	$SIG{'INT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';

	$PROGRAM_NAME = 'package log for ' . $self->get('Package_SVersion') . '_' . $self->get('Host Arch');

	if (!$self->get_conf('NOLOG') &&
	    $self->get_conf('LOG_DIR_AVAILABLE')) {
	    unlink $filename; # To prevent opening symlink to elsewhere
	    open( CPLOG, ">$filename" ) or
		Sbuild::Exception::Build->throw(error => "Failed to open build log $filename: $!",
						failstage => "init");
	    CPLOG->autoflush(1);
	    $saved_stdout->autoflush(1);

	    # Create 'current' symlinks
	    if ($self->get_conf('SBUILD_MODE') eq 'buildd') {
		$self->log_symlink($filename,
				   $self->get_conf('BUILD_DIR') . '/current-' .
				   $self->get_conf('DISTRIBUTION'));
	    } else {
		$self->log_symlink($filename,
				   $self->get_conf('BUILD_DIR') . '/' .
				   $self->get('Package_SVersion') . '_' .
				   $self->get('Host Arch') . ".build");
	    }
	}

	# Cache vars to avoid repeated hash lookups.
	my $nolog = $self->get_conf('NOLOG');
	my $log = $self->get_conf('LOG_DIR_AVAILABLE');
	my $verbose = $self->get_conf('VERBOSE');
	my $log_colour = $self->get_conf('LOG_COLOUR');
	my @filter = ();
	my @colour = ();
	my ($text, $replacement);
	my $filter_regex = "^$filter_prefix(.*):(.*)\$";
	my $colour_regex = "^$colour_prefix(.*):(.*)\$";
	my @ignore = ();

	while (<STDIN>) {
	    # Add a replacement pattern to filter (sent from main
	    # process in log stream).
	    if (m/$filter_regex/) {
		($text,$replacement)=($1,$2);
		$replacement = "«$replacement»";
		push (@filter, [$text, $replacement]);
		$_ = "I: NOTICE: Log filtering will replace '$text' with '$replacement'\n";
	    } elsif (m/$colour_regex/) {
		my ($colour, $regex);
		($colour,$regex)=($1,$2);
		push (@colour, [$colour, $regex]);
#		$_ = "I: NOTICE: Log colouring will colour '$regex' in $colour\n";
		next;
	    } else {
		# Filter out any matching patterns
		foreach my $pattern (@filter) {
		    ($text,$replacement) = @{$pattern};
		    s/$text/$replacement/g;
		}
	    }
	    if (m/Deprecated key/ || m/please update your configuration/) {
		my $skip = 0;
		foreach my $ignore (@ignore) {
		    $skip = 1 if ($ignore eq $_);
		}
		next if $skip;
		push(@ignore, $_);
	    }

	    if ($nolog || $verbose) {
		if (-t $saved_stdout && $log_colour) {
		    my $colour = 'reset';
		    foreach my $pattern (@colour) {
			if (m/$$pattern[0]/) {
			    $colour = $$pattern[1];
			}
		    }
		    print $saved_stdout color $colour;
		}

		print $saved_stdout $_;
		if (-t $saved_stdout && $log_colour) {
		    print $saved_stdout color 'reset';
		}

		# Manual flushing due to Perl 5.10 bug.  Should autoflush.
		$saved_stdout->flush();
	    }
	    if (!$nolog && $log) {
		    print CPLOG $_;
	    }
	}

	close CPLOG;
	exit 0;
    }

    $PLOG->autoflush(1);
    open(STDOUT, '>&', $PLOG) or warn "Can't redirect stdout\n";
    open(STDERR, '>&', $PLOG) or warn "Can't redirect stderr\n";
    $self->set('Log File', $filename);
    $self->set('Log Stream', $PLOG);

    my $hostname = $self->get_conf('HOSTNAME');
    $self->log("sbuild (Debian sbuild) $version ($release_date) on $hostname\n");

    my $arch_string = $self->get('Build Arch');
    $arch_string = 'CROSS host=' . $self->get('Host Arch') .
	'/build=' . $self->get('Build Arch')
	if ($self->get('Host Arch') ne $self->get('Build Arch'));
    my $head1 = $self->get('Package') . ' ' . $self->get('Version') .
	' (' . $arch_string . ') ';
    my $head2 = strftime("%d %b %Y %H:%M",
			 localtime($self->get('Pkg Start Time')));
    my $head = $head1 . ' ' x (80 - 4 - length($head1) - length($head2)) .
	$head2;
    $self->log_section($head);

    $self->log("Package: " . $self->get('Package') . "\n");
    $self->log("Version: " . $self->get('Version') . "\n");
    $self->log("Source Version: " . $self->get('OVersion') . "\n");
    $self->log("Distribution: " . $self->get_conf('DISTRIBUTION') . "\n");
    $self->log("Machine Architecture: " . $self->get_conf('ARCH') . "\n");
    $self->log("Host Architecture: " . $self->get('Host Arch') . "\n");
    $self->log("Build Architecture: " . $self->get('Build Arch') . "\n");
    $self->log("\n");
}

sub close_build_log {
    my $self = shift;

    my $time = $self->get('Pkg End Time');
    if ($time == 0) {
        $time = time;
    }
    my $date = strftime("%Y%m%d-%H%M", localtime($time));

    my $hours = int($self->get('This Time')/3600);
    my $minutes = int(($self->get('This Time')%3600)/60),
    my $seconds = int($self->get('This Time')%60),
    my $space = $self->get('This Space');

    my $filename = $self->get('Log File');

    # building status at this point means failure.
    if ($self->get_status() eq "building") {
	$self->set_status('failed');
    }

    $self->log_subsection('Summary');
    $self->generate_stats();
    $self->log_stats();

    $self->log_sep();
    $self->log("Finished at ${date}\n");
    $self->log(sprintf("Build needed %02d:%02d:%02d, %dk disc space\n",
	       $hours, $minutes, $seconds, $space));

    if ($self->get_status() eq "successful") {
	if (defined($self->get_conf('KEY_ID')) && $self->get_conf('KEY_ID')) {
	    my $key_id = $self->get_conf('KEY_ID');
	    my $changes;
	    $self->log(sprintf("Signature with key '%s' requested:\n", $key_id));
	    $changes = $self->get_changes();
	    system "debsign", "-k$key_id", $changes;
	}
    }

    my $subject = "Log for " . $self->get_status() .
	" build of " . $self->get('Package_Version');
    if ($self->get('Host Arch')) {
	$subject .= " on " . $self->get('Host Arch');
    }
    if ($self->get_conf('ARCHIVE')) {
	$subject .= " (" . $self->get_conf('ARCHIVE') . "/" . $self->get_conf('DISTRIBUTION') . ")";
    }
    else {
	    $subject .= " (dist=" . $self->get_conf('DISTRIBUTION') . ")";
    }

    open(STDERR, '>&', $saved_stderr) or warn "Can't redirect stderr\n"
	if defined($saved_stderr);
    open(STDOUT, '>&', $saved_stdout) or warn "Can't redirect stdout\n"
	if defined($saved_stdout);
    $saved_stderr->close();
    undef $saved_stderr;
    $saved_stdout->close();
    undef $saved_stdout;
    $self->set('Log File', undef);
    if (defined($self->get('Log Stream'))) {
	$self->get('Log Stream')->close(); # Close child logger process
	$self->set('Log Stream', undef);
    }

    $self->send_build_log($self->get_conf('MAILTO'), $subject, $filename)
	if (defined($filename) && -f $filename &&
	    $self->get_conf('MAILTO'));
}

sub send_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');

    if ($conf->get('MIME_BUILD_LOG_MAILS')) {
	return $self->send_mime_build_log($to, $subject, $filename);
    } else {
        return send_mail($conf, $to, $subject, $filename);
    }
}

sub send_mime_build_log {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $filename = shift;

    my $conf = $self->get('Config');
    my $tmp; # Needed for gzip, here for proper scoping.

    my $msg = MIME::Lite->new(
	    From    => $conf->get('MAILFROM'),
	    To      => $to,
	    Subject => $subject,
	    Type    => 'multipart/mixed'
	    );

    # Add the GPG key ID to the mail if present so that it's clear if the log
    # still needs signing or not.
    if (defined($self->get_conf('KEY_ID')) && $self->get_conf('KEY_ID')) {
	$msg->add('Key-ID', $self->get_conf('KEY_ID'));
    }

    if (!$conf->get('COMPRESS_BUILD_LOG_MAILS')) {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => $filename,
		Filename => basename($filename)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    } else {
	local( *F, *GZFILE );

	if (!open( F, "<$filename" )) {
	    warn "Cannot open $filename for mailing: $!\n";
	    return 0;
	}

	$tmp = File::Temp->new();
	tie *GZFILE, 'IO::Zlib', $tmp->filename, 'wb';

	while( <F> ) {
	    print GZFILE $_;
	}
	untie *GZFILE;

	close F;
	close GZFILE;

	$msg->attach(
		Type     => 'application/x-gzip',
		Path     => $tmp->filename,
		Filename => basename($filename) . '.gz'
		);
    }
    my $changes = $self->get_changes();
    if ($self->get_status() eq 'successful' && -r $changes) {
	my $log_part = MIME::Lite->new(
		Type     => 'text/plain',
		Path     => $changes,
		Filename => basename($changes)
		);
	$log_part->attr('content-type.charset' => 'UTF-8');
	$msg->attach($log_part);
    }

    my $stats = '';
    foreach my $stat (sort keys %{$self->get('Summary Stats')}) {
	$stats .= sprintf("%s: %s\n", $stat, $self->get('Summary Stats')->{$stat});
    }
    $msg->attach(
	Type => 'text/plain',
	Filename => basename($filename) . '.summary',
	Data => $stats
	);

    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|" . $conf->get('MAILPROG') . " -oem $to" )) {
	warn "Could not open pipe to " . $conf->get('MAILPROG') . ": $!\n";
	close( F );
	return 0;
    }

    $msg->print(\*MAIL);

    if (!close( MAIL )) {
	warn $conf->get('MAILPROG') . " failed (exit status $?)\n";
	return 0;
    }
    return 1;
}

sub log_symlink {
    my $self = shift;
    my $log = shift;
    my $dest = shift;

    unlink $dest; # Don't return on failure, since the symlink will fail.
    symlink $log, $dest;
}

1;
