#
# Buildd.pm: library for buildd and friends
# Copyright (C) 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
# $Id: Buildd.pm,v 1.19 2002/10/10 18:50:41 rnhodek Exp $
#
# $Log: Buildd.pm,v $
# Revision 1.19  2002/10/10 18:50:41  rnhodek
# Security/accepted autobuilding patch by Ryan.
#
# Revision 1.18  1999/08/10 14:15:28  rnhodek
# Change lock_interval from 5s to 15s; there were some cases where a
# valid lock was broken.
#
# Revision 1.17  1999/08/04 09:07:25  rnhodek
# Implemented collecting of statistical data for buildd; several figures
# are written to files in ~/stats where some script will pick them up.
#
# Revision 1.16  1998/10/20 12:51:07  rnhodek
# Change message if locking failed.
#
# Revision 1.15  1998/10/13 11:50:22  rnhodek
# Use more elegant 'local' for ignoring SIGPIPE.
#
# Revision 1.14  1998/10/09 13:16:11  rnhodek
# Replace single '.'s in a line by ".." for sendmail.
# Ignore SIGPIPE during sendmail pipe.
#
# Revision 1.13  1998/10/09 09:51:29  rnhodek
# In exitstatus, don't use / but >>, otherwise we get a floating point
# result :-)
#
# Revision 1.12  1998/10/08 14:12:14  rnhodek
# Removed parse_deplist and build_deplist; not needed anymore.
#
# Revision 1.11  1998/10/06 10:20:23  rnhodek
# New functions parse_deplist and build_deplist.
#
# Revision 1.10  1998/09/22 09:49:17  rnhodek
# If lock_file fails, not only warn but also return.
#
# Revision 1.9  1998/09/21 12:37:38  rnhodek
# Make sure every log message ends in a newline, to avoid format errors
# in the log file.
#
# Revision 1.8  1998/09/21 11:24:58  rnhodek
# Fix removing of unneeded final newlines in logger.
#
# Revision 1.7  1998/09/19 23:08:34  rnhodek
# Fix typos.
#
# Revision 1.6  1998/09/17 14:11:34  rnhodek
# In logger, remove too much newlines before prepending time/name.
#
# Revision 1.5  1998/09/16 15:54:34  rnhodek
# Must use $>, not $< which is the real uid...
# GECOS field index is 6, not 4.
#
# Revision 1.4  1998/09/16 15:36:04  rnhodek
# -f on sendmail didn't work, need to construct a From: line manually.
# For this, gather some global infos in Buildd.om (user name, full name,
# hostname), so those need not be hardwired.
#
# Revision 1.3  1998/09/16 14:38:03  rnhodek
# Add -f buildd option to sendmail call; hope this avoids that mails are
# sent as From: nobody.
#
# Revision 1.2  1998/09/15 11:45:49  rnhodek
# Use new exitstatus function.
#
# Revision 1.1  1998/09/11 12:25:02  rnhodek
# Initial writing
#
#

package Buildd;

use strict;
use IO;
use POSIX;
use FileHandle;

require Exporter;
@Buildd::ISA = qw(Exporter);
@Buildd::EXPORT = qw(read_config lock_file unlock_file open_log reopen_log close_log
					 logger parse_deplist build_deplist send_mail
					 ll_send_mail isin exitstatus write_stats);

$Buildd::lock_interval = 15;
$Buildd::max_lock_trys = 120;
($Buildd::progname = $0) =~ s,.*/,,;
my @pwinfo = getpwuid($>);
$Buildd::username = $pwinfo[0];
$Buildd::gecos = $pwinfo[6];
$Buildd::gecos =~ s/,.*$//;
my $oldPATH = $ENV{'PATH'};
$ENV{'PATH'} = "/bin";
$Buildd::hostname = `/bin/hostname -f`;
$ENV{'PATH'} = $oldPATH;
$Buildd::hostname =~ /^(\S+)$/; $Buildd::hostname = $1; # untaint

sub read_config {
	if (-f "$main::HOME/buildd.conf") {
		package conf;
		require "$main::HOME/buildd.conf";
		$conf::admin_mail; # don't know why this is needed
		package Buildd;
	}
}


sub lock_file {
	my $file = shift;
	my $lockfile = "$file.lock";
	my $try = 0;
	
  repeat:
	if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
		if ($! == EEXIST) {
			# lock file exists, wait
			goto repeat if !open( F, "<$lockfile" );
			my $line = <F>;
			close( F );
			if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
				warn "Bad lock file contents ($lockfile) -- still trying\n";
			}
			else {
				my($pid, $user) = ($1, $2);
				if (kill( 0, $pid ) == 0 && $! == ESRCH) {
					# process doesn't exist anymore, remove stale lock
					warn "Removing stale lock file $lockfile ".
						 " (pid $pid, user $user)\n";
					unlink( $lockfile );
					goto repeat;
				}
			}
			if (++$try > $Buildd::max_lock_trys) {
				warn "Lockfile $lockfile still present after ".
				     "$Buildd::max_lock_trys * $Buildd::lock_interval ".
					 " seconds -- giving up\n";
				return;
			}
			sleep $Buildd::lock_interval;
			goto repeat;
		}
		die "Can't create lock file $lockfile: $!\n";
	}
	F->print("$$ $ENV{'LOGNAME'}\n");
	F->close();
}

sub unlock_file {
	my $file = shift;
	my $lockfile = "$file.lock";

	unlink( $lockfile );
}


sub write_stats {
	my ($cat, $val) = @_;
	local( *F );

	lock_file( "$main::HOME/stats" );
	open( F, ">>$main::HOME/stats/$cat" );
	print F "$val\n";
	close( F );
	unlock_file( "$main::HOME/stats" );
}

sub open_log {
	open( LOG, ">>$main::HOME/daemon.log" )
		or die "Cannot open my logfile $main::HOME/daemon.log: $!\n";
	chmod( 0640, "$main::HOME/daemon.log" )
		or die "Cannot set modes of $main::HOME/daemon.log: $!\n";
	select( (select(LOG), $| = 1)[0] );
	open( STDOUT, ">&LOG" )
		or die "$0: Can't redirect stdout to $main::HOME/daemon.log: $!\n";
	open( STDERR, ">&LOG" )
		or die "$0: Can't redirect stderr to $main::HOME/daemon.log: $!\n";
}

sub logger {
	my $t;
	my $text = "";

	# omit weekday and year for brevity
	($t = localtime) =~ /^\w+\s(.*)\s\d+$/; $t = $1;
	foreach (@_) { $text .= $_; }
	$text =~ s/\n+$/\n/; # remove newlines at end
	$text .= "\n" if $text !~ /\n$/; # ensure newline at end
	$text =~ s/^/$1$t $Buildd::progname: /mg;
	print LOG $text;
}

sub close_log {
	close( LOG );
	close( STDOUT );
	close( STDERR );
}

sub reopen_log {
	close_log();
	open_log();
}

sub send_mail {
	my $addr = shift;
	my $subject = shift;
	my $text = shift;
	my $add_headers = shift;

	return ll_send_mail( $addr,
						 "To: $addr\n".
						 "Subject: $subject\n".
						 "From: $Buildd::gecos ".
						 "<$Buildd::username\@$Buildd::hostname>\n".
						 ($add_headers ? $add_headers : "").
						 "\n$text\n" );
}

sub ll_send_mail {
	my $to = shift;
	my $text = shift;
	local( *MAIL );

	$text =~ s/^\.$/../mg;
	local $SIG{'PIPE'} = 'IGNORE';
	if (!open( MAIL, "|/usr/lib/sendmail -oem '$to'" )) {
		logger( "Could not open pipe to /usr/lib/sendmail: $!\n" );
		return 0;
	}
	print MAIL $text;
	if (!close( MAIL )) {
		logger( "sendmail failed (exit status ", exitstatus($?), ")\n" );
		return 0;
	}
	return 1;
}

sub isin {
	my $val = shift;
	return grep( $_ eq $val, @_ );
}

sub exitstatus {
	my $stat = shift;

	return ($stat >> 8) . "/" . ($stat % 256);
}

1;
