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

use Sbuild qw(debug copy version_compare);
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
	$builder->log_warning('Could not install aptitude!');
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

    my @non_default_deps = $self->get_non_default_deps(\@positive_deps, {});

    my @aptitude_install_command = (
	'aptitude', 
	'-y', 
	'--without-recommends', 
	'-o', 'APT::Install-Recommends=false', 
	'-o', 'Aptitude::CmdLine::Ignore-Trust-Violations=true', 
	'-o', 'Aptitude::ProblemResolver::StepScore=100', 
	'install',
	$dummy_pkg_name,
	(map { $_->[0] . "=" . $_->[1] } @non_default_deps)
    );

    $builder->log(join(" ", @aptitude_install_command), "\n");

    my $pipe = $session->pipe_command(
	    { COMMAND => \@aptitude_install_comand,
	      PIPE => 'in',
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

    if (!$pipe) {
	$builder->log_warning('Cannot open pipe from aptitude: ' . $! . "\n");
	goto aptitude_cleanup;
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
	goto aptitude_cleanup;
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
    $builder->unlock_file($builder->get('Session')->get('Install Lock'));

    return 1;

  package_cleanup:
    if (defined ($session->get('Session Purged')) &&
	$session->get('Session Purged') == 1) {
	$builder->log("Not removing build depends: cloned chroot in use\n");
    } else {
	$self->uninstall_deps();
    }

  aptitude_cleanup:
    if (defined ($session->get('Session Purged')) &&
        $session->get('Session Purged') == 1) {
	$builder->log("Not removing additional packages: cloned chroot in use\n");
    } else {
	$session->run_command(
		{ COMMAND => ['dpkg', '--purge', keys %{$self->get('Changes')->{'installed'}}],
		USER => $builder->get_conf('USERNAME'),
		CHROOT => 1,
		PRIORITY => 0});
	$session->run_command(
		{ COMMAND => ['dpkg', '--purge', $dummy_pkg_name],
		USER => $builder->get_conf('USERNAME'),
		CHROOT => 1,
		PRIORITY => 0});
    }

  cleanup:
    $self->set('Dummy package path', undef);
    $builder->unlock_file($builder->get('Session')->get('Install Lock'), 1);

    return 0;
}

sub get_non_default_deps {
    my $self = shift;
    my $deps = shift;
    my $already_checked = shift;

    my $builder = $self->get('Builder');

    my @res;
    foreach my $dep (@$deps) {
	my ($name, $rel, $requested_version) =
	    ($dep->{'Package'}, $dep->{'Rel'}, $dep->{'Version'});

	#Check if we already did this, otherwise mark it as done:
	if ($already_checked->{$name . "_" . ($requested_version || "")}) {
	    next;
	}

	$already_checked->{$name . "_" . ($requested_version || "")} = "True";

	my $dpkg_status = $self->get_dpkg_status($name);
	my $apt_policy = $self->get_apt_policy($name);
	my $default_version = $apt_policy->{$name}->{'defversion'};

	#Check if the package default version is not high enough:
	if (defined($rel) && $rel && $default_version && 
		!version_compare($default_version, $rel, $requested_version)) {
	    $builder->log("Need $name ($rel $requested_version), but default version is $default_version\n");

	    #Check if some of the other versions would do the job:
	    my $found_usable_version;
	    foreach my $non_default_version (@{$apt_policy->{$name}->{versions}}) {
		if (version_compare($non_default_version, $rel, $requested_version)) {
		    #Yay, we can use this:
		    $builder->log("... using version $non_default_version instead\n");
		    push @res, [$name, $non_default_version];
		    $found_usable_version = $non_default_version;

		    #Try to get the deps of this version, then check if we
		    #need additional stuff:
		    my $deps = $self->get_deps($name, $non_default_version);
		    my $expanded_dependencies = $builder->parse_one_srcdep($name, $deps);

		    foreach my $exp_dep (@$expanded_dependencies) {
			my $exp_dep_name = $exp_dep->{'Package'};

			push @res, $self->get_non_default_deps([$exp_dep], $already_checked);
		    }
		    last;
		} elsif ($default_version ne $non_default_version) {
		    $builder->log("... can't use version $non_default_version instead\n");
		}
	    }
	    if (!$found_usable_version) {
		$builder->log("... couldn't find pkg to satisfy " . $builder->format_deps([$dep])  . "\n");
	    }
	}
    }
    return @res;
}

sub get_deps {
    my $self = shift;
    my $requested_pkg = shift;
    my $requested_pkg_version = shift;

    my $builder = $self->get('Builder');
    my $pipe = $builder->get('Session')->pipe_command(
	    { COMMAND => [ $builder->get_conf('APT_CACHE'), '-q', 'show', $requested_pkg ],
	      PIPE => 'in',
	      USER => $builder->get_conf('USERNAME'),
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

    my ($version, $depends, $pre_depends, $res);
    while (<$pipe>){
	my $version = $1 if (/^Version: (.+)$/);
        my $depends = $1 if (/^Depends: (.+)$/);
	my $pre_depends = $1 if (/^Pre-Depends: (.+)$/);
        if (/^\s*\n$/ || eof($pipe)) {
	    if ($version eq $requested_pkg_version) {
		if ($depends && $pre_depends) {
		    $res = $depends . ", " . $pre_depends;
		} elsif ($depends) {
		    $res = $depends;			
		} elsif ($pre_depends) {
		    $res = $pre_depends;
		} else {
		    $res = "";
		}
		last;
	    }
	}
    }
    close ($pipe);

    return $res;
}
1;
