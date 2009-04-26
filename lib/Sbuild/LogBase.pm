#
# LogBase.pm: logging library (base functionality) for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2009 Roger Leigh <rleigh@debian.org>
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

package Sbuild::LogBase;

use strict;
use warnings;

sub open_log ($$$);
sub close_log ($);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT_OK);

    @ISA = qw(Exporter);

    @EXPORT_OK = qw(open_log close_log);
}

sub open_log ($$$) {
    my $conf = shift;
    my $F = shift; # File to log to
    my $logfunc = shift; # Function to handle logging

    if (!defined($logfunc)) {
	$logfunc = sub {
	    my $F = shift;
	    my $message = shift;

	    print $F $message;
	    print STDOUT $_;
	}
    }

    $F->autoflush(1) if defined($F);

    my $pid;
    ($pid = open( main::LOG, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to log: $!\n";
    }
    elsif ($pid == 0) {
	$SIG{'INT'} = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	$SIG{'PIPE'} = 'IGNORE';
	while (<STDIN>) {
	    $logfunc->($F, $_)
	        if ($conf->get('NOLOG') && defined($F));
	    $logfunc->(\*STDOUT, $_)
		if ($conf->get('VERBOSE'));
	}
	undef $F;
	exit 0;
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

    close( STDERR );
    close( STDOUT );
    close( main::LOG );
    if ($conf->get('VERBOSE')) {
	open( STDOUT, ">&main::SAVED_STDOUT" ) or warn "Can't redirect stdout\n";
	open( STDERR, ">&main::SAVED_STDERR" ) or warn "Can't redirect stderr\n";
	close (main::SAVED_STDOUT);
	close (main::SAVED_STDERR);
    }
}

1;
