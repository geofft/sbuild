# BuildDepSatisfierBase.pm: build library for sbuild
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

package Sbuild::AptitudeBuildDepSatisfier;

use strict;
use warnings;
use File::Temp qw(tempdir);

use Sbuild qw(debug copy);
use Sbuild::Base;
use Sbuild::BuildDepSatisfierBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::BuildDepSatisfierBase);

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
    my $builder = $self->get('Builder');

    $builder->log_subsection("Install build dependencies (aptitude-based resolver)");

    my $pkg = $builder->get('Package');

    my $dep = [];
    if (exists $builder->get('Dependencies')->{$pkg}) {
	$dep = $builder->get('Dependencies')->{$pkg};
    }
    debug("Source dependencies of $pkg: ", $builder->format_deps(@$dep), "\n");

  repeat:
    my $session = $builder->get('Session');
    $builder->lock_file($session->get('Install Lock'), 1);

    #install aptitude first:
    my (@aptitude_installed_packages, @aptitude_removed_packages);
    if (!$builder->run_apt('-y', \@aptitude_installed_packages, \@aptitude_removed_packages, 'aptitude')) {
	$self->log_warning('Could not install aptitude!');
	goto cleanup;
    }
    $self->set_installed(@aptitude_installed_packages);
    $self->set_removed(@aptitude_removed_packages);


    #Prepare a path to build a dummy package containing our deps:
    $self->set('Dummy package path',
	       tempdir($builder->get_conf('USERNAME') . '-' . $pkg . '-' .
		       $builder->get('Arch') . '-XXXXXX',
		       DIR => $session->get('Build Location')));
  
    my $dummy_pkg_name = 'sbuild-build-depends-' . $pkg . '-dummy';
    my $dummy_dir = $self->get('Dummy package path') . '/' . $dummy_pkg_name;
    my $dummy_deb = $self->get('Dummy package path') . '/' . $dummy_pkg_name . '.deb';

    if (!mkdir $dummy_dir) {
	$self->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . ': ' . $!);
 	goto cleanup;
    }
    if (!mkdir $dummy_dir . '/DEBIAN') {
	$self->log_warning('Could not create build-depends dummy dir ' . $dummy_dir . '/DEBIAN: ' . $!);
	goto cleanup;
    }

    if (!open(DUMMY_CONTROL, '>', $dummy_dir . '/DEBIAN/control')) {
	$self->log_warning('Could not open ' . $dummy_dir . '/DEBIAN/control for writing: ' . $!);
	goto cleanup;
    }

    my (@positive_deps, @negative_deps);
    for my $dep_entry (@$dep) {
	if ($dep_entry->{'Neg'}) {
	    my $new_dep_entry = copy($dep_entry);
	    $new_dep_entry->{'Neg'} = 0;
	    push @negative_deps, $new_dep_entry;
	} else {
	    push @positive_deps, $dep_entry;
	}
    }

    my $arch = $builder->get('Arch');
    print DUMMY_CONTROL <<"EOF";
Package: $dummy_pkg_name
Version: 0.invalid.0
Architecture: $arch
EOF

    if (@positive_deps) {
	print DUMMY_CONTROL 'Depends: ' . $builder->format_deps(@positive_deps) . "\n";
    }
    if (@negative_deps) {
	print DUMMY_CONTROL 'Conflicts: ' . $builder->format_deps(@negative_deps) . "\n";
    }

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
    $session->run_command(
	    { COMMAND => ['dpkg', '--install', $session->strip_chroot_path($dummy_deb)],
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0});
    $self->set_installed(keys %{$self->get('Changes')->{'installed'}}, $dummy_pkg_name);

    my $pipe = $session->pipe_command(
	    { COMMAND => [
		'aptitude', 
		    '-y', 
		    '--without-recommends', 
		    '-o', 'APT::Install-Recommends=false', 
		    '-o', 'Aptitude::CmdLine::Ignore-Trust-Violations=true', 
		    '-o', 'Aptitude::ProblemResolver::StepScore=100', 
		    'install',
		    $dummy_pkg_name],
	      PIPE => 'in',
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

    if (!$pipe) {
	$self->log_warning('Cannot open pipe from aptitude: ' . $! . "\n");
	goto aptitude_cleanup;
    }

    my $aptitude_output = "";
    while(<$pipe>) {
	$aptitude_output .= $_;
	$self->log($_);
    }

    close($pipe);

    if ($aptitude_output =~ /^E:/m) {
	$self->log('Satisfying build-deps with aptitude failed.' . "\n");
	goto aptitude_cleanup;
    }

    my ($installed_pkgs, $removed_pkgs) = ("", "");
    while ($aptitude_output =~ /The following NEW packages will be installed:\n((^[  ].*\n)*)/gmi) {
	($installed_pkgs = $1) =~ s/^[    ]*((.|\n)*)\s*$/$1/m;
	$installed_pkgs =~ s/\*//g;
    }
    while ($aptitude_output =~ /The following packages will be REMOVED:\n((^[    ].*\n)*)/gmi) {
	($removed_pkgs = $1) =~ s/^[   ]*((.|\n)*)\s*$/$1/m;
	$removed_pkgs =~ s/\*//g;
	$removed_pkgs =~ s/\{.\}//g; #remove {u}, {a} in output...
    }

    my @installed_packages = split( /\s+/, $installed_pkgs);

    $self->set_installed(keys %{$self->get('Changes')->{'installed'}}, @installed_packages);
    $self->set_removed(keys %{$self->get('Changes')->{'removed'}}, split( /\s+/, $removed_pkgs));

    #Seems it all went fine.
    $builder->unlock_file($builder->get('Session')->get('Install Lock'));

    return 1;

  aptitude_cleanup:
    $session->run_command(
	    { COMMAND => ['dpkg', '--purge', 'aptitude'],
	      USER => $self->get_conf('USERNAME'),
	      CHROOT => 1,
	      PRIORITY => 0});
    $session->run_command(
	    { COMMAND => ['dpkg', '--purge', $dummy_pkg_name],
	      USER => $self->get_conf('USERNAME'),
	      CHROOT => 1,
	      PRIORITY => 0});

  cleanup:
    $self->set('Dummy package path', undef);
    $builder->unlock_file($builder->get('Session')->get('Install Lock'), 1);

    return 0;
}

1;
