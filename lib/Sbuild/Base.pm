#
# Base.pm: base class containing common class infrastructure
# Copyright © 2008 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Base;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new ($$);
sub get (\%$);
sub set (\%$$);
sub get_conf (\%$);
sub set_conf (\%$$);

sub new ($$) {
    my $class = shift;
    my $conf = shift;

    my $self  = {};
    bless($self, $class);

    $self->set('Config', $conf);

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

sub get_conf (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->get('Config')->get($key);
}

sub set_conf (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->get('Config')->set($key,$value);
}

sub log ($) {
    my $self = shift;

    my $logfile = $self->get('Log Stream');
    if (defined($logfile)) {
	print $logfile @_;
    } else {
	print STDERR "E: Attempt to log to nonexistent log stream\n"
	    if (!defined($self->get('Log Stream Error')) ||
		!$self->get('Log Stream Error'));
	$self->set('Log Stream Error', 1)
    }
}

sub log_info ($) {
    my $self = shift;

    $self->log("I: ", @_);
}

sub log_warning ($) {
    my $self = shift;

    $self->log("W: ", @_);
}

sub log_error ($) {
    my $self = shift;

    $self->log("E: ", @_);
}

1;
