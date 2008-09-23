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

package Sbuild::ChrootInfo;

use strict;
use warnings;

use Sbuild::Base;
use Sbuild::Conf;

use POSIX;
use FileHandle;
use File::Temp ();

sub new ($$);
sub get_info (\%$);
sub get_info_all (\%);
sub find (\%$$$);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new ($$) {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Chroots', {});

    $self->get_info_all();

    return $self;
}

sub find (\%$$$) {
    my $self = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;

    my $chroots = $self->get('Chroots');

    my $arch_set = 1;

    if (!defined($arch) || $arch eq "") {
	$arch = $self->get_conf('ARCH');
	$arch_set = 0;
    }

    my $arch_found = 0;

    if (!defined $chroot) {
        if ($arch ne "" &&
            defined($chroots->{"${distribution}-${arch}-sbuild"})) {
            $chroot = "${distribution}-${arch}-sbuild";
            $arch_found = 1;
        }
        elsif (defined($chroots->{"${distribution}-sbuild"})) {
            $chroot = "${distribution}-sbuild";
        }
        elsif ($arch ne "" &&
               defined($chroots->{"${distribution}-${arch}"})) {
            $chroot = "${distribution}-${arch}";
            $arch_found = 1;
        } elsif (defined($chroots->{$distribution})) {
            $chroot = $distribution;
	}

	if ($arch_set && !$arch_found && $arch ne "") {
	    # TODO: Return error, rather than die.
	    die "Chroot $distribution for architecture $arch not found\n";
	    return undef;
	}
    }

    if (!$chroot) {
	# TODO: Return error, rather than die.
	die "Chroot for distribution $distribution, architecture $arch not found\n";
	return undef;
    }

    return $chroot;
}

1;
