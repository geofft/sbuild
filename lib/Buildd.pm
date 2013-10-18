#! /usr/bin/perl
#
# Buildd.pm: library for buildd and friends
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
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

package Buildd;

use strict;
use warnings;
use POSIX;
use FileHandle;
use Sbuild::LogBase;

require Exporter;
@Buildd::ISA = qw(Exporter);

@Buildd::EXPORT = qw(unset_env lock_file unlock_file send_mail
 		     ll_send_mail exitstatus isin);

$Buildd::lock_interval = 15;
$Buildd::max_lock_trys = 120;
($Buildd::progname = $0) =~ s,.*/,,;
my @pwinfo = getpwuid($>);
$Buildd::username = $pwinfo[0];
$Buildd::gecos = $pwinfo[6];
$Buildd::gecos =~ s/,.*$//;
$Buildd::hostname = `/bin/hostname -f`;
$Buildd::hostname =~ /^(\S+)$/; $Buildd::hostname = $1; # untaint

sub isin ($@);
sub unset_env ();
sub lock_file ($;$);
sub unlock_file ($);
sub send_mail ($$$;$);
sub ll_send_mail ($$);
sub exitstatus ($);

sub isin ($@) {
    my $val = shift;
    return grep( $_ eq $val, @_ );
}

sub unset_env () {
    # unset any locale variables (sorted to match output from locale(1))
    delete $ENV{'LANG'};
    delete $ENV{'LANGUAGE'};
    delete $ENV{'LC_CTYPE'};
    delete $ENV{'LC_NUMERIC'};
    delete $ENV{'LC_TIME'};
    delete $ENV{'LC_COLLATE'};
    delete $ENV{'LC_MONETARY'};
    delete $ENV{'LC_MESSAGES'};
    delete $ENV{'LC_PAPER'};
    delete $ENV{'LC_NAME'};
    delete $ENV{'LC_ADDRESS'};
    delete $ENV{'LC_TELEPHONE'};
    delete $ENV{'LC_MEASUREMENT'};
    delete $ENV{'LC_IDENTIFICATION'};
    delete $ENV{'LC_ALL'};
    # other unneeded variables that might be set
    delete $ENV{'DISPLAY'};
    delete $ENV{'TERM'};
}

sub lock_file ($;$) {
    my $file = shift;
    my $nowait = shift;
    my $lockfile = "$file.lock";
    my $try = 0;
    my $username = (getpwuid($<))[0] || $ENV{'LOGNAME'} || $ENV{'USER'};

    if (!defined($nowait)) {
        $nowait = 0;
    }

  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<$lockfile" );
	    my $line = <F>;
	    close( F );
	    # If this goes wrong it would be a spinlock and the world will
	    # end.
	    goto repeat if !defined( $line );
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		warn "Bad lock file contents ($lockfile) -- still trying\n";
	    }
	    else {
		my($pid, $user) = ($1, $2);
		my $cnt = kill( 0, $pid );
		if ($cnt == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    warn "Removing stale lock file $lockfile ".
			" (pid $pid, user $user)\n";
		    unlink( $lockfile );
		    goto repeat;
		} elsif ($cnt >= 1 and $nowait == 1) {
		    # process exists.
		    return 0;
		}
	    }
	    if (++$try > $Buildd::max_lock_trys) {
		warn "Lockfile $lockfile still present after ".
		    "$Buildd::max_lock_trys * $Buildd::lock_interval ".
		    " seconds -- giving up\n";
		return 0;
	    }
	    sleep $Buildd::lock_interval;
	    goto repeat;
	}
	die "$Buildd::progname: Can't create lock file $lockfile: $!\n";
    }
    F->print("$$ $username\n");
    F->close();
    return 1;
}

sub unlock_file ($) {
    my $file = shift;
    my $lockfile = "$file.lock";

    unlink( $lockfile );
}


sub send_mail ($$$;$) {
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

sub ll_send_mail ($$) {
    my $to = shift;
    my $text = shift;
    local( *MAIL );

    # TODO: Don't log to STDERR: Implement as class method using
    # standard pipe interface using normal log streams.

    $text =~ s/^\.$/../mg;
    local $SIG{'PIPE'} = 'IGNORE';
    if (!open( MAIL, "|/usr/sbin/sendmail -oem '$to'" )) {
	print STDERR "Could not open pipe to /usr/sbin/sendmail: $!\n";
	return 0;
    }
    print MAIL $text;
    if (!close( MAIL )) {
	print STDERR "sendmail failed (exit status ", exitstatus($?), ")\n";
	return 0;
    }
    return 1;
}

sub exitstatus ($) {
    my $stat = shift;

    return ($stat >> 8) . "/" . ($stat % 256);
}

1;
