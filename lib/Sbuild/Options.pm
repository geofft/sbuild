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
use Sbuild qw(help_text version_text usage_error);
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
		       "arch=s" => sub {
			   $self->set_conf('USER_ARCH', $_[1]);
		       },
		       "A|arch-all" => sub {
			   $self->set_conf('BUILD_ARCH_ALL', 1);
		       },
		       "auto-give-back=s" => sub {
			   $self->set_conf('AUTO_GIVEBACK', 1);
			   if ($_[1]) {
			       my @parts = split( '@', $_[1] );
			       $self->set_conf('AUTO_GIVEBACK_SOCKET',
					  $parts[$#parts-3])
				   if @parts > 3;
			       $self->set_conf('AUTO_GIVEBACK_WANNABUILD_USER',
					  $parts[$#parts-2])
				   if @parts > 2;
			       $self->set_conf('AUTO_GIVEBACK_USER',
					  $parts[$#parts-1])
				   if @parts > 1;
			       $self->set_conf('AUTO_GIVEBACK_HOST',
					  $parts[$#parts]);
			   }
		       },
		       "f|force-depends=s" => sub {
			   push(@{$self->get_conf('MANUAL_SRCDEPS')},
				"f".$_[1]);
		       },
		       "a|add-depends=s" => sub {
			   push(@{$self->get_conf('MANUAL_SRCDEPS')},
				"a".$_[1] );
		       },
		       "check-depends-algorithm=s" => sub {
			   $self->set_conf('CHECK_DEPENDS_ALGORITHM', $_[1]);
		       },
		       "b|batch" => sub {
			   $self->set_conf('BATCH_MODE', 1);
		       },
		       "make-binNMU=s" => sub {
			   $self->set_conf('BIN_NMU', $_[1]);
			   $self->set_conf(
			       'BIN_NMU_VERSION',
			       $self->set_conf('BIN_NMU_VERSION') || 1);
		       },
		       "binNMU=i" => sub {
			   $self->set_conf('BIN_NMU_VERSION', $_[1]);
		       },
		       "c|chroot=s" => sub {
			   $self->set_conf('CHROOT', $_[1]);
		       },
		       "database=s" => sub {
			   $self->set_conf('WANNABUILD_DATABASE', $_[1]);
		       },
		       "D|debug" => sub {
			   $self->set_conf('DEBUG',
					   $self->get_conf('DEBUG') + 1);
		       },
		       "apt-update" => sub {
			   $self->set_conf('APT_UPDATE', $_[1]);
		       },
		       "d|dist=s" => sub {
			   $self->set_conf('DISTRIBUTION', $_[1]);
			   $self->set_conf('DISTRIBUTION', "oldstable")
			       if $self->get_conf('DISTRIBUTION') eq "o";
			   $self->set_conf('DISTRIBUTION', "stable")
			       if $self->get_conf('DISTRIBUTION') eq "s";
			   $self->set_conf('DISTRIBUTION', "testing")
			       if $self->get_conf('DISTRIBUTION') eq "t";
			   $self->set_conf('DISTRIBUTION', "unstable")
			       if $self->get_conf('DISTRIBUTION') eq "u";
			   $self->set_conf('DISTRIBUTION', "experimental")
			       if $self->get_conf('DISTRIBUTION') eq "e";
			   $self->set_conf('OVERRIDE_DISTRIBUTION', 1);
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
		       },
		       "s|source" => sub {
			   $self->set_conf('BUILD_SOURCE', 1);
		       },
		       "stats-dir=s" => sub {
			   $self->set_conf('STATS_DIR', $_[1]);
		       },
		       "use-snapshot" => sub {
			   $self->set_conf('GCC_SNAPSHOT', 1);
			   $self->set_conf('LD_LIBRARY_PATH',
					   '/usr/lib/gcc-snapshot/lib' .
					   $self->get_conf('LD_LIBRARY_PATH') ne '' ? ':' . $self->get_conf('LD_LIBRARY_PATH') : '');
			   $self->set_conf('PATH',
					   '/usr/lib/gcc-snapshot/bin' .
					   $self->get_conf('PATH') ne '' ? ':' . $self->get_conf('PATH') : '');
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
