#
# Options.pm: options parser for sbuild
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

package Sbuild::Options;

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case auto_abbrev gnu_getopt);
use Sbuild qw(isin help_text version_text usage_error);
use Sbuild::Conf;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new ($);
sub get (\%$);
sub set (\%$$);
sub get_conf (\%$);
sub set_conf (\%$$);
sub parse_options (\%);

sub new ($) {
    my $conf = shift;

    my $self  = {};
    bless($self);

    $self->{'CONFIG'} = $conf;
    $self->{'User Arch'} = '';
    $self->{'Build Arch All'} = 0;
    $self->{'Auto Giveback'} = 0;
    $self->{'Auto Giveback Host'} = 0;
    $self->{'Auto Giveback Socket'} = 0;
    $self->{'Auto Giveback User'} = 0;
    $self->{'Auto Giveback WannaBuild User'} = 0;
    $self->{'Manual Srcdeps'} = [];
    $self->{'Batch Mode'} = 0;
    $self->{'WannaBuild Database'} = 0;
    $self->{'Build Source'} = 0;
    $self->{'Distribution'} = 'unstable';
    $self->{'Override Distribution'} = 0;
    $self->{'binNMU'} = undef;
    $self->{'binNMU Version'} = undef;
    $self->{'Chroot'} = undef;
    $self->{'LD_LIBRARY_PATH'} = undef;
    $self->{'GCC Snapshot'} = 0;

    if (!$self->parse_options()) {
	usage_error("sbuild", "Error parsing command-line options");
	return undef;
    }
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

# TODO: Check if key exists before setting it.

    return $self->{$key} = $value;
}

sub get_conf (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->get('CONFIG')->get($key);
}

sub set_conf (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

    return $self->get('CONFIG')->set($key,$value);
}

sub parse_options (\%) {
    my $self = shift;

    return GetOptions ("h|help" => sub { help_text("1", "sbuild"); },
		       "V|version" => sub {version_text("sbuild"); },
		       "arch=s" => \$self->{'User Arch'},
		       "A|arch-all" => sub {
			   $self->set('Build Arch All', 1);
		       },
		       "auto-give-back=s" => sub {
			   $self->set('Auto Giveback', 1);
			   if ($_[1]) {
			       my @parts = split( '@', $_[1] );
			       $self->set('Auto Giveback Socket',
					  $parts[$#parts-3])
				   if @parts > 3;
			       $self->set('Auto Giveback WannaBuild User',
					  $parts[$#parts-2])
				   if @parts > 2;
			       $self->set('Auto Giveback User',
					  $parts[$#parts-1])
				   if @parts > 1;
			       $self->set('Auto Giveback Host',
					  $parts[$#parts]);
			   }
		       },
		       "f|force-depends=s" => sub {
			   push( @{$self->get('Manual Srcdeps')}, "f".$_[1] );
		       },
		       "a|add-depends=s" => sub {
			   push( @{$self->get('Manual Srcdeps')}, "a".$_[1] );
		       },
		       "check-depends-algorithm=s" => sub {
			   die "Bad build dependency check algorithm\n"
			       if( ! ($_[1] eq "first-only"
				      || $_[1] eq "alternatives") );
			   $self->set_conf('CHECK_DEPENDS_ALGORITHM', $_[1]);
		       },
		       "b|batch" => sub {
			   $self->set('Batch Mode', 1);
		       },
		       "make-binNMU=s" => sub {
			   $self->set('binNMU', $_[1]);
			   $self->set('binNMU Version',
				      $self->get('binNMU Version') || 1);
		       },
		       "binNMU=i" => sub {
			   $self->set('binNMU Version', $_[1]);
		       },
		       "c|chroot=s" => sub {
			   $self->set('Chroot', $_[1]);
		       },
		       "database=s" => sub {
			   $self->set('WannaBuild Database', $_[1]);
		       },
		       "D|debug" => sub {
			   $self->set_conf('DEBUG',
					   $self->get_conf('DEBUG') + 1);
		       },
		       "apt-update" => sub {
			   $self->set_conf('APT_UPDATE', $_[1]);
		       },
		       "d|dist=s" => sub {
			   $self->set('Distribution', $_[1]);
			   $self->set('Distribution', "oldstable")
			       if $self->{'Distribution'} eq "o";
			   $self->set('Distribution', "stable")
			       if $self->{'Distribution'} eq "s";
			   $self->set('Distribution', "testing")
			       if $self->{'Distribution'} eq "t";
			   $self->set('Distribution', "unstable")
			       if $self->{'Distribution'} eq "u";
			   $self->set('Distribution', "experimental")
			       if $self->{'Distribution'} eq "e";
			   $self->set('Override Distribution', 1);
		       },
		       "force-orig-source" => sub {
			   $self->set_conf('FORCE_ORIG_SOURCE', 1);
		       },
		       "m|maintainer=s" => sub {
			   $self->set_conf('MAINTAINER_NAME', $_[1]);
		       },
		       "k|keyid=s" => sub {
			   $self->set_conf('KEY_ID', $_[1]);
		       },
		       "e|uploader=s" => sub {
			   $self->set_conf('UPLOADER_NAME', $_[1]);
		       },
		       "n|nolog" => sub {
			   $self->set('NOLOG', 1);
		       },
		       "p|purge=s" => sub {
			   $self->set_conf('PURGE_BUILD_DIRECTORY', $_[1]);
			   die "Bad purge mode '$_[1]'\n"
			       if !isin($self->get_conf('PURGE_BUILD_DIRECTORY'),
					qw(always successful never));
		       },
		       "s|source" => sub {
			   $self->set('Build Source', 1);
		       },
		       "stats-dir=s" => sub {
			   $self->set_conf('STATS_DIR', $_[1]);
		       },
		       "use-snapshot" => sub {
			   $self->set('GCC Snapshot', 1);
			   $self->set('LD_LIBRARY_PATH',
				      "/usr/lib/gcc-snapshot/lib");
			   $self->set_conf('PATH',
					   "/usr/lib/gcc-snapshot/bin:" .
					   $self->get_conf('PATH'))
		       },
		       "v|verbose" => sub {
			   $self->set_conf('VERBOSE',
					  $self->get_conf('VERBOSE') + 1);
		       },
		       "q|quiet" => sub {
			   $self->set_conf('VERBOSE',
					   $self->get_conf('VERBOSE') - 1)
			       if $self->get_conf('VERBOSE');
		       },
	);
}

1;
