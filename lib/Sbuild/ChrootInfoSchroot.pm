#
# ChrootInfo.pm: chroot utility library for sbuild
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::ChrootInfoSchroot;

use Sbuild::ChrootInfo;
use Sbuild::ChrootSchroot;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ChrootInfo);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    return $self;
}

sub get_info_from_stream {
    my $self = shift;
    my $stream = shift;

    my $chroot_type = '';
    my %tmp = ('Namespace' => '',
	       'Name' => '',
	       'Priority' => 0,
	       'Location' => '',
	       'Session Purged' => 0);

    while (<$stream>) {
	chomp;

	last if ! $_;

	if (/\s*─── Chroot ───/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'chroot';
	}
	if (/\s*─── Session ───/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'session';
	}
	if (/\s*─── Source ───/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'source';
	}
	if (/\s*--- Chroot ---/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'chroot';
	}
	if (/\s*--- Session ---/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'session';
	}
	if (/\s*--- Source ---/ &&
	    $tmp{'Namespace'} eq "") {
	    $tmp{'Namespace'} = 'source';
	}
	if (/^\s*Name:?\s+(.*)$/ &&
	    $tmp{'Name'} eq "") {
	    $tmp{'Name'} = $1;
	}
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
	if (/^\s*Aliases:?\s+(.*)$/) {
	    $tmp{'Aliases'} = $1;
	}
    }

    if ($self->get_conf('DEBUG') && $tmp{'Name'})  {
	print STDERR "Found schroot chroot: $tmp{'Namespace'}:$tmp{'Name'}\n";
	foreach (sort keys %tmp) {
	    print STDERR "  $_ $tmp{$_}\n";
	}
    }

    if (!$tmp{'Name'}) {
	return undef;
    }
    return \%tmp;
}

sub get_info {
    my $self = shift;
    my $chroot = shift;

    my $chroot_type = "";

    # If namespaces aren't supported, try to fall back to old style session.
    open CHROOT_DATA, '-|', $self->get_conf('SCHROOT'), '--info', '--chroot', "session:$chroot" or
	open CHROOT_DATA, '-|', $self->get_conf('SCHROOT'), '--info', '--chroot', $chroot or
	die 'Can\'t run ' . $self->get_conf('SCHROOT') . ' to get chroot data';

    my $tmp = $self->get_info_from_stream(\*CHROOT_DATA);

    close CHROOT_DATA or die "Can't close schroot pipe getting chroot data";

    return $tmp;
}

sub get_info_all {
    my $self = shift;

    my $chroots = {};
    my $build_dir = $self->get_conf('BUILD_DIR');

    local %ENV;

    $ENV{'LC_ALL'} = 'C';
    $ENV{'LANGUAGE'} = 'C';

    open CHROOTS, '-|', $self->get_conf('SCHROOT'), '--info'
	or die 'Can\'t run ' . $self->get_conf('SCHROOT');
    my $tmp = undef;
    while (defined($tmp = $self->get_info_from_stream(\*CHROOTS))) {
	my $namespace = $tmp->{'Namespace'};
	$namespace = "chroot"
	    if !$tmp->{'Namespace'};
	$chroots->{$namespace} = {}
	    if (!exists($chroots->{$namespace}));
	$chroots->{$namespace}->{$tmp->{'Name'}} = $tmp;
	foreach my $alias (split(/\s+/, $tmp->{'Aliases'})) {
	    $chroots->{$namespace}->{$alias} = $tmp;
	}
    }
    close CHROOTS or die "Can't close schroot pipe";

    $self->set('Chroots', $chroots);
}

sub _create {
    my $self = shift;
    my $chroot_id = shift;

    my $chroot = undef;

    if (defined($chroot_id)) {
	$chroot = Sbuild::ChrootSchroot->new($self->get('Config'), $chroot_id);
    }

    return $chroot;
}

1;
