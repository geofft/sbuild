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
use GDBM_File;
use POSIX;
use FileHandle;
use File::Basename qw(basename);
use Sbuild::Sysconfig qw($arch $hostname $version);

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
    my $date = strftime("%Y%m%d-%H%M",localtime);
    $pkg_name = shift;
    $pkg_distribution = shift;

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

    print main::PLOG "Automatic build of $pkg_name on $hostname by ".
	"sbuild/$arch $version\n";
    print main::PLOG "Build started at $date\n";
    print main::PLOG "*"x78, "\n";
    return 1;
}

sub close_pkg_log {
    my $date = strftime("%Y%m%d-%H%M",localtime);
    my $status = shift;
    my $pkg_start_time = shift;
    my $pkg_end_time = shift;
    my $space = shift;

    my $time = $pkg_end_time - $pkg_start_time;

    $time = 0 if $time < 0;
    if (defined($status) && $status eq "successful") {
	add_time_entry( $pkg_name, $time );
	add_space_entry( $pkg_name, $space );
    }
    print main::PLOG "*"x78, "\n";
    printf main::PLOG "Finished at ${date}\nBuild needed %02d:%02d:%02d, %dk disk space\n",
    int($time/3600), int(($time%3600)/60), int($time%60), $space;
    close( main::PLOG );
    open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
    send_mail( $Sbuild::Conf::mailto,
	       "Log for $status build of $pkg_name (dist=$pkg_distribution)",
	       $pkg_logfile ) if !$Sbuild::Conf::nolog && $log_dir_available && $Sbuild::Conf::mailto;
}

sub add_time_entry {
    my $pkg = shift;
    my $t = shift;

    return if !$Sbuild::Conf::avg_time_db;
    my %db;
    if (!tie %db, 'GDBM_File',$Sbuild::Conf::avg_time_db,GDBM_WRCREAT,0664) {
	print "Can't open average time db $Sbuild::Conf::avg_time_db\n";
	return;
    }
    $pkg =~ s/_.*//;

    if (exists $db{$pkg}) {
	my @times = split( /\s+/, $db{$pkg} );
	push( @times, $t );
	my $sum = 0;
	foreach (@times[1..$#times]) { $sum += $_; }
	$times[0] = $sum / (@times-1);
	$db{$pkg} = join( ' ', @times );
    }
    else {
	$db{$pkg} = "$t $t";
    }
    untie %db;
}

sub add_space_entry {
    my $pkg = shift;
    my $space = shift;

    my $keepvals = 4;

    return if !$Sbuild::Conf::avg_space_db || $space == 0;
    my %db;
    if (!tie %db, 'GDBM_File',$Sbuild::Conf::avg_space_db,GDBM_WRCREAT,0664) {
	print "Can't open average space db $Sbuild::Conf::avg_space_db\n";
	return;
    }
    $pkg =~ s/_.*//;

    if (exists $db{$pkg}) {
	my @values = split( /\s+/, $db{$pkg} );
	shift @values;
	unshift( @values, $space );
	pop @values if @values > $keepvals;
	my ($sum, $n, $weight, $i) = (0, 0, scalar(@values));
	for( $i = 0; $i < @values; ++$i) {
	    $sum += $values[$i] * $weight;
	    $n += $weight;
	}
	unshift( @values, $sum/$n );
	$db{$pkg} = join( ' ', @values );
    }
    else {
	$db{$pkg} = "$space $space";
    }
    untie %db;
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
