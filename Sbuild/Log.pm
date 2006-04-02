#
# Log.pm: logging library for sbuild
# Copyright (C) 2005      Ryan Murray <rmurray@debian.org>
# Copyright (C) 2005-2006 Roger Leigh <rleigh@debian.org>
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
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
# $Id: Sbuild.pm,v 1.2 2006/03/07 16:58:12 rleigh Exp $
#

package Sbuild::Log;

use Sbuild::Conf;

use strict;
use warnings;
use GDBM_File;
use POSIX;
use FileHandle;
use Sbuild qw(basename);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(open_log close_log
		 open_pkg_log close_pkg_log);
}

sub open_log {
	my $date = strftime("%Y%m%d-%H%M",localtime);

	if ($main::nolog) {
		open( main::LOG, ">&STDOUT" );
		open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
		select( main::LOG );
		return;
	}

	my $F = new File::Temp( TEMPLATE => "build-${main::distribution}-$date.XXXXXX",
				DIR => $Sbuild::Conf::build_dir,
				SUFFIX => '.log',
				UNLINK => 0)
		or die "Can't open logfile: $!\n";
	$F->autoflush(1);
	$main::main_logfile = $F->filename;

	if ($main::verbose) {
		my $pid;
		($pid = open( main::LOG, "|-"));
		if (!defined $pid) {
			warn "Cannot open pipe to '$main::main_logfile': $!\n";
		}
		elsif ($pid == 0) {
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
			or warn "Cannot open log file $main::main_logfile: $!\n";
	}
	undef $F;
	main::LOG->autoflush(1);
	select(main::LOG);
	if ($main::verbose) {
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
	if ($main::verbose) {
		open( STDOUT, ">&SAVED_STDOUT" ) or warn "Can't redirect stdout\n";
		open( STDERR, ">&SAVED_STDERR" ) or warn "Can't redirect stderr\n";
		close (SAVED_STDOUT);
		close (SAVED_STDERR);
	}
	if (!$main::nolog && !$main::verbose &&
		-s $main::main_logfile && $Sbuild::Conf::mailto) {
		send_mail( $Sbuild::Conf::mailto, "Log from sbuild $date",
				   $main::main_logfile ) if $Sbuild::Conf::mailto;
	}
	elsif (!$main::nolog && ! -s $main::main_logfile) {
		unlink( $main::main_logfile );
	}
}

sub open_pkg_log {
	my $date = strftime("%Y%m%d-%H%M",localtime);
	my $pkg = shift;

	if ($main::nolog) {
		open( main::PLOG, ">&STDOUT" );
	}
	else {
		$pkg = Sbuild::basename( $pkg );
		if ($main::binNMU) {
			$pkg =~ /^([^_]+)_([^_]+)(.*)$/;
			$pkg = $1."_".Sbuild::binNMU_version($2,$main::binNMUver);
			$main::binNMU_name = $pkg;
			$pkg .= $3;
		}
		$main::pkg_logfile = "$Sbuild::Conf::log_dir/${pkg}_$date";
		log_symlink($main::pkg_logfile,
			    "$Sbuild::Conf::build_dir/current-$main::distribution");
		log_symlink($main::pkg_logfile, "$Sbuild::Conf::build_dir/current");
		if ($main::verbose) {
			my $pid;
			($pid = open( main::PLOG, "|-"));
			if (!defined $pid) {
				warn "Cannot open pipe to '$main::pkg_logfile': $!\n";
			}
			elsif ($pid == 0) {
				open( CPLOG, ">$main::pkg_logfile" ) or
					die "Can't open logfile $main::pkg_logfile: $!\n";
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
			if (!open( main::PLOG, ">$main::pkg_logfile" )) {
				warn "Can't open logfile $main::pkg_logfile: $!\n";
				return 0;
			}
		}
	}
	main::PLOG->autoflush(1);
	select(main::PLOG);

	my $revision = '$Revision: 1.107 $';
	$revision =~ /([\d.]+)/;
	$revision = $1;

	print main::PLOG "Automatic build of $pkg on $main::HOSTNAME by ".
			   "sbuild/$main::arch $revision\n";
	print main::PLOG "Build started at $date\n";
	print main::PLOG "*"x78, "\n";
	return 1;
}

sub close_pkg_log {
	my $date = strftime("%Y%m%d-%H%M",localtime);
	my $pkg = shift;
	my $t = $main::pkg_end_time - $main::pkg_start_time;
	
	$pkg = Sbuild::basename( $pkg );
	$t = 0 if $t < 0;
	if (defined($main::pkg_status) && $main::pkg_status eq "successful") {
		add_time_entry( $pkg, $t );
		add_space_entry( $pkg, $main::this_space );
	}
	print main::PLOG "*"x78, "\n";
	printf main::PLOG "Finished at ${date}\nBuild needed %02d:%02d:%02d, %dk disk space\n",
		   int($t/3600), int(($t%3600)/60), int($t%60), $main::this_space;
	close( main::PLOG );
	open( main::PLOG, ">&main::LOG" ) or warn "Can't redirect PLOG\n";
	send_mail( $Sbuild::Conf::mailto,
			   "Log for $main::pkg_status build of ".
			   ($main::binNMU_name || $pkg)." (dist=$main::distribution)",
			   $main::pkg_logfile ) if !$main::nolog && $Sbuild::Conf::mailto;
	undef $main::binNMU_name;
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
	my $t = shift;

	my $keepvals = 4;
	
	return if !$Sbuild::Conf::avg_space_db || $main::this_space == 0;
	my %db;
	if (!tie %db, 'GDBM_File',$Sbuild::Conf::avg_space_db,GDBM_WRCREAT,0664) {
		print "Can't open average space db $Sbuild::Conf::avg_space_db\n";
		return;
	}
	$pkg =~ s/_.*//;
		
	if (exists $db{$pkg}) {
		my @values = split( /\s+/, $db{$pkg} );
		shift @values;
		unshift( @values, $t );
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
		$db{$pkg} = "$t $t";
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
