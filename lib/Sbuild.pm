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
use Dpkg::Control;
use Dpkg::Checksums;
use Dpkg::Version;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw($debug_level $devnull binNMU_version parse_date isin
		 copy dump_file check_packages help_text version_text
		 usage_error send_mail debug debug2 df
		 check_group_membership dsc_files);
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
sub dsc_files ($);

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

sub dsc_files ($) {
    my $dsc = shift;

    debug("Parsing $dsc\n");
    my $pdsc = Dpkg::Control->new(type => CTRL_PKG_SRC);
    $pdsc->set_options(allow_pgp => 1);
    if (!$pdsc->load($dsc)) {
	print STDERR "Could not parse $dsc\n";
	return undef;
    }

    my $csums = Dpkg::Checksums->new();
    $csums->add_from_control($pdsc, use_files_for_md5 => 1);
    return $csums->get_files();
}

1;
