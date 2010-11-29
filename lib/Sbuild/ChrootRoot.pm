#
# ChrootRoot.pm: Run commands on the root filesystem
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootRoot;

use strict;
use warnings;

use Sbuild::Conf;
use Sbuild::ChrootPlain;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootPlain);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf, '/');
    bless($self, $class);

    # There's no difference between split and unsplit when running on
    # the root filesystem.
    $self->set('Split', 0);

    return $self;
}

1;
