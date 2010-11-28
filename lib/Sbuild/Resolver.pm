#
# Resolver.pm: library for sbuild
# Copyright © 2010 Roger Leigh <rleigh@debian.org
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

package Sbuild::Resolver;

use Sbuild::InternalResolver;
use Sbuild::AptResolver;
use Sbuild::AptitudeResolver;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(get_resolver);
}

sub get_resolver ($$);

sub get_resolver ($$) {
    my $conf = shift;
    my $session = shift;

    my $resolver;
    if ($conf->get('BUILD_DEP_RESOLVER') eq "apt") {
	$resolver = Sbuild::AptResolver->new($conf, $session);
    } elsif ($conf->get('BUILD_DEP_RESOLVER') eq "aptitude") {
	$resolver = Sbuild::AptitudeResolver->new($conf, $session);
    } else {
	$resolver = Sbuild::InternalResolver->new($conf, $session);
    }

    return $resolver;
}

1;
