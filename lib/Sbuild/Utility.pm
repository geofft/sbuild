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
use Sbuild::Conf;
use Sbuild::Log qw(open_log close_log);
use Sbuild::Chroot qw(get_command run_command exec_command
		      get_apt_command run_apt_command current);

$ENV{'LC_ALL'} = "POSIX";
$ENV{'SHELL'} = "/bin/sh";

# avoid intermixing of stdout and stderr
$| = 1;

Sbuild::Conf::init();
$Sbuild::Conf::verbose++;
Sbuild::Chroot::init();

package Sbuild::Utility;

use strict;
use warnings;

use Sbuild::Conf;
use Sbuild::Chroot qw(begin_session end_session);
use Sbuild::Sysconfig qw($arch);

sub get_dist ($);
sub setup ($);
sub cleanup ();
sub shutdown ($);

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

sub setup ($) {
    my $chroot = shift;

    $Sbuild::Conf::nolog = 1;
    Sbuild::Log::open_log($chroot);

    $chroot = get_dist($chroot);

    # TODO: Allow user to specify arch.
    if (!begin_session($chroot, $arch)) {
	print STDERR "Error setting up $chroot chroot\n";
	return 1;
    }

    if (defined(&main::local_setup)) {
	return main::local_setup($chroot);
    }
    return 0;
}

sub cleanup () {
    if (defined(&main::local_cleanup)) {
	main::local_cleanup();
    }
    end_session();
    Sbuild::Log::close_log();
}

sub shutdown ($) {
    cleanup();
    exit 1;
}

1;
