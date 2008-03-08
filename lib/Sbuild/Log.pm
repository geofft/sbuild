#
# Log.pm: logging library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
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

package Sbuild::Log;

use Sbuild::Conf;

use strict;
use warnings;
use File::Temp ();
use POSIX;
use FileHandle;
use File::Basename qw(basename);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(open_log close_log
		 open_pkg_log close_pkg_log);
}

my $main_logfile;
my $pkg_logfile;
my $pkg_distribution;
my $pkg_name;
my $log_dir_available;

sub open_log {
    my $main_distribution = shift;

    my $date = strftime("%Y%m%d-%H%M",localtime);

    if ($Sbuild::Conf::nolog) {
	open( main::LOG, ">&STDOUT" );
	open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
	select( main::LOG );
	return;
    }

    my $F = new File::Temp( TEMPLATE => "build-${main_distribution}-$date.XXXXXX",
			    DIR => $Sbuild::Conf::build_dir,
			    SUFFIX => '.log',
			    UNLINK => 0)
	or die "Can't open logfile: $!\n";
    $F->autoflush(1);
    $main_logfile = $F->filename;

    if ($Sbuild::Conf::verbose) {
	my $pid;
	($pid = open( main::LOG, "|-"));
	if (!defined $pid) {
	    warn "Cannot open pipe to '$main_logfile': $!\n";
	}
	elsif ($pid == 0) {
	    $SIG{'INT'} = 'IGNORE';
	    $SIG{'QUIT'} = 'IGNORE';
	    $SIG{'TERM'} = 'IGNORE';
	    $SIG{'PIPE'} = 'IGNORE';
	    while (<STDIN>) {
		print $F $_;
		print STDOUT $_;
	    }
	    undef $F;
	    exit 0;
	}
    }
    else {
	open( main::LOG, ">$F" )
	    or warn "Cannot open log file $main_logfile: $!\n";
    }
    undef $F;
    main::LOG->autoflush(1);
    select(main::LOG);
    if ($Sbuild::Conf::verbose) {
	open( SAVED_STDOUT, ">&STDOUT" ) or warn "Can't redirect stdout\n";
	open( SAVED_STDERR, ">&STDERR" ) or warn "Can't redirect stderr\n";
    }
    open( STDOUT, ">&main::LOG" ) or warn "Can't redirect stdout\n";
    open( STDERR, ">&main::LOG" ) or warn "Can't redirect stderr\n";
    open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
}

sub close_log {
    my $date = strftime("%Y%m%d-%H%M",localtime);

    close( main::PLOG );
    close( STDERR );
    close( STDOUT );
    close( main::LOG );
    if ($Sbuild::Conf::verbose) {
	open( STDOUT, ">&SAVED_STDOUT" ) or warn "Can't redirect stdout\n";
	open( STDERR, ">&SAVED_STDERR" ) or warn "Can't redirect stderr\n";
	close (SAVED_STDOUT);
	close (SAVED_STDERR);
    }
    if (!$Sbuild::Conf::nolog && !$Sbuild::Conf::verbose &&
	-s $main_logfile && $Sbuild::Conf::mailto) {
	send_mail( $Sbuild::Conf::mailto, "Log from sbuild $date",
		   $main_logfile ) if $Sbuild::Conf::mailto;
    }
    elsif (!$Sbuild::Conf::nolog && ! -s $main_logfile) {
	unlink( $main_logfile );
    }
}

sub open_pkg_log {
    $pkg_name = shift;
    $pkg_distribution = shift;
    my $date = shift;

    if (!defined $log_dir_available) {
	if (! -d $Sbuild::Conf::log_dir &&
	    !mkdir $Sbuild::Conf::log_dir) {
	    warn "Could not create $Sbuild::Conf::log_dir: $!\n";
	    $log_dir_available = 0;
	} else {
	    $log_dir_available = 1;
	}
    }

    if ($Sbuild::Conf::nolog || !$log_dir_available) {
	open( main::PLOG, ">&STDOUT" );
    }
    else {
	$pkg_logfile = "$Sbuild::Conf::log_dir/${pkg_name}_$date";
	log_symlink($pkg_logfile,
		    "$Sbuild::Conf::build_dir/current-$pkg_distribution");
	log_symlink($pkg_logfile, "$Sbuild::Conf::build_dir/current");
	if ($Sbuild::Conf::verbose) {
	    my $pid;
	    ($pid = open( main::PLOG, "|-"));
	    if (!defined $pid) {
		warn "Cannot open pipe to '$pkg_logfile': $!\n";
	    }
	    elsif ($pid == 0) {
		$SIG{'INT'} = 'IGNORE';
		$SIG{'QUIT'} = 'IGNORE';
		$SIG{'TERM'} = 'IGNORE';
		$SIG{'PIPE'} = 'IGNORE';

		open( CPLOG, ">$pkg_logfile" ) or
		    die "Can't open logfile $pkg_logfile: $!\n";
		CPLOG->autoflush(1);

		while (<STDIN>) {
		    print CPLOG $_;
		    print SAVED_STDOUT $_;
		}
		close CPLOG;
		exit 0;
	    }
	}
	else {
	    if (!open( main::PLOG, ">$pkg_logfile" )) {
		warn "Can't open logfile $pkg_logfile: $!\n";
		return 0;
	    }
	}
    }
    main::PLOG->autoflush(1);
    select(main::PLOG);

    return 1;
}

sub close_pkg_log {
    my $pkg_name = shift;
    my $pkg_distribution = shift;
    my $status = shift;
    my $pkg_start_time = shift;
    my $pkg_end_time = shift;
    my $date = strftime("%Y%m%d-%H%M", localtime($pkg_end_time));

    close( main::PLOG );
    open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
    send_mail( $Sbuild::Conf::mailto,
	       "Log for $status build of $pkg_name (dist=$pkg_distribution)",
	       $pkg_logfile ) if !$Sbuild::Conf::nolog && $log_dir_available && $Sbuild::Conf::mailto;
}

sub send_mail {
    my $to = shift;
    my $subject = shift;
    my $file = shift;
    local( *MAIL, *F );

    if (!open( F, "<$file" )) {
	warn "Cannot open $file for mailing: $!\n";
	return 0;
    }
    local $SIG{'PIPE'} = 'IGNORE';

    if (!open( MAIL, "|$Sbuild::Conf::mailprog -oem $to" )) {
	warn "Could not open pipe to $Sbuild::Conf::mailprog: $!\n";
	close( F );
	return 0;
    }

    print MAIL "From: $Sbuild::Conf::mailfrom\n";
    print MAIL "To: $to\n";
    print MAIL "Subject: $subject\n\n";
    while( <F> ) {
	print MAIL "." if $_ eq ".\n";
	print MAIL $_;
    }

    close( F );
    if (!close( MAIL )) {
	warn "$Sbuild::Conf::mailprog failed (exit status $?)\n";
	return 0;
    }
    return 1;
}

sub log_symlink {
    my $log = shift;
    my $dest = shift;

    unlink $dest || return;
    symlink $log, $dest || return;
}

1;
