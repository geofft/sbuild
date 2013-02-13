# Resolver.pm: build library for sbuild
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

package Sbuild::ResolverBase;

use strict;
use warnings;
use POSIX;
use Fcntl;
use File::Temp qw(tempdir tempfile);
use File::Copy;

use Dpkg::Deps;
use Sbuild::Base;
use Sbuild qw(isin debug debug2);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $session = shift;
    my $host = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Session', $session);
    $self->set('Host', $host);
    $self->set('Changes', {});
    $self->set('AptDependencies', {});
    $self->set('Split', $self->get_conf('CHROOT_SPLIT'));
    # Typically set by Sbuild::Build, but not outside a build context.
    $self->set('Host Arch', $self->get_conf('HOST_ARCH'));
    $self->set('Build Arch', $self->get_conf('BUILD_ARCH'));

    my $dummy_archive_list_file = $session->get('Location') .
        '/etc/apt/sources.list.d/sbuild-build-depends-archive.list';
    $self->set('Dummy archive list file', $dummy_archive_list_file);


    return $self;
}

sub setup {
    my $self = shift;

    my $session = $self->get('Session');
    my $chroot_dir = $session->get('Location');

    #Set up dpkg config
    $self->setup_dpkg();

    my $aptconf = "/var/lib/sbuild/apt.conf";
    $self->set('APT Conf', $aptconf);

    my $chroot_aptconf = $session->get('Location') . "/$aptconf";
    $self->set('Chroot APT Conf', $chroot_aptconf);

    # Always write out apt.conf, because it may become outdated.
    if (my $F = new File::Temp( TEMPLATE => "$aptconf.XXXXXX",
				DIR => $session->get('Location'),
				UNLINK => 0) ) {
	if ($self->get_conf('APT_ALLOW_UNAUTHENTICATED')) {
	    print $F "APT::Get::AllowUnauthenticated true;\n";
	}
	print $F "APT::Install-Recommends false;\n";

	if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	    print $F "APT::Architecture=".$self->get('Host Arch');
	    $self->log("Adding APT::Architecture ".$self->get('Host Arch')." to the apt config");
	}
	if ($self->get('Split')) {
	    print $F "Dir \"$chroot_dir\";\n";
	}

	if (! rename $F->filename, $chroot_aptconf) {
	    print STDERR "Can't rename $F->filename to $chroot_aptconf: $!\n";
	    return 0;
	}
    } else {
	print STDERR "Can't create $chroot_aptconf: $!";
	return 0;
    }

    # unsplit mode uses an absolute path inside the chroot, rather
    # than on the host system.
    if ($self->get('Split')) {
	$self->set('APT Options',
		   ['-o', "Dir::State::status=$chroot_dir/var/lib/dpkg/status",
		    '-o', "DPkg::Options::=--root=$chroot_dir",
		    '-o', "DPkg::Run-Directory=$chroot_dir"]);

	$self->set('Aptitude Options',
		   ['-o', "Dir::State::status=$chroot_dir/var/lib/dpkg/status",
		    '-o', "DPkg::Options::=--root=$chroot_dir",
		    '-o', "DPkg::Run-Directory=$chroot_dir"]);

	# sudo uses an absolute path on the host system.
	$session->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('Chroot APT Conf');
    } else { # no split
	$self->set('APT Options', []);
	$self->set('Aptitude Options', []);
	$session->get('Defaults')->{'ENV'}->{'APT_CONFIG'} =
	    $self->get('APT Conf');
    }

    $self->cleanup_apt_archive();
}

sub setup_dpkg {
    my $self = shift;

    my $session = $self->get('Session');

    # If cross-building, set the correct foreign-arch
    if ($self->get('Host Arch') ne $self->get('Build Arch')) {
	$session->run_command(
	    # this is the ubuntu dpkg 1.16.2 interface - we need to check (or configure) which to use with check_dpkg_version
#	    { COMMAND => ['sh', '-c', 'echo "foreign-architecture ' . $self->get('Host Arch') . '" > /etc/dpkg/dpkg.cfg.d/sbuild'],
#	      USER => 'root' });
	    # This is the Debian dpkg >= 1.16.3 interface
	    { COMMAND => ['dpkg', '--add-architecture', $self->get('Host Arch')],
	      USER => 'root' });
	if ($?) {
	    $self->log_error("E: Failed to set dpkg foreign-architecture config\n");
	    return 0;
	}
	$self->log("Adding dpkg foreign-architecture ".$self->get('Host Arch')."\n");
    }
}

sub cleanup {
    my $self = shift;

    #cleanup dpkg cross-config
    # rm /etc/dpkg/dpkg.cfg.d/sbuild
    # later: dpkg --delete-foreign-architecture $self->get('Host Arch')
    $self->cleanup_apt_archive();
}

sub update {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), 'update'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub update_archive {
    my $self = shift;

    if (!$self->get_conf('APT_UPDATE_ARCHIVE_ONLY')) {
	# Update with apt-get; causes complete archive update
	$self->run_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), 'update'],
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      DIR => '/' });
	return $?;
    } else {
	my $session = $self->get('Session');
	my $dummy_archive_list_file = $self->get('Dummy archive list file');
	# Create an empty sources.list.d directory that we can set as
	# Dir::Etc::sourceparts to suppress the real one. /dev/null
	# works in recent versions of apt, but not older ones (we want
	# 448eaf8 in apt 0.8.0 and af13d14 in apt 0.9.3). Since this
	# runs against the target chroot's apt, be conservative.
	my $dummy_sources_list_d = $self->get('Dummy package path') . '/sources.list.d';
	if (!(-d $dummy_sources_list_d || mkdir $dummy_sources_list_d, 0700)) {
	    $self->log_warning('Could not create build-depends dummy sources.list directory ' . $dummy_sources_list_d . ': ' . $!);
	    $self->cleanup_apt_archive();
	    return 0;
	}

	# Run apt-get update pointed at our dummy archive list file, and
	# the empty sources.list.d directory, so that we only update
	# this one source. Since apt doesn't have all the sources
	# available to it in this run, any caches it generates are
	# invalid, so we then need to run gencaches with all sources
	# available to it. (Note that the tempting optimization to run
	# apt-get update -o pkgCacheFile::Generate=0 is broken before
	# 872ed75 in apt 0.9.1.)
	$self->run_apt_command(
	    { COMMAND => [$self->get_conf('APT_GET'), 'update',
	                  '-o', 'Dir::Etc::sourcelist=' . $session->strip_chroot_path($dummy_archive_list_file),
			  '-o', 'Dir::Etc::sourceparts=' . $session->strip_chroot_path($dummy_sources_list_d),
			  '--no-list-cleanup'],
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      DIR => '/' });
	return $? if $?;

	$self->run_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'), 'gencaches'],
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      DIR => '/' });
	return $?;
    }
}

sub upgrade {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub distupgrade {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'dist-upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub clean {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'clean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoclean {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'autoclean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoremove {
    my $self = shift;

    $self->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'autoremove'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub add_dependencies {
    my $self = shift;
    my $pkg = shift;
    my $build_depends = shift;
    my $build_depends_arch = shift;
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_arch = shift;
    my $build_conflicts_indep = shift;

    debug("Build-Depends: $build_depends\n") if $build_depends;
    debug("Build-Depends-Arch: $build_depends_arch\n") if $build_depends_arch;
    debug("Build-Depends-Indep: $build_depends_indep\n") if $build_depends_indep;
    debug("Build-Conflicts: $build_conflicts\n") if $build_conflicts;
    debug("Build-Conflicts-Arch: $build_conflicts_arch\n") if $build_conflicts_arch;
    debug("Build-Conflicts-Indep: $build_conflicts_indep\n") if $build_conflicts_indep;

    my $deps = {
	'Build Depends' => $build_depends,
	'Build Depends Arch' => $build_depends_arch,
	'Build Depends Indep' => $build_depends_indep,
	'Build Conflicts' => $build_conflicts,
	'Build Conflicts Arch' => $build_conflicts_arch,
	'Build Conflicts Indep' => $build_conflicts_indep
    };

    $self->get('AptDependencies')->{$pkg} = $deps;
}

sub install_core_deps {
    my $self = shift;
    my $name = shift;

    return $self->install_deps($name, 0, @_);
}

sub install_main_deps {
    my $self = shift;
    my $name = shift;

    my $cross = $self->get('Host Arch') ne $self->get('Build Arch');
    return $self->install_deps($name, $cross, @_);
}

sub uninstall_deps {
    my $self = shift;

    my( @pkgs, @instd, @rmvd );

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $self->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'install', @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $self->log("Failed to remove installed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'remove', @pkgs);
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);
}

sub set_installed {
    my $self = shift;

    foreach (@_) {
	$self->get('Changes')->{'installed'}->{$_} = 1;
    }
    debug("Added to installed list: @_\n");
}

sub set_removed {
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

sub unset_installed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'installed'}->{$_};
    }
    debug("Removed from installed list: @_\n");
}

sub unset_removed {
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

sub dump_build_environment {
    my $self = shift;

    my $status = $self->get_dpkg_status();

    my $arch = $self->get('Arch');
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    $self->log_subsection("Build environment");
    $self->log("Kernel: $sysname $release $arch ($machine)\n");

    $self->log("Toolchain package versions:");
    foreach my $name (sort keys %{$status}) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    if ($name =~ m,^$regex, && defined($status->{$name}->{'Version'})) {
		$self->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    }
	}
    }
    $self->log("\n");

    $self->log("Package versions:");
    foreach my $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $self->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $self->log("\n");

}

sub run_apt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my @apt_command = ($self->get_conf('APT_GET'), '--purge',
	'-o', 'DPkg::Options::=--force-confold',
	'-o', 'DPkg::Options::=--refuse-remove-essential',
	'-o', 'APT::Install-Recommends=false',
	'-q');
    push @apt_command, '--allow-unauthenticated' if
	($self->get_conf('APT_ALLOW_UNAUTHENTICATED'));
    push @apt_command, "$mode", $action, @packages;
    my $pipe =
	$self->pipe_apt_command(
	    { COMMAND => \@apt_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });
    if (!$pipe) {
	$self->log("Can't open pipe to apt-get: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$self->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

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

sub run_xapt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my @xapt_command = ($self->get_conf('XAPT'));
    my $pipe =
	$self->pipe_xapt_command(
	    { COMMAND => \@xapt_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });
    if (!$pipe) {
	$self->log("Can't open pipe to xapt: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$self->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

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

    $self->log("xapt failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub format_deps {
    my $self = shift;

    return join( ", ",
		 map { join( "|",
			     map { ($_->{'Neg'} ? "!" : "") .
				       $_->{'Package'} .
				       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"")}
			     scalar($_), @{$_->{'Alternatives'}}) } @_ );
}

sub get_dpkg_status {
    my $self = shift;
    my @interest = @_;
    my %result;
    local( *STATUS );

    debug("Requesting dpkg status for packages: @interest\n");
    my $dpkg_status_file = $self->get('Session')->get('Location') . '/var/lib/dpkg/status';
    if (!open( STATUS, '<', $dpkg_status_file)) {
	$self->log("Can't open $dpkg_status_file: $!\n");
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
	    $self->log_error("parse error in $dpkg_status_file: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $self->log_error("parse error in $dpkg_status_file: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $self->log_error("parse error in $dpkg_status_file: no Version: field for package $pkg\n");
	    next;
	}
	$result{$pkg} = { Installed => 1, Version => $version }
	    if (isin( $pkg, @interest ) || !@interest);
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

# Create an apt archive. Add to it if one exists.
sub setup_apt_archive {
    my $self = shift;
    my $dummy_pkg_name = shift;
    my @pkgs = @_;

    my $session = $self->get('Session');

    #Prepare a path to build a dummy package containing our deps:
    if (! defined $self->get('Dummy package path')) {
        $self->set('Dummy package path',
		   tempdir('resolver' . '-XXXXXX',
			   DIR => $self->get('Chroot Build Dir')));
    }
    $session->run_command(
	{ COMMAND => ['chown', $self->get_conf('BUILD_USER') . ':sbuild',
		      $session->strip_chroot_path($self->get('Dummy package path'))],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	$self->log_error("E: Failed to set " . $self->get_conf('BUILD_USER') .
			 ":sbuild ownership on dummy package dir\n");
	return 0;
    }
    $session->run_command(
	{ COMMAND => ['chmod', '0770', $session->strip_chroot_path($self->get('Dummy package path'))],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	$self->log_error("E: Failed to set 0770 permissions on dummy package dir\n");
	return 0;
    }
    my $dummy_dir = $self->get('Dummy package path');
    my $dummy_gpghome = $dummy_dir . '/gpg';
    my $dummy_archive_dir = $dummy_dir . '/apt_archive';
    my $dummy_release_file = $dummy_archive_dir . '/Release';
    my $dummy_archive_seckey = $dummy_archive_dir . '/sbuild-key.sec';
    my $dummy_archive_pubkey = $dummy_archive_dir . '/sbuild-key.pub';

    $self->set('Dummy archive directory', $dummy_archive_dir);
    $self->set('Dummy Release file', $dummy_release_file);
    my $dummy_archive_list_file = $self->get('Dummy archive list file');

    if (! -d $dummy_dir) {
        $self->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . ': ' . $!);
        $self->cleanup_apt_archive();
        return 0;
    }
    if (!(-d $dummy_gpghome || mkdir $dummy_gpghome, 0700)) {
        $self->log_warning('Could not create build-depends dummy gpg home dir ' . $dummy_gpghome . ': ' . $!);
        $self->cleanup_apt_archive();
        return 0;
    }
    $session->run_command(
	{ COMMAND => ['chown', $self->get_conf('BUILD_USER') . ':sbuild',
		      $session->strip_chroot_path($dummy_gpghome)],
	  USER => 'root',
	  DIR => '/' });
    if ($?) {
	$self->log_error("E: Failed to set " . $self->get_conf('BUILD_USER') .
			 ":sbuild ownership on $dummy_gpghome\n");
	return 0;
    }
    if (!(-d $dummy_archive_dir || mkdir $dummy_archive_dir, 0775)) {
        $self->log_warning('Could not create build-depends dummy archive dir ' . $dummy_archive_dir . ': ' . $!);
        $self->cleanup_apt_archive();
        return 0;
    }

    my $dummy_pkg_dir = $dummy_dir . '/' . $dummy_pkg_name;
    my $dummy_deb = $dummy_archive_dir . '/' . $dummy_pkg_name . '.deb';
    my $dummy_dsc = $dummy_archive_dir . '/' . $dummy_pkg_name . '.dsc';

    if (!(mkdir($dummy_pkg_dir) && mkdir($dummy_pkg_dir . '/DEBIAN'))) {
	$self->log_warning('Could not create build-depends dummy dir ' . $dummy_pkg_dir . '/DEBIAN: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }

    if (!open(DUMMY_CONTROL, '>', $dummy_pkg_dir . '/DEBIAN/control')) {
	$self->log_warning('Could not open ' . $dummy_pkg_dir . '/DEBIAN/control for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }

    my $arch = $self->get('Build Arch');
    print DUMMY_CONTROL <<"EOF";
Package: $dummy_pkg_name
Version: 0.invalid.0
Architecture: $arch
EOF

    my @positive;
    my @negative;
    my @positive_arch;
    my @negative_arch;
    my @positive_indep;
    my @negative_indep;

    for my $pkg (@pkgs) {
	my $deps = $self->get('AptDependencies')->{$pkg};

	push(@positive, $deps->{'Build Depends'})
	    if (defined($deps->{'Build Depends'}) &&
		$deps->{'Build Depends'} ne "");
	push(@negative, $deps->{'Build Conflicts'})
	    if (defined($deps->{'Build Conflicts'}) &&
		$deps->{'Build Conflicts'} ne "");
	if ($self->get_conf('BUILD_ARCH_ALL')) {
	    push(@positive_arch, $deps->{'Build Depends Arch'})
		if (defined($deps->{'Build Depends Arch'}) &&
		    $deps->{'Build Depends Arch'} ne "");
	    push(@negative_arch, $deps->{'Build Conflicts Arch'})
		if (defined($deps->{'Build Conflicts Arch'}) &&
		    $deps->{'Build Conflicts Arch'} ne "");
	}
	if ($self->get_conf('BUILD_ARCH_ALL')) {
	    push(@positive_indep, $deps->{'Build Depends Indep'})
		if (defined($deps->{'Build Depends Indep'}) &&
		    $deps->{'Build Depends Indep'} ne "");
	    push(@negative_indep, $deps->{'Build Conflicts Indep'})
		if (defined($deps->{'Build Conflicts Indep'}) &&
		    $deps->{'Build Conflicts Indep'} ne "");
	}
    }

    my $positive = deps_parse(join(", ", @positive,
				   @positive_arch, @positive_indep),
			      reduce_arch => 1,
			      host_arch => $self->get('Host Arch'),
			      build_arch => $self->get('Build Arch'),
			      build_dep => 1);
    my $negative = deps_parse(join(", ", @negative,
				   @negative_arch, @negative_indep),
			      reduce_arch => 1,
			      host_arch => $self->get('Host Arch'),
			      build_arch => $self->get('Build Arch'),
			      build_dep => 1,
			      union => 1);

    $self->log("Merged Build-Depends: $positive\n") if $positive;
    $self->log("Merged Build-Conflicts: $negative\n") if $negative;

    # Filter out all but the first alternative except in special
    # cases.
    if (!$self->get_conf('RESOLVE_ALTERNATIVES')) {
	my $positive_filtered = Dpkg::Deps::AND->new();
	foreach my $item ($positive->get_deps()) {
	    my $alt_filtered = Dpkg::Deps::OR->new();
	    my @alternatives = $item->get_deps();
	    my $first = shift @alternatives;
	    $alt_filtered->add($first) if defined $first;
	    # Allow foo (rel x) | foo (rel y) as the only acceptable
	    # form of alternative.  i.e. where the package is the
	    # same, but different relations are needed, since these
	    # are effectively a single logical dependency.
	    foreach my $alt (@alternatives) {
		if ($first->{'package'} eq $alt->{'package'}) {
		    $alt_filtered->add($alt);
		} else {
		    last;
		}
	    }
	    $positive_filtered->add($alt_filtered);
	}
	$positive = $positive_filtered;
    }

    if ($positive ne "") {
	print DUMMY_CONTROL 'Depends: ' . $positive . "\n";
    }
    if ($negative ne "") {
	print DUMMY_CONTROL 'Conflicts: ' . $negative . "\n";
    }

    $self->log("Filtered Build-Depends: $positive\n") if $positive;
    $self->log("Filtered Build-Conflicts: $negative\n") if $negative;

    print DUMMY_CONTROL <<"EOF";
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
Description: Dummy package to satisfy dependencies with apt - created by sbuild
 This package was created automatically by sbuild and should never appear on
 a real system. You can safely remove it.
EOF
    close (DUMMY_CONTROL);

    foreach my $path ($dummy_pkg_dir . '/DEBIAN/control',
		      $dummy_pkg_dir . '/DEBIAN',
		      $dummy_pkg_dir,
		      $dummy_archive_dir) {
	$session->run_command(
	    { COMMAND => ['chown', $self->get_conf('BUILD_USER') . ':sbuild',
			  $session->strip_chroot_path($path)],
	      USER => 'root',
	      DIR => '/' });
	if ($?) {
	    $self->log_error("E: Failed to set " . $self->get_conf('BUILD_USER')
			   . ":sbuild ownership on $path\n");
	    return 0;
	}
    }

    #Now build the package:
    $session->run_command(
	{ COMMAND => ['dpkg-deb', '--build', $session->strip_chroot_path($dummy_pkg_dir), $session->strip_chroot_path($dummy_deb)],
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0});
    if ($?) {
	$self->log("Dummy package creation failed\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write the dummy dsc file.
    my $dummy_dsc_fh;
    if (!open($dummy_dsc_fh, '>', $dummy_dsc)) {
        $self->log_warning('Could not open ' . $dummy_dsc . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
        return 0;
    }

    print $dummy_dsc_fh <<"EOF";
Format: 1.0
Source: $dummy_pkg_name
Binary: $dummy_pkg_name
Architecture: any
Version: 0.invalid.0
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
EOF
    if (scalar(@positive)) {
       print $dummy_dsc_fh 'Build-Depends: ' . join(", ", @positive) . "\n";
    }
    if (scalar(@negative)) {
       print $dummy_dsc_fh 'Build-Conflicts: ' . join(", ", @negative) . "\n";
    }
    if (scalar(@positive_arch)) {
       print $dummy_dsc_fh 'Build-Depends-Arch: ' . join(", ", @positive_arch) . "\n";
    }
    if (scalar(@negative_arch)) {
       print $dummy_dsc_fh 'Build-Conflicts-Arch: ' . join(", ", @negative_arch) . "\n";
    }
    if (scalar(@positive_indep)) {
       print $dummy_dsc_fh 'Build-Depends-Indep: ' . join(", ", @positive_indep) . "\n";
    }
    if (scalar(@negative_indep)) {
       print $dummy_dsc_fh 'Build-Conflicts-Indep: ' . join(", ", @negative_indep) . "\n";
    }
    print $dummy_dsc_fh "\n";
    close $dummy_dsc_fh;

    # Do code to run apt-ftparchive
    if (!$self->run_apt_ftparchive()) {
        $self->log("Failed to run apt-ftparchive.\n");
        $self->cleanup_apt_archive();
        return 0;
    }

    # Sign the release file
    if (!$self->generate_keys()) {
        $self->log("Failed to generate archive keys.\n");
        $self->cleanup_apt_archive();
        return 0;
    }
    copy($self->get_conf('SBUILD_BUILD_DEPENDS_SECRET_KEY'), $dummy_archive_seckey) unless
        (-f $dummy_archive_seckey);
    copy($self->get_conf('SBUILD_BUILD_DEPENDS_PUBLIC_KEY'), $dummy_archive_pubkey) unless
        (-f $dummy_archive_pubkey);
    my @gpg_command = ('gpg', '--yes', '--no-default-keyring',
                       '--homedir',
                       $session->strip_chroot_path($dummy_gpghome),
                       '--secret-keyring',
                       $session->strip_chroot_path($dummy_archive_seckey),
                       '--keyring',
                       $session->strip_chroot_path($dummy_archive_pubkey),
                       '--default-key', 'Sbuild Signer', '-abs',
                       '-o', $session->strip_chroot_path($dummy_release_file) . '.gpg',
                       $session->strip_chroot_path($dummy_release_file));
    $session->run_command(
	{ COMMAND => \@gpg_command,
	  USER => $self->get_conf('BUILD_USER'),
	  PRIORITY => 0});
    if ($?) {
	$self->log("Failed to sign dummy archive Release file.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write a list file for the dummy archive if one not create yet.
    if (! -f $dummy_archive_list_file) {
        my ($tmpfh, $tmpfilename) = tempfile(DIR => $session->get('Location') . "/tmp");
        print $tmpfh 'deb file://' . $session->strip_chroot_path($dummy_archive_dir) . " ./\n";
        print $tmpfh 'deb-src file://' . $session->strip_chroot_path($dummy_archive_dir) . " ./\n";
        close($tmpfh);
        # List file needs to be moved with root.
        $session->run_command(
            { COMMAND => ['chmod', '0644', $session->strip_chroot_path($tmpfilename)],
              USER => 'root',
              PRIORITY => 0});
        if ($?) {
            $self->log("Failed to create apt list file for dummy archive.\n");
            $self->cleanup_apt_archive();
            return 0;
        }
        $session->run_command(
            { COMMAND => ['mv', $session->strip_chroot_path($tmpfilename),
                          $session->strip_chroot_path($dummy_archive_list_file)],
              USER => 'root',
              PRIORITY => 0});
        if ($?) {
            $self->log("Failed to create apt list file for dummy archive.\n");
            $self->cleanup_apt_archive();
            return 0;
        }
    }

    # Add the generated key
    $session->run_command(
        { COMMAND => ['apt-key', 'add', $session->strip_chroot_path($dummy_archive_pubkey)],
          USER => 'root',
          PRIORITY => 0});
    if ($?) {
        $self->log("Failed to add dummy archive key.\n");
        $self->cleanup_apt_archive();
        return 0;
    }

    return 1;
}

# Remove the apt archive.
sub cleanup_apt_archive {
    my $self = shift;

    my $session = $self->get('Session');

    if (defined $self->get('Dummy package path')) {
	$session->run_command(
	    { COMMAND => ['rm', '-fr', $session->strip_chroot_path($self->get('Dummy package path'))],
	      USER => $self->get_conf('BUILD_USER'),
	      DIR => '/' });
    }

    $session->run_command(
	{ COMMAND => ['rm', '-f', $session->strip_chroot_path($self->get('Dummy archive list file'))],
	  USER => 'root',
	  DIR => '/',
	  PRIORITY => 0});
    $self->set('Dummy package path', undef);
    $self->set('Dummy archive directory', undef);
    $self->set('Dummy Release file', undef);
}

# Generate a key pair if not already done.
sub generate_keys {
    my $self = shift;

    if ((-f $self->get_conf('SBUILD_BUILD_DEPENDS_SECRET_KEY')) &&
        (-f $self->get_conf('SBUILD_BUILD_DEPENDS_PUBLIC_KEY'))) {
        return 1;
    }

    $self->log_error("Local archive GPG signing key not found\n");
    $self->log_info("Please generate a key with 'sbuild-update --keygen'\n");
    $self->log_info("Note that on machines with scarce entropy, you may wish ".
		    "to generate the key with this command on another machine ".
		    "and copy the public and private keypair to '" .
		    $self->get_conf('SBUILD_BUILD_DEPENDS_PUBLIC_KEY')
		    ."' and '".
		    $self->get_conf('SBUILD_BUILD_DEPENDS_SECRET_KEY') ."'\n");
    return 0;
}

# Function that runs apt-ftparchive
sub run_apt_ftparchive {
    my $self = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    my ($tmpfh, $tmpfilename) = tempfile();
    my $dummy_archive_dir = $self->get('Dummy archive directory');

    for my $deb (@{$self->get_conf('EXTRA_PACKAGES')}) {
        copy($deb, $dummy_archive_dir);
    }

    # Write the conf file.
    print $tmpfh <<"EOF";
Dir {
 ArchiveDir "$dummy_archive_dir";
};

Default {
 Packages::Compress ". gzip";
 Sources::Compress ". gzip";
};

BinDirectory "$dummy_archive_dir" {
 Packages "Packages";
 Sources "Sources";
};

APT::FTPArchive::Release::Origin "sbuild-build-depends-archive";
APT::FTPArchive::Release::Label "sbuild-build-depends-archive";
APT::FTPArchive::Release::Suite "invalid";
APT::FTPArchive::Release::Codename "invalid";
APT::FTPArchive::Release::Description "Sbuild Build Dependency Temporary Archive";
EOF
    close $tmpfh;

    # Remove APT_CONFIG environment variable here, restore it later.
    my $env = $self->get('Session')->get('Defaults')->{'ENV'};
    my $apt_config_value = $env->{'APT_CONFIG'};
    delete $env->{'APT_CONFIG'};

    # Run apt-ftparchive to generate Packages and Sources files.
    $host->run_command(
        { COMMAND => ['apt-ftparchive', '-q=2', 'generate', $tmpfilename],
          USER => $self->get_conf('USERNAME'),
          PRIORITY => 0,
          DIR => '/'});
    if ($?) {
        $env->{'APT_CONFIG'} = $apt_config_value;
	unlink $tmpfilename;
        return 0;
    }

    # Get output for Release file
    my $pipe = $host->pipe_command(
        { COMMAND => ['apt-ftparchive', '-q=2', '-c', $tmpfilename, 'release', $dummy_archive_dir],
          USER => $self->get_conf('USERNAME'),
          PRIORITY => 0,
          DIR => '/'});
    if (!defined($pipe)) {
        $env->{'APT_CONFIG'} = $apt_config_value;
	unlink $tmpfilename;
        return 0;
    }
    $env->{'APT_CONFIG'} = $apt_config_value;


    # Write output to Release file path.
    my ($releasefh);
    if (!open($releasefh, '>', $self->get('Dummy Release file'))) {
        close $pipe;
	unlink $tmpfilename;
        return 0;
    }

    while (<$pipe>) {
        print $releasefh $_;
    }
    close $releasefh;
    close $pipe;

    # Remove config file.  Note also removed on failure paths above.
    unlink $tmpfilename;

    return 1;
}

sub get_apt_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('APT Options');

    debug2("APT Options: ", join(" ", @$apt_options), "\n")
	if defined($apt_options);

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, @{$command}[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    debug2("APT Command: ", join(" ", @aptcommand), "\n");

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub run_apt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->run_command_internal($options);
    } else {
	return $session->run_command_internal($options);
    }
}

sub pipe_apt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

sub pipe_xapt_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_apt_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

sub get_aptitude_command_internal {
    my $self = shift;
    my $options = shift;

    my $command = $options->{'COMMAND'};
    my $apt_options = $self->get('Aptitude Options');

    debug2("Aptitude Options: ", join(" ", @$apt_options), "\n")
	if defined($apt_options);

    my @aptcommand = ();
    if (defined($apt_options)) {
	push(@aptcommand, @{$command}[0]);
	push(@aptcommand, @$apt_options);
	if ($#$command > 0) {
	    push(@aptcommand, @{$command}[1 .. $#$command]);
	}
    } else {
	@aptcommand = @$command;
    }

    debug2("APT Command: ", join(" ", @aptcommand), "\n");

    $options->{'INTCOMMAND'} = \@aptcommand;
}

sub run_aptitude_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_aptitude_command_internal($options);

    if ($self->get('Split')) {
	return $host->run_command_internal($options);
    } else {
	return $session->run_command_internal($options);
    }
}

sub pipe_aptitude_command {
    my $self = shift;
    my $options = shift;

    my $session = $self->get('Session');
    my $host = $self->get('Host');

    # Set modfied command
    $self->get_aptitude_command_internal($options);

    if ($self->get('Split')) {
	return $host->pipe_command_internal($options);
    } else {
	return $session->pipe_command_internal($options);
    }
}

1;
