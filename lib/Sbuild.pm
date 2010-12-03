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

use Sbuild::Sysconfig;

use strict;
use warnings;
use POSIX;
use FileHandle;
use Filesys::Df qw();
use Time::Local;
use IO::Zlib;
use MIME::Base64;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($debug_level $devnull version_less version_lesseq
		 version_eq version_compare split_version
		 binNMU_version parse_date isin copy dump_file
		 check_packages help_text version_text usage_error
		 send_mail send_build_log debug debug2 df
		 check_group_membership);

}

our $devnull;
my $opt_correct_version_cmp = 1;
our $debug_level = 0;

BEGIN {
    # A file representing /dev/null
    if (!open($devnull, '+<', '/dev/null')) {
	die "Cannot open /dev/null: $!\n";;
    }
}

sub version_less ($$);
sub version_lesseq ($$);
sub version_eq ($$);
sub version_compare ($$$);
sub do_version_cmp ($$);
sub order ($);
sub version_cmp_single ($$);
sub split_version ($);
sub binNMU_version ($$$);
sub parse_date ($);
sub isin ($@);
sub copy ($);
sub dump_file ($);
sub check_packages ($$);
sub help_text ($$);
sub version_text ($);
sub usage_error ($$);
sub debug (@);
sub debug2 (@);
sub check_group_membership();

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

	# If we're trying to compare versions against a provided package,
	# always return "not satisfied", forcing an install attempt.
	if ($v1 eq "=*=PROVIDED=*=") {
		return 0;
	}

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

sub binNMU_version ($$$) {
	my $v = shift;
	my $binNMUver = shift;
	my $append_to_version = shift;

	my $ver = $v;
	if (defined($append_to_version) && $append_to_version) {
	    $ver .= $append_to_version;
	}
	if (defined($binNMUver) && $binNMUver) {
	    $ver .= "+b$binNMUver";
	}
	return $ver;
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
    return timegm($sec, $min, $hour, $day, $mon, $year);
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

sub dump_file ($) {
    my $file = shift;

    if (-r "$file" &&
	open(SOURCES, "<$file")) {

	print "   ┌────────────────────────────────────────────────────────────────────────\n";
	while (<SOURCES>) {
	    chomp;
	    print "   │$_\n";
	}
	print "   └────────────────────────────────────────────────────────────────────────\n";
	close(SOURCES) or print "Failed to close $file\n";
    } else {
	print "W: Failed to open $file\n";
    }
}

# set and list saved package list (used by sbuild-checkpackages)
sub check_packages ($$) {
    my $chroot = shift;
    my $mode = shift;

    my $package_checklist = $chroot->get_conf('PACKAGE_CHECKLIST');
    my $chroot_dir = $chroot->get('Location');

    my (@status, @ref, @install, @remove);

    if (! open STATUS, "grep-status -F Status -s Package ' installed' '$chroot_dir/var/lib/dpkg/status' | awk '{print \$2}' |" ) {
	print STDERR "Can't read dpkg status file in chroot: $!\n";
	return 1;
    }
    while (<STATUS>) {
	chomp;
	push @status, $_;
    }
    if (! close STATUS) {
	print STDERR "Error reading dpkg status file in chroot: $!\n";
	return 1;
    }
    @status = sort @status;
    if (!@status) {
	print STDERR "dpkg status file is empty\n";
	return 1;
    }

    if ($mode eq "set") {
	if (! open WREF, "> $chroot_dir/$package_checklist") {
	    print STDERR "Can't write reference status file $chroot_dir/$package_checklist: $!\n";
	    return 1;
	}
	foreach (@status) {
	    print WREF "$_\n";
	}
	if (! close WREF) {
	    print STDERR "Error writing reference status file: $!\n";
	    return 1;
	}
    } else { # "list"
	if (! open REF, "< $chroot_dir/$package_checklist") {
	    print STDERR "Can't read reference status file $chroot_dir/$package_checklist: $!\n";
	    return 1;
	}
	while (<REF>) {
	    chomp;
	    push @ref, $_;
	}
	if (! close REF) {
	    print STDERR "Error reading reference status file: $!\n";
	    return 1;
	}

	@ref = sort @ref;
	if (!@ref) {
	    print STDERR "Reference status file is empty\n";
	    return 1;
	}

	print "DELETE             ADD\n";
	print "──────────────────────────────────────\n";
	my $i = 0;
	my $j = 0;

	while ($i < scalar @status && $j < scalar @ref) {

	    my $c = $status[$i] cmp $ref[$j];
	    if ($c < 0) {
		# In status, not reference; remove.
		print "$status[$i]\n";
		$i++;
	    } elsif ($c > 0) {
		# In reference, not status; install.
		print "                   $ref[$j]\n";
		$j++;
	    } else {
		# Identical; skip.
		$i++; $j++;
	    }
	}

        # Print any remaining elements
	while ($i < scalar @status) {
	    print "$status[$i]\n";
	    $i++;
	}
	while ($j < scalar @ref) {
	    print "                   $ref[$j]\n";
	    $j++;
	}
    }
}

sub help_text ($$) {
    my $section = shift;
    my $page = shift;

    system("/usr/bin/man", "$section", "$page");
    exit 0;
}

sub version_text ($) {
    my $program = shift;

    print <<"EOF";
$program (Debian sbuild) $Sbuild::Sysconfig::version ($Sbuild::Sysconfig::release_date)

Written by Roman Hodek, James Troup, Ben Collins, Ryan Murray, Rick
Younie, Francesco Paolo Lovergine, Michael Banck, Roger Leigh and
Andres Mejia.

Copyright © 1998-2000 Roman Hodek <roman\@hodek.net>
          © 1998-1999 James Troup <troup\@debian.org>
	  © 2003-2006 Ryan Murray <rmurray\@debian.org>
	  © 2001-2003 Rick Younie <younie\@debian.org>
	  © 2003-2004 Francesco Paolo Lovergine <frankie\@debian.org>
	  © 2005      Michael Banck <mbanck\@debian.org>
	  © 2005-2010 Roger Leigh <rleigh\@debian.org>
	  © 2009-2010 Andres Mejia <mcitadel\@gmail.com>

This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
EOF
    exit 0;
}

# Print an error message about incorrect command-line options
sub usage_error ($$) {
    my $program = shift;
    my $message = shift;

    print STDERR "E: $message\n";
    print STDERR "I: Run “$program --help” to list usage example and all available options\n";
    exit 1;
}

sub send_build_log ($$$$) {
    my $conf = shift;
    my $to = shift;
    my $subject = shift;
    my $file = shift;

    # If no build log compression is desired, just pass this mail to the
    # ordinary mailing function that also handles the other notifications.
    if (!$conf->get('COMPRESS_BUILD_LOG_MAILS')) {
        return send_mail($conf, $to, $subject, $file);
    }

    # This writes the compressed build log to yet another temporary file,
    # generates base64 from it and pipes it into the mailer with
    # Content-Type: application/x-gzip and Content-Transfer-Encoding:
    # base64.
    local( *F, *GZFILE );

    if (!open( F, "<$file" )) {
	warn "Cannot open $file for mailing: $!\n";
	return 0;
    }

    my $tmp = File::Temp->new();
    tie *GZFILE, 'IO::Zlib', $tmp->filename, 'wb';

    while( <F> ) {
        print GZFILE $_;
    }
    untie *GZFILE;

    my $filename = $tmp->filename;
    if (!open( F, "<$filename" )) {
        warn "Cannot open $filename for mailing: $!\n";
        return 0;
    }

    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|" . $conf->get('MAILPROG') . " -oem $to" )) {
	warn "Could not open pipe to " . $conf->get('MAILPROG') . ": $!\n";
	close( F );
	return 0;
    }

    print MAIL "From: " . $conf->get('MAILFROM') . "\n";
    print MAIL "To: $to\n";
    print MAIL "Subject: $subject\n";
    print MAIL "Content-Type: application/x-gzip\n";
    print MAIL "Content-Transfer-Encoding: base64\n";
    print MAIL "\n";

    my $buf;
    while (read(F, $buf, 60*57)) {
	print MAIL encode_base64($buf);
    }

    close( F );
    if (!close( MAIL )) {
	warn $conf->get('MAILPROG') . " failed (exit status $?)\n";
	return 0;
    }
    return 1;
}


sub send_mail ($$$$) {
    my $conf = shift;
    my $to = shift;
    my $subject = shift;
    my $file = shift;
    local( *MAIL, *F );

    if (!open( F, "<$file" )) {
	warn "Cannot open $file for mailing: $!\n";
	return 0;
    }
    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|" . $conf->get('MAILPROG') . " -oem $to" )) {
	warn "Could not open pipe to " . $conf->get('MAILPROG') . ": $!\n";
	close( F );
	return 0;
    }

    print MAIL "From: " . $conf->get('MAILFROM') . "\n";
    print MAIL "To: $to\n";
    print MAIL "Subject: $subject\n";
    print MAIL "Content-Type: text/plain; charset=UTF-8\n";
    print MAIL "Content-Transfer-Encoding: 8bit\n";
    print MAIL "\n";
    while( <F> ) {
	print MAIL "." if $_ eq ".\n";
	print MAIL $_;
    }

    close( F );
    if (!close( MAIL )) {
	warn $conf->get('MAILPROG') . " failed (exit status $?)\n";
	return 0;
    }
    return 1;
}

# Note: split to stderr
sub debug (@) {

    # TODO: Add debug level checking.
    if ($debug_level) {
	print STDERR "D: ", @_;
    }
}

sub debug2 (@) {

    # TODO: Add debug level checking.
    if ($debug_level && $debug_level >= 2) {
	print STDERR "D2: ", @_;
    }
}

sub df {
    my $dir = shift;

    my $stat = Filesys::Df::df($dir);

    return $stat->{bfree} if (defined($stat));

# This only happens if $dir was not a valid file or directory.
    return 0;
}

sub check_group_membership () {
    # Skip for root
    return if ($< == 0);

    my $user = getpwuid($<);
    my ($name,$passwd,$gid,$members) = getgrnam("sbuild");

    if (!$gid) {
	die "Group sbuild does not exist";
    }

    my $in_group = 0;
    my @groups = getgroups();
    push @groups, getgid();
    foreach (@groups) {
	($name, $passwd, $gid, $members) = getgrgid($_);
	$in_group = 1 if defined($name) && $name eq 'sbuild';
    }

    if (!$in_group) {
	print STDERR "User $user is not currently a member of group sbuild, but is in the system group database\n";
	print STDERR "You need to log in again to gain sbuild group priveleges\n";
	exit(1);
    }

    return;
}

1;
