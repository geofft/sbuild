# buildd-watcher:
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
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

package Buildd::Watcher;

use strict;
use warnings;
use Buildd qw(send_mail lock_file unlock_file unset_env);
use Buildd::Conf qw();
use Buildd::Base;

use POSIX qw(ESRCH LONG_MAX);
use Cwd;

sub ST_MTIME () { 9 }

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Buildd::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Fudge', 1/24/6); # 10 minutes in units of a day
    $self->set('Graph Maxval', {
	'builds-per-day'	=> 100,
	'uploads-per-day'	=> 100,
	'failed-per-day'	=> 50,
	'dep-wait-per-day'	=> 50,
	'give-back-per-day'	=> 50,
	'time-per-build'	=> 10*60*60,
	'build-time-percent'	=> 1,
	'idle-time-percent'	=> 1});

    $self->open_log();

    return $self;
}

sub run {
    my $self = shift;

    unset_env();
    chdir($self->get_conf('HOME'));

# check if another watcher is still running
    my $watcher_pid;
    if (open( PID, "<watcher-running")) {
	$watcher_pid = <PID>;
	close( PID );
	$watcher_pid =~ /^\s*(\d+)/; $watcher_pid = $1;
	if (!$watcher_pid || (kill( 0, $watcher_pid ) == 0 && $! == ESRCH)) {
	    $self->log("Ignoring stale watcher-running file (pid $watcher_pid).\n");
	}
	else {
	    $self->log("Another buildd-watcher is still running ".
		       "(pid $watcher_pid) -- exiting.\n");
	    return 0;
	}
    }
    open( F, ">watcher-running.new" )
	or die "Can't create watcher-running.new: $!\n";
    printf F "%5d\n", $$;
    close( F );
    rename( "watcher-running.new", "watcher-running" )
	or die "Can't rename watcher-running.new: $!\n";

# check if buildd is still running, restart it if needed.
    my $restart = 0;
    my $daemon_pid;
    if (open( PID, "<" . $self->get_conf('PIDFILE') )) {
	$daemon_pid = <PID>;
	close( PID );
	$daemon_pid =~ /^\s*(\d+)/; $daemon_pid = $1;
	if (!$daemon_pid || (kill( 0, $daemon_pid ) == 0 && $! == ESRCH)) {
	    $self->log("pid file exists, but process $daemon_pid doesn't exist.\n");
	    $restart = 1;
	}
    }
    else {
	$self->log("daemon not running (no pid file).\n");
	$restart = 1;
    }

# do dir-purges that buildd-mail can't do (is running as nobody, so no sudo)
    lock_file( "build/PURGE" );
    my @to_purge = ();
    if (open( F, "<build/PURGE" )) {
	@to_purge = <F>;
	close( F );
	unlink( "build/PURGE" );
	chomp( @to_purge );
    }
    unlock_file( "build/PURGE" );

    foreach (@to_purge) {
	next if ! -d $_;
	system "sudo rm -rf $_";
	$self->log("Purged $_\n");
    }

# cut down mail-errormails file
    my $now = time;
    my @em = ();
    if (open( F, "<mail-errormails" )) {
	chomp( @em = <F> );
	close( F );
    }
    shift @em while @em && ($now - $em[0]) > $self->get_conf('ERROR_MAIL_WINDOW');
    if (@em) {
	open( F, ">mail-errormails" );
	print F join( "\n", @em ), "\n";
	close( F );
    }
    else {
	unlink( "mail-errormails" );
    }

# check for old stuff in build and upload dirs
    my %warnfile;
    my $file;
    my $dev;
    my $ino;
    foreach $file (<upload/*>) {
	($dev,$ino) = lstat $file;
	$warnfile{"$dev:$ino"} = $file if -M $file >= $self->get_conf('WARNING_AGE');
    }
    # TODO: Glob is incompatible with modern sbuild, which doesn't use
    # separate user directories.
    my $username = $self->get_conf('USERNAME');
    foreach $file (<build/chroot-*/build/$username/*>) {
	($dev,$ino) = lstat $file;
	if (! -d _ && ! -l _) {
	    $warnfile{"$dev:$ino"} = $file if -C _ >= $self->get_conf('WARNING_AGE');
	}
	else {
	    my $warnage = $self->get_conf('WARNING_AGE');
	    my $changed_files =
		`find $file -ctime -$warnage -print 2>/dev/null`;
	    $warnfile{"$dev:$ino"} = $file if !$changed_files;
	}
    }
    foreach $file (<build/*>) {
	next if $file =~ m#^build/chroot-[^/]+$#;
	($dev,$ino) = lstat $file;
	if (! -d _ && ! -l _) {
	    $warnfile{"$dev:$ino"} = $file if -C _ >= $self->get_conf('WARNING_AGE');
	}
	else {
	    my $warnage = $self->get_conf('WARNING_AGE');
	    my $changed_files =
		`find $file -ctime -$warnage -print 2>/dev/null`;
	    $warnfile{"$dev:$ino"} = $file if !$changed_files;
	}
    }
    my $nowarnpattern = $self->get_conf('NO_WARN_PATTERN');
    my @warnings = grep( !/$nowarnpattern/, sort values %warnfile );
    if (@warnings) {
	my %reported;
	my @do_warn;
	if (open( W, "<reported-old-files" )) {
	    while( <W> ) {
		next if !/^(\S+)\s+(\d+)$/;
		$reported{$1} = $2;
	    }
	    close( W );
	}

	foreach (@warnings) {
	    if (!exists($reported{$_}) ||
		($now - $reported{$_}) >= $self->get_conf('WARNING_AGE')*24*60*60) {
		push( @do_warn, $_ );
		$reported{$_} = $now;
	    }
	}

	my $old_umask = umask 007;
	open( W, ">reported-old-files" )
	    or die "Can't create/write reported-old-files: $!\n";
	foreach (keys %reported) {
	    print W "$_ $reported{$_}\n" if -e $_ || -l $_;
	}
	close( W );
	umask $old_umask;

	send_mail( $self->get_conf('ADMIN_MAIL'), "buildd-watcher found some old files",
		   "buildd-watcher has found some old files or directories in\n".
		   "~buildd/upload and/or ~buildd/build. Those are:\n\n  ".
		   join( "\n  ", @do_warn ). "\n\n".
		   "Please have a look at them and remove them if ".
		   "they're obsolete.\n" )
	    if @do_warn;
    }

# archive old package/build log files
    $self->archive_logs( "logs", "*", "old-logs/plog", $self->get_conf('PKG_LOG_KEEP') );
    $self->archive_logs( "build", "build-*.log", "old-logs/blog", $self->get_conf('BUILD_LOG_KEEP') );

# rotate daemon's log file
    if (!-f "old-logs/daemon-stamp" ||
	-M "old-logs/daemon-stamp" > $self->get_conf('DAEMON_LOG_ROTATE')-$self->get('Fudge')) {

	$self->log("Rotating daemon log file\n");
	system "touch old-logs/daemon-stamp";

	my $d = $self->format_time(time);
	if (-f $self->get_conf('DAEMON_LOG_FILE') . ".old") {
	    system "mv " . $self->get_conf('DAEMON_LOG_FILE') . ".old old-logs/daemon-$d.log";
	    system "gzip -9 old-logs/daemon-$d.log";
	}

	rename( $self->get_conf('DAEMON_LOG_FILE'),
		$self->get_conf('DAEMON_LOG_FILE') . ".old" );
	my $old_umask = umask 0007;
	system "touch " . $self->get_conf('DAEMON_LOG_FILE');
	umask $old_umask;
	kill( 1, $daemon_pid ) if $daemon_pid;
	$self->reopen_log();

	if ($self->get_conf('DAEMON_LOG_SEND')) {
	    my $text;
	    open( F, "<" . $self->get_conf('DAEMON_LOG_FILE') . ".old" );
	    { local($/); undef $/; $text = <F>; }
	    close( F );
	    send_mail( $self->get_conf('ADMIN_MAIL'), "Build Daemon Log $d", $text );
	}
    }
    $self->archive_logs( "old-logs", "daemon-*.log.gz", "old-logs/dlog", $self->get_conf('DAEMON_LOG_KEEP') );

# make buildd statistics
    if (!-f "stats/Stamp" ||
	-M "stats/Stamp" > $self->get_conf('STATISTICS_PERIOD')-$self->get('Fudge')) {

	$self->log("Making buildd statistics\n");
	lock_file( "stats" );
	my $lasttime = 0;
	if (open( F, "<stats/Stamp" )) {
	    chomp( $lasttime = <F> );
	    close( F );
	}
	my $now = time;

	$self->make_statistics( $lasttime, $now );

	open( F, ">stats/Stamp" );
	print F "$now\n";
	close( F );
	unlock_file( "stats" );

	my $text;
	open( F, "<stats/Summary" );
	{ local($/); undef $/; $text = <F>; }
	close( F );
	send_mail( $self->get_conf('STATISTICS_MAIL'), "Build Daemon Statistics", $text );
    }

    if ($restart) {
	if (-f "NO-DAEMON-PLEASE") {
	    $self->log("NO-DAEMON-PLEASE exists, not starting daemon\n");
	}
	else {
	    $self->close_log();
	    unlink ("watcher-running");
	    exec "buildd";
	}
    }

    unlink ("watcher-running");
    return 0;
}

sub archive_logs ($$$$) {
    my $self = shift;
    my $dir = shift;
    my $pattern = shift;
    my $destpat = shift;
    my $minage = shift;

    my( $olddir, $file, @todo, $oldest, $newest, $oldt, $newt );

    return if -f "$destpat-stamp" && -M "$destpat-stamp" < $minage-$self->get('Fudge');
    $self->log("Archiving logs in $dir:\n");
    system "touch $destpat-stamp";

    $olddir = cwd;
    chdir( $dir );

    $oldest = LONG_MAX;
    $newest = 0;
    foreach $file (glob($pattern)) {
	if (-M $file >= $minage) {
	    push( @todo, $file );
	    my $modtime = (stat(_))[ST_MTIME];
	    $oldest = $modtime if $oldest > $modtime;
	    $newest = $modtime if $newest < $modtime;
	}
    }
    if (@todo) {
	$oldt = $self->format_time($oldest);
	$newt = $self->format_time($newest);
	$file = $self->get_conf('HOME') . "/$destpat-$oldt-$newt.tar";

	system "tar cf $file @todo";
	system "gzip -9 $file";

	if ($dir eq "logs") {
	    local (*F);
	    my $index = $self->get_conf('HOME') . "/$destpat-$oldt-$newt.index";
	    if (open( F, ">$index" )) {
		print F join( "\n", @todo ), "\n";
		close( F );
	    }
	}

	unlink( @todo );
	$self->log("Archived ", scalar(@todo), " files from $oldt to $newt\n");
    }
    else {
	$self->log("No files to archive\n");
    }

    chdir( $olddir );
}

sub make_statistics ($$) {
    my $self = shift;
    my $start_time = shift;
    my $end_time = shift;

    my @svars = qw(taken builds uploads failed dep-wait no-build
		   give-back idle-time build-time remove-time
		   install-download-time);
    my ($s_taken, $s_builds, $s_uploads, $s_failed, $s_dep_wait,
	$s_no_build, $s_give_back, $s_idle_time, $s_build_time,
	$s_remove_time, $s_install_download_time);
    local( *F, *G, *OUT );

    my $var;
    foreach $var (@svars) {
	my $svar = "s_$var";
	$svar =~ s/-/_/g;
	eval "\$$svar = 0;";
	if (-f "stats/$var") {
	    if (!open( F, "<stats/$var" )) {
		$self->log("can't open stats/$var: $!\n");
		next;
	    }
	    my $n = 0;
	    while( <F> ) {
		chomp;
		$n += $_;
	    }
	    close( F );
	    eval "\$$svar = $n;";
	    unlink( "stats/$var" );
	}
    }

    my $total_time = $end_time - $start_time;
    my $days = $total_time / (24*60*60);

    if (!open( OUT, ">stats/Summary" )) {
	$self->log("Can't create stats/Summary: $!\n");
	return;
    }

    printf OUT "Build daemon statistics from %s to %s (%3.2f days):\n\n",
    $self->format_time($start_time), $self->format_time($end_time), $days;

    print  OUT "           #packages  % of taken  pkgs/day\n";
    print  OUT "-------------------------------------------\n";
    printf OUT "taken    : %5d                  %7.2f\n",
    $s_taken, $s_taken/$days;
    printf OUT "builds   : %5d       %7.2f%%   %7.2f\n",
    $s_builds, $s_taken ? $s_builds*100/$s_taken : 0, $s_builds/$days;
    printf OUT "uploaded : %5d       %7.2f%%   %7.2f\n",
    $s_uploads, $s_taken ? $s_uploads*100/$s_taken : 0, $s_uploads/$days;
    printf OUT "failed   : %5d       %7.2f%%   %7.2f\n",
    $s_failed, $s_taken ? $s_failed*100/$s_taken : 0, $s_failed/$days;
    printf OUT "dep-wait : %5d       %7.2f%%   %7.2f\n",
    $s_dep_wait, $s_taken ? $s_dep_wait*100/$s_taken : 0, $s_dep_wait/$days;
    printf OUT "give-back: %5d       %7.2f%%   %7.2f\n",
    $s_give_back, $s_taken ? $s_give_back*100/$s_taken : 0, $s_give_back/$days;
    printf OUT "no-build : %5d       %7.2f%%   %7.2f\n",
    $s_no_build, $s_taken ? $s_no_build*100/$s_taken : 0, $s_no_build/$days;
    print  OUT "\n";

    print  OUT "          time          % of total\n";
    print  OUT "----------------------------------\n";
    printf OUT "building: %s  %7.2f%%\n",
    $self->print_time($s_build_time), $s_build_time*100/$total_time;
    printf OUT "install : %s  %7.2f%%\n",
    $self->print_time($s_install_download_time), $s_install_download_time*100/$total_time;
    printf OUT "removing: %s  %7.2f%%\n",
    $self->print_time($s_remove_time), $s_remove_time*100/$total_time;
    printf OUT "idle    : %s  %7.2f%%\n",
    $self->print_time($s_idle_time), $s_idle_time*100/$total_time;
    printf OUT "total   : %s\n", $self->print_time($total_time);
    print  OUT "\n";

    my $proc = $s_uploads+$s_failed+$s_dep_wait+$s_no_build+$s_give_back;
    printf OUT "processed package (upl+fail+dep+nob): %7d\n", $proc;
    printf OUT "slipped (proc-taken)                : %7d\n", $proc-$s_taken;
    printf OUT "builds/taken package                : %7.2f\n",
    $s_builds/$s_taken
	if $s_taken;
    printf OUT "avg. time/taken package             : %s\n",
    $self->print_time($s_build_time/$s_taken)
	if $s_taken;
    printf OUT "avg. time/processed package         : %s\n",
    $self->print_time($s_build_time/$proc)
	if $proc;
    printf OUT "avg. time/build                     : %s\n",
    $self->print_time($s_build_time/$s_builds)
	if $s_builds;
    print  OUT "\n";

    my $date = $self->format_date(time);
    $self->print_graph( $s_builds/$days, $date, "builds-per-day" );
    $self->print_graph( $s_uploads/$days, $date, "uploads-per-day" );
    $self->print_graph( $s_failed/$days, $date, "failed-per-day" );
    $self->print_graph( $s_dep_wait/$days, $date, "dep-wait-per-day" );
    $self->print_graph( $s_give_back/$days, $date, "give-back-per-day" );
    $self->print_graph( $s_build_time/$s_builds, $date, "time-per-build" )
	if $s_builds;
    $self->print_graph( $s_build_time/$total_time, $date, "build-time-percent" );
    $self->print_graph( $s_idle_time/$total_time, $date, "idle-time-percent" );

    my $g;
    my $graph_maxval = $self->get('Graph Maxval');

    foreach $g (keys %{$graph_maxval}) {
	next if !open( G, "<stats/graphs/$g" );

	print OUT "$g (max. $graph_maxval->{$g}):\n\n";
	while( <G> ) {
	    print OUT $_;
	}
	close( G );
	print OUT "\n";
    }

    close( OUT );
}

sub print_time ($) {
    my $self = shift;
    my $t = shift;

    my $str = sprintf "%02d:%02d:%02d", int($t/3600), int(($t%3600)/60),
    int($t%60);
    $str = " "x(10-length($str)) . $str;

    return $str;
}

sub print_graph ($$$) {
    my $self = shift;
    my $val = shift;
    my $date = shift;
    my $graph = shift;

    my $width = 72;
    local( *G );

    my $graph_maxval = $self->get('Graph Maxval');
    if (!exists $graph_maxval->{$graph}) {
	$self->log("Unknown graph $graph\n");
	return;
    }
    if (!open( G, ">>stats/graphs/$graph" )) {
	$self->log("Can't create stats/graphs/$graph: $!\n");
	return;
    }
    $val = int( $val*$width/$graph_maxval->{$graph} + 0.5 );
    my $str = $val > $width ? "*"x($width-1)."+" : "*"x$val;
    $date = substr( $date, 0, 6 );
    $date .= " " x (6-length($date));
    print G "$date $str\n";
    close( G );
}

sub format_time ($) {
    my $self = shift;
    my $t = shift;

    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = localtime($t);

    return sprintf "%04d%02d%02d-%02d%02d",
    $year+1900, $mon+1, $mday, $hour, $min;
}

sub format_date ($) {
    my $self = shift;
    my $t = shift;

    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = localtime($t);

    return sprintf "%02d%02d%02d", $year%100, $mon+1, $mday;
}

1;
