#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfo;

use Sbuild::Conf;
use Sbuild::Sysconfig;

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

sub get_chroot_info ($);
sub get_chroot_info_all ();
sub find_chroot ($$$);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(%chroots get_chroot_info get_chroot_info_all
                 find_chroot);
}

INIT {
    get_chroot_info_all();
}

my %chroots = ();

sub get_chroot_info ($) {
    my $chroot = shift;
    my $chroot_type = "";
    my %tmp = ('Priority' => 0,
	       'Location' => "",
	       'Session Cloned' => 0);
    open CHROOT_DATA, '-|', $Sbuild::Conf::schroot, '--info', '--chroot', $chroot or die "Can't run $Sbuild::Conf::schroot to get chroot data";
    while (<CHROOT_DATA>) {
	chomp;
	if (/^\s*Type:?\s+(.*)$/) {
	    $chroot_type = $1;
	}
	if (/^\s*Location:?\s+(.*)$/ &&
	    $tmp{'Location'} eq "") {
	    $tmp{'Location'} = $1;
	}
	if (/^\s*Mount Location:?\s+(.*)$/ &&
	    $tmp{'Location'} eq "") {
	    $tmp{'Location'} = $1;
	}
	# Path takes priority over Location and Mount Location.
	if (/^\s*Path:?\s+(.*)$/) {
	    $tmp{'Location'} = $1;
	}
	if (/^\s*Priority:?\s+(\d+)$/) {
	    $tmp{'Priority'} = $1;
	}
	if (/^\s*Session Cloned\s+(.*)$/) {
	    if ($1 eq "true") {
		$tmp{'Session Cloned'} = 1;
	    }
	}
    }

    close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

    if ($Sbuild::Conf::debug) {
	print STDERR "Found schroot chroot: $chroot\n";
	foreach (sort keys %tmp) {
	    print STDERR "  $_ $tmp{$_}\n";
	}
    }

    return \%tmp;
}

sub get_chroot_info_all () {
    foreach (glob("${Sbuild::Conf::build_dir}/chroot-*")) {
	my %tmp = ('Priority' => 0,
		   'Location' => $_,
		   'Session Cloned' => 0);
	if (-d $tmp{'Location'}) {
	    my $name = $_;
	    $name =~ s/\Q${Sbuild::Conf::build_dir}\/chroot-\E//;
	    print STDERR "Found chroot $name\n"
		if $Sbuild::Conf::debug;
	    $chroots{$name} = \%tmp;
	}
    }

    # Pick up available chroots and dist_order from schroot
    %chroots = ();
    open CHROOTS, '-|', $Sbuild::Conf::schroot, '--list' or die "Can't run $Sbuild::Conf::schroot";
    while (<CHROOTS>) {
	chomp;
	my $chroot = $_;
	print STDERR "Getting info for $chroot chroot\n"
	    if $Sbuild::Conf::debug;
	$chroots{$chroot} = get_chroot_info($chroot);
    }
    close CHROOTS or die "Can't close schroot pipe";
}

sub find_chroot ($$$) {
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;
    my $arch_set = 1;

    if (!defined($arch) || $arch eq "") {
	$arch = $Sbuild::Sysconfig::arch;
	$arch_set = 0;
    }

    my $arch_found = 0;

    if (!defined $chroot) {
        if ($arch ne "" &&
            defined($chroots{"${distribution}-${arch}-sbuild"})) {
            $chroot = "${distribution}-${arch}-sbuild";
            $arch_found = 1;
        }
        elsif (defined($chroots{"${distribution}-sbuild"})) {
            $chroot = "${distribution}-sbuild";
        }
        elsif ($arch ne "" &&
               defined($chroots{"${distribution}-${arch}"})) {
            $chroot = "${distribution}-${arch}";
            $arch_found = 1;
        } elsif (defined($chroots{$distribution})) {
            $chroot = $distribution;
	}

	if ($arch_set && !$arch_found && $arch ne "") {
	    # TODO: Return error, rather than die.
	    die "Chroot $distribution for architecture $arch not found\n";
	    return undef;
	}
    }

    if (!$chroot) {
	# TODO: Return error, rather than die.
	die "Chroot for distribution $distribution, architecture $arch not found\n";
	return undef;
    }

    return $chroot;
}

1;
