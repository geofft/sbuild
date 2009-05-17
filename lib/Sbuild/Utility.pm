#
# Utility.pm: library for sbuild utility programs
# Copyright © 2006 Roger Leigh <rleigh@debian.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
#
############################################################################

# Import default modules into main
package main;
use Sbuild qw($devnull);
use Sbuild::Conf;
use Sbuild::Log qw(open_log close_log);
use Sbuild::ChrootInfoSchroot;
use Sbuild::ChrootInfoSudo;
use Sbuild::Sysconfig;

$ENV{'LC_ALL'} = "POSIX";
$ENV{'SHELL'} = $Sbuild::Sysconfig::programs{'SHELL'};

# avoid intermixing of stdout and stderr
$| = 1;

package Sbuild::Utility;

use strict;
use warnings;

use Sbuild::Conf;
use Sbuild::Chroot;

sub get_dist ($);
sub setup ($$);
sub cleanup ($);
sub shutdown ($);

my $current_session;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(setup cleanup shutdown);

    $SIG{'INT'} = \&shutdown;
    $SIG{'TERM'} = \&shutdown;
    $SIG{'ALRM'} = \&shutdown;
    $SIG{'PIPE'} = \&shutdown;
}

sub get_dist ($) {
    my $dist = shift;

    $dist = "unstable" if ($dist eq "-u" || $dist eq "u");
    $dist = "testing" if ($dist eq "-t" || $dist eq "t");
    $dist = "stable" if ($dist eq "-s" || $dist eq "s");
    $dist = "oldstable" if ($dist eq "-o" || $dist eq "o");
    $dist = "experimental" if ($dist eq "-e" || $dist eq "e");

    return $dist;
}

sub setup ($$) {
    my $chroot = shift;
    my $conf = shift;


    $conf->set('VERBOSE', 1);
    $conf->set('NOLOG', 1);

    Sbuild::Log::open_log($conf);

    $chroot = get_dist($chroot);

    # TODO: Allow user to specify arch.
    my $chroot_info;
    if ($conf->get('CHROOT_MODE') eq 'schroot') {
	$chroot_info = Sbuild::ChrootInfoSchroot->new($conf);
    } else {
	$chroot_info = Sbuild::ChrootInfoSudo->new($conf);
    }

    my $session;

    $session = $chroot_info->create($chroot,
				    undef, # TODO: Add --chroot option
				    $conf->get('ARCH'));

    $session->set('Log Stream', \*STDOUT);

    my $chroot_defaults = $session->get('Defaults');
    $chroot_defaults->{'DIR'} = '/';
    $chroot_defaults->{'STREAMIN'} = $Sbuild::devnull;
    $chroot_defaults->{'STREAMOUT'} = \*STDOUT;
    $chroot_defaults->{'STREAMERR'} =\*STDOUT;

    $Sbuild::Utility::current_session = $session;

    if (!$session->begin_session()) {
	print STDERR "Error setting up $chroot chroot\n";
	return undef;
    }

    if (defined(&main::local_setup)) {
	return main::local_setup($session);
    }
    return $session;
}

sub cleanup ($) {
    my $conf = shift;

    if (defined(&main::local_cleanup)) {
	main::local_cleanup($Sbuild::Utility::current_session);
    }
    $Sbuild::Utility::current_session->end_session();
    Sbuild::Log::close_log($conf);
}

sub shutdown ($) {
    cleanup($main::conf); # FIXME: don't use global
    exit 1;
}

1;
