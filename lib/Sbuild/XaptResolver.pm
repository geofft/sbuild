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

package Sbuild::XaptResolver;

use strict;
use warnings;

use Sbuild qw(debug);
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
    my $cross = shift;
    my @pkgs = @_;

    my $status = 0;
    my $session = $self->get('Session');
#    my $dummy_pkg_name = 'sbuild-build-depends-' . $name. '-dummy';

    # Call functions to setup an archive to install dummy package.
#    return 0 unless ($self->setup_apt_archive($dummy_pkg_name, @pkgs));
#    return 0 unless (!$self->update_archive());


    $self->log_subsection("Install $name cross-build dependencies (xapt-based resolver)");

    # Install the dummy package
    my (@instd, @rmvd);
    $self->log("Installing cross-build dependencies\n");
    if (!$self->run_xapt("-a", $self->get_conf('HOST_ARCH'), @pkgs)) {
	$self->log("Package installation failed\n");
	if (defined ($self->get('Session')->get('Session Purged')) &&
	    $self->get('Session')->get('Session Purged') == 1) {
	    $self->log("Not removing build depends: cloned chroot in use\n");
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
	    $self->log("Not removing installed packages: cloned chroot in use\n");
	} else {
	    $self->uninstall_deps();
	}
    }

    $self->cleanup_apt_archive();

    return $status;
}

1;
