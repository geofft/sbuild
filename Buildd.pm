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
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# $Id$
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
