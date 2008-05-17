#
# Build.pm: build library for sbuild
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

package Sbuild::Build;

use Sbuild::Conf;
use Sbuild::Sysconfig;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(new);
}

sub new ();
sub get (\%$);
sub set (\%$$);

sub new() {
    my $self  = {};
    bless($self);


    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->{$key} = $value;
}

sub get_package_status (\$) {
    my $self = shift;

    return $self->get('Package Status');
}
sub get_package_status (\$$) {
    my $self = shift;
    my $status = shift;

    return $self->set('Package Status', $status);
}
