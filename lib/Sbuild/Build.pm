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

use POSIX;
use Errno qw(:POSIX);
use Fcntl;
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir);
use FileHandle;
use GDBM_File;
use File::Copy qw(); # copy is already exported from Sbuild, so don't export
		     # anything.
use Cwd qw(:DEFAULT abs_path);
use Dpkg::Arch;
use Dpkg::Control;

use Sbuild qw($devnull binNMU_version version_compare split_version copy isin send_build_log debug df);
use Sbuild::Base;
use Sbuild::ChrootSetup qw(clean update upgrade distupgrade);
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoSudo;
use Sbuild::ChrootRoot;
use Sbuild::Sysconfig qw($version $release_date);
use Sbuild::Conf;
use Sbuild::LogBase qw($saved_stdout);
use Sbuild::Sysconfig;
use Sbuild::Utility qw(check_url download parse_file dsc_files);
use Sbuild::AptitudeResolver;
use Sbuild::InternalResolver;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $dsc = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Arch', undef);
    $self->set('Chroot Dir', '');
    $self->set('Chroot Build Dir', '');
    $self->set('Max Lock Trys', 120);
    $self->set('Lock Interval', 5);
    $self->set('Srcdep Lock Count', 0);
    $self->set('Pkg Status', 'pending');
    $self->set('Pkg Status Trigger', undef);
    $self->set('Pkg Start Time', 0);
    $self->set('Pkg End Time', 0);
    $self->set('Pkg Fail Stage', 0);
    $self->set('Build Start Time', 0);
    $self->set('Build End Time', 0);
    $self->set('This Time', 0);
    $self->set('This Space', 0);
    $self->set('This Watches', {});
    $self->set('Sub Task', 'initialisation');
    $self->set('Host', Sbuild::ChrootRoot->new($self->get('Config')));
    # Host execution defaults
    my $host_defaults = $self->get('Host')->get('Defaults');
    $host_defaults->{'CHROOT'} = 0;
    $host_defaults->{'USER'} = $self->get_conf('USERNAME');
    $host_defaults->{'DIR'} = $self->get_conf('HOME');
    $host_defaults->{'STREAMIN'} = $devnull;
    $host_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
    $host_defaults->{'ENV'}->{'SHELL'} = $Sbuild::Sysconfig::programs{'SHELL'};

    $self->set('Session', undef);
    $self->set('Dependency Resolver', undef);
    $self->set('Log File', undef);
    $self->set('Log Stream', undef);

    # DSC, package and version information:
    $self->set_dsc($dsc);
    my $ver = $self->get('DSC Base');
    $ver =~ s/\.dsc$//;
    # Note, will be overwritten by Version: in DSC.
    $self->set_version($ver);

    # Do we need to download?
    $self->set('Download', 0);
    $self->set('Download', 1)
	if (!($self->get('DSC Base') =~ m/\.dsc$/) || # Use apt to download
	    check_url($self->get('DSC'))); # Valid URL

    # Can sources be obtained?
    $self->set('Invalid Source', 0);
    $self->set('Invalid Source', 1)
	if ((!$self->get('Download') ||
      (!($self->get('DSC Base') =~ m/\.dsc$/) &&
        $self->get('DSC') ne $self->get('Package_OVersion')) ||
      !defined $self->get('Version')) &&
      !defined $self->get('Debian Source Dir'));

    debug("Download = " . $self->get('Download') . "\n");
    debug("Invalid Source = " . $self->get('Invalid Source') . "\n");

    return $self;
}

sub set_dsc {
    my $self = shift;
    my $dsc = shift;

    debug("Setting DSC: $dsc\n");

    # Check if the DSC given is a directory on the local system. This
    # means we'll build the source package with dpkg-source first.
    if (-d $dsc) {
	my $host = $self->get('Host');
	my $pipe = $host->pipe_command(
	    { COMMAND => [$Sbuild::Sysconfig::programs{'DPKG_PARSECHANGELOG'},
			  "-l" . abs_path($dsc) . "/debian/changelog"],
	      CHROOT => 0,
	      PRIORITY => 0,
	    });

	if (!defined($pipe)) {
	    $self->log_error("Could not parse $dsc/debian/changelog: $!");
	    $self->set('Invalid Source', 1);
	    goto set_vars;
	}

	my $stanzas = parse_file($pipe);

	my $stanza = @{$stanzas}[0];
	my $package = ${$stanza}{'Source'};
	my $version = ${$stanza}{'Version'};

	if (!defined($package) || !defined($version)) {
	    $self->log_error("Missing Source or Version in $dsc/debian/changelog");
	    $self->set('Invalid Source', 1);
	    goto set_vars;
	}

	my $dir = getcwd();
	# Note: need to support cases when invoked from a subdirectory
	# of the build directory, i.e. $dsc/foo -> $dsc/.. in addition
	# to $dsc -> $dsc/.. as below.
	if ($dir eq abs_path($dsc)) {
	    # We won't attempt to build the source package from the source
	    # directory so the source package files will go to the parent dir.
	    $dir = abs_path("$dir/..");
	    $self->set_conf('BUILD_DIR', $dir);
	}
	$self->set('Debian Source Dir', abs_path($dsc));

	$self->set_version("${package}_${version}");
	$dsc = "$dir/" . $self->get('Package_OSVersion') . ".dsc";
    }

set_vars:
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

    my ($pkg, $version) = split /_/, $pkgv;
    return if (!defined($pkg) || !defined($version));

    # Original version (no binNMU or other addition)
    my $oversion = $version;
    # Original version with stripped epoch
    (my $osversion = $version) =~ s/^\d+://;

    # Add binNMU to version if needed.
    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	$version = binNMU_version($version, $self->get_conf('BIN_NMU_VERSION'),
	    $self->get_conf('APPEND_TO_VERSION'));
    }

    # Version with binNMU or other additions and stripped epoch
    (my $sversion = $version) =~ s/^\d+://;

    my ($epoch, $uversion, $dversion) = split_version($version);

    $self->set('Package', $pkg);
    $self->set('Version', $version);
    $self->set('Package_Version', "${pkg}_$version");
    $self->set('Package_OVersion', "${pkg}_$oversion");
    $self->set('Package_OSVersion', "${pkg}_$osversion");
    $self->set('Package_SVersion', "${pkg}_$sversion");
    $self->set('OVersion', $oversion);
    $self->set('OSVersion', $osversion);
    $self->set('SVersion', $sversion);
    $self->set('VersionEpoch', $epoch);
    $self->set('VersionUpstream', $uversion);
    $self->set('VersionDebian', $dversion);
    $self->set('DSC File', "${pkg}_${osversion}.dsc");
    $self->set('DSC Dir', "${pkg}-${uversion}");

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

sub run {
    my $self = shift;

    $self->set_status('building');

    if ($self->get_conf('BUILD_DEP_RESOLVER') eq "aptitude") {
	$self->set('Dependency Resolver',
		   Sbuild::AptitudeResolver->new($self));
    } else {
	$self->set('Dependency Resolver',
		   Sbuild::InternalResolver->new($self));
    }
    my $resolver = $self->get('Dependency Resolver');


    $self->set('Pkg Start Time', time);

    # Acquire the architecture we're building for.
    $self->set('Arch', $self->get_conf('ARCH'));

    my $dist = $self->get_conf('DISTRIBUTION');
    if (!defined($dist) || !$dist) {
	$self->log("No distribution defined\n");
	goto cleanup_skip;
    }

    if ($self->get('Invalid Source')) {
	$self->log("Invalid source: " . $self->get('DSC') . "\n");
	$self->log("Skipping " . $self->get('Package') . " \n");
	$self->set_status('failed');
	goto cleanup_skip;
    }

    my $chroot_info;
    if ($self->get_conf('CHROOT_MODE') eq 'schroot') {
	$chroot_info = Sbuild::ChrootInfoSchroot->new($self->get('Config'));
    } else {
	$chroot_info = Sbuild::ChrootInfoSudo->new($self->get('Config'));
    }

    # Build the source package if given a Debianized source directory
    if ($self->get('Debian Source Dir')) {
	$self->set('Pkg Fail Stage', 'pack-source');
	$self->log_subsection("Build Source Package");

	$self->log_subsubsection('clean');
	$self->get('Host')->run_command(
	    { COMMAND => [$self->get_conf('FAKEROOT'),
			  'debian/rules',
			  'clean'],
	      CHROOT => 0,
	      DIR => $self->get('Debian Source Dir'),
	      PRIORITY => 0,
	    });
	if ($?) {
	    $self->log_error("Failed to clean source directory");

	    goto cleanup_skip;
	}

	$self->log_subsubsection('dpkg-source');
	my @dpkg_source_command = ($self->get_conf('DPKG_SOURCE'), '-b');
	push @dpkg_source_command, @{$self->get_conf('DPKG_SOURCE_OPTIONS')} if
	    ($self->get_conf('DPKG_SOURCE_OPTIONS'));
	push @dpkg_source_command, $self->get('Debian Source Dir');
	$self->get('Host')->run_command(
	    { COMMAND => \@dpkg_source_command,
	      CHROOT => 0,
	      DIR => $self->get_conf('BUILD_DIR'),
	      PRIORITY => 0,
	    });
	if ($?) {
	    $self->log_error("Failed to build source package");
	    goto cleanup_skip;
	}
    }

    my $end_session = 1;
    my $session = $chroot_info->create($self->get_conf('DISTRIBUTION'),
				       $self->get_conf('CHROOT'),
				       $self->get_conf('ARCH'));

    # TODO: Get package name from build object
    if (!$self->open_build_log()) {
	goto cleanup_close;
    }

    # Set a chroot to run commands in host
    my $host = $self->get('Host');

    # Host execution defaults (set streams)
    my $host_defaults = $host->get('Defaults');
    $host_defaults->{'STREAMIN'} = $devnull;
    $host_defaults->{'STREAMOUT'} = $self->get('Log Stream');
    $host_defaults->{'STREAMERR'} = $self->get('Log Stream');

    # Run pre build external commands
    $self->run_external_commands("pre-build-commands",
				 $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				 $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

    if (!$session->begin_session()) {
	$self->log("Error creating chroot session: skipping " .
		   $self->get('Package') . "\n");
	$self->set_status('failed');
	goto cleanup_close;
    }

    $self->set('Session', $session);
    $self->set('Arch', $self->chroot_arch());

    $self->set('Chroot Dir', $session->get('Location'));
    $self->set('Chroot Build Dir',
	       tempdir($self->get_conf('USERNAME') . '-' .
		       $self->get('Package_SVersion') . '-' .
		       $self->get('Arch') . '-XXXXXX',
		       DIR => $session->get('Build Location')));
    # TODO: Don't hack the build location in; add a means to customise
    # the chroot directly.
    $session->set('Build Location', $self->get('Chroot Build Dir'));

    # Needed so chroot commands log to build log
    $session->set('Log Stream', $self->get('Log Stream'));

    # Chroot execution defaults
    my $chroot_defaults = $session->get('Defaults');
    $chroot_defaults->{'DIR'} =
	$session->strip_chroot_path($session->get('Build Location'));
    $chroot_defaults->{'STREAMIN'} = $devnull;
    $chroot_defaults->{'STREAMOUT'} = $self->get('Log Stream');
    $chroot_defaults->{'STREAMERR'} = $self->get('Log Stream');
    $chroot_defaults->{'ENV'}->{'LC_ALL'} = 'POSIX';
    $chroot_defaults->{'ENV'}->{'SHELL'} = $Sbuild::Sysconfig::programs{'SHELL'};

    $self->set('Session', $session);

    # Lock chroot so it won't be tampered with during the build.
    if (!$session->lock_chroot($self->get('Package_SVersion'), $$, $self->get_conf('USERNAME'))) {
	goto cleanup_close;
    }

    # Clean APT cache.
    $self->set('Pkg Fail Stage', 'apt-get-clean');
    if ($self->get_conf('APT_CLEAN')) {
	if (clean($session, $self->get('Config'))) {
	    # Since apt-clean was requested specifically, fail on
	    # error when not in buildd mode.
	    $self->log("apt-get clean failed\n");
	    if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		$self->set_status('failed');
		goto cleanup_close;
	    }
	}
    }

    # Update APT cache.
    $self->set('Pkg Fail Stage', 'apt-get-update');
    if ($self->get_conf('APT_UPDATE')) {
	if (update($session, $self->get('Config'))) {
	    # Since apt-update was requested specifically, fail on
	    # error when not in buildd mode.
	    $self->log("apt-get update failed\n");
	    $self->set_status('failed');
	    goto cleanup_close;
	}
    }

    # Upgrade using APT.
    if ($self->get_conf('APT_DISTUPGRADE')) {
	$self->set('Pkg Fail Stage', 'apt-get-distupgrade');
	if ($self->get_conf('APT_DISTUPGRADE')) {
	    if (distupgrade($session, $self->get('Config'))) {
		# Since apt-distupgrade was requested specifically, fail on
		# error when not in buildd mode.
		$self->log("apt-get dist-upgrade failed\n");
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    $self->set_status('failed');
		    goto cleanup_close;
		}
	    }
	}
    } elsif ($self->get_conf('APT_UPGRADE')) {
	$self->set('Pkg Fail Stage', 'apt-get-upgrade');
	if ($self->get_conf('APT_UPGRADE')) {
	    if (upgrade($session, $self->get('Config'))) {
		# Since apt-upgrade was requested specifically, fail on
		# error when not in buildd mode.
		$self->log("apt-get upgrade failed\n");
		if ($self->get_conf('SBUILD_MODE') ne 'buildd') {
		    $self->set_status('failed');
		    goto cleanup_close;
		}
	    }
	}
    }

    $self->set('Pkg Fail Stage', 'fetch-src');
    if (!$self->fetch_source_files()) {
	goto cleanup_packages;
    }

    # Display message about chroot setup script option use being deprecated
    if ($self->get_conf('CHROOT_SETUP_SCRIPT')) {
	my $msg = "setup-hook option is deprecated. It has been superceded by ";
	$msg .= "the chroot-setup-commands feature. setup-hook script will be ";
	$msg .= "run via chroot-setup-commands.\n";
	$self->log_warning($msg);
    }

    # Run specified chroot setup commands
    $self->run_external_commands("chroot-setup-commands",
				 $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				 $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

    $resolver->add_dependencies('CORE', join(", ", @{$self->get_conf('CORE_DEPENDS')}) , "", "", "");
    if (!$resolver->install_deps('core', 'CORE')) {
	$self->log("Core source dependencies not satisfied; skipping");
	goto cleanup_packages;
    }

    $resolver->add_dependencies('ESSENTIAL', $self->read_build_essential(), "", "", "");

    my $snapshot = "";
    $snapshot = "gcc-snapshot" if ($self->get_conf('GCC_SNAPSHOT'));
    $resolver->add_dependencies('GCC_SNAPSHOT', $snapshot , "", "", "");

    # Add additional build dependencies specified on the command-line.
    # TODO: Split dependencies into an array from the start to save
    # lots of joining.
    $resolver->add_dependencies('MANUAL',
				join(", ", @{$self->get_conf('MANUAL_DEPENDS')}),
				join(", ", @{$self->get_conf('MANUAL_DEPENDS_INDEP')}),
				join(", ", @{$self->get_conf('MANUAL_CONFLICTS')}),
				join(", ", @{$self->get_conf('MANUAL_CONFLICTS_INDEP')}));

    $resolver->add_dependencies($self->get('Package'),
				$self->get('Build Depends'),
				$self->get('Build Depends Indep'),
				$self->get('Build Conflicts'),
				$self->get('Build Conflicts Indep'));

    $self->set('Pkg Fail Stage', 'install-deps');
    if (!$resolver->install_deps($self->get('Package'),
				 'ESSENTIAL', 'GCC_SNAPSHOT', 'MANUAL',
				 $self->get('Package'))) {
	$self->log("Source-dependencies not satisfied; skipping " .
		   $self->get('Package') . "\n");
	goto cleanup_packages;
    }

    $resolver->dump_build_environment();

    if ($self->build()) {
	$self->set_status('successful');
    } else {
	$self->set_status('failed');
    }

    # Run specified chroot cleanup commands
    $self->run_external_commands("chroot-cleanup-commands",
				 $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				 $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

    if ($self->get('Pkg Status') eq "successful") {
	$self->log_subsection("Post Build");

	# Run lintian.
	my $lintian = $self->get_conf('LINTIAN');
	if (($self->get_conf('RUN_LINTIAN')) && (-x $lintian)) {
	    $self->log_subsubsection("lintian");

	    my @lintian_command = ($lintian);
	    push @lintian_command, @{$self->get_conf('LINTIAN_OPTIONS')} if
		($self->get_conf('LINTIAN_OPTIONS'));
	    push @lintian_command, $self->get('Changes File');
	    $self->get('Host')->run_command(
		{ COMMAND => \@lintian_command,
		  CHROOT => 0,
		  PRIORITY => 0,
		});
	    my $status = $? >> 8;

	    $self->log("\n");
	    if (! $?) {
		$self->log_info("Lintian run was successful.\n");
	    } else {
		my $why = "unknown reason";
		$why = "runtime error" if ($status == 2);
		$why = "policy violation" if ($status == 1);
		$why = "received signal " . $? & 127 if ($? & 127);
		$self->log_error("Lintian run failed ($why)\n");
	    }
	}

	# Run post build external commands
	$self->run_external_commands("post-build-commands",
				     $self->get_conf('LOG_EXTERNAL_COMMAND_OUTPUT'),
				     $self->get_conf('LOG_EXTERNAL_COMMAND_ERROR'));

    }

  cleanup_packages:
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

    # Purge non-cloned session
    if ($is_cloned_session) {
	$self->log("Not cleaning session: cloned chroot in use\n");
	$end_session = 0
	    if ($purge_build_directory == 0 || $purge_build_deps == 0);
    } else {
	if ($purge_build_directory) {
	    # Purge package build directory
	    $self->log("Purging " . $self->get('Chroot Build Dir') . "\n");
	    my $bdir = $self->get('Session')->strip_chroot_path($self->get('Chroot Build Dir'));
	    $self->get('Session')->run_command(
		{ COMMAND => ['rm', '-rf', $bdir],
		  USER => 'root',
		  CHROOT => 1,
		  PRIORITY => 0,
		  DIR => '/' });
	}

	if ($purge_build_deps) {
	    # Removing dependencies
	    $resolver->uninstall_deps();
	} else {
	    $self->log("Not removing build depends: as requested\n");
	}
    }

  cleanup_close:
    # Unlock chroot now it's cleaned up and ready for other users.
    $session->unlock_chroot();

    # End chroot session
    if ($end_session == 1) {
	$session->end_session();
    } else {
	$self->log("Keeping session: " . $session->get('Session ID') . "\n");
    }
    $session = undef;
    $self->set('Session', $session);

    $self->close_build_log();

  cleanup_skip:
}

sub fetch_source_files {
    my $self = shift;

    my $dir = $self->get('Source Dir');
    my $dsc = $self->get('DSC File');
    my $build_dir = $self->get('Chroot Build Dir');
    my $pkg = $self->get('Package');
    my $ver = $self->get('OVersion');
    my $arch = $self->get('Arch');

    my ($dscarchs, $dscpkg, $dscver, @fetched);

    my $build_depends = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->log_subsection("Fetch source files");

    if (!defined($self->get('Package')) ||
	!defined($self->get('OVersion')) ||
	!defined($self->get('Source Dir'))) {
	$self->log("Invalid source: $self->get('DSC')\n");
	return 0;
    }

    if ($self->get('DSC Base') =~ m/\.dsc$/) {
	# Work with a .dsc file.
	# $file is the name of the downloaded dsc file written in a tempfile.
	my $file;
	$file = download($self->get('DSC')) or
	    $self->log_error("Could not download " . $self->get('DSC')) and
	    return 0;
	debug("Parsing $dsc\n");
	my @cwd_files = dsc_files($file);
	if (-f "$dir/$dsc") {
	    # Copy the local source files into the build directory.
	    $self->log_subsubsection("Local sources");
	    $self->log("$dsc exists in $dir; copying to chroot\n");
	    if (! File::Copy::copy("$dir/$dsc", "$build_dir")) {
		$self->log_error("Could not copy $dir/$dsc to $build_dir\n");
		return 0;
	    }
	    push(@fetched, "$build_dir/$dsc");
	    foreach (@cwd_files) {
		if (! File::Copy::copy("$dir/$_", "$build_dir")) {
		    $self->log_error("Could not copy $dir/$_ to $build_dir\n");
		    return 0;
		}
		push(@fetched, "$build_dir/$_");
	    }
	} else {
	    # Copy the remote source files into the build directory.
	    $self->log_subsubsection("Remote sources");
	    $self->log("Downloading source files from $dir.\n");
	    if (! File::Copy::copy("$file", "$build_dir/" . $self->get('DSC File'))) {
		$self->log_error("Could not copy downloaded file $file to $build_dir\n");
		return 0;
	    }
	    push(@fetched, "$build_dir/" . $self->get('DSC File'));
	    foreach (@cwd_files) {
		download("$dir/$_", "$build_dir/$_") or
		    $self->log_error("Could not download $dir/$_") and
		    return 0;
		push(@fetched, "$build_dir/$_");
	    }
	}
    } else {
	# Use apt to download the source files
	$self->log_subsubsection("Check APT");
	my %entries = ();
	my $retried = $self->get_conf('APT_UPDATE'); # Already updated if set
      retry:
	$self->log("Checking available source versions...\n");

	my $pipe = $self->get('Session')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'),
			  '-q', 'showsrc', "$pkg"],
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      DIR => '/'});
	if (!$pipe) {
	    $self->log("Can't open pipe to $conf::apt_cache: $!\n");
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
		update($self->get('Session'), $self->get('Config'));
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

	my $pipe2 = $self->get('Session')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), '--only-source', '-q', '-d', 'source', "$pkg=$ver"],
	      USER => $self->get_conf('USERNAME'),
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
    $build_depends_indep = $pdsc->{'Build-Depends-Indep'};
    $build_conflicts = $pdsc->{'Build-Conflicts'};
    $build_conflicts_indep = $pdsc->{'Build-Conflicts-Indep'};
    $dscarchs = $pdsc->{'Architecture'};
    $dscpkg = $pdsc->{'Source'};
    $dscver = $pdsc->{'Version'};

    $self->set_version("${dscpkg}_${dscver}");

    $build_depends =~ s/\n\s+/ /g if defined $build_depends;
    $build_depends_indep =~ s/\n\s+/ /g if defined $build_depends_indep;
    $build_conflicts =~ s/\n\s+/ /g if defined $build_conflicts;
    $build_conflicts_indep =~ s/\n\s+/ /g if defined $build_conflicts_indep;

    $self->log_subsubsection("Check arch");
    if (!$dscarchs) {
	$self->log("$dsc has no Architecture: field -- skipping arch check!\n");
    } else {
	my $valid_arch;
	for my $a (split(/\s+/, $dscarchs)) {
	    if (Dpkg::Arch::debarch_is($arch, $a)) {
		$valid_arch = 1;
		last;
	    }
	}
	if ($dscarchs ne "any" && !($valid_arch) &&
	    !($dscarchs eq "all" && $self->get_conf('BUILD_ARCH_ALL')) )  {
	    my $msg = "$dsc: $arch not in arch list or does not match any arch ";
	    $msg .= "wildcards: $dscarchs -- skipping\n";
	    $self->log($msg);
	    $self->set('Pkg Fail Stage', "arch-check");
	    return 0;
	}
    }

    debug("Arch check ok ($arch included in $dscarchs)\n");

    $self->set('Build Depends', $build_depends);
    $self->set('Build Depends Indep', $build_depends_indep);
    $self->set('Build Conflicts', $build_conflicts);
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
		    CHROOT => 0,
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
		    USER => $self->get_conf('USERNAME'),
		    CHROOT => 1,
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

sub build {
    my $self = shift;

    my $dscfile = $self->get('DSC File');
    my $dscdir = $self->get('DSC Dir');
    my $pkg = $self->get('Package');
    my $build_dir = $self->get('Chroot Build Dir');
    my $arch = $self->get('Arch');

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
	$self->set('Pkg Fail Stage', "unpack");
	# dpkg-source refuses to remove the remanants of an aborted
	# dpkg-source extraction, so we will if necessary.
	if (-d $tmpunpackdir) {
	    system ("rm -fr '$tmpunpackdir'");
	}
	$self->set('Sub Task', "dpkg-source");
	$self->get('Session')->run_command(
		    { COMMAND => [$self->get_conf('DPKG_SOURCE'),
				  '-x', $dscfile, $dscdir],
		      USER => $self->get_conf('USERNAME'),
		      CHROOT => 1,
		      PRIORITY => 0});
	if ($?) {
	    $self->log("FAILED [dpkg-source died]\n");

	    system ("rm -fr '$tmpunpackdir'") if -d $tmpunpackdir;
	    return 0;
	}
	$dscdir = "$build_dir/$dscdir";

	if (system( "chmod -R g-s,go+rX $dscdir" ) != 0) {
	    $self->log("chmod -R g-s,go+rX $dscdir failed.\n");
	    return 0;
	}
    }
    else {
	$dscdir = "$build_dir/$dscdir";

	$self->log_subsubsection("Check unpacked source");
	$self->set('Pkg Fail Stage', "check-unpacked-version");
	# check if the unpacked tree is really the version we need
	$dscdir = $self->get('Session')->strip_chroot_path($dscdir);
	my $pipe = $self->get('Session')->pipe_command(
	    { COMMAND => [$Sbuild::Sysconfig::programs{'DPKG_PARSECHANGELOG'}],
	      USER => $self->get_conf('USERNAME'),
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
	    return 0;
	}
	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    $self->log("dpkg-parsechangelog didn't print Version:\n");
	    return 0;
	}
    }

    $self->log_subsubsection("Check disc space");
    $self->set('Pkg Fail Stage', "check-space");
    my $du = $Sbuild::Sysconfig::programs{'DU'};
    my $current_usage = `"$du" -k -s "$dscdir"`;
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $free = df($dscdir);
	if ($free < 2*$current_usage && $self->get_conf('CHECK_SPACE')) {
	    $self->log("Disc space is propably not enough for building.\n".
		       "(Source needs $current_usage KB, free are $free KB.)\n");
	    # TODO: Only purge in a single place.
	    $self->log("Purging $build_dir\n");
	    $self->get('Session')->run_command(
		{ COMMAND => [$Sbuild::Sysconfig::programs{'RM'},
			      '-rf', $build_dir],
		  USER => 'root',
		  CHROOT => 1,
		  PRIORITY => 0,
		  DIR => '/' });
	    return 0;
	}
    }

    if ($self->get_conf('BIN_NMU') || $self->get_conf('APPEND_TO_VERSION')) {
	$self->log_subsubsection("Hack binNMU version");
	$self->set('Pkg Fail Stage', "hack-binNMU");
	if (open( F, "<$dscdir/debian/changelog" )) {
	    my($firstline, $text);
	    $firstline = "";
	    $firstline = <F> while $firstline =~ /^$/;
	    { local($/); undef $/; $text = <F>; }
	    close( F );
	    $firstline =~ /^(\S+)\s+\((\S+)\)\s+([^;]+)\s*;\s*urgency=(\S+)\s*$/;
	    my ($name, $version, $dists, $urgent) = ($1, $2, $3, $4);
	    my $NMUversion = $self->get('Version');
	    chomp( my $date = `date -R` );
	    if (!open( F, ">$dscdir/debian/changelog" )) {
		$self->log("Can't open debian/changelog for binNMU hack: $!\n");
		return 0;
	    }
	    $dists = $self->get_conf('DISTRIBUTION');

	    print F "$name ($NMUversion) $dists; urgency=low\n\n";
	    if ($self->get_conf('APPEND_TO_VERSION')) {
		print F "  * Append ", $self->get_conf('APPEND_TO_VERSION'),
		    " to version number; no source changes\n";
	    }
	    if ($self->get_conf('BIN_NMU')) {
		print F "  * Binary-only non-maintainer upload for $arch; ",
		    "no source changes.\n";
		print F "  * ", join( "    ", split( "\n", $self->get_conf('BIN_NMU') )), "\n";
	    }
	    print F "\n";

	    print F " -- " . $self->get_conf('MAINTAINER_NAME') . "  $date\n\n";
	    print F $firstline, $text;
	    close( F );
	    $self->log("*** Created changelog entry for bin-NMU version $NMUversion\n");
	}
	else {
	    $self->log("Can't open debian/changelog -- no binNMU hack!\n");
	}
    }

    if (-f "$dscdir/debian/files") {
	local( *FILES );
	my @lines;
	open( FILES, "<$dscdir/debian/files" );
	chomp( @lines = <FILES> );
	close( FILES );
	@lines = map { my $ind = 76-length($_);
		       $ind = 0 if $ind < 0;
		       "│ $_".(" " x $ind). " │\n"; } @lines;

	$self->log_warning("After unpacking, there exists a file debian/files with the contents:\n");

	$self->log('┌', '─'x78, '┐', "\n");
	foreach (@lines) {
	    $self->log($_);
	}
	$self->log('└', '─'x78, '┘', "\n");

	$self->log_info("This should be reported as a bug.\n");
	$self->log_info("The file has been removed to avoid dpkg-genchanges errors.\n");

	unlink "$dscdir/debian/files";
    }

    $self->log_subsubsection("dpkg-buildpackage");
    $self->set('Build Start Time', time);
    $self->set('Pkg Fail Stage', "build");

    my $binopt = $self->get_conf('BUILD_SOURCE') ?
	$self->get_conf('FORCE_ORIG_SOURCE') ? "-sa" : "" :
	$self->get_conf('BUILD_ARCH_ALL') ?	"-b" : "-B";

    my $bdir = $self->get('Session')->strip_chroot_path($dscdir);
    if (-f "$self->{'Chroot Dir'}/etc/ld.so.conf" &&
	! -r "$self->{'Chroot Dir'}/etc/ld.so.conf") {
	$self->get('Session')->run_command(
	    { COMMAND => [$Sbuild::Sysconfig::programs{'CHMOD'},
			  'a+r', '/etc/ld.so.conf'],
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

	$self->log("ld.so.conf was not readable! Fixed.\n");
    }

    my $buildcmd = [];
    push (@{$buildcmd}, $self->get_conf('BUILD_ENV_CMND'))
	if (defined($self->get_conf('BUILD_ENV_CMND')) &&
	    $self->get_conf('BUILD_ENV_CMND'));
    push (@{$buildcmd}, 'dpkg-buildpackage');

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
	if (ref($self->get_conf('SIGNING_OPTIONS') eq 'ARRAY')) {
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

    my $buildenv = {};
    $buildenv->{'PATH'} = $self->get_conf('PATH');
    $buildenv->{'LD_LIBRARY_PATH'} = $self->get_conf('LD_LIBRARY_PATH')
	if defined($self->get_conf('LD_LIBRARY_PATH'));

    my $command = {
	COMMAND => $buildcmd,
	ENV => $buildenv,
	USER => $self->get_conf('USERNAME'),
	SETSID => 1,
	CHROOT => 1,
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
	      CHROOT => 1,
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
    my $date = strftime("%Y%m%d-%H%M",localtime($self->get('Build End Time')));
    $self->log_sep();
    $self->log("Build finished at $date\n");

    my @space_files = ("$dscdir");
    if ($rv) {
	$self->log("FAILED [dpkg-buildpackage died]\n");
    } else {
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

	$changes = $self->get('Package_SVersion') . "_$arch.changes";
	my @cfiles;
	if (-r "$build_dir/$changes") {
	    my(@do_dists, @saved_dists);
	    $self->log("\n$changes:\n");
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
	    next if $deb !~ /(\Q$arch\E|all)\.[\w\d.-]*$/;

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
	$self->log_subsection("Finished");
	$self->log("Built successfully\n");
    }

    $self->check_watches();
    $self->check_space(@space_files);

    $self->log_sep();
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

    return join( ", ", @essential );
}

sub check_space {
    my $self = shift;
    my @files = @_;
    my $sum = 0;

    foreach (@files) {
	my $pipe = $self->get('Session')->pipe_command(
	    { COMMAND => [$Sbuild::Sysconfig::programs{'DU'}, '-k', '-s', $_],
	      USER => $self->get_conf('USERNAME'),
	      CHROOT => 0,
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

sub prepare_watches {
    my $self = shift;
    my $dependencies = shift;
    my @instd = @_;
    my(@dep_on, $dep, $pkg, $prg);

    @dep_on = @instd;
    foreach $dep (@$dependencies) {
	if ($dep->{'Neg'} && $dep->{'Package'} =~ /^needs-no-(\S+)/) {
	    push( @dep_on, $1 );
	}
	elsif ($dep->{'Package'} !~ /^\*/ && !$dep->{'Neg'}) {
	    foreach (scalar($dep), @{$dep->{'Alternatives'}}) {
		push( @dep_on, $_->{'Package'} );
	    }
	}
    }
    # init %this_watches to names of packages which have not been
    # installed as source dependencies
    $self->set('This Watches', {});
    foreach $pkg (keys %{$self->get_conf('WATCHES')}) {
	if (isin( $pkg, @dep_on )) {
	    debug("Excluding from watch: $pkg\n");
	    next;
	}
	foreach $prg (@{$self->get_conf('WATCHES')->{$pkg}}) {
	    # Add /usr/bin to programs without a path
	    $prg = "/usr/bin/$prg" if $prg !~ m,^/,;
	    $self->get('This Watches')->{"$self->{'Chroot Dir'}$prg"} = $pkg;
	    debug("Will watch for $prg ($pkg)\n");
	}
    }
}

sub check_watches {
    my $self = shift;
    my($prg, @st, %used);

    return if (!$self->get_conf('CHECK_WATCHES'));

    foreach $prg (keys %{$self->get('This Watches')}) {
	if (!(@st = stat( $prg ))) {
	    debug("Watch: $prg: stat failed\n");
	    next;
	}
	if ($st[8] > $self->get('Build Start Time')) {
	    my $pkg = $self->get('This Watches')->{$prg};
	    my $prg2 = $self->get('Session')->strip_chroot_path($prg);
	    push( @{$used{$pkg}}, $prg2 );
	}
	else {
	    debug("Watch: $prg: untouched\n");
	}
    }
    return if !%used;

    $self->log_warning("NOTE: Binaries from the following packages (access time changed) used\nwithout a source dependency:");

    foreach (keys %used) {
	$self->log("  $_: @{$used{$_}}\n");
    }
    $self->log("\n");
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
	{ COMMAND => [$self->get_conf('DPKG'),
		      '--print-architecture'],
	  USER => $self->get_conf('USERNAME'),
	  CHROOT => 1,
	  PRIORITY => 0,
	  DIR => '/' }) || return undef;

    chomp(my $chroot_arch = <$pipe>);
    close($pipe);

    die "Can't determine architecture of chroot: $!\n"
	if ($? || !defined($chroot_arch));

    return $chroot_arch;
}

sub open_build_log {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time')));

    my $filename = $self->get_conf('LOG_DIR') . '/' .
	$self->get('Package_SVersion') . '-' .
	$self->get('Arch') .
	"-$date";

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

	if (!$self->get_conf('NOLOG') &&
	    $self->get_conf('LOG_DIR_AVAILABLE')) {
	    open( CPLOG, ">$filename" ) or
		die "Can't open logfile $filename: $!\n";
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
				   $self->get('Arch') . '.build');
	    }
	}

	# Cache vars to avoid repeated hash lookups.
	my $nolog = $self->get_conf('NOLOG');
	my $log = $self->get_conf('LOG_DIR_AVAILABLE');
	my $verbose = $self->get_conf('VERBOSE');

	while (<STDIN>) {
	    if ($nolog) {
		print $saved_stdout $_;
		# Manual flushing due to Perl 5.10 bug.  Should autoflush.
		$saved_stdout->flush();
	    } else {
		if ($log) {
		    print CPLOG $_;
		}
		if ($verbose) {
		    print $saved_stdout $_;
		    # Manual flushing due to Perl 5.10 bug.  Should autoflush.
		    $saved_stdout->flush();
		}
	    }
	}

	close CPLOG;
	exit 0;
    }

    $PLOG->autoflush(1);
    $self->set('Log File', $filename);
    $self->set('Log Stream', $PLOG);

    my $hostname = $self->get_conf('HOSTNAME');
    $self->log("sbuild (Debian sbuild) $version ($release_date) on $hostname\n");

    my $head1 = $self->get('Package') . ' ' . $self->get('Version') .
	' (' . $self->get('Arch') . ') ';
    my $head2 = strftime("%d %b %Y %H:%M",
			 localtime($self->get('Pkg Start Time')));
    my $head = $head1 . ' ' x (80 - 4 - length($head1) - length($head2)) .
	$head2;
    $self->log_section($head);

    $self->log("Package: " . $self->get('Package') . "\n");
    $self->log("Version: " . $self->get('Version') . "\n");
    $self->log("Source Version: " . $self->get('OVersion') . "\n");
    $self->log("Architecture: " . $self->get('Arch') . "\n");
    $self->log("Chroot Build Dir: " . $self->get('Chroot Build Dir') . "\n");
    $self->log("Start Time: " . strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time'))) . "\n");
}

sub close_build_log {
    my $self = shift;

    my $time = $self->get('Pkg End Time');
    if ($time == 0) {
        $time = time;
    }
    my $date = strftime("%Y%m%d-%H%M", localtime($time));

    if ($self->get_status() eq "successful") {
	$self->add_time_entry($self->get('Package_Version'), $self->get('This Time'));
	$self->add_space_entry($self->get('Package_Version'), $self->get('This Space'));
    }

    $self->log_sep();
    $self->log("End Time: " . strftime("%Y%m%d-%H%M", localtime($self->get('Pkg End Time'))) . "\n");
    $self->log("Finished at ${date}\n");

    my $hours = int($self->get('This Time')/3600);
    my $minutes = int(($self->get('This Time')%3600)/60),
    my $seconds = int($self->get('This Time')%60),
    my $space = $self->get('This Space');

    $self->log(sprintf("Build needed %02d:%02d:%02d, %dk disc space\n",
	       $hours, $minutes, $seconds, $space));

    my $filename = $self->get('Log File');

    # Only report success or failure
    if ($self->get_status() ne "successful") {
	$self->set_status('failed');
    }

    my $subject = "Log for " . $self->get_status() .
	" build of " . $self->get('Package_Version');
    if ($self->get('Arch')) {
	$subject .= " on " . $self->get('Arch');
    }
    if ($self->get_conf('ARCHIVE')) {
	$subject .= " (" . $self->get_conf('ARCHIVE') . "/" . $self->get_conf('DISTRIBUTION') . ")";
    }
    else {
	    $subject .= " (dist=" . $self->get_conf('DISTRIBUTION') . ")";
    }
    send_build_log($self->get('Config'), $self->get_conf('MAILTO'), $subject, $filename)
	if (defined($filename) && -f $filename &&
	    $self->get_conf('MAILTO'));

    $self->set('Log File', undef);
    if (defined($self->get('Log Stream'))) {
	$self->get('Log Stream')->close(); # Close child logger process
	$self->set('Log Stream', undef);
    }
}

sub log_symlink {
    my $self = shift;
    my $log = shift;
    my $dest = shift;

    unlink $dest; # Don't return on failure, since the symlink will fail.
    symlink $log, $dest;
}

sub add_time_entry {
    my $self = shift;
    my $pkg = shift;
    my $t = shift;

    return if !$self->get_conf('AVG_TIME_DB');
    my %db;
    if (!tie %db, 'GDBM_File', $self->get_conf('AVG_TIME_DB'), GDBM_WRCREAT, 0664) {
	$self->log("Can't open average time db " . $self->get_conf('AVG_TIME_DB') . "\n");
	return;
    }
    $pkg =~ s/_.*//;

    if (exists $db{$pkg}) {
	my @times = split( /\s+/, $db{$pkg} );
	push( @times, $t );
	my $sum = 0;
	foreach (@times[1..$#times]) { $sum += $_; }
	$times[0] = $sum / (@times-1);
	$db{$pkg} = join( ' ', @times );
    }
    else {
	$db{$pkg} = "$t $t";
    }
    untie %db;
}

sub add_space_entry {
    my $self = shift;
    my $pkg = shift;
    my $space = shift;

    my $keepvals = 4;

    return if !$self->get_conf('AVG_SPACE_DB') || $space == 0;
    my %db;
    if (!tie %db, 'GDBM_File', $self->get_conf('AVG_SPACE_DB'), &GDBM_WRCREAT, 0664) {
	$self->log("Can't open average space db " . $self->get_conf('AVG_SPACE_DB') . "\n");
	return;
    }
    $pkg =~ s/_.*//;

    if (exists $db{$pkg}) {
	my @values = split( /\s+/, $db{$pkg} );
	shift @values;
	unshift( @values, $space );
	pop @values if @values > $keepvals;
	my ($sum, $n, $weight, $i) = (0, 0, scalar(@values));
	for( $i = 0; $i < @values; ++$i) {
	    $sum += $values[$i] * $weight;
	    $n += $weight;
	}
	unshift( @values, $sum/$n );
	$db{$pkg} = join( ' ', @values );
    }
    else {
	$db{$pkg} = "$space $space";
    }
    untie %db;
}

sub log_section {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log('╔', '═' x 78, '╗', "\n");
    $self->log('║', " $section ", ' ' x (80 - length($section) - 4), '║', "\n");
    $self->log('╚', '═' x 78, '╝', "\n\n");
}

sub log_subsection {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log('┌', '─' x 78, '┐', "\n");
    $self->log('│', " $section ", ' ' x (80 - length($section) - 4), '│', "\n");
    $self->log('└', '─' x 78, '┘', "\n\n");
}

sub log_subsubsection {
    my $self = shift;
    my $section = shift;

    $self->log("\n");
    $self->log("$section\n");
    $self->log('─' x (length($section)), "\n\n");
}

sub log_sep {
    my $self = shift;

    $self->log('─' x 80, "\n");
}

1;
