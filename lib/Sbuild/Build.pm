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
use Sbuild qw(binNMU_version version_compare copy isin);
use Sbuild::Chroot qw();
use Sbuild::Log qw(open_pkg_log close_pkg_log);
use Sbuild::Sysconfig qw($arch $hostname $version);
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

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new ($$$);
sub get (\%$);
sub set (\%$$);
sub get_option (\%$);
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
    my $dsc = shift;
    my $options = shift;
    my $conf = shift;

    my $self  = {};
    bless($self);

    # DSC, package and version information:
    $self->set_dsc($dsc);

    # Do we need to download?
    $self->{'Download'} = 0;
    $self->{'Download'} = 1
	if (!($self->{'DSC Base'} =~ m/\.dsc$/));

    # Can sources be obtained?
    $self->{'Invalid Source'} = 0;
    $self->{'Invalid Source'} = 1
	if ((!$self->{'Download'} && ! -f $self->{'DSC'}) ||
	    ($self->{'Download'} &&
	     $self->{'DSC'} ne $self->{'Package_Version'}) ||
	    (!defined $self->{'Version'}));

    if ($conf::debug) {
	print STDERR "D: DSC = $self->{'DSC'}\n";
	print STDERR "D: Source Dir = $self->{'Source Dir'}\n";
	print STDERR "D: DSC Base = $self->{'DSC Base'}\n";
	print STDERR "D: DSC File = $self->{'DSC Base'}\n";
	print STDERR "D: DSC Dir = $self->{'DSC Base'}\n";
	print STDERR "D: Package_Version = $self->{'Package_Version'}\n";
	print STDERR "D: Package_SVersion = $self->{'Package_SVersion'}\n";
	print STDERR "D: Package = $self->{'Package'}\n";
	print STDERR "D: Version = $self->{'Version'}\n";
	print STDERR "D: SVersion = $self->{'SVersion'}\n";
	print STDERR "D: Download = $self->{'Download'}\n";
	print STDERR "D: Invalid Source = $self->{'Invalid Source'}\n";
    }

    $self->{'Options'} = $options;
    $self->{'Config'} = $conf;
    $self->{'Arch'} = $Sbuild::Sysconfig::arch;
    $self->{'Chroot Dir'} = '';
    $self->{'Chroot Build Dir'} = '';
    $self->{'Jobs File'} = 'build-progress';
    $self->{'Max Lock Trys'} = 120;
    $self->{'Lock Interval'} = 5;
    $self->{'Srcdep Lock Count'} = 0;
    $self->{'Pkg Status'} = '';
    $self->{'Pkg Start Time'} = 0;
    $self->{'Pkg End Time'} = 0;
    $self->{'Pkg Fail Stage'} = 0;
    $self->{'Build Start Time'} = 0;
    $self->{'Build End Time'} = 0;
    $self->{'This Time'} = 0;
    $self->{'This Space'} = 0;
    $self->{'This Watches'} = {};
    $self->{'Toolchain Packages'} = [];
    $self->{'Sub Task'} = 'initialisation';
    $self->{'Sub PID'} = undef;
    $self->{'Session'} = undef;
    $self->{'Additional Deps'} = [];
    $self->{'binNMU Name'} = undef;
    $self->{'Changes'} = {};
    $self->{'Dependencies'} = {};
    $self->{'Signing Options'} = {};
    $self->{'Have DSC Build Deps'} = [];

    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->{$key} = $value;
}

sub get_option (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->get('Options')->get($key);
}

sub get_conf (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->get('Config')->get($key);
}

sub set_conf (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->set('Config')->set($key,$value);
}

sub set_dsc (\$$) {
    my $self = shift;
    my $dsc = shift;

    $self->{'DSC'} = $dsc;
    $self->{'Source Dir'} = dirname($dsc);

    $self->{'DSC Base'} = basename($dsc);

    my $pkgv = $self->{'DSC Base'};
    $pkgv =~ s/\.dsc$//;
    $self->{'Package_Version'} = $pkgv;
    my ($pkg, $version) = split /_/, $self->{'Package_Version'};
    (my $sversion = $version) =~ s/^\d+://; # Strip epoch
    $self->{'Package_SVersion'} = "${pkg}_$sversion";

    $self->{'Package'} = $pkg;
    $self->{'Version'} = $version;
    $self->{'SVersion'} = $sversion;
    $self->{'DSC File'} = "${pkg}_${sversion}.dsc";
    $self->{'DSC Dir'} = "${pkg}-${sversion}";
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

    my $dir = $self->{'Source Dir'};
    my $dsc = $self->{'DSC File'};

    my ($files, @other_files, $dscarchs, @fetched);

    my $build_depends = "";
    my $build_depends_indep = "";
    my $build_conflicts = "";
    my $build_conflicts_indep = "";
    local( *F );

    $self->{'Have DSC Build Deps'} = [];

    if (!defined($self->{'Package'}) ||
	!defined($self->{'Version'}) ||
	!defined($self->{'Source Dir'})) {
	print main::PLOG "Invalid source: $self->{'DSC'}\n";
	return 0;
    }

    if (-f "$dir/$dsc" && !$self->{'Download'}) {
	print main::PLOG "$dsc exists in $dir; copying to chroot\n";
	my @cwd_files = $self->dsc_files("$dir/$dsc");
	foreach (@cwd_files) {
	    if (system ("cp '$_' '$self->{'Chroot Build Dir'}'")) {
		print main::PLOG "ERROR: Could not copy $_ to $self->{'Chroot Build Dir'} \n";
		return 0;
	    }
	    push(@fetched, "$self->{'Chroot Build Dir'}/" . basename($_));
	}
    } else {
	my %entries = ();
	my $retried = $self->get_conf('APT_UPDATE'); # Already updated if set
      retry:
	print main::PLOG "Checking available source versions...\n";
	my $command = $self->{'Session'}->get_apt_command("$conf::apt_cache", "-q showsrc $self->{'Package'}", $Sbuild::Conf::username, 0, '/');
	my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
	if (!$pid) {
	    print main::PLOG "Can't open pipe to $conf::apt_cache: $!\n";
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
		print main::PLOG "$conf::apt_cache returned no information about $self->{'Package'} source\n";
		print main::PLOG "Are there any deb-src lines in your /etc/apt/sources.list?\n";
		return 0;

	    }
	}
	close(PIPE);
	waitpid $pid, 0;
	if ($?) {
	    print main::PLOG "$conf::apt_cache failed\n";
	    return 0;
	}

	if (!defined($entries{"$self->{'Package'} $self->{'Version'}"})) {
	    if (!$retried) {
		# try to update apt's cache if nothing found
		$self->{'Session'}->run_apt_command("$conf::apt_get", "update >/dev/null", "root", 0, '/');
		$retried = 1;
		goto retry;
	    }
	    print main::PLOG "Can't find source for $self->{'Package_Version'}\n";
	    print main::PLOG "(only different version(s) ",
	    join( ", ", sort keys %entries), " found)\n"
		if %entries;
	    return 0;
	}

	print main::PLOG "Fetching source files...\n";
	foreach (@{$entries{"$self->{'Package'} $self->{'Version'}"}}) {
	    push(@fetched, "$self->{'Chroot Build Dir'}/$_");
	}

	my $command2 = $self->{'Session'}->get_apt_command("$conf::apt_get", "--only-source -q -d source $self->{'Package'}=$self->{'Version'} 2>&1 </dev/null", $Sbuild::Conf::username, 0, undef);
	if (!open( PIPE, "$command2 |" )) {
	    print main::PLOG "Can't open pipe to $conf::apt_get: $!\n";
	    return 0;
	}
	while( <PIPE> ) {
	    print main::PLOG $_;
	}
	close( PIPE );
	if ($?) {
	    print main::PLOG "$conf::apt_get for sources failed\n";
	    return 0;
	}
	$self->set_dsc((grep { /\.dsc$/ } @fetched)[0]);
    }

    if (!open( F, "<$self->{'Chroot Build Dir'}/$dsc" )) {
	print main::PLOG "Can't open $self->{'Chroot Build Dir'}/$dsc: $!\n";
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
    $files =~ /(\Q$self->{'Package'}\E.*orig.tar.gz)/mi and $orig = $1;

    if (!$dscarchs) {
	print main::PLOG "$dsc has no Architecture: field -- skipping arch check!\n";
    }
    else {
	if ($dscarchs ne "any" && $dscarchs !~ /\b$self->{'Arch'}\b/ &&
	    !($dscarchs eq "all" && $self->get_option('Build Arch All')) )  {
	    print main::PLOG "$dsc: $self->{'Arch'} not in arch list: $dscarchs -- ".
		"skipping\n";
	    $self->{'Pkg Fail Stage'} = "arch-check";
	    return 0;
	}
    }
    print "Arch check ok ($self->{'Arch'} included in $dscarchs)\n"
	if $conf::debug;

    @{$self->{'Have DSC Build Deps'}} =
	($build_depends, $build_depends_indep,
	 $build_conflicts,$build_conflicts_indep);
    $self->merge_pkg_build_deps($self->{'Package'},
				$build_depends, $build_depends_indep,
				$build_conflicts, $build_conflicts_indep);

    return 1;
}

sub build (\$$$) {
    my $self = shift;

    my $dscfile = $self->{'DSC File'};
    my $dscdir = $self->{'DSC Dir'};
    my $pkgv = $self->{'Package_Version'};

    my( $rv, $changes );
    local( *PIPE, *F, *F2 );

    $pkgv = $self->fixup_pkgv($pkgv);
    print main::PLOG "-"x78, "\n";
    $self->{'This Space'} = 0;
    $pkgv =~ /^([a-zA-Z\d.+-]+)_([a-zA-Z\d:.+~-]+)/;
    # Note, this version contains ".dsc".
    my ($pkg, $version) = ($1,$2);

    my $tmpunpackdir = $dscdir;
    $tmpunpackdir =~ s/-.*$/.orig.tmp-nest/;
    $tmpunpackdir =~ s/_/-/;
    $tmpunpackdir = "$self->{'Chroot Build Dir'}/$tmpunpackdir";

    if (-d "$self->{'Chroot Build Dir'}/$dscdir" && -l "$self->{'Chroot Build Dir'}/$dscdir") {
	# if the package dir already exists but is a symlink, complain
	print main::PLOG "Cannot unpack source: a symlink to a directory with the\n",
	"same name already exists.\n";
	return 0;
    }
    if (! -d "$self->{'Chroot Build Dir'}/$dscdir") {
	$self->{'Pkg Fail Stage'} = "unpack";
	# dpkg-source refuses to remove the remanants of an aborted
	# dpkg-source extraction, so we will if necessary.
	if (-d $tmpunpackdir) {
	    system ("rm -fr '$tmpunpackdir'");
	}
	$self->{'Sub Task'} = "dpkg-source";
	$self->{'Session'}->run_command("$conf::dpkg_source -sn -x $dscfile $dscdir 2>&1", $Sbuild::Conf::username, 1, 0, undef);
	if ($?) {
	    print main::PLOG "FAILED [dpkg-source died]\n";

	    system ("rm -fr '$tmpunpackdir'") if -d $tmpunpackdir;
	    return 0;
	}
	$dscdir = "$self->{'Chroot Build Dir'}/$dscdir";

	if (system( "chmod -R g-s,go+rX $dscdir" ) != 0) {
	    print main::PLOG "chmod -R g-s,go+rX $dscdir failed.\n";
	    return 0;
	}
    }
    else {
	$dscdir = "$self->{'Chroot Build Dir'}/$dscdir";

	$self->{'Pkg Fail Stage'} = "check-unpacked-version";
	# check if the unpacked tree is really the version we need
	$self->{'Sub PID'} = open( PIPE, "-|" );
	if (!defined $self->{'Sub PID'}) {
	    print main::PLOG "Can't spawn dpkg-parsechangelog: $!\n";
	    return 0;
	}
	if ($self->{'Sub PID'} == 0) {
	    $dscdir = $self->{'Session'}->strip_chroot_path($dscdir);
	    $self->{'Session'}->exec_command("cd '$dscdir' && dpkg-parsechangelog 2>&1", $Sbuild::Conf::username, 1, 0, undef);
	}
	$self->{'Sub Task'} = "dpkg-parsechangelog";

	my $clog = "";
	while( <PIPE> ) {
	    $clog .= $_;
	}
	close( PIPE );
	undef $self->{'Sub PID'};
	if ($?) {
	    print main::PLOG "FAILED [dpkg-parsechangelog died]\n";
	    return 0;
	}
	if ($clog !~ /^Version:\s*(.+)\s*$/mi) {
	    print main::PLOG "dpkg-parsechangelog didn't print Version:\n";
	    return 0;
	}
	my $tree_version = $1;
	my $cmp_version = ($self->get_option('binNMU') && -f "$dscdir/debian/.sbuild-binNMU-done") ?
	    binNMU_version($version,$self->get_option('binNMU Version')) : $version;
	if ($tree_version ne $cmp_version) {
	    print main::PLOG "The unpacked source tree $dscdir is version ".
		"$tree_version, not wanted $cmp_version!\n";
	    return 0;
	}
    }

    $self->{'Pkg Fail Stage'} = "check-space";
    my $current_usage = `/usr/bin/du -k -s "$dscdir"`;
    $current_usage =~ /^(\d+)/;
    $current_usage = $1;
    if ($current_usage) {
	my $free = $self->df($dscdir);
	if ($free < 2*$current_usage) {
	    print main::PLOG "Disk space is propably not enough for building.\n".
		"(Source needs $current_usage KB, free are $free KB.)\n";
	    # TODO: Only purge in a single place.
	    print main::PLOG "Purging $self->{'Chroot Build Dir'}\n";
	    $self->{'Session'}->run_command("rm -rf '$self->{'Chroot Build Dir'}'", "root", 1, 0, '/');
	    return 0;
	}
    }

    $self->{'Pkg Fail Stage'} = "hack-binNMU";
    if ($self->get_option('binNMU') && ! -f "$dscdir/debian/.sbuild-binNMU-done") {
	if (open( F, "<$dscdir/debian/changelog" )) {
	    my($firstline, $text);
	    $firstline = "";
	    $firstline = <F> while $firstline =~ /^$/;
	    { local($/); undef $/; $text = <F>; }
	    close( F );
	    $firstline =~ /^(\S+)\s+\((\S+)\)\s+([^;]+)\s*;\s*urgency=(\S+)\s*$/;
	    my ($name, $version, $dists, $urgent) = ($1, $2, $3, $4);
	    my $NMUversion = binNMU_version($version,$self->get_option('binNMU Version'));
	    chomp( my $date = `date -R` );
	    if (!open( F, ">$dscdir/debian/changelog" )) {
		print main::PLOG "Can't open debian/changelog for binNMU hack: $!\n";
		return 0;
	    }
	    $dists = $self->get_option('Distribution');
	    print F "$name ($NMUversion) $dists; urgency=low\n\n";
	    print F "  * Binary-only non-maintainer upload for $self->{'Arch'}; ",
	    "no source changes.\n";
	    print F "  * ", join( "    ", split( "\n", $self->get_option('binNMU') )), "\n\n";
	    print F " -- $conf::maintainer_name  $date\n\n";

	    print F $firstline, $text;
	    close( F );
	    system "touch '$dscdir/debian/.sbuild-binNMU-done'";
	    print main::PLOG "*** Created changelog entry for bin-NMU version $NMUversion\n";
	}
	else {
	    print main::PLOG "Can't open debian/changelog -- no binNMU hack!\n";
	}
    }

    if (-f "$dscdir/debian/files") {
	local( *FILES );
	my @lines;
	open( FILES, "<$dscdir/debian/files" );
	chomp( @lines = <FILES> );
	close( FILES );
	@lines = map { my $ind = 68-length($_);
		       $ind = 0 if $ind < 0;
		       "│ $_".(" " x $ind)." │\n"; } @lines;

	print main::PLOG <<"EOF";

┌──────────────────────────────────────────────────────────────────────┐
│ sbuild Warning:                                                      │
│ ---------------                                                      │
│ After unpacking, there exists a file debian/files with the contents: │
│                                                                      │
EOF

	print main::PLOG @lines;
	print main::PLOG <<"EOF";
│                                                                      │
│ This should be reported as a bug.                                    │
│ The file has been removed to avoid dpkg-genchanges errors.           │
└──────────────────────────────────────────────────────────────────────┘

EOF

	unlink "$dscdir/debian/files";
    }

    $self->{'Build Start Time'} = time;
    $self->{'Pkg Fail Stage'} = "build";
    $self->{'Sub PID'} = open( PIPE, "-|" );
    if (!defined $self->{'Sub PID'}) {
	print main::PLOG "Can't spawn dpkg-buildpackage: $!\n";
	return 0;
    }
    if ($self->{'Sub PID'} == 0) {
	open( STDIN, "</dev/null" );
	my $binopt = $self->get_option('Build Source') ?
	    $conf::force_orig_source ? "-sa" : "" :
	    $self->get_option('Build Arch All') ?	"-b" : "-B";

	my $bdir = $self->{'Session'}->strip_chroot_path($dscdir);
	if (-f "$self->{'Chroot Dir'}/etc/ld.so.conf" &&
	    ! -r "$self->{'Chroot Dir'}/etc/ld.so.conf") {
	    $self->{'Session'}->run_command("chmod a+r /etc/ld.so.conf", "root", 1, 0, '/');
	    print main::PLOG "ld.so.conf was not readable! Fixed.\n";
	}
	my $buildcmd = "cd $bdir && PATH=$conf::path ".
	    (defined($self->get_option('LD_LIBRARY_PATH')) ?
	     "LD_LIBRARY_PATH=".$self->get_option('LD_LIBRARY_PATH')." " : "").
	     "exec $conf::build_env_cmnd dpkg-buildpackage $conf::pgp_options ".
	     "$binopt " . $self->get_option('Signing Options') .
	     " -r$conf::fakeroot 2>&1";
	$self->{'Session'}->exec_command($buildcmd, $Sbuild::Conf::username, 1, 0, undef);
    }
    $self->{'Sub Task'} = "dpkg-buildpackage";

    # We must send the signal as root, because some subprocesses of
    # dpkg-buildpackage could run as root. So we have to use a shell
    # command to send the signal... but /bin/kill can't send to
    # process groups :-( So start another Perl :-)
    my $timeout = $conf::individual_stalled_pkg_timeout{$pkg} ||
	$conf::stalled_pkg_timeout;
    $timeout *= 60;
    my $timed_out = 0;
    my(@timeout_times, @timeout_sigs, $last_time);

    local $SIG{'ALRM'} = sub {
	my $signal = ($timed_out > 0) ? "KILL" : "TERM";
	$self->{'Session'}->run_command("perl -e \"kill( \\\"$signal\\\", $self->{'Sub PID'} )\"", "root", 1, 0, '/');
	$timeout_times[$timed_out] = time - $last_time;
	$timeout_sigs[$timed_out] = $signal;
	$timed_out++;
	$timeout = 5*60; # only wait 5 minutes until next signal
    };

    alarm( $timeout );
    while( <PIPE> ) {
	alarm( $timeout );
	$last_time = time;
	print main::PLOG $_;
    }
    close( PIPE );
    undef $self->{'Sub PID'};
    alarm( 0 );
    $rv = $?;

    my $i;
    for( $i = 0; $i < $timed_out; ++$i ) {
	print main::PLOG "Build killed with signal ", $timeout_sigs[$i],
	           " after ", int($timeout_times[$i]/60),
	           " minutes of inactivity\n";
    }
    $self->{'Build End Time'} = time;
    $self->{'Pkg End Time'} = time;
    $self->write_stats('build-time',
		       $self->{'Build End Time'}-$self->{'Build Start Time'});
    my $date = strftime("%Y%m%d-%H%M",localtime($self->{'Build End Time'}));
    print main::PLOG "*"x78, "\n";
    print main::PLOG "Build finished at $date\n";

    my @space_files = ("$dscdir");
    if ($rv) {
	print main::PLOG "FAILED [dpkg-buildpackage died]\n";
    }
    else {
	if (-r "$dscdir/debian/files" && $self->{'Chroot Build Dir'}) {
	    my @files = $self->debian_files_list("$dscdir/debian/files");

	    foreach (@files) {
		if (! -f "$self->{'Chroot Build Dir'}/$_") {
		    print main::PLOG "ERROR: Package claims to have built ".basename($_).", but did not.  This is a bug in the packaging.\n";
		    next;
		}
		if (/_all.u?deb$/ and not $self->get_option('Build Arch All')) {
		    print main::PLOG "ERROR: Package builds ".basename($_)." when binary-indep target is not called.  This is a bug in the packaging.\n";
		    unlink("$self->{'Chroot Build Dir'}/$_");
		    next;
		}
	    }
	}

	$changes = "${pkg}_".
	    ($self->get_option('binNMU') ?
	     binNMU_version($self->{'SVersion'},
			    $self->get_option('binNMU Version')) :
	     $self->{'SVersion'}).
	    "_$self->{'Arch'}.changes";
	my @cfiles;
	if (-r "$self->{'Chroot Build Dir'}/$changes") {
	    my(@do_dists, @saved_dists);
	    print main::PLOG "\n$changes:\n";
	    open( F, "<$self->{'Chroot Build Dir'}/$changes" );
	    if (open( F2, ">$changes.new" )) {
		while( <F> ) {
		    if (/^Distribution:\s*(.*)\s*$/ and $self->get_option('Override Distribution')) {
			print main::PLOG "Distribution: " . $self->get_option('Distribution') . "\n";
			print F2 "Distribution: " . $self->get_option('Distribution') . "\n";
		    }
		    else {
			print F2 $_;
			while (length $_ > 989)
			{
			    my $index = rindex($_,' ',989);
			    print main::PLOG substr ($_,0,$index) . "\n";
			    $_ = '        ' . substr ($_,$index+1);
			}
			print main::PLOG $_;
			if (/^ [a-z0-9]{32}/) {
			    push(@cfiles, (split( /\s+/, $_ ))[5] );
			}
		    }
		}
		close( F2 );
		rename( "$changes.new", "$changes" )
		    or print main::PLOG "$changes.new could not be renamed ".
		    "to $changes: $!\n";
		unlink( "$self->{'Chroot Build Dir'}/$changes" )
		    if $self->{'Chroot Build Dir'};
	    }
	    else {
		print main::PLOG "Cannot create $changes.new: $!\n";
		print main::PLOG "Distribution field may be wrong!!!\n";
		if ($self->{'Chroot Build Dir'}) {
		    system "mv", "-f", "$self->{'Chroot Build Dir'}/$changes", "."
			and print main::PLOG "ERROR: Could not move ".basename($_)." to .\n";
		}
	    }
	    close( F );
	}
	else {
	    print main::PLOG "Can't find $changes -- can't dump info\n";
	}

	my @debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$self->{'Chroot Build Dir'}/$_";
	    next if $deb !~ /($self->{'Arch'}|all)\.[\w\d.-]*$/;

	    print main::PLOG "\n$deb:\n";
	    if (!open( PIPE, "dpkg --info $deb 2>&1 |" )) {
		print main::PLOG "Can't spawn dpkg: $! -- can't dump info\n";
	    }
	    else {
		print main::PLOG $_ while( <PIPE> );
		close( PIPE );
	    }
	}

	@debcfiles = @cfiles;
	foreach (@debcfiles) {
	    my $deb = "$self->{'Chroot Build Dir'}/$_";
	    next if $deb !~ /($self->{'Arch'}|all)\.[\w\d.-]*$/;

	    print main::PLOG "\n$deb:\n";
	    if (!open( PIPE, "dpkg --contents $deb 2>&1 |" )) {
		print main::PLOG "Can't spawn dpkg: $! -- can't dump info\n";
	    }
	    else {
		print main::PLOG $_ while( <PIPE> );
		close( PIPE );
	    }
	}

	foreach (@cfiles) {
	    push( @space_files, $_ );
	    system "mv", "-f", "$self->{'Chroot Build Dir'}/$_", "."
		and print main::PLOG "ERROR: Could not move $_ to .\n";
	}
	print main::PLOG "\n";
	print main::PLOG "*"x78, "\n";
	print main::PLOG "Built successfully\n";
    }

    $self->check_watches();
    $self->check_space(@space_files);

    if ($conf::purge_build_directory eq "always" ||
	($conf::purge_build_directory eq "successful" && $rv == 0)) {
	print main::PLOG "Purging $self->{'Chroot Build Dir'}\n";
	my $bdir = $self->{'Session'}->strip_chroot_path($self->{'Chroot Build Dir'});
	$self->{'Session'}->run_command("rm -rf '$bdir'", "root", 1, 0, '/');
    }

    print main::PLOG "-"x78, "\n";
    return $rv == 0 ? 1 : 0;
}

sub analyze_fail_stage (\$) {
    my $self = shift;

    my $pkgv = $self->{'Package_Version'};

    return if $self->{'Pkg Status'} ne "failed";
    return if !$self->get_option('Auto Giveback');
    if (isin( $self->{'Pkg Fail Stage'},
	      qw(find-dsc fetch-src unpack-check check-space install-deps-env))) {
	$self->{'Pkg Status'} = "given-back";
	print main::PLOG "Giving back package $pkgv after failure in ".
	    "$self->{'Pkg Fail Stage'} stage.\n";
	my $cmd = "";
	$cmd = "ssh -l " . $self->get_option('Auto Giveback User') . " " .
	    $self->get_option('Auto Giveback Host') . " "
	    if $self->get_option('Auto Giveback Host');
	$cmd .= "-S " . $self->get_option('Auto Giveback Socket') . " "
	    if $self->get_option('Auto Giveback Socket');
	$cmd .= "wanna-build --give-back --no-down-propagation ".
	    "--dist=" . $self->get_option('Distribution') . " ";
	$cmd .= "--database=" . $self->get_option('WannaBuild Database') . " "
	    if $self->get_option('WannaBuild Database');
	$cmd .= "--user=" . $self->get_option('Auto Giveback WannaBuild User') . " "
	    if $self->get_option('Auto Giveback WannaBuild User');
	$cmd .= "$pkgv";
	system $cmd;
	if ($?) {
	    print main::PLOG "wanna-build failed with status $?\n";
	}
	else {
	    $self->add_givenback($pkgv, time );
	    $self->write_stats('give-back', 1);
	}
    }
}

sub install_deps (\$) {
    my $self = shift;

    my $pkg = $self->{'Package'};
    my( @positive, @negative, @instd, @rmvd );

    my $dep = [];
    if (exists $self->{'Dependencies'}->{$pkg}) {
	$dep = $self->{'Dependencies'}->{$pkg};
    }
    if ($conf::debug) {
	print "Source dependencies of $pkg: ", $self->format_deps(@$dep), "\n";
    }

  repeat:
    $self->lock_file($self->{'Session'}->{'Install Lock'}, 1);

    print "Filtering dependencies\n" if $conf::debug;
    if (!$self->filter_dependencies($dep, \@positive, \@negative )) {
	print main::PLOG "Package installation not possible\n";
	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	return 0;
    }

    print main::PLOG "Checking for source dependency conflicts...\n";
    if (!$self->run_apt("-s", \@instd, \@rmvd, @positive)) {
	print main::PLOG "Test what should be installed failed.\n";
	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	return 0;
    }
    # add negative deps as to be removed for checking srcdep conflicts
    push( @rmvd, @negative );
    my @confl;
    if (@confl = $self->check_srcdep_conflicts(\@instd, \@rmvd)) {
	print main::PLOG "Waiting for job(s) @confl to finish\n";

	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	$self->wait_for_srcdep_conflicts(@confl);
	goto repeat;
    }

    $self->write_srcdep_lock_file($dep);

    my $install_start_time = time;
    print "Installing positive dependencies: @positive\n" if $conf::debug;
    if (!$self->run_apt("-y", \@instd, \@rmvd, @positive)) {
	print main::PLOG "Package installation failed\n";
	# try to reinstall removed packages
	print main::PLOG "Trying to reinstall removed packages:\n";
	print "Reinstalling removed packages: @rmvd\n" if $conf::debug;
	my (@instd2, @rmvd2);
	print main::PLOG "Failed to reinstall removed packages!\n"
	    if !$self->run_apt("-y", \@instd2, \@rmvd2, @rmvd);
	print "Installed were: @instd2\n" if $conf::debug;
	print "Removed were: @rmvd2\n" if $conf::debug;
	# remove additional packages
	print main::PLOG "Trying to uninstall newly installed packages:\n";
	$self->uninstall_debs($self->{'Chroot Dir'} ? "purge" : "remove",
			      @instd);
	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);

    print "Removing negative dependencies: @negative\n" if $conf::debug;
    if (!$self->uninstall_debs($self->{'Chroot Dir'} ? "purge" : "remove",
			       @negative)) {
	print main::PLOG "Removal of packages failed\n";
	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	return 0;
    }
    $self->set_removed(@negative);
    my $install_stop_time = time;
    $self->write_stats('install-download-time',
		       $install_stop_time - $install_start_time);

    my $fail = $self->check_dependencies($dep);
    if ($fail) {
	print main::PLOG "After installing, the following source dependencies are ".
	    "still unsatisfied:\n$fail\n";
	$self->unlock_file($self->{'Session'}->{'Install Lock'});
	return 0;
    }

    local (*F);

    my $command = $self->{'Session'}->get_command("$conf::dpkg --set-selections", "root", 1, 0, '/');

    my $success = open( F, "| $command");

    if ($success) {
	foreach my $tpkg (@instd) {
	    print F $tpkg . " purge\n";
	}
	close( F );
	if ($?) {
	    print main::PLOG "$conf::dpkg --set-selections failed\n";
	}
    }

    $self->unlock_file($self->{'Session'}->{'Install Lock'});

    $self->prepare_watches($dep, @instd );
    return 1;
}

sub wait_for_srcdep_conflicts (\$@) {
    my $self = shift;
    my @confl = @_;

    for(;;) {
	sleep( $conf::srcdep_lock_wait*60 );
	my $allgone = 1;
	for (@confl) {
	    /^(\d+)-(\d+)$/;
	    my $pid = $1;
	    if (-f "$self->{'Session'}->{'Srcdep Lock Dir'}/$_") {
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    print main::PLOG "Ignoring stale src-dep lock $_\n";
		    unlink( "$self->{'Session'}->{'Srcdep Lock Dir'}/$_" ) or
			print main::PLOG "Cannot remove $self->{'Session'}->{'Srcdep Lock Dir'}/$_: $!\n";
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

    $self->lock_file($self->{'Session'}->{'Install Lock'}, 1);

    @pkgs = keys %{$self->{'Changes'}->{'removed'}};
    print "Reinstalling removed packages: @pkgs\n" if $conf::debug;
    print main::PLOG "Failed to reinstall removed packages!\n"
	if !$self->run_apt("-y", \@instd, \@rmvd, @pkgs);
    print "Installed were: @instd\n" if $conf::debug;
    print "Removed were: @rmvd\n" if $conf::debug;
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->{'Changes'}->{'installed'}};
    print "Removing installed packages: @pkgs\n" if $conf::debug;
    print main::PLOG "Failed to remove installed packages!\n"
	if !$self->uninstall_debs("purge", @pkgs);
    $self->unset_installed(@pkgs);

    $self->unlock_file($self->{'Session'}->{'Install Lock'});
}

sub uninstall_debs (\$$@) {
    my $self = shift;
    my $mode = shift;
    local (*PIPE);
    local (%ENV) = %ENV; # make local environment hardwire frontend
			 # for debconf to non-interactive
    $ENV{'DEBIAN_FRONTEND'} = "noninteractive";

    return 1 if !@_;
    print "Uninstalling packages: @_\n" if $conf::debug;

    my $command = $self->{'Session'}->get_command("$conf::dpkg --$mode @_ 2>&1 </dev/null", "root", 1, 0, '/');
  repeat:
    my $output;
    my $remove_start_time = time;

    if (!open( PIPE, "$command |")) {
	print main::PLOG "Can't open pipe to dpkg: $!\n";
	return 0;
    }
    while ( <PIPE> ) {
	$output .= $_;
	print main::PLOG $_;
    }
    close( PIPE );

    if ($output =~ /status database area is locked/mi) {
	print main::PLOG "Another dpkg is running -- retrying later\n";
	$output = "";
	sleep( 2*60 );
	goto repeat;
    }
    my $remove_end_time = time;
    $self->write_stats('remove-time',
		       $remove_end_time - $remove_start_time);
    print main::PLOG "dpkg run to remove packages (@_) failed!\n" if $?;
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
	$self->{'Session'}->get_apt_command("$conf::apt_get", "--purge ".
				  "-o DPkg::Options::=--force-confold ".
				  "-q $mode install @to_install ".
				  "2>&1 </dev/null", "root", 0, '/');

    if (!open( PIPE, "$command |" )) {
	print main::PLOG "Can't open pipe to apt-get: $!\n";
	return 0;
    }
    while( <PIPE> ) {
	$msgs .= $_;
	print main::PLOG $_ if $mode ne "-s" || $conf::debug;
    }
    close( PIPE );
    $status = $?;

    if ($status != 0 && $msgs =~ /^E: Packages file \S+ (has changed|is out of sync)/mi) {
	my $command =
	    $self->{'Session'}->get_apt_command("$conf::apt_get", "-q update 2>&1",
				      "root", 1, '/');
	if (!open( PIPE, "$command |" )) {
	    print main::PLOG "Can't open pipe to apt-get: $!\n";
	    return 0;
	}

	$msgs = "";
	while( <PIPE> ) {
	    $msgs .= $_;
	    print main::PLOG $_;
	}
	close( PIPE );
	print main::PLOG "apt-get update failed\n" if $?;
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
	print main::PLOG "$to_replace is a virtual package provided by: @providers\n";
	my $selected;
	if (@providers == 1) {
	    $selected = $providers[0];
	    print main::PLOG "Using $selected (only possibility)\n";
	}
	elsif (exists $self->get_conf('ALTERNATIVES')->{$to_replace}) {
	    $selected = $self->get_conf('ALTERNATIVES')->{$to_replace};
	    print main::PLOG "Using $selected (selected in sbuildrc)\n";
	}
	else {
	    $selected = $providers[0];
	    print main::PLOG "Using $selected (no default, using first one)\n";
	}

	@to_install = grep { $_ ne $to_replace } @to_install;
	push( @to_install, $selected );

	goto repeat;
    }

    if ($status != 0 && ($msgs =~ /^E: Could( not get lock|n.t lock)/mi ||
			 $msgs =~ /^dpkg: status database area is locked/mi)) {
	print main::PLOG "Another apt-get or dpkg is running -- retrying later\n";
	sleep( 2*60 );
	goto repeat;
    }

    # check for errors that are probably caused by something broken in
    # the build environment, and give back the packages.
    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem./mi) ||
	 ($msgs =~ /^dpkg: parse error, in file `\/.+\/var\/lib\/dpkg\/(?:available|status)' near line/mi) ||
	 ($msgs =~ /^E: Unmet dependencies. Try 'apt-get -f install' with no packages \(or specify a solution\)\./mi))) {
	print main::PLOG "Build environment unusable, giving back\n";
	$self->{'Pkg Fail Stage'} = "install-deps-env";
    }

    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^E: Unable to fetch some archives, maybe run apt-get update or try with/mi))) {
	print main::PLOG "Unable to fetch build-depends\n";
	$self->{'Pkg Fail Stage'} = "install-deps-env";
    }

    if ($status != 0 && $mode ne "-s" &&
	(($msgs =~ /^W: Couldn't stat source package list /mi))) {
	print main::PLOG "Missing a packages file (mismatch with Release.gpg?), giving back.\n";
	$self->{'Pkg Fail Stage'} = "install-deps-env";
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

    print main::PLOG "apt-get failed.\n" if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub filter_dependencies (\$\@\@\@) {
    my $self = shift;
    my $dependencies = shift;
    my $pos_list = shift;
    my $neg_list = shift;
    my($dep, $d, $name, %names);

    print main::PLOG "Checking for already installed source dependencies...\n";

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
		    print "$name: neg dep, installed, not versioned or ",
		          "version relation satisfied --> remove\n"
			      if $conf::debug;
		    print main::PLOG "$name: installed (negative dependency)";
		    print main::PLOG " (bad version $ivers $rel $vers)"
			if $rel;
		    print main::PLOG "\n";
		    push( @$neg_list, $name );
		}
		else {
		    print main::PLOG "$name: installed (negative dependency)",
		    "(but version ok $ivers $rel $vers)\n";
		}
	    }
	    else {
		print "$name: neg dep, not installed\n" if $conf::debug;
		print main::PLOG "$name: already deinstalled\n";
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
		print "$name: pos dep, not installed\n" if $conf::debug;
		print main::PLOG "$name: missing\n";
		if ($self->get_conf('APT_POLICY') && $rel) {
		    if (!version_compare($policy{$name}->{defversion}, $rel, $vers)) {
			print main::PLOG "Default version of $name not sufficient, ";
			foreach my $cvers (@{$policy{$name}->{versions}}) {
			    if (version_compare($cvers, $rel, $vers)) {
				print main::PLOG "using version $cvers\n";
				$installable = $name . "=" . $cvers if !$installable;
				last;
			    }
			}
			if(!$installable) {
			    print main::PLOG "no suitable version found. Skipping for now, maybe there are alternatives.\n";
			    next if ($conf::check_depends_algorithm eq "alternatives");
			}
		    } else {
			print main::PLOG "Using default version " . $policy{$name}->{defversion} . "\n";
		    }
		}
		$installable = $name if !$installable;
		next;
	    }
	    my $ivers = $stat->{'Version'};
	    if (!$rel || version_compare( $ivers, $rel, $vers )) {
		print "$name: pos dep, installed, no versioned dep or ",
		"version ok\n" if $conf::debug;
		print main::PLOG "$name: already installed ($ivers";
		print main::PLOG " $rel $vers is satisfied"
		    if $rel;
		print main::PLOG ")\n";
		$is_satisfied = 1;
		last;
	    }
	    print "$name: vers dep, installed $ivers ! $rel $vers\n"
		if $conf::debug;
	    print main::PLOG "$name: non-matching version installed ",
	    "($ivers ! $rel $vers)\n";
	    if ($rel =~ /^</ ||
		($rel eq '=' && version_compare($ivers, '>>', $vers))) {
		print "$name: would be a downgrade!\n" if $conf::debug;
		print main::PLOG "$name: would have to downgrade!\n";
	    }
	    else {
		if ($self->get_conf('APT_POLICY') &&
		    !version_compare($policy{$name}->{defversion}, $rel, $vers)) {
		    print main::PLOG "Default version of $name not sufficient, ";
		    foreach my $cvers (@{$policy{$name}->{versions}}) {
			if(version_compare($cvers, $rel, $vers)) {
			    print main::PLOG "using version $cvers\n";
			    $upgradeable = $name if ! $upgradeable;
			    last;
			}
		    }
		    print main::PLOG "no suitable alternative found. I probably should dep-wait this one.\n" if !$upgradeable;
		    return 0;
		} else {
		    print main::PLOG "Using default version " . $policy{$name}->{defversion} . "\n";
		}
		$upgradeable = $name if !$upgradeable;
	    }
	}
	if (!$is_satisfied) {
	    if ($upgradeable) {
		print "using $upgradeable for upgrade\n" if $conf::debug;
		push( @$pos_list, $upgradeable );
	    }
	    elsif ($installable) {
		print "using $installable for install\n" if $conf::debug;
		push( @$pos_list, $installable );
	    }
	    else {
		print main::PLOG "This dependency could not be satisfied. Possible reasons:\n";
		print main::PLOG "* The package has a versioned dependency that is not yet available.\n";
		print main::PLOG "* The package has a versioned dependency on a package version that is\n  older than the currently-installed package. Downgrades are not implemented.\n";
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

    print main::PLOG "Checking correctness of source dependencies...\n";

    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
    }
    foreach $name (@{$self->{'Toolchain Packages'}}) {
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
    if (!$fail && @{$self->{'Toolchain Packages'}}) {
	my ($sysname, $nodename, $release, $version, $machine) = uname();
	print main::PLOG "Kernel: $sysname $release $self->{'Arch'} ($machine)\n";
	print main::PLOG "Toolchain package versions:";
	foreach $name (@{$self->{'Toolchain Packages'}}) {
	    if (defined($status->{$name}->{'Version'})) {
		print main::PLOG ' ' . $name . '_' . $status->{$name}->{'Version'};
	    } else {
		print main::PLOG ' ' . $name . '_' . ' =*=NOT INSTALLED=*=';

	    }
	}
	print main::PLOG "\n";
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
	$self->{'Session'}->get_apt_command("$conf::apt_cache",
				  "policy @interest",
				  $Sbuild::Conf::username, 0, '/');

    my $pid = open3(\*main::DEVNULL, \*APTCACHE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die "Cannot start $conf::apt_cache $!\n";
    }
    while(<APTCACHE>) {
	$package=$1 if /^([0-9a-z+.-]+):$/;
	$packages{$package}->{curversion}=$1 if /^ {2}Installed: ([0-9a-zA-Z-.:~+]*)$/;
	$packages{$package}->{defversion}=$1 if /^ {2}Candidate: ([0-9a-zA-Z-.:~+]*)$/;
	push @{$packages{$package}->{versions}}, "$2" if /^ (\*{3}| {3}) ([0-9a-zA-Z-.:~+]*) 0$/;
    }
    close(APTCACHE);
    waitpid $pid, 0;
    die "$conf::apt_cache exit status $?\n" if $?;

    return %packages;
}

sub get_dpkg_status (\$@) {
    my $self = shift;
    my @interest = @_;
    my %result;
    local( *STATUS );

    return () if !@_;
    print "Requesting dpkg status for packages: @interest\n"
	if $conf::debug;
    if (!open( STATUS, "<$self->{'Chroot Dir'}/var/lib/dpkg/status" )) {
	print main::PLOG "Can't open $self->{'Chroot Dir'}/var/lib/dpkg/status: $!\n";
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
	    print main::PLOG "sbuild: parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: ",
	    "no Package: field\n";
	    next;
	}
	if (defined($version)) {
	    print "$pkg ($version) status: $status\n" if $conf::debug >= 2;
	} else {
	    print "$pkg status: $status\n" if $conf::debug >= 2;
	}
	if (!$status) {
	    print main::PLOG "sbuild: parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: ",
	    "no Status: field for package $pkg\n";
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    print main::PLOG "sbuild: parse error in $self->{'Chroot Dir'}/var/lib/dpkg/status: ",
	    "no Version: field for package $pkg\n";
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

    print main::PLOG "** Using build dependencies supplied by package:\n";
    print main::PLOG "Build-Depends: $depends\n" if $depends;
    print main::PLOG "Build-Depends-Indep: $dependsi\n" if $dependsi;
    print main::PLOG "Build-Conflicts: $conflicts\n" if $conflicts;
    print main::PLOG "Build-Conflicts-Indep: $conflictsi\n" if $conflictsi;

    $self->{'Dependencies'}->{$pkg} = []
	if (!defined $self->{'Dependencies'}->{$pkg});
    my $old_deps = copy($self->{'Dependencies'}->{$pkg});

    # Add gcc-snapshot as an override.
    if ( $self->get_option('GCC Snapshot') ) {
	$dep->{'Package'} = "gcc-snapshot";
	$dep->{'Override'} = 1;
	push( @{$self->{'Dependencies'}->{$pkg}}, $dep );
    }

    foreach $dep (@{$self->{'Dependencies'}->{$pkg}}) {
	if ($dep->{'Override'}) {
	    print main::PLOG "Added override: ",
	    (map { ($_->{'Neg'} ? "!" : "") .
		       $_->{'Package'} .
		       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"") }
	     scalar($dep), @{$dep->{'Alternatives'}}), "\n";
	    push( @l, $dep );
	}
    }

    $conflicts = join( ", ", map { "!$_" } split( /\s*,\s*/, $conflicts ));
    $conflictsi = join( ", ", map { "!$_" } split( /\s*,\s*/, $conflictsi ));

    my $deps = $depends . ", " . $conflicts;
    $deps .= ", " . $dependsi . ", " . $conflictsi if $self->get_option('Build Arch All');
    @{$self->{'Dependencies'}->{$pkg}} = @l;
    print "Merging pkg deps: $deps\n" if $conf::debug;
    $self->parse_one_srcdep($pkg, $deps);

    my $missing = ($self->cmp_dep_lists($old_deps,
					$self->{'Dependencies'}->{$pkg}))[1];

    # read list of build-essential packages (if not yet done) and
    # expand their dependencies (those are implicitly essential)
    if (!defined($self->{'Dependencies'}->{'ESSENTIAL'})) {
	my $ess = $self->read_build_essential();
	$self->parse_one_srcdep('ESSENTIAL', $ess);
    }
    my ($exp_essential, $exp_pkgdeps, $filt_essential, $filt_pkgdeps);
    $exp_essential = $self->expand_dependencies($self->{'Dependencies'}->{'ESSENTIAL'});
    print "Dependency-expanded build essential packages:\n",
    $self->format_deps(@$exp_essential), "\n" if $conf::debug;

    # populate Toolchain Packages from toolchain_regexes and
    # build-essential packages.
    $self->{'Toolchain Packages'} = [];
    foreach my $tpkg (@$exp_essential) {
        foreach my $regex (@conf::toolchain_regex) {
	    push @{$self->{'Toolchain Packages'}},$tpkg->{'Package'}
	        if $tpkg->{'Package'} =~ m,^$regex,;
	}
    }

    return if !@$missing;

    # remove missing essential deps
    ($filt_essential, $missing) = $self->cmp_dep_lists($missing,
                                                       $exp_essential);
    print main::PLOG "** Filtered missing build-essential deps:\n",
	       $self->format_deps(@$filt_essential), "\n"
	           if @$filt_essential;

    # if some build deps are virtual packages, replace them by an
    # alternative over all providing packages
    $exp_pkgdeps = $self->expand_virtuals($self->{'Dependencies'}->{$pkg} );
    print "Provided-expanded build deps:\n",
	  $self->format_deps(@$exp_pkgdeps), "\n" if $conf::debug;

    # now expand dependencies of package build deps
    $exp_pkgdeps = $self->expand_dependencies($exp_pkgdeps);
    print "Dependency-expanded build deps:\n",
	  $self->format_deps(@$exp_pkgdeps), "\n" if $conf::debug;
    # NOTE: Was $main::additional_deps, not @main::additional_deps.
    # They may be separate?
    @{$self->{'Additional Deps'}} = @$exp_pkgdeps;

    # remove missing essential deps that are dependencies of build
    # deps
    ($filt_pkgdeps, $missing) = $self->cmp_dep_lists($missing, $exp_pkgdeps);
    print main::PLOG "** Filtered missing build-essential deps that are dependencies of ",
	       "or provide build-deps:\n",
	       $self->format_deps(@$filt_pkgdeps), "\n"
	           if @$filt_pkgdeps;

    # remove comment package names
    push( @{$self->{'Additional Deps'}},
	  grep { $_->{'Neg'} && $_->{'Package'} =~ /^needs-no-/ } @$missing );
    $missing = [ grep { !($_->{'Neg'} &&
	                ($_->{'Package'} =~ /^this-package-does-not-exist/ ||
	                 $_->{'Package'} =~ /^needs-no-/)) } @$missing ];

    print main::PLOG "**** Warning:\n",
	       "**** The following src deps are ",
	       "(probably) missing:\n  ", $self->format_deps(@$missing), "\n"
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

    my $command = $self->{'Session'}->get_apt_command("$conf::apt_cache", "show @_", $Sbuild::Conf::username, 0, '/');
    my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die "Cannot start $conf::apt_cache $!\n";
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
    die "$conf::apt_cache exit status $?\n" if $?;

    return \%deps;
}

sub get_virtuals (\$@) {
    my $self = shift;

    local(*PIPE);

    my $command = $self->{'Session'}->get_apt_command("$conf::apt_cache", "showpkg @_", $Sbuild::Conf::username, 0, '/');
    my $pid = open3(\*main::DEVNULL, \*PIPE, '>&main::PLOG', "$command" );
    if (!$pid) {
	die "Cannot start $conf::apt_cache $!\n";
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
    die "$conf::apt_cache exit status $?\n" if $?;

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
		warn "Warning: syntax error in dependency '$_' of $pkg\n";
		next;
	    }
	    my( $dep, $rel, $relv, $archlist ) = ($1, $3, $4, $6);
	    if ($archlist) {
		$archlist =~ s/^\s*(.*)\s*$/$1/;
		my @archs = split( /\s+/, $archlist );
		my ($use_it, $ignore_it, $include) = (0, 0, 0);
		foreach (@archs) {
		    if (/^!/) {
			$ignore_it = 1 if substr($_, 1) eq $self->{'Arch'};
		    }
		    else {
			$use_it = 1 if $_ eq $self->{'Arch'};
			$include = 1;
		    }
		}
		warn "Warning: inconsistent arch restriction on ",
		"$pkg: $dep depedency\n"
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
		if ($Sbuild::Conf::verbose) {
		    print main::PLOG "Replacing source dep $dep";
		    print main::PLOG " ($rel $relv)" if $relv;
		    print main::PLOG " with $conf::srcdep_over{$dep}[0]";
		    print main::PLOG " ($conf::srcdep_over{$dep}[1] $conf::srcdep_over{$dep}[2])"
			if $conf::srcdep_over{$dep}[1];
		    print main::PLOG ".\n";
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
	    warn "Warning: $pkg: alternatives with negative dependencies ",
	    "forbidden -- skipped\n";
	}
	elsif (@l) {
	    my $l = shift @l;
	    foreach (@l) {
		push( @{$l->{'Alternatives'}}, $_ );
	    }
	    push( @{$self->{'Dependencies'}->{$pkg}}, $l );
	}
    }
}

sub parse_manual_srcdeps (\$@) {
    my $self = shift;
    my @for_pkgs = @_;

    foreach (@{$self->get_option('Manual Srcdeps')}) {
	if (!/^([fa])([a-zA-Z\d.+-]+):\s*(.*)\s*$/) {
	    warn "Syntax error in manual source dependency: ",
	    substr( $_, 1 ), "\n";
	    next;
	}
	my ($mode, $pkg, $deps) = ($1, $2, $3);
	next if !isin( $pkg, @for_pkgs );
	@{$self->{'Dependencies'}->{$pkg}} = () if $mode eq 'f';
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
	    $_ = $self->{'Session'}->strip_chroot_path($_);
	    $command = $self->{'Session'}->get_command("/usr/bin/du -k -s $_ 2>/dev/null", "root", 1, 0);
	} else {
	    $command = $self->{'Session'}->get_command("/usr/bin/du -k -s $_ 2>/dev/null", $Sbuild::Conf::username, 0, 0);
	}

	if (!open( PIPE, "$command |" )) {
	    print main::PLOG "Cannot determine space needed (du failed): $!\n";
	    return;
	}
	while( <PIPE> ) {
	    next if !/^(\d+)/;
	    $sum += $1;
	}
	close( PIPE );
    }

    $self->{'This Time'} = $self->{'Pkg End Time'} - $self->{'Pkg Start Time'};
    $self->{'This Time'} = 0 if $self->{'This Time'} < 0;
    $self->{'This Space'} = $sum;
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

    return if !$self->get_option('Batch Mode');

    return if !open( F, ">$self->{'Jobs File'}" );
    foreach $job (@ARGV) {
	my $jobname;

	if ($job eq $main::current_job and $self->{'binNMU Name'}) {
	    $jobname = $self->{'binNMU Name'};
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

sub append_to_FINISHED (\$) {
    my $self = shift;

    my $pkg = $self->{'Package_Version'};
    local( *F );

    return if !$self->get_option('Batch Mode');

    open( F, ">>SBUILD-FINISHED" );
    print F "$pkg\n";
    close( F );
}

sub write_srcdep_lock_file (\$\@) {
    my $self = shift;
    my $deps = shift;
    local( *F );

    ++$self->{'Srcdep Lock Count'};
    my $f = "$self->{'Session'}->{'Srcdep Lock Dir'}/$$-$self->{'Srcdep Lock Count'}";
    if (!open( F, ">$f" )) {
	print "Warning: cannot create srcdep lock file $f: $!\n";
	return;
    }
    print "Writing srcdep lock file $f:\n" if $conf::debug;

    my $user = getpwuid($<);
    print F "$main::current_job $$ $user\n";
    print "Job $main::current_job pid $$ user $user\n" if $conf::debug;
    foreach (@$deps) {
	my $name = $_->{'Package'};
	print F ($_->{'Neg'} ? "!" : ""), "$name\n";
	print "  ", ($_->{'Neg'} ? "!" : ""), "$name\n" if $conf::debug;
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

    if (!opendir( DIR, $self->{'Session'}->{'Srcdep Lock Dir'} )) {
	print main::PLOG "Cannot opendir $self->{'Session'}->{'Srcdep Lock Dir'}: $!\n";
	return 1;
    }
    my @files = grep { !/^\.\.?$/ && !/^install\.lock/ && !/^$mypid-\d+$/ }
    readdir(DIR);
    closedir(DIR);

    my $file;
    foreach $file (@files) {
	if (!open( F, "<$self->{'Session'}->{'Srcdep Lock Dir'}/$file" )) {
	    print main::PLOG "Cannot open $self->{'Session'}->{'Srcdep Lock Dir'}/$file: $!\n";
	    next;
	}
	<F> =~ /^(\S+)\s+(\S+)\s+(\S+)/;
	my ($job, $pid, $user) = ($1, $2, $3);

	# ignore (and remove) a lock file if associated process
	# doesn't exist anymore
	if (kill( 0, $pid ) == 0 && $! == ESRCH) {
	    close( F );
	    print main::PLOG "Found stale srcdep lock file $file -- removing it\n";
	    print main::PLOG "Cannot remove: $!\n"
		if !unlink( "$self->{'Session'}->{'Srcdep Lock Dir'}/$file" );
	    next;
	}

	print "Reading srclock file $file by job $job user $user\n"
	    if $conf::debug;

	while( <F> ) {
	    my ($neg, $pkg) = /^(!?)(\S+)/;
	    print "Found ", ($neg ? "neg " : ""), "entry $pkg\n"
		if $conf::debug;

	    if (isin( $pkg, @$to_inst, @$to_remove )) {
		print main::PLOG "Source dependency conflict with build of ",
		           "$job by $user (pid $pid):\n";
		print main::PLOG "  $job ", ($neg ? "conflicts with" : "needs"),
		           " $pkg\n";
		print main::PLOG "  $main::current_job wants to ",
		           (isin( $pkg, @$to_inst ) ? "update" : "remove"),
		           " $pkg\n";
		$conflict_builds{$file} = 1;
	    }
	}
	close( F );
    }

    my @conflict_builds = keys %conflict_builds;
    if (@conflict_builds) {
	print "Srcdep conflicts with: @conflict_builds\n" if $conf::debug;
    }
    else {
	print "No srcdep conflicts\n" if $conf::debug;
    }
    return @conflict_builds;
}

sub remove_srcdep_lock_file (\$) {
    my $self = shift;

    my $f = "$self->{'Session'}->{'Srcdep Lock Dir'}/$$-$self->{'Srcdep Lock Count'}";

    print "Removing srcdep lock file $f\n" if $conf::debug;
    if (!unlink( $f )) {
	print "Warning: cannot remove srcdep lock file $f: $!\n"
	    if $! != ENOENT;
    }
}

sub prepare_watches (\$\@@) {
    my $self = shift;
    my $dependencies = shift;
    my @instd = @_;
    my(@dep_on, $dep, $pkg, $prg);

    @dep_on = @instd;
    foreach $dep (@$dependencies, @{$self->{'Additional Deps'}}) {
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
    $self->{'This Watches'} = {};
    foreach $pkg (keys %conf::watches) {
	if (isin( $pkg, @dep_on )) {
	    print "Excluding from watch: $pkg\n" if $conf::debug;
	    next;
	}
	foreach $prg (@{$conf::watches{$pkg}}) {
	    $prg = "/usr/bin/$prg" if $prg !~ m,^/,;
	    $self->{'This Watches'}->{"$self->{'Chroot Dir'}$prg"} = $pkg;
	    print "Will watch for $prg ($pkg)\n" if $conf::debug;
	}
    }
}

sub check_watches (\$) {
    my $self = shift;
    my($prg, @st, %used);

    return if (!$conf::check_watches);

    foreach $prg (keys %{$self->{'This Watches'}}) {
	if (!(@st = stat( $prg ))) {
	    print "Watch: $prg: stat failed\n" if $conf::debug;
	    next;
	}
	if ($st[8] > $self->{'Build Start Time'}) {
	    my $pkg = $self->{'This Watches'}->{$prg};
	    my $prg2 = $self->{'Session'}->strip_chroot_path($prg);
	    push( @{$used{$pkg}}, $prg2 )
		if @{$self->{'Have DSC Build Deps'}} ||
		!isin( $pkg, @conf::ignore_watches_no_build_deps );
	}
	else {
	    print "Watch: $prg: untouched\n" if $conf::debug;
	}
    }
    return if !%used;

    print main::PLOG <<EOF;

NOTE: The package could have used binaries from the following packages
(access time changed) without a source dependency:
EOF

    foreach (keys %used) {
	print main::PLOG "  $_: @{$used{$_}}\n";
    }
    print main::PLOG "\n";
}

sub should_skip (\$) {
    my $self = shift;

    my $pkgv = $self->{'Package_Version'};

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
	    print main::PLOG "$pkgv found in SKIP file -- skipping building it\n";
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
	print main::PLOG "Can't open SBUILD-GIVEN-BACK: $!\n";
    }

  unlock:
    $self->unlock_file("SBUILD-GIVEN-BACK");
}

sub set_installed (\$@) {
    my $self = shift;
    foreach (@_) {
	$self->{'Changes'}->{'installed'}->{$_} = 1;
    }
    print "Added to installed list: @_\n" if $conf::debug;
}

sub set_removed (\$@) {
    my $self = shift;
    foreach (@_) {
	$self->{'Changes'}->{'removed'}->{$_} = 1;
	if (exists $self->{'Changes'}->{'installed'}->{$_}) {
	    delete $self->{'Changes'}->{'installed'}->{$_};
	    $self->{'Changes'}->{'auto-removed'}->{$_} = 1;
	    print "Note: $_ was installed\n" if $conf::debug;
	}
    }
    print "Added to removed list: @_\n" if $conf::debug;
}

sub unset_installed (\$@) {
    my $self = shift;
    foreach (@_) {
	delete $self->{'Changes'}->{'installed'}->{$_};
    }
    print "Removed from installed list: @_\n" if $conf::debug;
}

sub unset_removed (\$@) {
    my $self = shift;
    foreach (@_) {
	delete $self->{'Changes'}->{'removed'}->{$_};
	if (exists $self->{'Changes'}->{'auto-removed'}->{$_}) {
	    delete $self->{'Changes'}->{'auto-removed'}->{$_};
	    $self->{'Changes'}->{'installed'}->{$_} = 1;
	    print "Note: revived $_ to installed list\n" if $conf::debug;
	}
    }
    print "Removed from removed list: @_\n" if $conf::debug;
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
		warn "Bad lock file contents ($lockfile) -- still trying\n";
	    }
	    else {
		($pid, $user) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    warn "Removing stale lock file $lockfile ".
			" (pid $pid, user $user)\n";
		    unlink( $lockfile );
		    goto repeat;
		}
	    }
	    ++$try;
	    if (!$for_srcdep && $try > $Sbuild::Conf::max_lock_trys) {
		warn "Lockfile $lockfile still present after ".
		    $Sbuild::Conf::max_lock_trys*$Sbuild::Conf::lock_interval.
		    " seconds -- giving up\n";
		return;
	    }
	    print main::PLOG "Another sbuild process ($pid by $user) is currently ",
	    "installing or\n",
	    "removing packages -- waiting...\n"
		if $for_srcdep && $try == 1;
	    sleep $Sbuild::Conf::lock_interval;
	    goto repeat;
	}
	warn "Can't create lock file $lockfile: $!\n";
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

    return if not defined $conf::stats_dir;

    if (! -d $conf::stats_dir &&
	!mkdir $conf::stats_dir) {
	warn "Could not create $conf::stats_dir: $!\n";
	return;
    }

    my ($cat, $val) = @_;
    local( *F );

    $self->lock_file($conf::stats_dir, 0);
    open( F, ">>$conf::stats_dir/$cat" );
    print F "$val\n";
    close( F );
    $self->unlock_file($conf::stats_dir);
}

sub debian_files_list (\$$) {
    my $self = shift;
    my $files = shift;

    my @list;

    print STDERR "Parsing $files\n" if $conf::debug;

    if (-r $files && open( FILES, "<$files" )) {
	while (<FILES>) {
	    chomp;
	    my $f = (split( /\s+/, $_ ))[0];
	    push( @list, "$f" );
	    print STDERR "  $f\n" if $conf::debug;
	}
	close( FILES ) or print main::PLOG "Failed to close $files\n" && return 1;
    }

    return @list;
}

sub dsc_files (\$$) {
    my $self = shift;
    my $dsc = shift;
    my @files;

    print STDERR "Parsing $dsc\n" if $conf::debug;

    if (-r $dsc && open( DSC, "$conf::dcmd $dsc|" )) {
	while (<DSC>) {
	    chomp;
	    push @files, $_;
	    print STDERR "  $_\n" if $conf::debug;
	}
	close( DSC ) or print main::PLOG "Failed to close $dsc\n";
    } else {
	print main::PLOG "Failed to open $dsc\n";
    }

    return @files;
}

# Figure out chroot architecture
sub chroot_arch (\$) {
    my $self = shift;

    $self->{'Sub PID'} = open( PIPE, "-|" );
    if (!defined $self->{'Sub PID'}) {
	print main::PLOG "Can't spawn dpkg: $!\n";
	return 0;
    }
    if ($self->{'Sub PID'} == 0) {
	$self->{'Session'}->exec_command("$conf::dpkg --print-installation-architecture 2>/dev/null", $Sbuild::Conf::username, 1, 0, '/');
    }
    chomp( my $chroot_arch = <PIPE> );
    close( PIPE );
    undef $self->{'Sub PID'};

    die "Can't determine architecture of chroot: $!\n"
	if ($? || !defined($chroot_arch));

    return $chroot_arch;
}

sub open_build_log (\$) {
    my $self = shift;

    open_pkg_log("$Sbuild::Conf::username-$self->{'Package_SVersion'}-$self->{'Arch'}",
		 $self->get_option('Distribution'),
		 $self->{'Pkg Start Time'});
    print main::PLOG "Automatic build of $self->{'Package_SVersion'} on $hostname by " .
	"sbuild/$arch $version\n";
    print main::PLOG "Build started at " .
	strftime("%Y%m%d-%H%M", localtime($self->{'Pkg Start Time'})) . "\n";
    print main::PLOG "*"x78, "\n";
}

sub close_build_log (\$$$$$$$) {
    my $self = shift;

    my $date = strftime("%Y%m%d-%H%M", localtime($self->{'Pkg End Time'}));

    if (defined($self->{'Pkg Status'}) &&
	$self->{'Pkg Status'} eq "successful") {
	$self->add_time_entry($self->{'Package_Version'}, $self->{'This Time'});
	$self->add_space_entry($self->{'Package_Version'}, $self->{'This Space'});
    }
    print main::PLOG "*"x78, "\n";
    printf main::PLOG "Finished at ${date}\nBuild needed %02d:%02d:%02d, %dk disk space\n",
    int($self->{'This Time'}/3600),
    int(($self->{'This Time'}%3600)/60),
    int($self->{'This Time'}%60),
    $self->{'This Space'};

    close_pkg_log($self->{'Package_Version'},
		  $self->get_option('Distribution'),
		  $self->{'Pkg Status'},
		  $self->{'Pkg Start Time'},
		  $self->{'Pkg End Time'});
}

sub add_time_entry (\$$$) {
    my $self = shift;
    my $pkg = shift;
    my $t = shift;

    return if !$Sbuild::Conf::avg_time_db;
    my %db;
    if (!tie %db, 'GDBM_File', $Sbuild::Conf::avg_time_db, GDBM_WRCREAT, 0664) {
	print "Can't open average time db $Sbuild::Conf::avg_time_db\n";
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

    return if !$Sbuild::Conf::avg_space_db || $space == 0;
    my %db;
    if (!tie %db, 'GDBM_File', $Sbuild::Conf::avg_space_db, &GDBM_WRCREAT, 0664) {
	print "Can't open average space db $Sbuild::Conf::avg_space_db\n";
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

1;
