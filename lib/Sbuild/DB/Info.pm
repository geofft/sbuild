#
# DBInfo.pm: Database abstraction
# Copyright © 1998      Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::DBInfo;

use Sbuild qw(debug isin);

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(category);
}

sub category ($);

my %short_category = (
    'u' => 'uploaded-fixed-pkg',
    'f' => 'fix-expected',
    'r' => 'reminder-sent',
    'n' => 'nmu-offered',
    'e' => 'easy',
    'm' => 'medium',
    'h' => 'hard',
    'c' => 'compiler-error',
    ''  => 'none'
);

sub category ($) {
    my $category = shift;

    if (!isin($category, values %short_category)) {
	$category = $short_category{$category}
    }

    return $category;
}
