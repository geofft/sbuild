# Buildd common base functionality
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
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

package Buildd::Base;

use strict;
use warnings;

use Buildd qw(lock_file unlock_file);

use Sbuild::Base;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub write_stats ($$$) {
    my $self = shift;
    my ($cat, $val) = @_;

    local( *F );

    my $home = $self->get_conf('HOME');

    lock_file( "$home/stats" );
    open( F, ">>$home/stats/$cat" );
    print F "$val\n";
    close( F );
    unlock_file( "$home/stats" );
}

1;
