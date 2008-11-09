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

use strict;
use warnings;
use File::Temp ();
use POSIX;
use FileHandle;
use File::Basename qw(basename);
use Sbuild qw(send_mail);

sub open_log ($$);
sub close_log ($);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(open_log close_log);
}

my $main_logfile;

sub open_log ($$) {
    my $main_distribution = shift;
    my $conf = shift;

    my $date = strftime("%Y%m%d-%H%M",localtime);

    if ($conf->get('NOLOG')) {
	open( main::LOG, ">&STDOUT" );
	select( main::LOG );
	return;
    }

    my $F = new File::Temp( TEMPLATE => "build-${main_distribution}-$date.XXXXXX",
			    DIR => $conf->get('BUILD_DIR'),
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
	open( main::SAVED_STDOUT, ">&STDOUT" ) or warn "Can't redirect stdout\n";
	open( main::SAVED_STDERR, ">&STDERR" ) or warn "Can't redirect stderr\n";
    }
    open( STDOUT, ">&main::LOG" ) or warn "Can't redirect stdout\n";
    open( STDERR, ">&main::LOG" ) or warn "Can't redirect stderr\n";
}

sub close_log ($) {
    my $conf = shift;

    my $date = strftime("%Y%m%d-%H%M",localtime);

    close( STDERR );
    close( STDOUT );
    close( main::LOG );
    if ($conf->get('VERBOSE')) {
	open( STDOUT, ">&main::SAVED_STDOUT" ) or warn "Can't redirect stdout\n";
	open( STDERR, ">&main::SAVED_STDERR" ) or warn "Can't redirect stderr\n";
	close (main::SAVED_STDOUT);
	close (main::SAVED_STDERR);
    }
    if (!$conf->get('NOLOG') && !$conf->get('VERBOSE') &&
	-s $main_logfile && $conf->get('MAILTO')) {
	send_mail( $conf,
		   $conf->get('MAILTO'), "Log from sbuild $date",
		   $main_logfile ) if $conf->get('MAILTO');
    }
    elsif (!$conf->get('NOLOG') && ! -s $main_logfile) {
	unlink( $main_logfile );
    }
}

1;
