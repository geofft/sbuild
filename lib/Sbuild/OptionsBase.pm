#
# OptionsBase.pm: options parser (base functionality) for sbuild
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

package Sbuild::OptionsBase;

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case auto_abbrev gnu_getopt);
use Sbuild qw(help_text version_text usage_error);
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
    my $program = shift;
    my $section = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->add_options("h|help" => sub { help_text($section, $program); },
		       "V|version" => sub {version_text($program); },
		       "D|debug" => sub {
			   $self->set_conf('DEBUG',
					   $self->get_conf('DEBUG') + 1); },
		       "v|verbose" => sub {
			   $self->set_conf('VERBOSE',
					   $self->get_conf('VERBOSE') + 1);
		       },
		       "q|quiet" => sub {
			   $self->set_conf('VERBOSE',
					   $self->get_conf('VERBOSE') - 1)
			       if $self->get_conf('VERBOSE');
		       });

    $self->set_options();

    if (!$self->parse_options()) {
	usage_error($program, "Error parsing command-line options");
	return undef;
    }
    return $self;
}

sub add_options () {
    my $self = shift;
    my @newopts = @_;

    my %options;
    if (defined($self->get('Options'))) {
	%options = (%{$self->get('Options')}, @newopts);
    } else {
	%options = (@newopts);
    }
    $self->set('Options', \%options);
}

sub set_options () {
    my $self = shift;
}

sub parse_options {
    my $self = shift;

    return GetOptions((%{$self->get('Options')}));
}

1;
