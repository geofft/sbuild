#
# Sbuild.pm: library for sbuild
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org
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

package Sbuild;

use Sbuild::Conf;

use strict;
use POSIX;
use FileHandle;
use Time::Local;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @Sbuild::ISA = qw(Exporter);

    @Sbuild::EXPORT = qw(version_less version_lesseq version_eq
		         version_compare binNMU_version parse_date
		         isin copy);
}

my $opt_correct_version_cmp;

sub version_less ($$);
sub version_lesseq ($$);
sub version_eq ($$);
sub version_compare ($$$);
sub do_version_cmp ($$);
sub order ($);
sub version_cmp_single ($$);
sub split_version ($);
sub binNMU_version ($$);
sub parse_date ($);
sub isin ($@);

sub version_less ($$) {
	my $v1 = shift;
	my $v2 = shift;

	return version_compare( $v1, "<<", $v2 );
}

sub version_lesseq ($$) {
	my $v1 = shift;
	my $v2 = shift;

	return version_compare( $v1, "<=", $v2 );
}

sub version_eq ($$) {
	my $v1 = shift;
	my $v2 = shift;

	return version_compare( $v1, "=", $v2 );
}

sub version_compare ($$$) {
	my $v1 = shift;
	my $rel = shift;
	my $v2 = shift;

	if ($Sbuild::opt_correct_version_cmp) {
		system "dpkg", "--compare-versions", $v1, $rel, $v2;
		return $? == 0;
	}
	else {
		if ($rel eq "=" || $rel eq "==") {
			return $v1 eq $v2;
		}
		elsif ($rel eq "<<") {
			return do_version_cmp( $v1, $v2 );
		}
		elsif ($rel eq "<=" || $rel eq "<") {
			return $v1 eq $v2 || do_version_cmp( $v1, $v2 );
		}
		elsif ($rel eq ">=" || $rel eq ">") {
			return !do_version_cmp( $v1, $v2 );
		}
		elsif ($rel eq ">>") {
			return $v1 ne $v2 && !do_version_cmp( $v1, $v2 );
		}
		else {
			warn "version_compare called with bad relation '$rel'\n";
			return $v1 eq $2;
		}
	}
}

sub do_version_cmp ($$) {
	my($versa, $versb) = @_;
	my($epocha,$upstra,$reva);
	my($epochb,$upstrb,$revb);
	my($r);

	($epocha,$upstra,$reva) = split_version($versa);
	($epochb,$upstrb,$revb) = split_version($versb);

	# compare epochs
	return 1 if $epocha < $epochb;
	return 0 if $epocha > $epochb;

	# compare upstream versions
	$r = version_cmp_single( $upstra, $upstrb );
	return $r < 0 if $r != 0;

	# compare Debian revisions
	$r = version_cmp_single( $reva, $revb );
	return $r < 0;
}

sub order ($) {
	for ($_[0])
	{
	/\~/     and return -1;
	/\d/     and return  0;
	/[a-z]/i and return ord;
		     return (ord) + 256;
	}
}

sub version_cmp_single ($$) {
	my($versa, $versb) = @_;
	my($a,$b,$lena,$lenb,$va,$vb,$i);

	for(;;) {
		# compare non-numeric parts
		$versa =~ /^([^\d]*)(.*)/; $a = $1; $versa = $2;
		$versb =~ /^([^\d]*)(.*)/; $b = $1; $versb = $2;
		$lena = length($a);
		$lenb = length($b);
		for( $i = 0; $i < $lena || $i < $lenb; ++$i ) {
			$va = $i < $lena ? order(substr( $a, $i, 1 )) : 0;
			$vb = $i < $lenb ? order(substr( $b, $i, 1 )) : 0;
			return $va - $vb if $va != $vb;
		}
		# compare numeric parts
		$versa =~ /^(\d*)(.*)/; $a = $1; $a ||= 0; $versa = $2;
		$versb =~ /^(\d*)(.*)/; $b = $1; $b ||= 0; $versb = $2;
		return $a - $b if $a != $b;
		return 0 if !$versa && !$versb;
		if (!$versa) {
			return +1 if order(substr( $versb, 0, 1 ) ) < 0;
			return -1;
		}
		if (!$versb) {
			return -1 if order(substr( $versa, 0, 1 ) ) < 0;
			return +1;
		}
	}
}

sub split_version ($) {
	my($vers) = @_;
	my($epoch,$revision) = (0,"");

	if ($vers =~ /^(\d+):(.*)/) {
		$epoch = $1;
		$vers = $2;
	}

	if ($vers =~ /(.*)-([^-]+)$/) {
		$revision = $2;
		$vers = $1;
	}

	return( $epoch, $vers, $revision );
}

sub binNMU_version ($$) {
	my $v = shift;
	my $binNMUver = shift;

	return "$v+b$binNMUver";
}

my %monname = ('jan', 0, 'feb', 1, 'mar', 2, 'apr', 3, 'may', 4, 'jun', 5,
	       'jul', 6, 'aug', 7, 'sep', 8, 'oct', 9, 'nov', 10, 'dec', 11 );

sub parse_date ($) {
    my $text = shift;

    return 0 if !$text;
    die "Cannot parse date: $text\n"
	if $text !~ /^(\d{4}) (\w{3}) (\d+) (\d{2}):(\d{2}):(\d{2})$/;
    my ($year, $mon, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
    $mon =~ y/A-Z/a-z/;
    die "Invalid month name $mon" if !exists $monname{$mon};
    $mon = $monname{$mon};
    return timelocal($sec, $min, $hour, $day, $mon, $year);
}

sub isin ($@) {
    my $val = shift;
    return grep( $_ eq $val, @_ );
}

sub copy ($) {
    my $r = shift;
    my $new;

    if (ref($r) eq "HASH") {
	$new = { };
	foreach (keys %$r) {
	    $new->{$_} = copy($r->{$_});
	}
    }
    elsif (ref($r) eq "ARRAY") {
	my $i;
	$new = [ ];
	for( $i = 0; $i < @$r; ++$i ) {
	    $new->[$i] = copy($r->[$i]);
	}
    }
    elsif (!ref($r)) {
	$new = $r;
    }
    else {
	die "unknown ref type in copy\n";
    }

    return $new;
}


1;
