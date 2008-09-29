#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfoSudo;

use Sbuild::ChrootInfo;
use Sbuild::ChrootSudo;

use strict;
use warnings;

sub new ($$);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootInfo);

    @EXPORT = qw();
}

sub new ($$) {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub get_info_all (\%) {
    my $self = shift;

    my $chroots = {};
    my $build_dir = $self->get_conf('BUILD_DIR');

    # TODO: Configure $build_dir as $sudo_chroot_dir
    foreach (glob($self->get_conf('SBUILD_MODE') eq "user" ?
		  "/etc/sbuild/chroot/*" :
		  "$build_dir/chroot-*")) {
	my %tmp = ('Priority' => 0,
		   'Location' => $_,
		   'Session Purged' => 0);
	if (-d $tmp{'Location'}) {
	    my $name = $_;
	    if ($self->get_conf('SBUILD_MODE') eq "user") {
		$name =~ s/^\/etc\/sbuild\/chroot\///;
	    } else {
		$name =~ s/\Q${build_dir}\/chroot-\E//;
	    }
	    if ($self->get_conf('DEBUG')) {
		print STDERR "Found chroot $name\n";
		foreach (sort keys %tmp) {
		    print STDERR "  $_ $tmp{$_}\n";
		}
	    }

	    $chroots->{$name} = \%tmp;
	}
    }

    $self->set('Chroots', $chroots);
}

sub _create (\%$) {
    my $self = shift;
    my $chroot_id = shift;

    my $chroot = undef;

    if (defined($chroot_id)) {
	$chroot = Sbuild::ChrootSudo->new($self->get('Config'), $chroot_id);
    }

    return $chroot;
}

1;
