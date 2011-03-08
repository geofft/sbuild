#
# Exception.pm: exceptions for sbuild
# Copyright © 2011 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Exception;

use strict;
use warnings;

use Exception::Class (
    'Sbuild::Exception::Base',

    'Sbuild::Exception::Build' => { isa => 'Sbuild::Exception::Base',
				    fields => [ 'info', 'failstage' ] }

    );

1;
