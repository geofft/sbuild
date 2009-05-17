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
use Sbuild::LogBase;

sub open_log ($);
sub close_log ($);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw(open_log close_log);
}

my $main_logfile;

sub open_log ($) {
    my $conf = shift;

    my $main_distribution = $conf->get('DISTRIBUTION');
    my $date = strftime("%Y%m%d-%H%M",localtime);

    my $F = undef;
    $main_logfile = undef;

    if (!$conf->get('NOLOG')) {
	my $F = new File::Temp( TEMPLATE => "build-${main_distribution}-$date.XXXXXX",
				DIR => $conf->get('BUILD_DIR'),
				SUFFIX => '.log',
				UNLINK => 0)
	    or die "Can't open logfile: $!\n";
	$F->autoflush(1);
	$main_logfile = $F->filename;
    }

    return Sbuild::LogBase::open_log($conf, $F, undef);
}

sub close_log ($) {
    my $conf = shift;

    my $date = strftime("%Y%m%d-%H%M",localtime);

    Sbuild::LogBase::close_log($conf);

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
