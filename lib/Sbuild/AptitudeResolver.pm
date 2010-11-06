# ResolverBase.pm: build library for sbuild
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

package Sbuild::AptitudeResolver;

use strict;
use warnings;
use File::Temp qw(tempdir);

use Dpkg::Deps;
use Sbuild qw(debug copy version_compare);
use Sbuild::Base;
use Sbuild::ResolverBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ResolverBase);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $builder = shift;

    my $self = $class->SUPER::new($builder);
    bless($self, $class);

    return $self;
}

sub install_deps {
    my $self = shift;
    my @pkgs = @_;

    my $status = 0;

    my $builder = $self->get('Builder');
    my $session = $builder->get('Session');

    my $dummy_pkg_name = 'sbuild-build-depends-' . $builder->get('Package') . '-dummy';
    #Prepare a path to build a dummy package containing our deps:
    $self->set('Dummy package path',
	       tempdir($builder->get_conf('USERNAME') . '-' . $builder->get('Package') . '-' .
		       $builder->get('Arch') . '-XXXXXX',
		       DIR => $session->get('Build Location')));
    my $dummy_dir = $self->get('Dummy package path') . '/' . $dummy_pkg_name;
    my $dummy_deb = $self->get('Dummy package path') . '/' . $dummy_pkg_name . '.deb';

    $builder->log_subsection("Install build dependencies (aptitude-based resolver)");

    #install aptitude first:
    my (@aptitude_installed_packages, @aptitude_removed_packages);
    if (!$self->run_apt('-y', \@aptitude_installed_packages, \@aptitude_removed_packages, 'install', 'aptitude')) {
	$builder->log_warning('Could not install aptitude!');
	goto cleanup;
    }
    $self->set_installed(@aptitude_installed_packages);
    $self->set_removed(@aptitude_removed_packages);

    if (!mkdir $dummy_dir) {
	$builder->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . ': ' . $!);
 	goto cleanup;
    }
    if (!mkdir $dummy_dir . '/DEBIAN') {
	$builder->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . '/DEBIAN: ' . $!);
	goto cleanup;
    }

    if (!open(DUMMY_CONTROL, '>', $dummy_dir . '/DEBIAN/control')) {
	$builder->log_warning('Could not open ' . $dummy_dir . '/DEBIAN/control for writing: ' . $!);
	goto cleanup;
    }

    my $arch = $builder->get('Arch');
    print DUMMY_CONTROL <<"EOF";
Package: $dummy_pkg_name
Version: 0.invalid.0
Architecture: $arch
EOF

    my @positive;
    my @negative;

    for my $pkg (@pkgs) {
	my $deps = $self->get('AptDependencies')->{$pkg};

	push(@positive, $deps->{'Build Depends'})
	    if (defined($deps->{'Build Depends'}) &&
		$deps->{'Build Depends'} ne "");
	push(@negative, $deps->{'Build Conflicts'})
	    if (defined($deps->{'Build Conflicts'}) &&
		$deps->{'Build Conflicts'} ne "");
	if ($self->get_conf('BUILD_ARCH_ALL')) {
	    push(@positive, $deps->{'Build Depends Indep'})
		if (defined($deps->{'Build Depends Indep'}) &&
		    $deps->{'Build Depends Indep'} ne "");
	    push(@negative, $deps->{'Build Conflicts Indep'})
		if (defined($deps->{'Build Conflicts Indep'}) &&
		    $deps->{'Build Conflicts Indep'} ne "");
	}
    }

    my $positive = deps_parse(join(", ", @positive),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));
    my $negative = deps_parse(join(", ", @negative),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));

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
Description: Dummy package to satisfy dependencies with aptitude - created by sbuild
 This package was created automatically by sbuild and should never appear on
 a real system. You can safely remove it.
EOF
    close (DUMMY_CONTROL);

    #Now build and install the package:
    $session->run_command(
	{ COMMAND => ['dpkg-deb', '--build', $session->strip_chroot_path($dummy_dir), $session->strip_chroot_path($dummy_deb)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});
    if ($?) {
	$builder->log("Dummy package creation failed\n");
	goto cleanup;
    }

    $session->run_command(
	{ COMMAND => ['dpkg', '--force-depends', '--force-conflicts', '--install', $session->strip_chroot_path($dummy_deb)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});

    $self->set_installed(keys %{$self->get('Changes')->{'installed'}}, $dummy_pkg_name);

    if ($?) {
	$builder->log("Dummy package installation failed\n");
	goto package_cleanup;
    }

    my $ignore_trust_violations =
	$self->get_conf('APT_ALLOW_UNAUTHENTICATED') ? 'true' : 'false';

    my @aptitude_install_command = (
	$self->get_conf('APTITUDE'),
	'-y',
	'--without-recommends',
	'-o', "Aptitude::CmdLine::Ignore-Trust-Violations=$ignore_trust_violations",
	'-o', 'Aptitude::ProblemResolver::StepScore=100',
	'-o', "Aptitude::ProblemResolver::Hints::KeepDummy=reject $dummy_pkg_name :UNINST",
	'-o', 'Aptitude::ProblemResolver::Keep-All-Tier=55000',
	'-o', 'Aptitude::ProblemResolver::Remove-Essential-Tier=maximum',
	'install',
	$dummy_pkg_name
    );

    $builder->log(join(" ", @aptitude_install_command), "\n");

    my $pipe = $session->pipe_aptitude_command(
	    { COMMAND => \@aptitude_install_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      PIPE => 'in',
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

    if (!$pipe) {
	$builder->log_warning('Cannot open pipe from aptitude: ' . $! . "\n");
	goto package_cleanup;
    }

    my $aptitude_output = "";
    while(<$pipe>) {
	$aptitude_output .= $_;
	$builder->log($_);
    }
    close($pipe);
    my $aptitude_exit_code = $?;

    if ($aptitude_output =~ /^E:/m) {
	$builder->log('Satisfying build-deps with aptitude failed.' . "\n");
	goto package_cleanup;
    }

    my ($installed_pkgs, $removed_pkgs) = ("", "");
    while ($aptitude_output =~ /The following NEW packages will be installed:\n((^[  ].*\n)*)/gmi) {
	($installed_pkgs = $1) =~ s/^[    ]*((.|\n)*)\s*$/$1/m;
	$installed_pkgs =~ s/\*//g;
	$installed_pkgs =~ s/\{.\}//g;
    }
    while ($aptitude_output =~ /The following packages will be REMOVED:\n((^[    ].*\n)*)/gmi) {
	($removed_pkgs = $1) =~ s/^[   ]*((.|\n)*)\s*$/$1/m;
	$removed_pkgs =~ s/\*//g;
	$removed_pkgs =~ s/\{.\}//g; #remove {u}, {a} in output...
    }

    my @installed_packages = split( /\s+/, $installed_pkgs);

    $self->set_installed(keys %{$self->get('Changes')->{'installed'}}, @installed_packages);
    $self->set_removed(keys %{$self->get('Changes')->{'removed'}}, split( /\s+/, $removed_pkgs));

    if ($aptitude_exit_code != 0) {
	goto package_cleanup;
    }

    #Seems it all went fine.

    $status = 1;

  package_cleanup:
    if ($status == 0) {
	if (defined ($session->get('Session Purged')) &&
	    $session->get('Session Purged') == 1) {
	    $builder->log("Not removing installed packages: cloned chroot in use\n");
	} else {
	    $self->uninstall_deps();
	}
    }

    $session->run_command(
	{ COMMAND => ['rm', $session->strip_chroot_path($dummy_deb)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});

  cleanup:
    $session->run_command(
	{ COMMAND => ['rm', '-rf', $session->strip_chroot_path($dummy_dir)],
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0});

    $self->set('Dummy package path', undef);

    return $status;
}

1;
