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

use strict;
use warnings;
use POSIX;
use FileHandle;
use File::Temp ();

sub new ($);
sub get (\%$);
sub set (\%$$);
sub get_conf (\%$);
sub get_info (\%$);
sub get_info_all (\%);
sub find (\%$$$);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new ($) {
    my $conf = shift;

    my $self  = {};
    bless($self);

    $self->set('Config', $conf);
    $self->set('Chroots', {});

    $self->get_info_all();

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

sub get_info (\%$) {
    my $self = shift;
    my $chroot = shift;

    my $chroot_type = "";
    my %tmp = ('Priority' => 0,
	       'Location' => "",
	       'Session Purged' => 0);
    open CHROOT_DATA, '-|', $self->get_conf('SCHROOT'), '--info', '--chroot', $chroot
	or die 'Can\'t run ' . $self->get_conf('SCHROOT') . ' to get chroot data';
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
	if (/^\s*Session Purged\s+(.*)$/) {
	    if ($1 eq "true") {
		$tmp{'Session Purged'} = 1;
	    }
	}
    }

    close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

    if ($self->get_conf('DEBUG')) {
	print STDERR "Found schroot chroot: $chroot\n";
	foreach (sort keys %tmp) {
	    print STDERR "  $_ $tmp{$_}\n";
	}
    }

    return \%tmp;
}

sub get_info_all (\%) {
    my $self = shift;

    my $chroots = $self->get('Chroots');
    my $build_dir = $self->get_conf('BUILD_DIR');

    # TODO: Redundant block?  Leave in place for sudo use in the future.
    foreach (glob("$build_dir/chroot-*")) {
	my %tmp = ('Priority' => 0,
		   'Location' => $_,
		   'Session Purged' => 0);
	if (-d $tmp{'Location'}) {
	    my $name = $_;
	    $name =~ s/\Q${build_dir}\/chroot-\E//;
	    print STDERR "Found chroot $name\n"
		if $self->get_conf('DEBUG');
	    $chroots->{$name} = \%tmp;
	}
    }

    # Pick up available chroots and dist_order from schroot
    $chroots = {};
    open CHROOTS, '-|', $self->get_conf('SCHROOT'), '--list'
	or die 'Can\'t run ' . $self->get_conf('SCHROOT');
    while (<CHROOTS>) {
	chomp;
	my $chroot = $_;
	print STDERR "Getting info for $chroot chroot\n"
	    if $self->get_conf('DEBUG');
	$chroots->{$chroot} = $self->get_info($chroot);
    }

    $self->set('Chroots', $chroots);

    close CHROOTS or die "Can't close schroot pipe";
}

sub find (\%$$$) {
    my $self = shift;
    my $distribution = shift;
    my $chroot = shift;
    my $arch = shift;

    my $chroots = $self->get('Chroots');

    my $arch_set = 1;

    if (!defined($arch) || $arch eq "") {
	$arch = $self->get_conf('ARCH');
	$arch_set = 0;
    }

    my $arch_found = 0;

    if (!defined $chroot) {
        if ($arch ne "" &&
            defined($chroots->{"${distribution}-${arch}-sbuild"})) {
            $chroot = "${distribution}-${arch}-sbuild";
            $arch_found = 1;
        }
        elsif (defined($chroots->{"${distribution}-sbuild"})) {
            $chroot = "${distribution}-sbuild";
        }
        elsif ($arch ne "" &&
               defined($chroots->{"${distribution}-${arch}"})) {
            $chroot = "${distribution}-${arch}";
            $arch_found = 1;
        } elsif (defined($chroots->{$distribution})) {
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
