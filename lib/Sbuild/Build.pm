#
# Build.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

use Errno qw(:POSIX);
use Fcntl;
use File::Basename qw(basename dirname);
use GDBM_File;
use IPC::Open3;
use Sbuild qw(binNMU_version version_compare copy isin send_mail debug);
use Sbuild::Base;
use Sbuild::Chroot qw();
use Sbuild::Sysconfig qw($version);
use Sbuild::Conf;
use Sbuild::Sysconfig;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new ($$$);
sub set_dsc (\$$);
sub fetch_source_files (\$);
sub build (\$$$);
sub analyze_fail_stage (\$);
sub install_deps (\$);
sub wait_for_srcdep_conflicts (\$@);
sub uninstall_deps (\$);
sub uninstall_debs (\$$@);
sub run_apt (\$$\@\@@);
sub filter_dependencies (\$\@\@\@);
sub check_dependencies (\$\@);
sub get_apt_policy (\$@);
sub get_dpkg_status (\$@);
sub merge_pkg_build_deps (\$$$$$$);
sub cmp_dep_lists (\$\@\@);
sub get_altlist (\$$);
sub is_superset (\$\%\%);
sub read_build_essential (\$);
sub expand_dependencies (\$\@);
sub expand_virtuals (\$\@);
sub get_dependencies (\$@);
sub get_virtuals (\$@);
sub parse_one_srcdep (\$$$);
sub parse_manual_srcdeps (\$@);
sub check_space (\$@);
sub file_for_name (\$$@);
sub write_jobs_file (\$$);
sub append_to_FINISHED (\$);
sub write_srcdep_lock_file (\$\@);
sub check_srcdep_conflicts (\$\@\@);
sub remove_srcdep_lock_file (\$);
sub prepare_watches (\$\@@);
sub check_watches (\$);
sub should_skip (\$);
sub add_givenback (\$$$);
sub set_installed (\$@);
sub set_removed (\$@);
sub unset_installed (\$@);
sub unset_removed (\$@);
sub df (\$$);
sub fixup_pkgv (\$$);
sub format_deps (\$@);
sub lock_file (\$$$);
sub unlock_file (\$$);
sub write_stats (\$$$);
sub debian_files_list (\$$);
sub dsc_files (\$$);
sub chroot_arch (\$);
sub open_build_log (\$);
sub close_build_log (\$$$$$$$);
sub add_time_entry (\$$$);
sub add_space_entry (\$$$);


# TODO: put in all package version data and job ID (for indexing in job list)
sub new ($$$) {
    my $class = shift;
    my $dsc = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    # DSC, package and version information:
    $self->set_dsc($dsc);

    # Do we need to download?
    $self->set('Download', 0);
    $self->set('Download', 1)
	if (!($self->get('DSC Base') =~ m/\.dsc$/));

    # Can sources be obtained?
    $self->set('Invalid Source', 0);
    $self->set('Invalid Source', 1)
	if ((!$self->get('Download') && ! -f $self->get('DSC')) ||
	    ($self->get('Download') &&
	     $self->get('DSC') ne $self->get('Package_Version')) ||
	    (!defined $self->get('Version')));

    debug("DSC = " . $self->get('DSC') . "\n");
    debug("Source Dir = " . $self->get('Source Dir') . "\n");
    debug("DSC Base = " . $self->get('DSC Base') . "\n");
    debug("DSC File = " . $self->get('DSC Base') . "\n");
    debug("DSC Dir = " . $self->get('DSC Base') . "\n");
    debug("Package_Version = " . $self->get('Package_Version') . "\n");
    debug("Package_SVersion = " . $self->get('Package_SVersion') . "\n");
    debug("Package = " . $self->get('Package') . "\n");
    debug("Version = " . $self->get('Version') . "\n");
    debug("SVersion = " . $self->get('SVersion') . "\n");
    debug("Download = " . $self->get('Download') . "\n");
    debug("Invalid Source = " . $self->get('Invalid Source') . "\n");

    $self->set('Arch', $self->get_conf('ARCH'));
    $self->set('Chroot Dir', '');
    $self->set('Chroot Build Dir', '');
    $self->set('Jobs File', 'build-progress');
    $self->set('Max Lock Trys', 120);
    $self->set('Lock Interval', 5);
    $self->set('Srcdep Lock Count', 0);
    $self->set('Pkg Status', '');
    $self->set('Pkg Start Time', 0);
    $self->set('Pkg End Time', 0);
    $self->set('Pkg Fail Stage', 0);
    $self->set('Build Start Time', 0);
    $self->set('Build End Time', 0);
    $self->set('This Time', 0);
    $self->set('This Space', 0);
    $self->set('This Watches', {});
    $self->set('Toolchain Packages', []);
    $self->set('Sub Task', 'initialisation');
    $self->set('Sub PID', undef);
    $self->set('Session', undef);
    $self->set('Additional Deps', []);
    $self->set('binNMU Name', undef);
    $self->set('Changes', {});
    $self->set('Dependencies', {});
    $self->set('Have DSC Build Deps', []);

    return $self;
}

sub set_dsc (\$$) {
    my $self = shift;
    my $dsc = shift;

    debug("Setting DSC: $dsc\n");

    $self->set('DSC', $dsc);
    $self->set('Source Dir', dirname($dsc));

    $self->set('DSC Base', basename($dsc));

    my $pkgv = $self->get('DSC Base');
    $pkgv =~ s/\.dsc$//;
    $self->set('Package_Version', $pkgv);
    my ($pkg, $version) = split /_/, $self->get('Package_Version');
    (my $sversion = $version) =~ s/^\d+://; # Strip epoch
    $self->set('Package_SVersion', "${pkg}_$sversion");

    $self->set('Package', $pkg);
    $self->set('Version', $version);
    $self->set('SVersion', $sversion);
    $self->set('DSC File', "${pkg}_${sversion}.dsc");
    $self->set('DSC Dir', "${pkg}-${sversion}");
}

# sub get_package_status (\$) {
#     my $self = shift;

#     return $self->get('Package Status');
# }
# sub set_package_status (\$$) {
#     my $self = shift;
#     my $status = shift;

#     return $self->set('Package Status', $status);
# }

sub fetch_source_files (\$) {
    my $self = shift;

    my $dir = $self->get('Source Dir');
    my $dsc = $self->get('DSC File');
    my $build_dir = $self->get('Chroot Build Dir');
    my $pkg = $self->get('Package');
    my $ver = $self->get('Version');
    my $arch = $self->get('Arch');

    my ($files, @other_files, $dscarchs, @fetched);

    my $build_depends = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->set('Have DSC Build Deps', []);

    $self->log_subsection("Fetch source files");

    if (!defined($self->get('Package')) ||
	!defined($self->get('Version')) ||
	!defined($self->get('Source Dir'))) {
	$self->log("Invalid source: $self->get('DSC')\n");
	return 0;
    }

    if (-f "$dir/$dsc" && !$self->get('Download')) {
	$self->log_subsubsection("Local sources");
	$self->log("$dsc exists in $dir; copying to chroot\n");
	my @cwd_files = $self->dsc_files("$dir/$dsc");
	foreach (@cwd_files) {
	    if (system ("cp '$_' '$build_dir'")) {
		$self->log_error("Could not copy $_ to $build_dir\n");
		return 0;
	    }
	    push(@fetched, "$build_dir/" . basename($_));
	}
    } else {
	$self->log_subsubsection("Check APT");
	my %entries = ();
	my $retried = $self->get_conf('APT_UPDATE'); # Already updated if set
      retry:
	$self->log("Checking available source versions...\n");
	my $command = $self->get('Session')->get_apt_command($self->get_conf('APT_CACHE'),
							  "-q showsrc $pkg",
							  $self->get_conf('USERNAME'), 0, '/');
	my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
	if (!$pid) {
	    $self->log('Can\'t open pipe to ' . $self->get_conf('APT_CACHE') . ": $!\n");
	    return 0;
	}
	{
	    local($/) = "";
	    my $package;
	    my $ver;
	    my $tfile;
	    while( <PIPE> ) {
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
	close(PIPE);
	waitpid $pid, 0;
	if ($?) {
	    $self->log($self->get_conf('APT_CACHE') . " failed\n");
	    return 0;
	}

	if (!defined($entries{"$pkg $ver"})) {
	    if (!$retried) {
		$self->log_subsubsection("Update APT");
		# try to update apt's cache if nothing found
		$self->get('Session')->run_apt_command($self->get_conf('APT_GET'),
						    "update >/dev/null", "root", 0, '/');
		$retried = 1;
		goto retry;
	    }
	    $self->log("Can't find source for " .
		       $self->get('Package_Version') . "\n");
	    $self->log("(only different version(s) ",
	    join( ", ", sort keys %entries), " found)\n")
		if %entries;
	    return 0;
	}

	$self->log_subsubsection("Download source files with APT");

	foreach (@{$entries{"$pkg $ver"}}) {
	    push(@fetched, "$build_dir/$_");
	}

	my $command2 = $self->get('Session')->get_apt_command($self->get_conf('APT_GET'),
							      "--only-source -q -d source $pkg=$ver 2>&1 </dev/null",
							      $self->get_conf('USERNAME'), 0, undef);
	if (!open( PIPE, "$command2 |" )) {
	    $self->log('Can\'t open pipe to ' . $self->get_conf('APT_GET') . ": $!\n");
	    return 0;
	}
	while( <PIPE> ) {
	    $self->log($_);
	}
	close( PIPE );
	if ($?) {
	    $self->log($self->get_conf('APT_GET') . " for sources failed\n");
	    return 0;
	}
	$self->set_dsc((grep { /\.dsc$/ } @fetched)[0]);
    }

    if (!open( F, "<$build_dir/$dsc" )) {
	$self->log("Can't open $build_dir/$dsc: $!\n");
	return 0;
    }
    my $dsctext;
    my $orig;
    { local($/); $dsctext = <F>; }
    close( F );

    $dsctext =~ /^Build-Depends:\s*((.|\n\s+)*)\s*$/mi
	and $build_depends = $1;
    $dsctext =~ /^Build-Depends-Indep:\s*((.|\n\s+)*)\s*$/mi
	and $build_depends_indep = $1;
    $dsctext =~ /^Build-Conflicts:\s*((.|\n\s+)*)\s*$/mi
	and $build_conflicts = $1;
    $dsctext =~ /^Build-Conflicts-Indep:\s*((.|\n\s+)*)\s*$/mi
	and $build_conflicts_indep = $1;
    $build_depends =~ s/\n\s+/ /g if defined $build_depends;
    $build_depends_indep =~ s/\n\s+/ /g if defined $build_depends_indep;
    $build_conflicts =~ s/\n\s+/ /g if defined $build_conflicts;
    $build_conflicts_indep =~ s/\n\s+/ /g if defined $build_conflicts_indep;

    $dsctext =~ /^Architecture:\s*(.*)$/mi and $dscarchs = $1;

    $dsctext =~ /^Files:\s*\n((\s+.*\s*\n)+)/mi and $files = $1;
    @other_files = map { (split( /\s+/, $_ ))[3] } split( "\n", $files );
    $files =~ /(\Q$pkg\E.*orig.tar.gz)/mi and $orig = $1;

    $self->log_subsubsection("Check arch");
    if (!$dscarchs) {
	$self->log("$dsc has no Architecture: field -- skipping arch check!\n");
    }
    else {
	if ($dscarchs ne "any" && $dscarchs !~ /\b$arch\b/ &&
	    !($dscarchs eq "all" && $self->get_conf('BUILD_ARCH_ALL')) )  {
	    $self->log("$dsc: $arch not in arch list: $dscarchs -- skipping\n");
	    $self->set('Pkg Fail Stage', "arch-check");
	    return 0;
	}
    }

    debug("Arch check ok ($arch included in $dscarchs)\n");

    @{$self->get('Have DSC Build Deps')} =
	($build_depends, $build_depends_indep,
	 $build_conflicts,$build_conflicts_indep);
    $self->merge_pkg_build_deps($self->get('Package'),
				$build_depends, $build_depends_indep,
				$build_conflicts, $build_conflicts_indep);

    return 1;
}

sub build (\$$$) {
    my $self = shift;

    my $dscfile = $self->get('DSC File');
    my $dscdir = $self->get('DSC Dir');
    my $pkgv = $self->get('Package_Version');
    my $build_dir = $self->get('Chroot Build Dir');
    my $arch = $self->get('Arch');

    my( $rv, $changes );
    local( *PIPE, *F, *F2 );

    $pkgv = $self->fixup_pkgv($pkgv);
    $self->log_subsection("Build");
    $self->set('This Space', 0);
    $pkgv =~ /^([a-zA-Z\d.+-]+)_([a-zA-Z\d:.+~-]+)/;
    # Note, this version contains ".dsc".
    my ($pkg, $version) = ($1,$2);

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
	$self->get('Session')->run_command($self->get_conf('DPKG_SOURCE') . " -sn -x $dscfile $dscdir 2>&1", $self->get_conf('USERNAME'), 1, 0, undef);
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
	$self->set('Sub PID', open( PIPE, "-|" ));
	if (!defined $self->get('Sub PID')) {
	    $self->log("Can't spawn dpkg-parsechangelog: $!\n");
	    return 0;
	}
	if ($self->get('Sub PID') == 0) {
	    $dscdir = $self->get('Session')->strip_chroot_path($dscdir);
	    $self->get('Session')->exec_command("cd '$dscdir' && dpkg-parsechangelog 2>&1", $self->get_conf('USERNAME'), 1, 0, undef);
	}
	$self->set('Sub Task', "dpkg-parsechangelog");

	my $clog = "";
	while( <PIPE> ) {
	    $clog .= $_;
	}
	close( PIPE );
	$self->set('Sub PID', undef);
	if ($?) {
	    $self->log("FAILED [dpkg-parsechangelog died]\n");
	    return 0;
	}
	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    $self->log("dpkg-parsechangelog didn't print Version:\n");
	    return 0;
	}
	my $tree_version = $1;
	my $cmp_version = ($self->get_conf('BIN_NMU') && -f "$dscdir/debian/.sbuild-binNMU-done") ?
	    binNMU_version($version,$self->get_conf('BIN_NMU_VERSION')) : $version;
	if ($tree_version ne $cmp_version) {
	    $$self->log("The unpacked source tree $dscdir is version ".
			"$tree_version, not wanted $cmp_version!\n");
	    return 0;
	}
    }

    $self->log_subsubsection("Check disc space");
    $self->set('Pkg Fail Stage', "check-space");
    my $current_usage = `/usr/bin/du -k -s "$dscdir"`;
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $free = $self->df($dscdir);
	if ($free < 2*$current_usage) {
	    $self->log("Disc space is propably not enough for building.\n".
		       "(Source needs $current_usage KB, free are $free KB.)\n");
	    # TODO: Only purge in a single place.
	    $self->log("Purging $build_dir\n");
	    $self->get('Session')->run_command("rm -rf '$build_dir'", "root", 1, 0, '/');
	    return 0;
	}
    }

    $self->log_subsubsection("Hack binNMU version");
    $self->set('Pkg Fail Stage', "hack-binNMU");
    if ($self->get_conf('BIN_NMU') && ! -f "$dscdir/debian/.sbuild-binNMU-done") {
	if (open( F, "<$dscdir/debian/changelog" )) {
	    my($firstline, $text);
	    $firstline = "";
	    $firstline = <F> while $firstline =~ /^$/;
	    { local($/); undef $/; $text = <F>; }
	    close( F );
	    $firstline =~ /^(\S+)\s+\((\S+)\)\s+([^;]+)\s*;\s*urgency=(\S+)\s*$/;
	    my ($name, $version, $dists, $urgent) = ($1, $2, $3, $4);
	    my $NMUversion = binNMU_version($version,$self->get_conf('BIN_NMU_VERSION'));
	    chomp( my $date = `date -R` );
	    if (!open( F, ">$dscdir/debian/changelog" )) {
		$self->log("Can't open debian/changelog for binNMU hack: $!\n");
		return 0;
	    }
	    $dists = $self->get_conf('DISTRIBUTION');
	    print F "$name ($NMUversion) $dists; urgency=low\n\n";
	    print F "  * Binary-only non-maintainer upload for $arch; ",
	    "no source changes.\n";
	    print F "  * ", join( "    ", split( "\n", $self->get_conf('BIN_NMU') )), "\n\n";
	    print F " -- " . $self->get_conf('MAINTAINER_NAME') . "  $date\n\n";

	    print F $firstline, $text;
	    close( F );
	    system "touch '$dscdir/debian/.sbuild-binNMU-done'";
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
    $self->set('Sub PID', open( PIPE, "-|" ));
    if (!defined $self->get('Sub PID')) {
	$self->log("Can't spawn dpkg-buildpackage: $!\n");
	return 0;
    }
    if ($self->get('Sub PID') == 0) {
	open( STDIN, "</dev/null" );
	my $binopt = $self->get_conf('BUILD_SOURCE') ?
	    $self->get_conf('FORCE_ORIG_SOURCE') ? "-sa" : "" :
	    $self->get_conf('BUILD_ARCH_ALL') ?	"-b" : "-B";

	my $bdir = $self->get('Session')->strip_chroot_path($dscdir);
	if (-f "$self->{'Chroot Dir'}/etc/ld.so.conf" &&
	    ! -r "$self->{'Chroot Dir'}/etc/ld.so.conf") {
	    $self->get('Session')->run_command("chmod a+r /etc/ld.so.conf", "root", 1, 0, '/');
	    $self->log("ld.so.conf was not readable! Fixed.\n");
	}
	my $buildcmd = "cd $bdir && PATH=" . $self->get_conf('PATH') . " " .
	    (defined($self->get_conf('LD_LIBRARY_PATH')) ?
	     "LD_LIBRARY_PATH=".$self->get_conf('LD_LIBRARY_PATH')." " : "").
	     "exec " . $self->get_conf('BUILD_ENV_CMND') . " dpkg-buildpackage " .
	     $self->get_conf('PGP_OPTIONS') .
	     " $binopt " . $self->get_conf('SIGNING_OPTIONS') .
	     ' -r' . $self->get_conf('FAKEROOT') . ' 2>&1';
	$self->get('Session')->exec_command($buildcmd, $self->get_conf('USERNAME'), 1, 0, undef);
    }
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
	my $signal = ($timed_out > 0) ? "KILL" : "TERM";
	$self->get('Session')->run_command("perl -e \"kill( \\\"$signal\\\", $self->{'Sub PID'} )\"", "root", 1, 0, '/');
	$timeout_times[$timed_out] = time - $last_time;
	$timeout_sigs[$timed_out] = $signal;
	$timed_out++;
	$timeout = 5*60; # only wait 5 minutes until next signal
    };

    alarm( $timeout );
    while( <PIPE> ) {
	alarm( $timeout );
	$last_time = time;
	$self->log($_);
    }
    close( PIPE );
    $self->set('Sub PID', undef);
    alarm( 0 );
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
    }
    else {
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

	$changes = "${pkg}_".
	    ($self->get_conf('BIN_NMU') ?
	     binNMU_version($self->get('SVersion'),
			    $self->get_conf('BIN_NMU_VERSION')) :
	     $self->get('SVersion')).
	    "_$arch.changes";
	my @cfiles;
	if (-r "$build_dir/$changes") {
	    my(@do_dists, @saved_dists);
	    $self->log("\n$changes:\n");
	    open( F, "<$build_dir/$changes" );
	    if (open( F2, ">$changes.new" )) {
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
		rename("$changes.new", "$changes")
		    or $self->log("$changes.new could not be renamed to $changes: $!\n");
		unlink("$build_dir/$changes")
		    if $build_dir;
	    }
	    else {
		$self->log("Cannot create $changes.new: $!\n");
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

	    $self->log("\n$deb:\n");
	    if (!open( PIPE, "dpkg --info $deb 2>&1 |" )) {
		$self->log("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($_) while( <PIPE> );
		close( PIPE );
	    }
	}

	@debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$build_dir/$_";
	    next if $deb !~ /(\Q$arch\E|all)\.[\w\d.-]*$/;

	    $self->log("\n$deb:\n");
	    if (!open( PIPE, "dpkg --contents $deb 2>&1 |" )) {
		$self->log("Can't spawn dpkg: $! -- can't dump info\n");
	    }
	    else {
		$self->log($_) while( <PIPE> );
		close( PIPE );
	    }
	}

	foreach (@cfiles) {
	    push( @space_files, $_ );
	    system "mv", "-f", "$build_dir/$_", "."
		and $self->log_error("Could not move $_ to .\n");
	}
	$self->log_subsection("Finished");
	$self->log("Built successfully\n");
    }

    $self->check_watches();
    $self->check_space(@space_files);

    if ($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'always' ||
	($self->get_conf('PURGE_BUILD_DIRECTORY') eq 'successful' && $rv == 0)) {
	$self->log("Purging $build_dir\n");
	my $bdir = $self->get('Session')->strip_chroot_path($self->get('Chroot Build Dir'));
	$self->get('Session')->run_command("rm -rf '$bdir'", "root", 1, 0, '/');
    }

    $self->log_sep();
    return $rv == 0 ? 1 : 0;
}

sub analyze_fail_stage (\$) {
    my $self = shift;

    my $pkgv = $self->get('Package_Version');

    return if $self->get('Pkg Status') ne "failed";
    return if !$self->get_conf('AUTO_GIVEBACK');
    if (isin( $self->get('Pkg Fail Stage'),
	      qw(find-dsc fetch-src unpack-check check-space install-deps-env))) {
	$self->set('Pkg Status', "given-back");
	$self->log("Giving back package $pkgv after failure in ".
		   "$self->{'Pkg Fail Stage'} stage.\n");
	my $cmd = "";
	$cmd = "ssh -l " . $self->get_conf('AUTO_GIVEBACK_USER') . " " .
	    $self->get_conf('AUTO_GIVEBACK_HOST') . " "
	    if $self->get_conf('AUTO_GIVEBACK_HOST');
	$cmd .= "-S " . $self->get_conf('AUTO_GIVEBACK_SOCKET') . " "
	    if $self->get_conf('AUTO_GIVEBACK_SOCKET');
	$cmd .= "wanna-build --give-back --no-down-propagation ".
	    "--dist=" . $self->get_conf('DISTRIBUTION') . " ";
	$cmd .= "--database=" . $self->get_conf('WANNABUILD_DATABASE') . " "
	    if $self->get_conf('WANNABUILD_DATABASE');
	$cmd .= "--user=" . $self->get_conf('AUTO_GIVEBACK_WANNABUILD_USER') . " "
	    if $self->get_conf('AUTO_GIVEBACK_WANNABUILD_USER');
	$cmd .= "$pkgv";
	system $cmd;
	if ($?) {
	    $self->log("wanna-build failed with status $?\n");
	}
	else {
	    $self->add_givenback($pkgv, time );
	    $self->write_stats('give-back', 1);
	}
    }
}

sub install_deps (\$) {
    my $self = shift;

    $self->log_subsection("Install build dependencies");

    my $pkg = $self->get('Package');
    my( @positive, @negative, @instd, @rmvd );

    my $dep = [];
    if (exists $self->get('Dependencies')->{$pkg}) {
	$dep = $self->get('Dependencies')->{$pkg};
    }
    debug("Source dependencies of $pkg: ", $self->format_deps(@$dep), "\n");

  repeat:
    $self->lock_file($self->get('Session')->get('Install Lock'), 1);

    debug("Filtering dependencies\n");
    if (!$self->filter_dependencies($dep, \@positive, \@negative )) {
	$self->log("Package installation not possible\n");
	$self->unlock_file($self->get('Session')->get('Install Lock'));
	return 0;
    }

    $self->log("Checking for source dependency conflicts...\n");
    if (!$self->run_apt("-s", \@instd, \@rmvd, @positive)) {
	$self->log("Test what should be installed failed.\n");
	$self->unlock_file($self->get('Session')->get('Install Lock'));
	return 0;
    }
    # add negative deps as to be removed for checking srcdep conflicts
    push( @rmvd, @negative );
    my @confl;
    if (@confl = $self->check_srcdep_conflicts(\@instd, \@rmvd)) {
	$self->log("Waiting for job(s) @confl to finish\n");

	$self->unlock_file($self->get('Session')->get('Install Lock'));
	$self->wait_for_srcdep_conflicts(@confl);
	goto repeat;
    }

    $self->write_srcdep_lock_file($dep);

    my $install_start_time = time;
    debug("Installing positive dependencies: @positive\n");
    if (!$self->run_apt("-y", \@instd, \@rmvd, @positive)) {
	$self->log("Package installation failed\n");
	# try to reinstall removed packages
	$self->log("Trying to reinstall removed packages:\n");
	debug("Reinstalling removed packages: @rmvd\n");
	my (@instd2, @rmvd2);
	$self->log("Failed to reinstall removed packages!\n")
	    if !$self->run_apt("-y", \@instd2, \@rmvd2, @rmvd);
	debug("Installed were: @instd2\n");
	debug("Removed were: @rmvd2\n");
	# remove additional packages
	$self->log("Trying to uninstall newly installed packages:\n");
	$self->uninstall_debs($self->get('Chroot Dir') ? "purge" : "remove",
			      @instd);
	$self->unlock_file($self->get('Session')->get('Install Lock'));
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);

    debug("Removing negative dependencies: @negative\n");
    if (!$self->uninstall_debs($self->get('Chroot Dir') ? "purge" : "remove",
			       @negative)) {
	$self->log("Removal of packages failed\n");
	$self->unlock_file($self->get('Session')->get('Install Lock'));
	return 0;
    }
    $self->set_removed(@negative);
    my $install_stop_time = time;
    $self->write_stats('install-download-time',
		       $install_stop_time - $install_start_time);

    my $fail = $self->check_dependencies($dep);
    if ($fail) {
	$self->log("After installing, the following source dependencies are ".
		   "still unsatisfied:\n$fail\n");
	$self->unlock_file($self->get('Session')->get('Install Lock'));
	return 0;
    }

    local (*F);

    my $command = $self->get('Session')->get_command($self->get_conf('DPKG') . ' --set-selections', "root", 1, 0, '/');

    my $success = open( F, "| $command");

    if ($success) {
	foreach my $tpkg (@instd) {
	    print F $tpkg . " purge\n";
	}
	close( F );
	if ($?) {
	    $self->log($self->get_conf('DPKG') . ' --set-selections failed\n');
	}
    }

    $self->unlock_file($self->get('Session')->get('Install Lock'));

    $self->prepare_watches($dep, @instd );
    return 1;
}

sub wait_for_srcdep_conflicts (\$@) {
    my $self = shift;
    my @confl = @_;

    for(;;) {
	sleep($self->get_conf('SRCDEP_LOCK_WAIT') * 60);
	my $allgone = 1;
	for (@confl) {
	    /^(\d+)-(\d+)$/;
	    my $pid = $1;
	    if (-f "$self->{'Session'}->{'Srcdep Lock Dir'}/$_") {
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    $self->log("Ignoring stale src-dep lock $_\n");
		    unlink( "$self->{'Session'}->{'Srcdep Lock Dir'}/$_" ) or
			$self->log("Cannot remove $self->{'Session'}->{'Srcdep Lock Dir'}/$_: $!\n");
		}
		else {
		    $allgone = 0;
		    last;
		}
	    }
	}
	last if $allgone;
    }
}

sub uninstall_deps (\$) {
    my $self = shift;

    my( @pkgs, @instd, @rmvd );

    $self->lock_file($self->get('Session')->get('Install Lock'), 1);

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $self->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $self->log("Failed to remove installed packages!\n")
	if !$self->uninstall_debs("purge", @pkgs);
    $self->unset_installed(@pkgs);

    $self->unlock_file($self->get('Session')->get('Install Lock'));
}

sub uninstall_debs (\$$@) {
    my $self = shift;
    my $mode = shift;
    local (*PIPE);
    local (%ENV) = %ENV; # make local environment hardwire frontend
			 # for debconf to non-interactive
    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";

    return 1 if !@_;
    debug("Uninstalling packages: @_\n");

    my $command = $self->get('Session')->get_command($self->get_conf('DPKG') . " --$mode @_ 2>&1 </dev/null", "root", 1, 0, '/');
  repeat:
    my $output;
    my $remove_start_time = time;

    if (!open( PIPE, "$command |")) {
	$self->log("Can't open pipe to dpkg: $!\n");
	return 0;
    }
    while ( <PIPE> ) {
	$output .= $_;
	$self->log($_);
    }
    close( PIPE );

    if ($output =~ /status database area is locked/mi) {
	$self->log("Another dpkg is running -- retrying later\n");
	$output = "";
	sleep( 2*60 );
	goto repeat;
    }
    my $remove_end_time = time;
    $self->write_stats('remove-time',
		       $remove_end_time - $remove_start_time);
    $self->log("dpkg run to remove packages (@_) failed!\n") if $?;
    return $? == 0;
}

sub run_apt (\$$\@\@@) {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my @to_install = @_;
    my( $msgs, $status, $pkgs, $rpkgs );
    local (*PIPE);
    local (%ENV) = %ENV; # make local environment hardwire frontend
			 # for debconf to non-interactive
    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";

    @$inst_ret = ();
    @$rem_ret = ();
    return 1 if !@to_install;
  repeat:

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my $command =
	$self->get('Session')->get_apt_command($self->get_conf('APT_GET'), '--purge '.
					    '-o DPkg::Options::=--force-confold '.
					    "-q $mode install @to_install ".
					    "2>&1 </dev/null", "root", 0, '/');

    if (!open( PIPE, "$command |" )) {
	$self->log('Can\'t open pipe to ' . $self->get_conf('APT_GET') .
		   ": $!\n");
	return 0;
    }
    while( <PIPE> ) {
	$msgs .= $_;
	$self->log($_) if $mode ne "-s" || debug($_);
    }
    close( PIPE );
    $status = $?;

    if ($status != 0 && $msgs =~ /^E: Packages file \S+ (has changed|is out of sync)/mi) {
	my $command =
	    $self->get('Session')->get_apt_command($self->get_conf('APT_GET'),
						"-q update 2>&1",
						"root", 1, '/');
	if (!open( PIPE, "$command |" )) {
	    $self->log("Can't open pipe to apt-get: $!\n");
	    return 0;
	}

	$msgs = "";
	while( <PIPE> ) {
	    $msgs .= $_;
	    $self->log($_);
	}
	close( PIPE );
	$self->log("apt-get update failed\n") if $?;
	$msgs = "";
	goto repeat;
    }

    if ($status != 0 && $msgs =~ /^Package (\S+) is a virtual package provided by:\n((^\s.*\n)*)/mi) {
	my $to_replace = $1;
	my @providers;
	foreach (split( "\n", $2 )) {
	    s/^\s*//;
	    push( @providers, (split( /\s+/, $_ ))[0] );
	}
	$self->log("$to_replace is a virtual package provided by: @providers\n");
	my $selected;
	if (@providers == 1) {
	    $selected = $providers[0];
	    $self->log("Using $selected (only possibility)\n");
	}
	elsif (exists $self->get_conf('ALTERNATIVES')->{$to_replace}) {
	    $selected = $self->get_conf('ALTERNATIVES')->{$to_replace};
	    $self->log("Using $selected (selected in sbuildrc)\n");
	}
	else {
	    $selected = $providers[0];
	    $self->log("Using $selected (no default, using first one)\n");
	}

	@to_install = grep { $_ ne $to_replace } @to_install;
	push( @to_install, $selected );

	goto repeat;
    }

    if ($status != 0 && ($msgs =~ /^E: Could( not get lock|n.t lock)/mi ||
			 $msgs =~ /^dpkg: status database area is locked/mi)) {
	$self->log("Another apt-get or dpkg is running -- retrying later\n");
	sleep( 2*60 );
	goto repeat;
    }

    # check for errors that are probably caused by something broken in
    # the build environment, and give back the packages.
    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem./mi) ||
	 ($msgs =~ /^dpkg: parse error, in file `\/.+\/var\/lib\/dpkg\/(?:available|status)' near line/mi) ||
	 ($msgs =~ /^E: Unmet dependencies. Try 'apt-get -f install' with no packages \(or specify a solution\)\./mi))) {
	$self->log_error("Build environment unusable, giving back\n");
	$self->set('Pkg Fail Stage', "install-deps-env");
    }

    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^E: Unable to fetch some archives, maybe run apt-get update or try with/mi))) {
	$self->log("Unable to fetch build-depends\n");
	$self->set('Pkg Fail Stage', "install-deps-env");
    }

    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^W: Couldn't stat source package list /mi))) {
	$self->log("Missing a packages file (mismatch with Release.gpg?), giving back.\n");
	$self->set('Pkg Fail Stage', "install-deps-env");
    }

    $pkgs = $rpkgs = "";
    if ($msgs =~ /NEW packages will be installed:\n((^[ 	].*\n)*)/mi) {
	($pkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$pkgs =~ s/\*//g;
    }
    if ($msgs =~ /packages will be REMOVED:\n((^[ 	].*\n)*)/mi) {
	($rpkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$rpkgs =~ s/\*//g;
    }
    @$inst_ret = split( /\s+/, $pkgs );
    @$rem_ret = split( /\s+/, $rpkgs );

    $self->log("apt-get failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub filter_dependencies (\$\@\@\@) {
    my $self = shift;
    my $dependencies = shift;
    my $pos_list = shift;
    my $neg_list = shift;
    my($dep, $d, $name, %names);

    $self->log("Checking for already installed source dependencies...\n");

    @$pos_list = @$neg_list = ();
    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
    }
    my $status = $self->get_dpkg_status(keys %names);

    my %policy;
    if ($self->get_conf('APT_POLICY')) {
	%policy = $self->get_apt_policy(keys %names);
    }

    foreach $dep (@$dependencies) {
	$name = $dep->{'Package'};
	next if !$name;

	my $stat = $status->{$name};
	if ($dep->{'Neg'}) {
	    if ($stat->{'Installed'}) {
		my ($rel, $vers) = ($dep->{'Rel'}, $dep->{'Version'});
		my $ivers = $stat->{'Version'};
		if (!$rel || version_compare( $ivers, $rel, $vers )){
		    debug("$name: neg dep, installed, not versioned or ",
				 "version relation satisfied --> remove\n");
		    $self->log("$name: installed (negative dependency)");
		    $self->log(" (bad version $ivers $rel $vers)")
			if $rel;
		    $self->log("\n");
		    push( @$neg_list, $name );
		}
		else {
		    $self->log("$name: installed (negative dependency) (but version ok $ivers $rel $vers)\n");
		}
	    }
	    else {
		debug("$name: neg dep, not installed\n");
		$self->log("$name: already deinstalled\n");
	    }
	    next;
	}

	my $is_satisfied = 0;
	my $installable = "";
	my $upgradeable = "";
	foreach $d ($dep, @{$dep->{'Alternatives'}}) {
	    my ($name, $rel, $vers) =
		($d->{'Package'}, $d->{'Rel'}, $d->{'Version'});
	    my $stat = $status->{$name};
	    if (!$stat->{'Installed'}) {
		debug("$name: pos dep, not installed\n");
		$self->log("$name: missing\n");
		if ($self->get_conf('APT_POLICY') && $rel) {
		    if (!version_compare($policy{$name}->{defversion}, $rel, $vers)) {
			$self->log("Default version of $name not sufficient, ");
			foreach my $cvers (@{$policy{$name}->{versions}}) {
			    if (version_compare($cvers, $rel, $vers)) {
				$self->log("using version $cvers\n");
				$installable = $name . "=" . $cvers if !$installable;
				last;
			    }
			}
			if(!$installable) {
			    $self->log("no suitable version found. Skipping for now, maybe there are alternatives.\n");
			    next if ($self->get_conf('CHECK_DEPENDS_ALGORITHM') eq "alternatives");
			}
		    } else {
			$self->log("Using default version " . $policy{$name}->{defversion} . "\n");
		    }
		}
		$installable = $name if !$installable;
		next;
	    }
	    my $ivers = $stat->{'Version'};
	    if (!$rel || version_compare( $ivers, $rel, $vers )) {
		debug("$name: pos dep, installed, no versioned dep or ",
			     "version ok\n");
		$self->log("$name: already installed ($ivers");
		$self->log(" $rel $vers is satisfied")
		    if $rel;
		$self->log(")\n");
		$is_satisfied = 1;
		last;
	    }
	    debug("$name: vers dep, installed $ivers ! $rel $vers\n");
	    $self->log("$name: non-matching version installed ".
		       "($ivers ! $rel $vers)\n");
	    if ($rel =~ /^</ ||
		($rel eq '=' && version_compare($ivers, '>>', $vers))) {
		debug("$name: would be a downgrade!\n");
		$self->log("$name: would have to downgrade!\n");
	    }
	    else {
		if ($self->get_conf('APT_POLICY') &&
		    !version_compare($policy{$name}->{defversion}, $rel, $vers)) {
		    $self->log("Default version of $name not sufficient, ");
		    foreach my $cvers (@{$policy{$name}->{versions}}) {
			if(version_compare($cvers, $rel, $vers)) {
			    $self->log("using version $cvers\n");
			    $upgradeable = $name if ! $upgradeable;
			    last;
			}
		    }
		    $self->log("no suitable alternative found. I probably should dep-wait this one.\n") if !$upgradeable;
		    return 0;
		} else {
		    $self->log("Using default version " . $policy{$name}->{defversion} . "\n");
		}
		$upgradeable = $name if !$upgradeable;
	    }
	}
	if (!$is_satisfied) {
	    if ($upgradeable) {
		debug("using $upgradeable for upgrade\n");
		push( @$pos_list, $upgradeable );
	    }
	    elsif ($installable) {
		debug("using $installable for install\n");
		push( @$pos_list, $installable );
	    }
	    else {
		$self->log("This dependency could not be satisfied. Possible reasons:\n");
		$self->log("* The package has a versioned dependency that is not yet available.\n");
		$self->log("* The package has a versioned dependency on a package version that is\n  older than the currently-installed package. Downgrades are not implemented.\n");
		return 0;
	    }
	}
    }

    return 1;
}

sub check_dependencies (\$\@) {
    my $self = shift;
    my $dependencies = shift;
    my $fail = "";
    my($dep, $d, $name, %names);

    $self->log("Checking correctness of source dependencies...\n");

    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
    }
    foreach $name (@{$self->get('Toolchain Packages')}) {
	$names{$name} = 1;
    }
    my $status = $self->get_dpkg_status(keys %names);

    foreach $dep (@$dependencies) {
	$name = $dep->{'Package'};
	next if $name =~ /^\*/;
	my $stat = $status->{$name};
	if ($dep->{'Neg'}) {
	    if ($stat->{'Installed'}) {
		if (!$dep->{'Rel'}) {
		    $fail .= "$name(still installed) ";
		}
		elsif ($stat->{'Version'} eq '~*=PROVIDED=*=') {
		    # It's a versioned build-conflict, but we installed
		    # a package that provides the conflicted package. It's ok.
		}
		elsif (version_compare($stat->{'Version'}, $dep->{'Rel'},
				       $dep->{'Version'})) {
		    $fail .= "$name(inst $stat->{'Version'} $dep->{'Rel'} ".
			"conflicted $dep->{'Version'})\n";
		}
	    }
	}
	else {
	    my $is_satisfied = 0;
	    my $f = "";
	    foreach $d ($dep, @{$dep->{'Alternatives'}}) {
		my $name = $d->{'Package'};
		my $stat = $status->{$name};
		if (!$stat->{'Installed'}) {
		    $f =~ s/ $/\|/ if $f;
		    $f .= "$name(missing) ";
		}
		elsif ($d->{'Rel'} &&
		       !version_compare( $stat->{'Version'}, $d->{'Rel'},
					 $d->{'Version'} )) {
		    $f =~ s/ $/\|/ if $f;
		    $f .= "$name(inst $stat->{'Version'} ! $d->{'Rel'} ".
			"wanted $d->{'Version'}) ";
		}
		else {
		    $is_satisfied = 1;
		}
	    }
	    if (!$is_satisfied) {
		$fail .= $f;
	    }
	}
    }
    $fail =~ s/\s+$//;
    if (!$fail && @{$self->get('Toolchain Packages')}) {
	my ($sysname, $nodename, $release, $version, $machine) = uname();
	my $arch = $self->get('Arch');

	$self->log("Kernel: $sysname $release $arch ($machine)\n");
	$self->log("Toolchain package versions:");
	foreach $name (@{$self->get('Toolchain Packages')}) {
	    if (defined($status->{$name}->{'Version'})) {
		$self->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    } else {
		$self->log(' ' . $name . '_' . ' =*=NOT INSTALLED=*=');

	    }
	}
	$self->log("\n");
    }

    return $fail;
}

sub get_apt_policy (\$@) {
    my $self = shift;
    my @interest = @_;
    my $package;
    my %packages;

    $ENV{LC_ALL}='C';

    my $command =
	$self->get('Session')->get_apt_command($self->get_conf('APT_CACHE'),
					    "policy @interest",
					    $self->get_conf('USERNAME'), 0, '/');

    my $pid = open3(\*main::DEVNULL, \*APTCACHE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die 'Can\'t start ' . $self->get_conf('APT_CACHE') . ": $!\n";
    }
    while(<APTCACHE>) {
	$package=$1 if /^([0-9a-z+.-]+):$/;
	$packages{$package}->{curversion}=$1 if /^ {2}Installed: ([0-9a-zA-Z-.:~+]*)$/;
	$packages{$package}->{defversion}=$1 if /^ {2}Candidate: ([0-9a-zA-Z-.:~+]*)$/;
	push @{$packages{$package}->{versions}}, "$2" if /^ (\*{3}| {3}) ([0-9a-zA-Z-.:~+]*) 0$/;
    }
    close(APTCACHE);
    waitpid $pid, 0;
    die $self->get_conf('APT_CACHE') . " exit status $?\n" if $?;

    return %packages;
}

sub get_dpkg_status (\$@) {
    my $self = shift;
    my @interest = @_;
    my %result;
    local( *STATUS );

    return () if !@_;
    debug("Requesting dpkg status for packages: @interest\n");
    if (!open( STATUS, "<$self->{'Chroot Dir'}/var/lib/dpkg/status" )) {
	$self->log("Can't open $self->{'Chroot Dir'}/var/lib/dpkg/status: $!\n");
	return ();
    }
    local( $/ ) = "";
    while( <STATUS> ) {
	my( $pkg, $status, $version, $provides );
	/^Package:\s*(.*)\s*$/mi and $pkg = $1;
	/^Status:\s*(.*)\s*$/mi and $status = $1;
	/^Version:\s*(.*)\s*$/mi and $version = $1;
	/^Provides:\s*(.*)\s*$/mi and $provides = $1;
	if (!$pkg) {
	    $self->log_error("parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $self->log_error("parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $self->log_error("parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: no Version: field for package $pkg\n");
	    next;
	}
	$result{$pkg} = { Installed => 1, Version => $version }
	if isin( $pkg, @interest );
	if ($provides) {
	    foreach (split( /\s*,\s*/, $provides )) {
		$result{$_} = { Installed => 1, Version => '~*=PROVIDED=*=' }
		if isin( $_, @interest ) and (not exists($result{$_}) or
					      ($result{$_}->{'Installed'} == 0));
	    }
	}
    }
    close( STATUS );
    return \%result;
}

sub merge_pkg_build_deps (\$$$$$$) {
    my $self = shift;
    my $pkg = shift;
    my $depends = shift;
    my $dependsi = shift;
    my $conflicts = shift;
    my $conflictsi = shift;
    my (@l, $dep);

    $self->log("** Using build dependencies supplied by package:\n");
    $self->log("Build-Depends: $depends\n") if $depends;
    $self->log("Build-Depends-Indep: $dependsi\n") if $dependsi;
    $self->log("Build-Conflicts: $conflicts\n") if $conflicts;
    $self->log("Build-Conflicts-Indep: $conflictsi\n") if $conflictsi;

    $self->get('Dependencies')->{$pkg} = []
	if (!defined $self->get('Dependencies')->{$pkg});
    my $old_deps = copy($self->get('Dependencies')->{$pkg});

    # Add gcc-snapshot as an override.
    if ($self->get_conf('GCC_SNAPSHOT')) {
	$dep->set('Package', "gcc-snapshot");
	$dep->set('Override', 1);
	push( @{$self->get('Dependencies')->{$pkg}}, $dep );
    }

    foreach $dep (@{$self->get('Dependencies')->{$pkg}}) {
	if ($dep->{'Override'}) {
	    $self->log("Added override: ",
	    (map { ($_->{'Neg'} ? "!" : "") .
		       $_->{'Package'} .
		       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"") }
	     scalar($dep), @{$dep->{'Alternatives'}}), "\n");
	    push( @l, $dep );
	}
    }

    $conflicts = join( ", ", map { "!$_" } split( /\s*,\s*/, $conflicts ));
    $conflictsi = join( ", ", map { "!$_" } split( /\s*,\s*/, $conflictsi ));

    my $deps = $depends . ", " . $conflicts;
    $deps .= ", " . $dependsi . ", " . $conflictsi
	if $self->get_conf('BUILD_ARCH_ALL');
    @{$self->get('Dependencies')->{$pkg}} = @l;
    debug("Merging pkg deps: $deps\n");
    $self->parse_one_srcdep($pkg, $deps);

    my $missing = ($self->cmp_dep_lists($old_deps,
					$self->get('Dependencies')->{$pkg}))[1];

    # read list of build-essential packages (if not yet done) and
    # expand their dependencies (those are implicitly essential)
    if (!defined($self->get('Dependencies')->{'ESSENTIAL'})) {
	my $ess = $self->read_build_essential();
	$self->parse_one_srcdep('ESSENTIAL', $ess);
    }
    my ($exp_essential, $exp_pkgdeps, $filt_essential, $filt_pkgdeps);
    $exp_essential = $self->expand_dependencies($self->get('Dependencies')->{'ESSENTIAL'});
    debug("Dependency-expanded build essential packages:\n",
		 $self->format_deps(@$exp_essential), "\n");

    # populate Toolchain Packages from toolchain_regexes and
    # build-essential packages.
    $self->set('Toolchain Packages', []);
    foreach my $tpkg (@$exp_essential) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    push @{$self->get('Toolchain Packages')},$tpkg->{'Package'}
	        if $tpkg->{'Package'} =~ m,^$regex,;
	}
    }

    return if !@$missing;

    # remove missing essential deps
    ($filt_essential, $missing) = $self->cmp_dep_lists($missing,
                                                       $exp_essential);
    $self->log("** Filtered missing build-essential deps:\n" .
	       $self->format_deps(@$filt_essential) . "\n")
	           if @$filt_essential;

    # if some build deps are virtual packages, replace them by an
    # alternative over all providing packages
    $exp_pkgdeps = $self->expand_virtuals($self->get('Dependencies')->{$pkg} );
    debug("Provided-expanded build deps:\n",
		 $self->format_deps(@$exp_pkgdeps), "\n");

    # now expand dependencies of package build deps
    $exp_pkgdeps = $self->expand_dependencies($exp_pkgdeps);
    debug("Dependency-expanded build deps:\n",
		 $self->format_deps(@$exp_pkgdeps), "\n");
    # NOTE: Was $main::additional_deps, not @main::additional_deps.
    # They may be separate?
    @{$self->get('Additional Deps')} = @$exp_pkgdeps;

    # remove missing essential deps that are dependencies of build
    # deps
    ($filt_pkgdeps, $missing) = $self->cmp_dep_lists($missing, $exp_pkgdeps);
    $self->log("** Filtered missing build-essential deps that are dependencies of or provide build-deps:\n" .
	       $self->format_deps(@$filt_pkgdeps), "\n")
	           if @$filt_pkgdeps;

    # remove comment package names
    push( @{$self->get('Additional Deps')},
	  grep { $_->{'Neg'} && $_->{'Package'} =~ /^needs-no-/ } @$missing );
    $missing = [ grep { !($_->{'Neg'} &&
	                ($_->{'Package'} =~ /^this-package-does-not-exist/ ||
	                 $_->{'Package'} =~ /^needs-no-/)) } @$missing ];

    $self->log("**** Warning:\n" .
	       "**** The following src deps are " .
	       "(probably) missing:\n  ", $self->format_deps(@$missing), "\n")
	           if @$missing;
}

sub cmp_dep_lists (\$\@\@) {
    my $self = shift;
    my $list1 = shift;
    my $list2 = shift;

    my ($dep, @common, @missing);

    foreach $dep (@$list1) {
	my $found = 0;

	if ($dep->{'Neg'}) {
	    foreach (@$list2) {
		if ($dep->{'Package'} eq $_->{'Package'} && $_->{'Neg'}) {
		    $found = 1;
		    last;
		}
	    }
	}
	else {
	    my $al = $self->get_altlist($dep);
	    foreach (@$list2) {
		if ($self->is_superset($self->get_altlist($_), $al)) {
		    $found = 1;
		    last;
		}
	    }
	}

	if ($found) {
	    push( @common, $dep );
	}
	else {
	    push( @missing, $dep );
	}
    }
    return (\@common, \@missing);
}

sub get_altlist (\$$) {
    my $self = shift;
    my $dep = shift;
    my %l;

    foreach (scalar($dep), @{$dep->{'Alternatives'}}) {
	$l{$_->{'Package'}} = 1 if !$_->{'Neg'};
    }
    return \%l;
}

sub is_superset (\$\%\%) {
    my $self = shift;
    my $l1 = shift;
    my $l2 = shift;

    foreach (keys %$l2) {
	return 0 if !exists $l1->{$_};
    }
    return 1;
}

sub read_build_essential (\$) {
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

sub expand_dependencies (\$\@) {
    my $self = shift;
    my $dlist = shift;
    my (@to_check, @result, %seen, $check, $dep);

    foreach $dep (@$dlist) {
	next if $dep->{'Neg'} || $dep->{'Package'} =~ /^\*/;
	foreach (scalar($dep), @{$dep->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    push( @to_check, $name );
	    $seen{$name} = 1;
	}
	push( @result, copy($dep) );
    }

    while( @to_check ) {
	my $deps = $self->get_dependencies(@to_check);
	my @check = @to_check;
	@to_check = ();
	foreach $check (@check) {
	    if (defined($deps->{$check})) {
		foreach (split( /\s*,\s*/, $deps->{$check} )) {
		    foreach (split( /\s*\|\s*/, $_ )) {
			my $pkg = (/^([^\s([]+)/)[0];
			if (!$seen{$pkg}) {
			    push( @to_check, $pkg );
			    push( @result, { Package => $pkg, Neg => 0 } );
			    $seen{$pkg} = 1;
			}
		    }
		}
	    }
	}
    }

    return \@result;
}

sub expand_virtuals (\$\@) {
    my $self = shift;
    my $dlist = shift;
    my ($dep, %names, @new_dlist);

    foreach $dep (@$dlist) {
	foreach (scalar($dep), @{$dep->{'Alternatives'}}) {
	    $names{$_->{'Package'}} = 1;
	}
    }
    my $provided_by = $self->get_virtuals(keys %names);

    foreach $dep (@$dlist) {
	my %seen;
	foreach (scalar($dep), @{$dep->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $seen{$name} = 1;
	    if (exists $provided_by->{$name}) {
		foreach( keys %{$provided_by->{$name}} ) {
		    $seen{$_} = 1;
		}
	    }
	}
	my @l = map { { Package => $_, Neg => 0 } } keys %seen;
	my $l = shift @l;
	foreach (@l) {
	    push( @{$l->{'Alternatives'}}, $_ );
	}
	push( @new_dlist, $l );
    }

    return \@new_dlist;
}

sub get_dependencies (\$@) {
    my $self = shift;

    local(*PIPE);
    my %deps;

    my $command = $self->get('Session')->get_apt_command($self->get_conf('APT_CACHE'),
						      "show @_",
						      $self->get_conf('USERNAME'), 0, '/');
    my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die 'Can\'t start ' . $self->get_conf('APT_CACHE') . ": $!\n";
    }
    local($/) = "";
    while( <PIPE> ) {
	my ($name, $dep, $predep);
	/^Package:\s*(.*)\s*$/mi and $name = $1;
	next if !$name || $deps{$name};
	/^Depends:\s*(.*)\s*$/mi and $dep = $1;
	/^Pre-Depends:\s*(.*)\s*$/mi and $predep = $1;
	$dep .= ", " if defined($dep) && $dep && defined($predep) && $predep;
	$dep .= $predep if defined($predep);
	$deps{$name} = $dep;
    }
    close( PIPE );
    waitpid $pid, 0;
    die $self->get_conf('APT_CACHE') . " exit status $?\n" if $?;

    return \%deps;
}

sub get_virtuals (\$@) {
    my $self = shift;

    local(*PIPE);

    my $command = $self->get('Session')->get_apt_command($self->get_conf('APT_CACHE'),
						      "showpkg @_",
						      $self->get_conf('USERNAME'), 0, '/');
    my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die 'Can\'t start ' . $self->get_conf('APT_CACHE') . ": $!\n";
    }
    my $name;
    my $in_rprov = 0;
    my %provided_by;
    while( <PIPE> ) {
	if (/^Package:\s*(\S+)\s*$/) {
	    $name = $1;
	}
	elsif (/^Reverse Provides: $/) {
	    $in_rprov = 1;
	}
	elsif ($in_rprov && /^(\w+):\s/) {
	    $in_rprov = 0;
	}
	elsif ($in_rprov && /^(\S+)\s*\S+\s*$/) {
	    $provided_by{$name}->{$1} = 1;
	}
    }
    close( PIPE );
    waitpid $pid, 0;
    die $self->get_conf('APT_CACHE') . " exit status $?\n" if $?;

    return \%provided_by;
}

sub parse_one_srcdep (\$$$) {
    my $self = shift;
    my $pkg = shift;
    my $deps = shift;

    $deps =~ s/^\s*(.*)\s*$/$1/;
    foreach (split( /\s*,\s*/, $deps )) {
	my @l;
	my $override;
	if (/^\&/) {
	    $override = 1;
	    s/^\&\s+//;
	}
	my @alts = split( /\s*\|\s*/, $_ );
	my $neg_seen = 0;
	foreach (@alts) {
	    if (!/^([^\s([]+)\s*(\(\s*([<=>]+)\s*(\S+)\s*\))?(\s*\[([^]]+)\])?/) {
		$self->log_warning("syntax error in dependency '$_' of $pkg\n");
		next;
	    }
	    my( $dep, $rel, $relv, $archlist ) = ($1, $3, $4, $6);
	    if ($archlist) {
		$archlist =~ s/^\s*(.*)\s*$/$1/;
		my @archs = split( /\s+/, $archlist );
		my ($use_it, $ignore_it, $include) = (0, 0, 0);
		foreach (@archs) {
		    if (/^!/) {
			$ignore_it = 1 if substr($_, 1) eq $self->get('Arch');
		    }
		    else {
			$use_it = 1 if $_ eq $self->get('Arch');
			$include = 1;
		    }
		}
		$self->log_warning("inconsistent arch restriction on $pkg: $dep depedency\n")
		    if $ignore_it && $use_it;
		next if $ignore_it || ($include && !$use_it);
	    }
	    my $neg = 0;
	    if ($dep =~ /^!/) {
		$dep =~ s/^!\s*//;
		$neg = 1;
		$neg_seen = 1;
	    }
	    if ($conf::srcdep_over{$dep}) {
		if ($self->get_conf('VERBOSE')) {
		    $self->log("Replacing source dep $dep");
		    $self->log(" ($rel $relv)") if $relv;
		    $self->log(" with $conf::srcdep_over{$dep}[0]");
		    $self->log(" ($conf::srcdep_over{$dep}[1] $conf::srcdep_over{$dep}[2])")
			if $conf::srcdep_over{$dep}[1];
		    $self->log(".\n");
		}
		$dep = $conf::srcdep_over{$dep}[0];
		$rel = $conf::srcdep_over{$dep}[1];
		$relv = $conf::srcdep_over{$dep}[2];
	    }
	    my $h = { Package => $dep, Neg => $neg };
	    if ($rel && $relv) {
		$h->{'Rel'} = $rel;
		$h->{'Version'} = $relv;
	    }
	    $h->{'Override'} = $override if $override;
	    push( @l, $h );
	}
	if (@alts > 1 && $neg_seen) {
	    $self->log_warning("$pkg: alternatives with negative dependencies forbidden -- skipped\n");
	}
	elsif (@l) {
	    my $l = shift @l;
	    foreach (@l) {
		push( @{$l->{'Alternatives'}}, $_ );
	    }
	    push( @{$self->get('Dependencies')->{$pkg}}, $l );
	}
    }
}

sub parse_manual_srcdeps (\$@) {
    my $self = shift;
    my @for_pkgs = @_;

    foreach (@{$self->get_conf('MANUAL_SRCDEPS')}) {
	if (!/^([fa])([a-zA-Z\d.+-]+):\s*(.*)\s*$/) {
	    $self->log_warning("Syntax error in manual source dependency: ",
			       substr( $_, 1 ), "\n");
	    next;
	}
	my ($mode, $pkg, $deps) = ($1, $2, $3);
	next if !isin( $pkg, @for_pkgs );
	@{$self->get('Dependencies')->{$pkg}} = () if $mode eq 'f';
	$self->parse_one_srcdep($pkg, $deps);
    }
}

sub check_space (\$@) {
    my $self = shift;
    my @files = @_;
    my $sum = 0;
    local( *PIPE );

    foreach (@files) {
	my $command;

	if (/^\Q$self->{'Chroot Dir'}\E/) {
	    $_ = $self->get('Session')->strip_chroot_path($_);
	    $command = $self->get('Session')->get_command("/usr/bin/du -k -s $_ 2>/dev/null", "root", 1, 0);
	} else {
	    $command = $self->get('Session')->get_command("/usr/bin/du -k -s $_ 2>/dev/null", $self->get_conf('USERNAME'), 0, 0);
	}

	if (!open( PIPE, "$command |" )) {
	    $self->log("Cannot determine space needed (du failed): $!\n");
	    return;
	}
	while( <PIPE> ) {
	    next if !/^(\d+)/;
	    $sum += $1;
	}
	close( PIPE );
    }

    $self->set('This Time', $self->get('Pkg End Time') - $self->get('Pkg Start Time'));
    $self->get('This Time') = 0 if $self->get('This Time') < 0;
    $self->set('This Space', $sum);
}

# UNUSED
sub file_for_name (\$$@) {
    my $self = shift;
    my $name = shift;
    my @x = grep { /^\Q$name\E_/ } @_;
    return $x[0];
}

# only called from main loop, but depends on job state.
sub write_jobs_file (\$$) {
    my $self = shift;
    my $news = shift;
    my $job;
    local( *F );

    $main::job_state{$main::current_job} = $news
	if $news && $main::current_job;

    if ($self->get_conf('BATCH_MODE')) {

	return if !open( F, ">$self->{'Jobs File'}" );
	foreach $job (@ARGV) {
	    my $jobname;

	    if ($job eq $main::current_job and $self->get('binNMU Name')) {
		$jobname = $self->get('binNMU Name');
	    } else {
		$jobname = $job;
	    }
	    print F ($job eq $main::current_job) ? "" : "  ",
	    $jobname,
	    ($main::job_state{$job} ? ": $main::job_state{$job}" : ""),
	    "\n";
	}
	close( F );
    }
}

sub append_to_FINISHED (\$) {
    my $self = shift;

    my $pkg = $self->get('Package_Version');
    local( *F );

    if ($self->get_conf('BATCH_MODE')) {
	open( F, ">>SBUILD-FINISHED" );
	print F "$pkg\n";
	close( F );
    }
}

sub write_srcdep_lock_file (\$\@) {
    my $self = shift;
    my $deps = shift;
    local( *F );

    ++$self->{'Srcdep Lock Count'};
    my $f = "$self->{'Session'}->{'Srcdep Lock Dir'}/$$-$self->{'Srcdep Lock Count'}";
    if (!open( F, ">$f" )) {
	$self->log_warning("cannot create srcdep lock file $f: $!\n");
	return;
    }
    debug("Writing srcdep lock file $f:\n");

    my $user = getpwuid($<);
    print F "$main::current_job $$ $user\n";
    debug("Job $main::current_job pid $$ user $user\n");
    foreach (@$deps) {
	my $name = $_->{'Package'};
	print F ($_->{'Neg'} ? "!" : ""), "$name\n";
	debug("  ", ($_->{'Neg'} ? "!" : ""), "$name\n");
    }
    close( F );
}

sub check_srcdep_conflicts (\$\@\@) {
    my $self = shift;
    my $to_inst = shift;
    my $to_remove = shift;
    local( *F, *DIR );
    my $mypid = $$;
    my %conflict_builds;

    if (!opendir( DIR, $self->get('Session')->{'Srcdep Lock Dir'} )) {
	$self->log("Cannot opendir $self->{'Session'}->{'Srcdep Lock Dir'}: $!\n");
	return 1;
    }
    my @files = grep { !/^\.\.?$/ && !/^install\.lock/ && !/^$mypid-\d+$/ }
    readdir(DIR);
    closedir(DIR);

    my $file;
    foreach $file (@files) {
	if (!open( F, "<$self->{'Session'}->{'Srcdep Lock Dir'}/$file" )) {
	    $self->log("Cannot open $self->{'Session'}->{'Srcdep Lock Dir'}/$file: $!\n");
	    next;
	}
	<F> =~ /^(\S+)\s+(\S+)\s+(\S+)/;
	my ($job, $pid, $user) = ($1, $2, $3);

	# ignore (and remove) a lock file if associated process
	# doesn't exist anymore
	if (kill( 0, $pid ) == 0 && $! == ESRCH) {
	    close( F );
	    $self->log("Found stale srcdep lock file $file -- removing it\n");
	    $self->log("Cannot remove: $!\n")
		if !unlink( "$self->{'Session'}->{'Srcdep Lock Dir'}/$file" );
	    next;
	}

	debug("Reading srclock file $file by job $job user $user\n");

	while( <F> ) {
	    my ($neg, $pkg) = /^(!?)(\S+)/;
	    debug(print "Found ", ($neg ? "neg " : ""), "entry $pkg\n");

	    if (isin( $pkg, @$to_inst, @$to_remove )) {
		$self->log("Source dependency conflict with build of " .
		           "$job by $user (pid $pid):\n");
		$self->log("  $job " . ($neg ? "conflicts with" : "needs") .
		           " $pkg\n");
		$self->log("  $main::current_job wants to " .
		           (isin( $pkg, @$to_inst ) ? "update" : "remove") .
		           " $pkg\n");
		$conflict_builds{$file} = 1;
	    }
	}
	close( F );
    }

    my @conflict_builds = keys %conflict_builds;
    if (@conflict_builds) {
	debug("Srcdep conflicts with: @conflict_builds\n");
    }
    else {
	debug("No srcdep conflicts\n");
    }
    return @conflict_builds;
}

sub remove_srcdep_lock_file (\$) {
    my $self = shift;

    my $f = "$self->{'Session'}->{'Srcdep Lock Dir'}/$$-$self->{'Srcdep Lock Count'}";

    debug("Removing srcdep lock file $f\n");
    if (!unlink( $f )) {
	$self->log_warning("cannot remove srcdep lock file $f: $!\n")
	    if $! != ENOENT;
    }
}

sub prepare_watches (\$\@@) {
    my $self = shift;
    my $dependencies = shift;
    my @instd = @_;
    my(@dep_on, $dep, $pkg, $prg);

    @dep_on = @instd;
    foreach $dep (@$dependencies, @{$self->get('Additional Deps')}) {
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
	    $prg = "/usr/bin/$prg" if $prg !~ m,^/,;
	    $self->get('This Watches')->{"$self->{'Chroot Dir'}$prg"} = $pkg;
	    debug("Will watch for $prg ($pkg)\n");
	}
    }
}

sub check_watches (\$) {
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
	    push( @{$used{$pkg}}, $prg2 )
		if @{$self->get('Have DSC Build Deps')} ||
		!isin($pkg, @{$self->get_conf('IGNORE_WATCHES_NO_BUILD_DEPS')});
	}
	else {
	    debug("Watch: $prg: untouched\n");
	}
    }
    return if !%used;

    print main::PLOG <<EOF;

NOTE: The package could have used binaries from the following packages
(access time changed) without a source dependency:
EOF

    foreach (keys %used) {
	$self->log("  $_: @{$used{$_}}\n");
    }
    $self->log("\n");
}

sub should_skip (\$) {
    my $self = shift;

    my $pkgv = $self->get('Package_Version');

    $pkgv = $self->fixup_pkgv($pkgv);
    $self->lock_file("SKIP", 0);
    goto unlock if !open( F, "SKIP" );
    my @pkgs = <F>;
    close( F );

    if (!open( F, ">SKIP" )) {
	print "Can't open SKIP for writing: $!\n",
	"Would write: @pkgs\nminus $pkgv\n";
	goto unlock;
    }
    my $found = 0;
    foreach (@pkgs) {
	if (/^\Q$pkgv\E$/) {
	    ++$found;
	    $self->log("$pkgv found in SKIP file -- skipping building it\n");
	}
	else {
	    print F $_;
	}
    }
    close( F );
  unlock:
    $self->unlock_file("SKIP");
    return $found;
}

sub add_givenback (\$$$) {
    my $self = shift;
    my $pkgv = shift;
    my $time = shift;
    local( *F );

    $self->lock_file("SBUILD-GIVEN-BACK", 0);

    if (open( F, ">>SBUILD-GIVEN-BACK" )) {
	print F "$pkgv $time\n";
	close( F );
    }
    else {
	$self->log("Can't open SBUILD-GIVEN-BACK: $!\n");
    }

  unlock:
    $self->unlock_file("SBUILD-GIVEN-BACK");
}

sub set_installed (\$@) {
    my $self = shift;
    foreach (@_) {
	$self->get('Changes')->{'installed'}->{$_} = 1;
    }
    debug("Added to installed list: @_\n");
}

sub set_removed (\$@) {
    my $self = shift;
    foreach (@_) {
	$self->get('Changes')->{'removed'}->{$_} = 1;
	if (exists $self->get('Changes')->{'installed'}->{$_}) {
	    delete $self->get('Changes')->{'installed'}->{$_};
	    $self->get('Changes')->{'auto-removed'}->{$_} = 1;
	    debug("Note: $_ was installed\n");
	}
    }
    debug("Added to removed list: @_\n");
}

sub unset_installed (\$@) {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'installed'}->{$_};
    }
    debug("Removed from installed list: @_\n");
}

sub unset_removed (\$@) {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'removed'}->{$_};
	if (exists $self->get('Changes')->{'auto-removed'}->{$_}) {
	    delete $self->get('Changes')->{'auto-removed'}->{$_};
	    $self->get('Changes')->{'installed'}->{$_} = 1;
	    debug("Note: revived $_ to installed list\n");
	}
    }
    debug("Removed from removed list: @_\n");
}

sub df (\$$) {
    my $self = shift;
    my $dir = shift;

    my $free = `/bin/df $dir | tail -n 1`;
    my @free = split( /\s+/, $free );
    return $free[3];
}

sub fixup_pkgv (\$$) {
    my $self = shift;
    my $pkgv = shift;

    $pkgv =~ s,^.*/,,; # strip path
    $pkgv =~ s/\.(dsc|diff\.gz|tar\.gz|deb)$//; # strip extension
    $pkgv =~ s/_[a-zA-Z\d+~-]+\.(changes|deb)$//; # strip extension

    return $pkgv;
}

sub format_deps (\$@) {
    my $self = shift;

    return join( ", ",
		 map { join( "|",
			     map { ($_->{'Neg'} ? "!" : "") .
				       $_->{'Package'} .
				       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"")}
			     scalar($_), @{$_->{'Alternatives'}}) } @_ );
}

sub lock_file (\$$$) {
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
    F->print("$$ $ENV{'LOGNAME'}\n");
    F->close();
}

sub unlock_file (\$$) {
    my $self = shift;
    my $file = shift;
    my $lockfile = "$file.lock";

    unlink( $lockfile );
}

sub write_stats (\$$$) {
    my $self = shift;

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

sub debian_files_list (\$$) {
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

sub dsc_files (\$$) {
    my $self = shift;
    my $dsc = shift;
    my @files;

    debug("Parsing $dsc\n");

    if (-r $dsc && open(DSC, $self->get_conf('DCMD') . " $dsc|")) {
	while (<DSC>) {
	    chomp;
	    push @files, $_;
	    debug("  $_\n");
	}
	close( DSC ) or $self->log("Failed to close $dsc\n");
    } else {
	$self->log("Failed to open $dsc\n");
    }

    return @files;
}

# Figure out chroot architecture
sub chroot_arch (\$) {
    my $self = shift;

    $self->set('Sub PID', open( PIPE, "-|" ));
    if (!defined $self->get('Sub PID')) {
	$self->log("Can't spawn dpkg: $!\n");
	return 0;
    }
    if ($self->get('Sub PID') == 0) {
	$self->get('Session')->exec_command($self->get_conf('DPKG') . ' --print-installation-architecture 2>/dev/null', $self->get_conf('USERNAME'), 1, 0, '/');
    }
    chomp( my $chroot_arch = <PIPE> );
    close( PIPE );
    $self->set('Sub PID', undef);

    die "Can't determine architecture of chroot: $!\n"
	if ($? || !defined($chroot_arch));

    return $chroot_arch;
}

sub open_build_log (\$) {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time')));

    my $filename = $self->get_conf('LOG_DIR') . '/' .
	$self->get_conf('USERNAME') . '-' .
	$self->get('Package_SVersion') . '-' .
	$self->get('Arch') .
	"-$date";

    my $PLOG;

    my $pid;
    ($pid = open($PLOG, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to '$filename': $!\n";
    }
    elsif ($pid == 0) {
	$SIG{'INT'} = 'IGNORE';
#	$SIG{'TERM'} = 'IGNORE';
#	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';

	if (!$self->get_conf('NOLOG') &&
	    $self->get_conf('LOG_DIR_AVAILABLE')) {
	    open( CPLOG, ">$filename" ) or
		die "Can't open logfile $filename: $!\n";
	    CPLOG->autoflush(1);
	}

	while (<STDIN>) {
	    if (!$self->get_conf('NOLOG') &&
		$self->get_conf('LOG_DIR_AVAILABLE')) {
		print CPLOG $_;
	    }
	    if ($self->get_conf('NOLOG') || $self->get_conf('VERBOSE')) {
		print main::SAVED_STDOUT $_;
	    }
	}

	close CPLOG;
	exit 0;
    }

    # Create 'current' symlinks
    if (-f $filename &&
	$self->get_conf('SBUILD_MODE') eq 'buildd') {
	$self->log_symlink($filename,
			   $self->get_conf('BUILD_DIR') . '/current-' .
			   $self->get_conf('DISTRIBUTION'));
	$self->log_symlink($filename,
			   $self->get_conf('BUILD_DIR') . '/current');
    }

    $PLOG->autoflush(1);
    $self->set('Log File', $filename);
    $self->set('Log Stream', $PLOG);

    $self->log_section('sbuild/' . $self->get_conf('ARCH') . " $version");
    $self->log("Automatic build of $self->{'Package_SVersion'} on " .
	       $self->get_conf('HOSTNAME') . "\n");
    $self->log("Build started at " .
	       strftime("%Y%m%d-%H%M", localtime($self->get('Pkg Start Time'))) .
	       "\n");
    $self->log_sep();
}

sub close_build_log (\$$$$$$$) {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->get('Pkg End Time')));

    if (defined($self->get('Pkg Status')) &&
	$self->get('Pkg Status') eq "successful") {
	$self->add_time_entry($self->get('Package_Version'), $self->get('This Time'));
	$self->add_space_entry($self->get('Package_Version'), $self->get('This Space'));
    }
    $self->log_sep();
    printf main::PLOG "Finished at ${date}\nBuild needed %02d:%02d:%02d, %dk disc space\n",
    int($self->get('This Time')/3600),
    int(($self->get('This Time')%3600)/60),
    int($self->get('This Time')%60),
    $self->get('This Space');

    my $filename = $self->get('Log File');

    send_mail($self->get('Config'), $self->get_conf('MAILTO'),
	      "Log for " . $self->get('Pkg Status') .
	      " build of " . $self->get('Package_Version') .
	      " (dist=" . $self->get_conf('DISTRIBUTION') . ")",
	      $filename)
	if (defined($filename) && -f $filename &&
	    $self->get_conf('MAILTO'));

    $self->set('Log File', undef);
    $self->get('Log Stream')->close(); # Close child logger process
    $self->set('Log Stream', undef);
}

sub log_symlink (\$$$) {
    my $self = shift;
    my $log = shift;
    my $dest = shift;

    unlink $dest || return;
    symlink $log, $dest || return;
}

sub add_time_entry (\$$$) {
    my $self = shift;
    my $pkg = shift;
    my $t = shift;

    return if !$self->get_conf('AVG_TIME_DB');
    my %db;
    if (!tie %db, 'GDBM_File', $self->get_conf('AVG_TIME_DB'), GDBM_WRCREAT, 0664) {
	print "Can't open average time db " . $self->get_conf('AVG_TIME_DB') . '\n';
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

sub add_space_entry (\$$$) {
    my $self = shift;
    my $pkg = shift;
    my $space = shift;

    my $keepvals = 4;

    return if !$self->get_conf('AVG_SPACE_DB') || $space == 0;
    my %db;
    if (!tie %db, 'GDBM_File', $self->get_conf('AVG_SPACE_DB'), &GDBM_WRCREAT, 0664) {
	print "Can't open average space db " . $self->get_conf('AVG_SPACE_DB') . '\n';
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

sub log ($) {
    my $self = shift;

    my $logfile = $self->get('Log Stream');
    if (defined($logfile)) {
	print $logfile @_;
    }
}

sub log_info ($) {
    my $self = shift;

    $self->log("I: ", @_);
}

sub log_warning ($) {
    my $self = shift;

    $self->log("W: ", @_);
}

sub log_error ($) {
    my $self = shift;

    $self->log("E: ", @_);
}

sub log_section(\$$) {
    my $self = shift;
    my $section = shift;

    $self->log('╔', '═' x 78, '╗', "\n");
    $self->log('║', " $section ", ' ' x (80 - length($section) - 4), '║', "\n");
    $self->log('╚', '═' x 78, '╝', "\n\n");
}

sub log_subsection(\$$) {
    my $self = shift;
    my $section = shift;

    $self->log('┌', '─' x 78, '┐', "\n");
    $self->log('│', " $section ", ' ' x (80 - length($section) - 4), '│', "\n");
    $self->log('└', '─' x 78, '┘', "\n\n");
}

sub log_subsubsection(\$$) {
    my $self = shift;
    my $section = shift;

    $self->log('─' x 80, "\n");
    $self->log(" $section\n");
    $self->log('─' x (length($section) + 1), "\n\n");
}

sub log_sep(\$) {
    my $self = shift;

    $self->log('─' x 80, "\n");
}

1;
