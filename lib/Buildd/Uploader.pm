# buildd-uploader: upload finished packages for buildd
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
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

package Buildd::Uploader;

use strict;
use warnings;

use Buildd qw(lock_file unlock_file unset_env exitstatus send_mail);
use Buildd::Base;
use Buildd::Conf qw();

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

    $self->set('Uploader Lock', undef);
    $self->set('Uploaded Pkgs', {});

    $self->open_log();

    return $self;
}

sub run {
    my $self = shift;

    unset_env();

    $self->set('Uploader Lock',
	       lock_file("$main::HOME/buildd-uploader", 1));

    if (!$self->get('Uploader Lock')) {
	$self->log("exiting; another buildd-uploader is still running");
	return 1;
    }

    for my $queue_config (@{$self->get_conf('UPLOAD_QUEUES')}) {
	$self->upload( 
		$queue_config->get('DUPLOAD_LOCAL_QUEUE_DIR'), 
		$queue_config->get('DUPLOAD_ARCHIVE_NAME'));
    }

    my $uploaded_pkgs = $self->get('Uploaded Pkgs');

    foreach my $dist (keys %{$uploaded_pkgs}) {
	$self->log("Set to Uploaded($dist):$uploaded_pkgs->{$dist}");
    }

    return 0;
}

sub uploaded ($@) {
    my $self = shift;
    my $pkg = shift;

    my @propagated_pkgs = ();

    foreach my $dist_name (@_) {
	my $msgs = "";

	my $dist_config = $self->get_dist_config_by_name($dist_name);
	my $db = $self->get_db_handle($dist_config);

	my $pipe = $db->pipe_query('--uploaded', '--dist=' . $dist_name, $pkg);

	if ($pipe) {
	    while(<$pipe>) {
		if (/^(\S+): Propagating new state /) {
		    push( @propagated_pkgs, $1 );
		}
		elsif (/^(\S+): already uploaded/ &&
		       Buildd::isin( $1, @propagated_pkgs )) {
		    # be quiet on this
		}
		else {
		    $msgs .= $_;
		}
	    }
	    close($pipe);
	    if ($msgs or $?) {
		$self->log($msgs) if $msgs;
		$self->log("wanna-build --uploaded failed with status ",
			   exitstatus($?), "\n" )
		    if $?;
	    } else {
		$self->get('Uploaded Pkgs')->{$dist_name} .= " $pkg";
	    }
	}
	else {
	    $self->log("Can't spawn wanna-build --uploaded: $!\n");
	}
    }
}

sub upload ($$) {
    my $self = shift;
    my $udir = shift;
    my $upload_to = shift;

    chdir( "$main::HOME/$udir" ) || return;
    lock_file( "$main::HOME/$udir" );

    my( $f, $g, @before, @after );

    foreach $f (<*.changes>) {
	($g = $f) =~ s/\.changes$/\.upload/;
	push( @before, $f ) if ! -f $g;
    }

    unlock_file( "$main::HOME/$udir" );

    if (!@before) {
	$self->log("Nothing to do for $udir\n");
	return;
    }

    $self->log(scalar(@before), " jobs to upload in $udir: @before\n");

    foreach $f (@before) {
	($g = $f) =~ s/\.changes$/\.upload/;
	my $logref = $self->do_dupload( $upload_to, $f );

	if (defined $logref and scalar(@$logref) > 0) {
	    my $line;

	    foreach $line (@$logref) {
		$self->log($line);
	    }
	}

	if ( -f $g ) {
	    if (!open( F, "<$f" )) {
		$self->log("Cannot open $f: $!\n");
		next;
	    }
	    my $text;
	    { local($/); undef $/; $text = <F>; }
	    close( F );
	    if ($text !~ /^Distribution:\s*(.*)\s*$/m) {
		$self->log("$f doesn't have a Distribution: field\n");
		next;
	    }
	    my @dists = split( /\s+/, $1 );
	    my ($version,$source,$pkg);
	    if ($text =~ /^Version:\s*(\S+)\s*$/m) {
		$version = $1;
	    }
	    if ($text =~ /^Source:\s*(\S+)(?:\s+\(\S+\))?\s*$/m) {
		$source = $1;
	    }
	    if (defined($version) and defined($source)) {
		$pkg = "${source}_$version";
	    } else {
		($pkg = $f) =~ s/_\S+\.changes$//;
	    }
	    $self->uploaded($pkg,@dists);
	} else {
	    push (@after, $f);
	}
    }

    if (@after) {
	$self->log("The following jobs were not processed (successfully):\n" .
		   "@after\n");
    }
    else {
	$self->log("dupload successful.\n");
    }
    $self->write_stats("uploads", scalar(@before) - scalar(@after));
}

sub do_dupload ($@) {
    my $self = shift;
    my $upload_to = shift;

    my @jobs = @_;
    my @log;
    local( *PIPE );
    my( $current_job, $current_file, @failed, $errs );

    if (!open( PIPE, "dupload -k --to $upload_to @jobs </dev/null 2>&1 |" )) {
	return "Cannot spawn dupload: $!";
    }

    my $dup_log = "";
    while( <PIPE> ) {
	$dup_log .= $_;
	chomp;
	if (/^\[ job \S+ from (\S+\.changes)$/) {
	    $current_job = $1;
	}
	elsif (/^warning: MD5sum mismatch for (\S+), skipping/i) {
	    my $f = $1;
	    push( @log, "dupload error: md5sum mismatch for $f\n" );
	    $errs .= "md5sum mismatch on file $f ($current_job)\n";
	    push( @failed, $current_job );
	}
	elsif (/^\[ Uploading job (\S+)$/) {
	    $current_job = "$1.changes";
	}
	elsif (/dupload fatal error: Can't upload (\S+)/i ||
	       /^\s(\S+).*scp: (.*)$/) {
	    my($f, $e) = ($1, $2);
	    push( @log, "dupload error: upload error for $f\n" );
	    push( @log, "($e)\n" ) if $e;
	    $errs .= "upload error on file $f ($current_job)\n";
	    push( @failed, $current_job );
	}
	elsif (/Timeout at [\S]+ line [\d]+$/) {
	    $errs .= "upload timeout on file $current_job\n";
	    push( @failed, $current_job );
	}
	elsif (/^\s(\S+)\s+[\d.]+ kB /) {
	    $current_file = $1;
	}
    }
    close( PIPE );
    if ($?) {
	if (($? >> 8) == 141) {
	    push( @log, "dupload error: SIGPIPE (broken connection)\n" );
	    $errs .= "upload error (broken connection) during ".
		"file $current_file ($current_job)\n";
	    push( @failed, $current_job );
	}
	else {
	    push( @log, "dupload exit status ". exitstatus($?)  );
	    $errs .= "dupload exit status ".exitstatus($?)."\n";
	    push( @failed, $current_job );
	}
    }

    foreach (@failed) {
	my $u = $_;
	$u =~ s/\.changes$/\.upload/;
	unlink( $u );
	push( @log, "Removed $u due to upload errors.\n" );
	$errs .= "Removed $u to reupload later.\n";
    }

    if ($errs) {
	$errs .= "\nComplete output from dupload:\n\n$dup_log";
	send_mail($self->get_conf('ADMIN_MAIL'), "dupload errors", $errs);
    }
    return \@log;
}

1;
