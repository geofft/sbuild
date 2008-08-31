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

sub open_log ($$);
sub close_log ();
sub open_pkg_log ($$$);
sub close_pkg_log ($$$$$);
sub send_mail ($$$);
sub log_symlink ($$);

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
# TODO: Remove global.
my $conf;

sub open_log ($$) {
    my $main_distribution = shift;
    $conf = shift;

    my $date = strftime("%Y%m%d-%H%M",localtime);

    if ($conf->get('NOLOG')) {
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

    if ($conf->get('VERBOSE')) {
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
    if ($conf->get('VERBOSE')) {
	open( SAVED_STDOUT, ">&STDOUT" ) or warn "Can't redirect stdout\n";
	open( SAVED_STDERR, ">&STDERR" ) or warn "Can't redirect stderr\n";
    }
    open( STDOUT, ">&main::LOG" ) or warn "Can't redirect stdout\n";
    open( STDERR, ">&main::LOG" ) or warn "Can't redirect stderr\n";
    open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
}

# TODO: Don't require $conf for cleanup, or store in log object, or pass in as args?
sub close_log () {

    my $date = strftime("%Y%m%d-%H%M",localtime);

    close( main::PLOG );
    close( STDERR );
    close( STDOUT );
    close( main::LOG );
    if ($conf->get('VERBOSE')) {
	open( STDOUT, ">&SAVED_STDOUT" ) or warn "Can't redirect stdout\n";
	open( STDERR, ">&SAVED_STDERR" ) or warn "Can't redirect stderr\n";
	close (SAVED_STDOUT);
	close (SAVED_STDERR);
    }
    if (!$conf->get('NOLOG') && !$conf->get('VERBOSE') &&
	-s $main_logfile && $conf->get('MAILTO')) {
	send_mail( $conf->get('MAILTO'), "Log from sbuild $date",
		   $main_logfile ) if $conf->get('MAILTO');
    }
    elsif (!$conf->get('NOLOG') && ! -s $main_logfile) {
	unlink( $main_logfile );
    }
}

sub open_pkg_log ($$$) {
    $pkg_name = shift;
    $pkg_distribution = shift;
    my $pkg_start_time = shift;
    my $date = strftime("%Y%m%d-%H%M", localtime($pkg_start_time));

    if (!defined $log_dir_available) {
	if (! -d $conf->get('LOG_DIR') &&
	    !mkdir $conf->get('LOG_DIR')) {
	    warn "Could not create " . $conf->get('LOG_DIR') . ": $!\n";
	    $log_dir_available = 0;
	} else {
	    $log_dir_available = 1;
	}
    }

    if ($conf->get('NOLOG') || !$log_dir_available) {
	open( main::PLOG, ">&STDOUT" );
    }
    else {
	$pkg_logfile = $conf->get('LOG_DIR') . "/${pkg_name}-$date";
	log_symlink($pkg_logfile,
		    "$Sbuild::Conf::build_dir/current-$pkg_distribution");
	log_symlink($pkg_logfile, "$Sbuild::Conf::build_dir/current");
	if ($conf->get('VERBOSE')) {
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

sub close_pkg_log ($$$$$) {
    my $pkg_name = shift;
    my $pkg_distribution = shift;
    my $status = shift;
    my $pkg_start_time = shift;
    my $pkg_end_time = shift;
    my $date = strftime("%Y%m%d-%H%M", localtime($pkg_end_time));

    close( main::PLOG );
    open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
    send_mail($conf->get('MAILTO'),
	      "Log for $status build of $pkg_name (dist=$pkg_distribution)",
	      $pkg_logfile) if !$conf->get('NOLOG') && $log_dir_available && $conf->get('MAILTO');
}

sub send_mail ($$$) {
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
    print MAIL "Subject: $subject\n\n";
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

sub log_symlink ($$) {
    my $log = shift;
    my $dest = shift;

    unlink $dest || return;
    symlink $log, $dest || return;
}

1;
