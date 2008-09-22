#
# Chroot.pm: chroot library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootSudo;

use Sbuild::Conf;
use Sbuild::ChrootInfoSudo;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new ($$$$$);

sub new ($$$$$) {
# TODO: specify distribution parameters here...
    my $class = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;
    my $conf = shift;

    my $info = Sbuild::ChrootInfoSudo->new($conf);

    my $self = $class->SUPER::new($distribution, $chroot, $arch, $conf, $info);
    bless($self, $class);

    return $self;
}

1;
