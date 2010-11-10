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

package Sbuild::AptResolver;

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
    my $name = shift;
    my @pkgs = @_;

    my $status = 0;

    my $builder = $self->get('Builder');
    my $session = $builder->get('Session');

    my $dummy_pkg_name = 'sbuild-build-depends-' . $name. '-dummy';
    #Prepare a path to build a dummy package containing our deps:
    $self->set('Dummy package path',
	       tempdir($builder->get_conf('USERNAME') . '-' . $builder->get('Package') . '-' .
		       $builder->get('Arch') . '-XXXXXX',
		       DIR => $session->get('Build Location')));
    my $dummy_dir = $self->get('Dummy package path') . '/' . $dummy_pkg_name;
    my $dummy_deb = $self->get('Dummy package path') . '/' . $dummy_pkg_name . '.deb';

    $builder->log_subsection("Install $name build dependencies (apt-based resolver)");

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
Description: Dummy package to satisfy dependencies with apt - created by sbuild
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

    my (@instd, @rmvd);
    $builder->log("Installing build dependencies\n");
    if (!$self->run_apt("-yf", \@instd, \@rmvd, 'install')) {
	$builder->log("Package installation failed\n");
	if (defined ($builder->get('Session')->get('Session Purged')) &&
	    $builder->get('Session')->get('Session Purged') == 1) {
	    $builder->log("Not removing build depends: cloned chroot in use\n");
	} else {
	    $self->set_installed(@instd);
	    $self->set_removed(@rmvd);
	    goto package_cleanup;
	}
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);
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
