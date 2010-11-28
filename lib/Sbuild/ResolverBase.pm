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
use File::Temp qw(tempdir tempfile);
use File::Path qw(remove_tree);
use File::Copy;

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
    my $conf = shift;
    my $session = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Session', $session);
    $self->set('Changes', {});
    $self->set('AptDependencies', {});

    my $dummy_archive_list_file = $session->get('Location') .
        '/etc/apt/sources.list.d/sbuild-build-depends-archive.list';
    $self->set('Dummy archive list file', $dummy_archive_list_file);

    return $self;
}

sub setup {
    my $self = shift;

    $self->cleanup_apt_archive();
}

sub cleanup {
    my $self = shift;

    $self->cleanup_apt_archive();
}

sub update {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), 'update'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub upgrade {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub distupgrade {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-uy', '-o', 'Dpkg::Options::=--force-confold', 'dist-upgrade'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub clean {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'clean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoclean {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
	{ COMMAND => [$self->get_conf('APT_GET'), '-y', 'autoclean'],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  DIR => '/' });
    return $?;
}

sub autoremove {
    my $self = shift;

    my $session = $self->get('Session');

    $session->run_apt_command(
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
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_indep = shift;

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
	'-q', '--no-install-recommends');
    push @apt_command, '--allow-unauthenticated' if
	($self->get_conf('APT_ALLOW_UNAUTHENTICATED'));
    push @apt_command, "$mode", $action, @packages;
    my $pipe =
	$self->get('Session')->pipe_apt_command(
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
			   DIR => $session->get('Build Location')));
    }
    my $dummy_dir = $self->get('Dummy package path');
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
    if (!(-d $dummy_archive_dir || mkdir $dummy_archive_dir)) {
        $self->log_warning('Could not create build-depends dummy archive dir ' . $dummy_archive_dir . ': ' . $!);
        $self->cleanup_apt_archive();
        return 0;
    }

    my $dummy_pkg_dir = $self->get('Dummy package path') . '/' . $dummy_pkg_name;
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

    my $arch = $self->get('Arch');
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
			       host_arch => $self->get('Arch'));
	$negative = deps_parse(join(", ", @negative, @negative_indep),
			       reduce_arch => 1,
			       host_arch => $self->get('Arch'));
    } else {
	$positive = deps_parse(join(", ", @positive),
			      reduce_arch => 1,
			      host_arch => $self->get('Arch'));
	$negative = deps_parse(join(", ", @negative),
			      reduce_arch => 1,
			      host_arch => $self->get('Arch'));
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
                       '--secret-keyring',
                       $session->strip_chroot_path($dummy_archive_seckey),
                       '--keyring',
                       $session->strip_chroot_path($dummy_archive_pubkey),
                       '--default-key', 'Sbuild Signer', '-abs',
                       '-o', $session->strip_chroot_path($dummy_release_file) . '.gpg',
                       $session->strip_chroot_path($dummy_release_file));
    $session->run_command(
	{ COMMAND => \@gpg_command,
	  USER => $self->get_conf('USER'),
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$self->log("Failed to sign dummy archive Release file.\n");
        $self->cleanup_apt_archive();
	return 0;
    }

    # Write a list file for the dummy archive if one not create yet.
    if (! -f $dummy_archive_list_file) {
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
            $self->log("Failed to create apt list file for dummy archive.\n");
            $self->cleanup_apt_archive();
            return 0;
        }
    }

    # Add the generated key
    $session->run_command(
        { COMMAND => ['apt-key', 'add', $session->strip_chroot_path($dummy_archive_pubkey)],
          USER => 'root',
          CHROOT => 1,
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
	remove_tree($self->get('Dummy package path'));
    }
    $session->run_command(
	{ COMMAND => ['rm', '-f', $session->strip_chroot_path($self->get('Dummy archive list file'))],
	  USER => 'root',
	  CHROOT => 1,
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

    my $session = $self->get('Session');

    if (generate_keys($session, $self->get('Config'))) {
	# Since apt-distupgrade was requested specifically, fail on
	# error when not in buildd mode.
	$self->log("generating gpg keys failed\n");
	return 0;
    }

    return 1;
}

# Function that runs apt-ftparchive
sub run_apt_ftparchive {
    my $self = shift;

    my $session = $self->get('Session');
    my ($tmpfh, $tmpfilename) = tempfile();
    my $dummy_archive_dir = $self->get('Dummy archive directory');

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
    $session->run_command(
        { COMMAND => ['apt-ftparchive', '-q=2', 'generate', $tmpfilename],
          USER => $self->get_conf('USER'),
          CHROOT => 0,
          PRIORITY => 0,
          DIR => '/'});
    if ($?) {
        $env->{'APT_CONFIG'} = $apt_config_value;
        return 0;
    }

    # Get output for Release file
    my $pipe = $session->pipe_command(
        { COMMAND => ['apt-ftparchive', '-q=2', '-c', $tmpfilename, 'release', $dummy_archive_dir],
          USER => $self->get_conf('USER'),
          CHROOT => 0,
          PRIORITY => 0,
          DIR => '/'});
    if (!defined($pipe)) {
        $env->{'APT_CONFIG'} = $apt_config_value;
        return 0;
    }
    $env->{'APT_CONFIG'} = $apt_config_value;

    # Write output to Release file path.
    my ($releasefh);
    if (!open($releasefh, '>', $self->get('Dummy Release file'))) {
        close $pipe;
        return 0;
    }

    while (<$pipe>) {
        print $releasefh $_;
    }
    close $releasefh;
    close $pipe;

    return 1;
}

1;
