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
    my $conf = shift;
    my $session = shift;
    my $host = shift;

    my $self = $class->SUPER::new($conf, $session, $host);
    bless($self, $class);

    return $self;
}

sub install_deps {
    my $self = shift;
    my $name = shift;
    my @pkgs = @_;


    my $status = 0;
    my $session = $self->get('Session');
    my $dummy_pkg_name = 'sbuild-build-depends-' . $name. '-dummy';

    # Call functions to setup an archive to install dummy package.
    return 0 unless ($self->setup_apt_archive($dummy_pkg_name, @pkgs));
    return 0 unless (!$self->update_archive());

    $self->log_subsection("Install $name build dependencies (aptitude-based resolver)");

    #install aptitude first:
    my (@aptitude_installed_packages, @aptitude_removed_packages);
    if (!$self->run_apt('-y', \@aptitude_installed_packages, \@aptitude_removed_packages, 'install', 'aptitude')) {
	$self->log_warning('Could not install aptitude!');
	goto cleanup;
    }
    $self->set_installed(@aptitude_installed_packages);
    $self->set_removed(@aptitude_removed_packages);


    my $ignore_trust_violations =
	$self->get_conf('APT_ALLOW_UNAUTHENTICATED') ? 'true' : 'false';

    my @aptitude_install_command = (
	$self->get_conf('APTITUDE'),
	'-y',
	'--without-recommends',
	'-o', "Aptitude::CmdLine::Ignore-Trust-Violations=$ignore_trust_violations",
	'-o', 'Aptitude::ProblemResolver::StepScore=100',
	'-o', "Aptitude::ProblemResolver::Hints::KeepDummy=reject $dummy_pkg_name :UNINST",
	'-o', 'Aptitude::ProblemResolver::Keep-All-Level=55000',
	'-o', 'Aptitude::ProblemResolver::Remove-Essential-Level=maximum',
	'install',
	$dummy_pkg_name
    );

    $self->log(join(" ", @aptitude_install_command), "\n");

    my $pipe = $self->pipe_aptitude_command(
	    { COMMAND => \@aptitude_install_command,
	      ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	      PIPE => 'in',
	      USER => 'root',
	      PRIORITY => 0,
	      DIR => '/' });

    if (!$pipe) {
	$self->log_warning('Cannot open pipe from aptitude: ' . $! . "\n");
	goto package_cleanup;
    }

    my $aptitude_output = "";
    while(<$pipe>) {
	$aptitude_output .= $_;
	$self->log($_);
    }
    close($pipe);
    my $aptitude_exit_code = $?;

    if ($aptitude_output =~ /^E:/m) {
	$self->log('Satisfying build-deps with aptitude failed.' . "\n");
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
	    $self->log("Not removing installed packages: cloned chroot in use\n");
	} else {
	    $self->uninstall_deps();
	}
    }

  cleanup:
    return $status;
}

1;
