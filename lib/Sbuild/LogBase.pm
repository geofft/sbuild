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

our $log = undef;
our $saved_stdout = undef;
our $saved_stderr = undef;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT_OK);

    @ISA = qw(Exporter);

    @EXPORT_OK = qw(open_log close_log $log $saved_stdout $saved_stderr);
}

sub open_log ($$$) {
    my $conf = shift;
    my $log_file = shift; # File to log to
    my $logfunc = shift; # Function to handle logging

    if (!defined($logfunc)) {
	$logfunc = sub {
	    my $log_file = shift;
	    my $message = shift;

	    print $log_file $message;
	}
    }

    $log_file->autoflush(1) if defined($log_file);

    my $pid;
    ($pid = open($log, "|-"));
    if (!defined $pid) {
	warn "Cannot open pipe to log: $!\n";
    }
    elsif ($pid == 0) {
	# We ignore SIG(INT|QUIT|TERM) because they will be caught in
	# the parent which will subsequently close the logging stream
	# resulting in our termination.  This is needed to ensure the
	# final log messages are sent and the parent doesn't die with
	# SIGPIPE.
	$SIG{'INT'} = 'IGNORE';
	$SIG{'QUIT'} = 'IGNORE';
	$SIG{'TERM'} = 'IGNORE';
	while (<STDIN>) {
	    $logfunc->($log_file, $_)
	        if (!$conf->get('NOLOG') && defined($log_file));
	    $logfunc->(\*STDOUT, $_)
		if ($conf->get('VERBOSE'));
	}
	undef $log_file;
	exit 0;
    }

    undef $log_file; # Close in parent
    $log->autoflush(1); # Automatically flush
    select($log); # It's the default stream

    open($saved_stdout, ">&STDOUT") or warn "Can't redirect stdout\n";
    open($saved_stderr, ">&STDERR") or warn "Can't redirect stderr\n";
    open(STDOUT, '>&', $log) or warn "Can't redirect stdout\n";
    open(STDERR, '>&', $log) or warn "Can't redirect stderr\n";

    return $log;
}

sub close_log ($) {
    my $conf = shift;

    # Note: It's imperative to close and reopen in the exact order in
    # which we originally opened and reopened, or else we can deadlock
    # in wait4 when closing the log stream due to waiting on the child
    # forever.
    open(STDERR, '>&', $saved_stderr) or warn "Can't redirect stderr\n"
	if defined($saved_stderr);
    open(STDOUT, '>&', $saved_stdout) or warn "Can't redirect stdout\n"
	if defined($saved_stdout);
    $saved_stderr->close();
    undef $saved_stderr;
    $saved_stdout->close();
    undef $saved_stdout;
    $log->close();
    undef $log;
}

1;
