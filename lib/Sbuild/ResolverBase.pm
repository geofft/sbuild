# Resolver.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
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
use Errno qw(:POSIX);
use File::Temp qw(tempdir tempfile);
use File::Path qw(remove_tree);
use File::Basename;
use Digest::MD5 qw(md5_hex);
use IO::Compress::Gzip qw(gzip $GzipError :level);

use Dpkg::Deps;
use Sbuild::Base;
use Sbuild qw(isin debug);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $builder = shift;

    my $self = $class->SUPER::new($builder->get('Config'));
    bless($self, $class);

    $self->set('Builder', $builder);
    $self->set('Changes', {});
    $self->set('AptDependencies', {});

    return $self;
}

sub add_dependencies {
    my $self = shift;
    my $pkg = shift;
    my $build_depends = shift;
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_indep = shift;

    my $builder = $self->get('Builder');

    debug("Build-Depends: $build_depends\n") if $build_depends;
    debug("Build-Depends-Indep: $build_depends_indep\n") if $build_depends_indep;
    debug("Build-Conflicts: $build_conflicts\n") if $build_conflicts;
    debug("Build-Conflicts-Indep: $build_conflicts_indep\n") if $build_conflicts_indep;

    my $deps = {
	'Build Depends' => $build_depends,
	'Build Depends Indep' => $build_depends_indep,
	'Build Conflicts' => $build_conflicts,
	'Build Conflicts Indep' => $build_conflicts_indep
    };

    $self->get('AptDependencies')->{$pkg} = $deps;
}

sub uninstall_deps {
    my $self = shift;
    my $builder = $self->get('Builder');

    my( @pkgs, @instd, @rmvd );

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $builder->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'install', @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $builder->log("Failed to remove installed packages!\n")
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
    my $builder = $self->get('Builder');

    my $status = $self->get_dpkg_status();

    my $arch = $builder->get('Arch');
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    $builder->log("Kernel: $sysname $release $arch ($machine)\n");

    $builder->log("Toolchain package versions:");
    foreach my $name (sort keys %{$status}) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    if ($name =~ m,^$regex, && defined($status->{$name}->{'Version'})) {
		$builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    }
	}
    }
    $builder->log("\n");

    $builder->log("Package versions:");
    foreach my $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $builder->log("\n");

}

sub run_apt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    my $builder = $self->get('Builder');

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my @apt_command = ($builder->get_conf('APT_GET'), '--purge',
	'-o', 'DPkg::Options::=--force-confold',
	'-o', 'DPkg::Options::=--refuse-remove-essential',
	'-q', '--no-install-recommends');
    push @apt_command, '--allow-unauthenticated' if
	($self->get_conf('APT_ALLOW_UNAUTHENTICATED'));
    push @apt_command, "$mode", $action, @packages;
    my $pipe =
	$builder->get('Session')->pipe_apt_command(
	{ COMMAND => \@apt_command,
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  PRIORITY => 0,
	  DIR => '/' });
    if (!$pipe) {
	$builder->log("Can't open pipe to apt-get: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$builder->log($_) if $mode ne "-s" || debug($_);
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

    $builder->log("apt-get failed.\n") if $status && $mode ne "-s";
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
    my $builder = $self->get('Builder');
    my @interest = @_;
    my %result;
    local( *STATUS );

    debug("Requesting dpkg status for packages: @interest\n");
    my $dpkg_status_file = $builder->{'Chroot Dir'} . '/var/lib/dpkg/status';
    if (!open( STATUS, '<', $dpkg_status_file)) {
	$builder->log("Can't open $dpkg_status_file: $!\n");
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
	    $builder->log_error("parse error in $dpkg_status_file: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $builder->log_error("parse error in $dpkg_status_file: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $builder->log_error("parse error in $dpkg_status_file: no Version: field for package $pkg\n");
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

# Setup an empty archive.
sub setup_apt_archive {
    my $self = shift;

    return 1 if (defined($self->get('Dummy archive created')));

    $self->set('Dummy archive created', undef);
    my $builder = $self->get('Builder');
    my $session = $builder->get('Session');

    #Prepare a path to build a dummy package containing our deps:
    $self->set('Dummy package path',
	       tempdir($builder->get_conf('USERNAME') . '-' . $builder->get('Package') . '-' .
		       $builder->get('Arch') . '-XXXXXX',
		       DIR => $session->get('Build Location')));
    my $dummy_dir = $self->get('Dummy package path');
    my $dummy_archive_dir = $dummy_dir . '/apt_archive';
    my $dummy_packages_file = $dummy_archive_dir . '/Packages';
    my $dummy_sources_file = $dummy_archive_dir . '/Sources';
    my $dummy_release_file = $dummy_archive_dir . '/Release';
    my $dummy_archive_list_file = $session->get('Location') .
        '/etc/apt/sources.list.d/sbuild-build-depends-archive.list';
    my $dummy_archive_seckey = '/tmp/sbuild-key.sec';
    my $dummy_archive_pubkey = '/tmp/sbuild-key.pub';

    $self->set('Dummy archive directory', $dummy_archive_dir);
    $self->set('Dummy Packages file', $dummy_packages_file);
    $self->set('Dummy Sources file', $dummy_sources_file);
    $self->set('Dummy Release file', $dummy_release_file);
    $self->set('Dummy archive list file', $dummy_archive_list_file);

    if (! -d $dummy_dir) {
	$builder->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . ': ' . $!);
	$self->cleanup_apt_archive();
	return 0;
    }
    if (!mkdir $dummy_archive_dir) {
        $builder->log_warning('Could not create build-depends dummy archive dir ' . $dummy_archive_dir . ': ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }

    # Filehandles
    my ($dummy_packages_fh, $dummy_sources_fh, $dummy_release_fh);

    # Create a blank Packages file.
    if (!open($dummy_packages_fh, '>', $dummy_packages_file)) {
        $builder->log_warning('Could not open ' . $dummy_packages_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    close($dummy_packages_fh);
    if (!(gzip $dummy_packages_file => "$dummy_packages_file.gz", AutoClose => 1, BinModeIn => 1, Append => 0, -Level => Z_NO_COMPRESSION)) {
        $builder->log_warning('Could not compress ' . $dummy_packages_file . ': ' . "$GzipError");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Create a blank Sources file.
    if (!open($dummy_sources_fh, '>', $dummy_sources_file)) {
        $builder->log_warning('Could not open ' . $dummy_sources_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    close($dummy_sources_fh);
    if (!(gzip $dummy_sources_file => "$dummy_sources_file.gz", AutoClose => 1, BinModeIn => 1, Append => 0, -Level => Z_NO_COMPRESSION)) {
        $builder->log_warning('Could not compress ' . $dummy_sources_file . ': ' . "$GzipError");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write the Release file.
    if (!open($dummy_release_fh, '>', $dummy_release_file)) {
        $builder->log_warning('Could not open ' . $dummy_release_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    print $dummy_release_fh <<"EOF";
Origin: sbuild-build-depends-archive
Label: sbuild-build-depends-archive
Suite: invalid
Codename: invalid
Description: Sbuild Build Dependency Temporary Archive
MD5Sum:
EOF
    print $dummy_release_fh ' ' . $self->md5_hex_file($dummy_packages_file) . ' ' .
          (-s $dummy_packages_file) . " Packages\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file("$dummy_packages_file.gz") . ' ' .
          (-s "$dummy_packages_file.gz") . " Packages.gz\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file($dummy_sources_file) . ' ' .
          (-s $dummy_sources_file) . " Sources\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file("$dummy_sources_file.gz") . ' ' .
          (-s "$dummy_sources_file.gz") . " Sources.gz\n";
    close($dummy_release_fh);

    # Sign the release file
    my @gpg_command = ('gpg', '--yes', '--no-default-keyring',
                       '--secret-keyring', $dummy_archive_seckey,
                       '--keyring', $dummy_archive_pubkey,
                       '--default-key', 'Sbuild Signer', '-abs',
                       '-o', $session->strip_chroot_path($dummy_release_file) . '.gpg',
                       $session->strip_chroot_path($dummy_release_file));
    $session->run_command(
	{ COMMAND => \@gpg_command,
	  USER => $self->get_conf('USER'),
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Failed to sign dummy archive Release file.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write a list file for the dummy archive
    my ($tmpfh, $tmpfilename) = tempfile();
    print $tmpfh 'deb file://' . $session->strip_chroot_path($dummy_archive_dir) . " ./\n";
    print $tmpfh 'deb-src file://' . $session->strip_chroot_path($dummy_archive_dir) . " ./\n";
    close($tmpfh);
    # List file needs to be moved with root.
    $session->run_command(
	{ COMMAND => ['mv', $tmpfilename,
                      $session->strip_chroot_path($dummy_archive_list_file)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Failed to create apt list file for dummy archive.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Add the generated key and rerun apt-get update
    $session->run_command(
	{ COMMAND => ['apt-key', 'add', $session->strip_chroot_path($dummy_archive_pubkey)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Failed to add dummy archive key.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    $self->set('Dummy archive created', 1);
    return 1;
}

# Adds entries to an archive
sub add_archive_entry {
    my $self = shift;
    my $name = shift;
    my @pkgs = @_;

    my $builder = $self->get('Builder');
    my $session = $builder->get('Session');

    if (!defined($self->get('Dummy archive created'))) {
	$builder->log_warning('Dummy apt archive has not been created!' . "\n");
	return 0;
    }

    my $dummy_pkg_name = 'sbuild-build-depends-' . $name. '-dummy';
    #Prepare a path to build a dummy package containing our deps:
    my $dummy_pkg_dir = $self->get('Dummy package path') . '/' . $dummy_pkg_name;
    my $dummy_archive_dir = $self->get('Dummy archive directory');
    my $dummy_packages_file = $self->get('Dummy Packages file');
    my $dummy_sources_file = $self->get('Dummy Sources file');
    my $dummy_release_file = $self->get('Dummy Release file');
    my $dummy_archive_list_file = $self->get('Dummy archive list file');
    my $dummy_deb = $dummy_archive_dir . '/' . $dummy_pkg_name . '.deb';
    my $dummy_archive_seckey = '/tmp/sbuild-key.sec';
    my $dummy_archive_pubkey = '/tmp/sbuild-key.pub';

    if (!(mkdir($dummy_pkg_dir) && mkdir($dummy_pkg_dir . '/DEBIAN'))) {
	$builder->log_warning('Could not create build-depends dummy dir ' . $dummy_pkg_dir . '/DEBIAN: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }

    if (!open(DUMMY_CONTROL, '>', $dummy_pkg_dir . '/DEBIAN/control')) {
	$builder->log_warning('Could not open ' . $dummy_pkg_dir . '/DEBIAN/control for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }

    my $arch = $builder->get('Arch');
    print DUMMY_CONTROL <<"EOF";
Package: $dummy_pkg_name
Version: 0.invalid.0
Architecture: $arch
EOF

    my @positive;
    my @negative;
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
	push(@positive_indep, $deps->{'Build Depends Indep'})
	    if (defined($deps->{'Build Depends Indep'}) &&
		$deps->{'Build Depends Indep'} ne "");
	push(@negative_indep, $deps->{'Build Conflicts Indep'})
	    if (defined($deps->{'Build Conflicts Indep'}) &&
		$deps->{'Build Conflicts Indep'} ne "");
    }

    my ($positive, $negative);
    if ($self->get_conf('BUILD_ARCH_ALL')) {
	$positive = deps_parse(join(", ", @positive, @positive_indep),
			       reduce_arch => 1,
			       host_arch => $builder->get('Arch'));
	$negative = deps_parse(join(", ", @negative, @negative_indep),
			       reduce_arch => 1,
			       host_arch => $builder->get('Arch'));
    } else {
	$positive = deps_parse(join(", ", @positive),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));
	$negative = deps_parse(join(", ", @negative),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));
    }

    if ($positive ne "") {
	print DUMMY_CONTROL 'Depends: ' . $positive . "\n";
    }
    if ($negative ne "") {
	print DUMMY_CONTROL 'Conflicts: ' . $negative . "\n";
    }

    debug("DUMMY Depends: $positive \n");
    debug("DUMMY Conflicts: $negative \n");

    print DUMMY_CONTROL <<"EOF";
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
Description: Dummy package to satisfy dependencies with apt - created by sbuild
 This package was created automatically by sbuild and should never appear on
 a real system. You can safely remove it.
EOF
    close (DUMMY_CONTROL);

    #Now build the package:
    $session->run_command(
	{ COMMAND => ['dpkg-deb', '--build', $session->strip_chroot_path($dummy_pkg_dir), $session->strip_chroot_path($dummy_deb)],
	  USER => $self->get_conf('USER'),
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Dummy package creation failed\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Acquire the dummy package size and MD5 sum
    my $dummy_size = -s $dummy_deb;
    my $dummy_md5sum = $self->md5_hex_file($dummy_deb);

    # Now create a Packages, Sources, and Release file for use in installing
    # the dummy package.
    my ($dummy_packages_fh, $dummy_sources_fh, $dummy_release_fh);

    # Write the Packages file.
    if (!open($dummy_packages_fh, '>>', $dummy_packages_file)) {
        $builder->log_warning('Could not open ' . $dummy_packages_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    print $dummy_packages_fh <<"EOF";
Package: $dummy_pkg_name
Priority: extra
Section: misc
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
Architecture: $arch
Version: 0.invalid.0
Source: $dummy_pkg_name
EOF
    if ($positive ne "") {
	print $dummy_packages_fh 'Depends: ' . $positive . "\n";
    }
    if ($negative ne "") {
	print $dummy_packages_fh 'Conflicts: ' . $negative . "\n";
    }
    print $dummy_packages_fh "Filename: " . basename($dummy_deb) . "\n";
    print $dummy_packages_fh <<"EOF";
Size: $dummy_size
MD5sum: $dummy_md5sum
Description: Dummy package to satisfy dependencies with apt - created by sbuild
 This package was created automatically by sbuild and should never appear on
 a real system. You can safely remove it.
EOF
    print $dummy_packages_fh "\n";
    close($dummy_packages_fh);
    if (!(gzip $dummy_packages_file => "$dummy_packages_file.gz", AutoClose => 1, BinModeIn => 1, Append => 0, -Level => Z_NO_COMPRESSION)) {
        $builder->log_warning('Could not compress ' . $dummy_packages_file . ': ' . "$GzipError");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write the Sources file.
    if (!open($dummy_sources_fh, '>>', $dummy_sources_file)) {
        $builder->log_warning('Could not open ' . $dummy_sources_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    print $dummy_sources_fh <<"EOF";
Package: $dummy_pkg_name
Binary: $dummy_pkg_name
Version: 0.invalid.0
Priority: extra
Section: misc
Maintainer: Debian buildd-tools Developers <buildd-tools-devel\@lists.alioth.debian.org>
Architecture: any
EOF
    if (scalar(@positive)) {
	print $dummy_sources_fh 'Build-Depends: ' . join(", ", @positive) . "\n";
    }
    if (scalar(@negative)) {
	print $dummy_sources_fh 'Build-Conflicts: ' . join(", ", @negative) . "\n";
    }
    if (scalar(@positive_indep)) {
	print $dummy_sources_fh 'Build-Depends-Indep: ' . join(", ", @positive_indep) . "\n";
    }
    if (scalar(@negative_indep)) {
	print $dummy_sources_fh 'Build-Conflicts-Indep: ' . join(", ", @negative_indep) . "\n";
    }
    print $dummy_sources_fh "\n";
    close($dummy_sources_fh);
    if (!(gzip $dummy_sources_file => "$dummy_sources_file.gz", AutoClose => 1, BinModeIn => 1, Append => 0, -Level => Z_NO_COMPRESSION)) {
        $builder->log_warning('Could not compress ' . $dummy_sources_file . ': ' . "$GzipError");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write the Release file.
    if (!open($dummy_release_fh, '>', $dummy_release_file)) {
        $builder->log_warning('Could not open ' . $dummy_release_file . ' for writing: ' . $!);
        $self->cleanup_apt_archive();
	return 0;
    }
    print $dummy_release_fh <<"EOF";
Origin: sbuild-build-depends-archive
Label: sbuild-build-depends-archive
Suite: invalid
Codename: invalid
Description: Sbuild Build Dependency Temporary Archive
MD5Sum:
EOF
    print $dummy_release_fh ' ' . $self->md5_hex_file($dummy_packages_file) . ' ' .
          (-s $dummy_packages_file) . " Packages\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file("$dummy_packages_file.gz") . ' ' .
          (-s "$dummy_packages_file.gz") . " Packages.gz\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file($dummy_sources_file) . ' ' .
          (-s $dummy_sources_file) . " Sources\n";
    print $dummy_release_fh ' ' . $self->md5_hex_file("$dummy_sources_file.gz") . ' ' .
          (-s "$dummy_sources_file.gz") . " Sources.gz\n";
    close($dummy_release_fh);

    # Sign the release file
    my @gpg_command = ('gpg', '--yes', '--no-default-keyring',
                       '--secret-keyring', $dummy_archive_seckey,
                       '--keyring', $dummy_archive_pubkey,
                       '--default-key', 'Sbuild Signer', '-abs',
                       '-o', $session->strip_chroot_path($dummy_release_file) . '.gpg',
                       $session->strip_chroot_path($dummy_release_file));
    $session->run_command(
	{ COMMAND => \@gpg_command,
	  USER => $self->get_conf('USER'),
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Failed to sign dummy archive Release file.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    return 1;
}

# Convenience function to run 'apt-get update'.
sub run_apt_update {
    my $self = shift;
    my $builder = $self->get('Builder');
    my $session = $builder->get('Session');
    $session->run_command(
	{ COMMAND => ['apt-get', 'update'],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Failed to run 'apt-get update'.\n");
        $self->cleanup_apt_archive();
	return 0;
    }
    return 1;
}

# Remove the apt archive.
sub cleanup_apt_archive {
    my $self = shift;
    my $session = $self->get('Builder')->get('Session');
    remove_tree($self->get('Dummy package path'));
    $session->run_command(
	{ COMMAND => ['rm', '-f', $session->strip_chroot_path($self->get('Dummy archive list file'))],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});
    $self->set('Dummy package path', undef);
    $self->set('Dummy archive directory', undef);
    $self->set('Dummy Packages file', undef);
    $self->set('Dummy Sources file', undef);
    $self->set('Dummy Release file', undef);
    $self->set('Dummy archive list file', undef);
    $self->set('Dummy archive created', undef);
}

# Convenience function that calculates MD5 sum of an entire file.
sub md5_hex_file {
    my $self = shift;
    my $file = shift;

    my $md5_fh;
    if (!open($md5_fh, $file)) {
        $self->get('Builder')->log_warning("Could not open $file to retrieve MD5 sum.\n");
        return 0;
    }
    binmode $md5_fh;
    my $md5sum = Digest::MD5->new->addfile($md5_fh)->hexdigest;
    close $md5_fh;

    return $md5sum;
}

1;
