# buildd-mail: mail answer processor for buildd
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

package Buildd::Mail;

use strict;
use warnings;

use Buildd qw(ll_send_mail);
use Buildd::Conf;
use Buildd::Base;
use Sbuild qw(binNMU_version $devnull);
use Sbuild::ChrootRoot;
use Sbuild::DB::Client;
use POSIX;
use File::Basename;
use MIME::QuotedPrint;
use MIME::Base64;

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

    $self->set('Mail Error', undef);
    $self->set('Mail Short Error', undef);
    $self->set('Mail Header', {});
    $self->set('Mail Body Text', '');

    return $self;
}

sub run {
    my $self = shift;

    chdir($self->get_conf('HOME'));

    $self->set('Mail Error', undef);
    $self->set('Mail Short Error', undef);
    $self->set('Mail Header', {});
    $self->set('Mail Body Text', '');

    $self->process_mail();

    return 0;
}


sub process_mail () {
    my $self = shift;

# Note: Mail Header (to|from|subject|message-id|date) are mandatory.
# Check for these and bail out if not present.
    my $header_text = "";
    my $lastheader = "";

    $self->set('Mail Header', {});

    $self->set('Mail Error', '');
    $self->set('Mail Short Error', '');
    $self->set('Mail Header', {});
    $self->set('Mail Body Text', '');

    while( <STDIN> ) {
	$header_text .= $_;
	last if /^$/;

	if (/^\s/ && $lastheader) {
	    $_ =~ s/^\s+//;
	    $_ = "$lastheader $_";
	}

	if (/^From (\S+)/) {
	    ;
	}
	if (/^([\w\d-]+):\s*(.*)\s*$/) {
	    my $hname;
	    ($hname = $1) =~ y/A-Z/a-z/;
	    $self->get('Mail Header')->{$hname} = $2;
	    $lastheader = $_;
	    chomp( $lastheader );
	}
	else {
	    $lastheader = "";
	}
    }
    while( <STDIN> ) {
	last if !/^\s*$/;
    }

    $self->set('Mail Body Text',
	       $self->get('Mail Body Text') . $_)
	if defined($_);

    if (!eof)
    {
	local($/);
	undef $/;
	$self->set('Mail Body Text',
		   $self->get('Mail Body Text') . <STDIN>);
    }

    if ($self->get('Mail Header')->{'from'} =~ /mail\s+delivery\s+(sub)?system|mailer.\s*daemon/i) {
	# is an error mail from a mailer daemon
	# To avoid mail loops if this error resulted from a mail we sent
	# outselves, we break the loop by not forwarding this mail after the 5th
	# error mail within 8 hours or so.
	my $n = $self->add_error_mail();
	if ($n > 5) {
	    $self->log("Too much error mails ($n) within ",
		       int($self->get_conf('ERROR_MAIL_WINDOW')/(60*60)), " hours\n",
		       "Not forwarding mail from ".$self->get('Mail Header')->{'from'}."\n",
		       "Subject: " . $self->get('Mail Header')->{'subject'} . "\n");
	    return;
	}
    }

    goto forward_mail if !$self->get('Mail Header')->{'subject'};
    my $subject = $self->get('Mail Header')->{'subject'};

    if ($subject =~ /^Re: Log for \S+ build of (\S+)(?: on [\w-]+)? \(dist=(\S+)\)/i) {
	# reply to a build log
	my( $package, $dist_name ) = ( $1, $2 );

	my $dist_config = $self->get_dist_config_by_name($dist_name);
	return if (!$dist_config); #get_dist_config sets the error mail

	my $text = $self->get('Mail Body Text');
	$text =~ /^(\S+)/;
	$self->set('Mail Body Text', $text);
	if (defined($self->get('Mail Header')->{'content-transfer-encoding'})) {
	    # Decode the mail if necessary.
	    if ($self->get('Mail Header')->{'content-transfer-encoding'} =~ /quoted-printable/) {
		$self->set('Mail Body Text',
			   decode_qp($self->get('Mail Body Text')));
	    } elsif ($self->get('Mail Header')->{'content-transfer-encoding'} =~ /base64/) {
		$self->set('Mail Body Text',
			   decode_base64($self->get('Mail Body Text')));
	    }
	}
	my $keyword = $1;
	my $from = $self->get('Mail Header')->{'from'};
	$from = $1 if $from =~ /<(.+)>/;
	$self->log("Log reply from $from\n");
	my %newv;

	if ($keyword =~ /^not-for-us/) {
	    $self->no_build( $package, $dist_config );
	    $self->purge_pkg( $package, $dist_config );
	}
	elsif ($keyword =~ /^up(l(oad)?)?-rem/) {
	    $self->remove_from_upload( $package, $dist_config );
	}
	elsif ($self->check_is_outdated( $dist_config, $package )) {
	    # Error has been set already -> no action here
	}
	elsif ($keyword =~ /^fail/) {
	    my $text = $self->get('Mail Body Text');
	    $text =~ s/^fail.*\n(\s*\n)*//;
	    $text =~ s/\n+$/\n/;
	    $self->set_to_failed( $package, $dist_config, $text );
	    $self->purge_pkg( $package, $dist_config );
	}
	elsif ($keyword =~ /^ret/) {
	    if (!$self->check_state( $package, $dist_config, qw(Building Build-Attempted) )) {
		# Error already set
	    }
	    else {
		$self->append_to_REDO( $package, $dist_config );
	    }
	}
	elsif ($keyword =~ /^d(ep(endency)?)?-(ret|w)/) {
	    if (!$self->check_state( $package, $dist_config, qw(Building Build-Attempted) )) {
		# Error already set
	    }
	    else {
		$self->get('Mail Body Text') =~ /^\S+\s+(.*)$/m;
		my $deps = $1;
		$self->set_to_depwait( $package, $dist_config, $deps );
		$self->purge_pkg( $package, $dist_config );
	    }
	}
	elsif ($keyword =~ /^man/) {
	    if (!$self->check_state( $package, $dist_config, "Building" )) {
		# Error already set
	    }
	    else {
		# no action
		$self->log("$package($dist_name) will be finished manually\n");
	    }
	}
	elsif ($keyword =~ /^newv/) {
	    # build a newer version instead
	    $self->get('Mail Body Text') =~ /^newv\S*\s+(\S+)/;
	    my $newv = $1;
	    if ($newv =~ /_/) {
		$self->log("Removing unneeded package name from $newv\n");
		$newv =~ s/^.*_//;
		$self->log("Result: $newv\n");
	    }
	    my $pkgname;
	    ($pkgname = $package) =~ s/_.*$//;
	    $self->redo_new_version( $dist_config, $package, "${pkgname}_${newv}" );
	    $self->purge_pkg( $package, $dist_config );
	}
	elsif ($keyword =~ /^(give|back)/) {
	    $self->get('Mail Body Text') =~ /^(give|back) ([-0-9]+)/;
	    my $pri = $1;
	    if (!$self->check_state( $package, $dist_config, qw(Building Build-Attempted) )) {
		# Error already set
	    }
	    else {
		$self->give_back( $package, $dist_config );
		$self->purge_pkg( $package, $dist_config );
	    }
	}
	elsif ($keyword =~ /^purge/) {
	    $self->purge_pkg( $package, $dist_config );
	}
	elsif ($self->get('Mail Body Text') =~ /^---+\s*BEGIN PGP SIGNED MESSAGE/) {
	    if ($self->prepare_for_upload( $package,
					   $self->get('Mail Body Text') )) {
		$self->purge_pkg( $package, $dist_config );
	    }
	}
	elsif ($self->get('Mail Body Text') =~ /^--/ &&
	       $self->get('Mail Header')->{'content-type'} =~ m,multipart/signed,) {
	    my ($prot)  = ($self->get('Mail Header')->{'content-type'} =~ m,protocol="([^"]*)",);
	    my ($bound) = ($self->get('Mail Header')->{'content-type'} =~ m,boundary="([^"]*)",);
	    my $text = $self->get('Mail Body Text');
	    $text =~ s,^--\Q$bound\E\nContent-Type: text/plain; charset=us-ascii\n\n,-----BEGIN PGP SIGNED MESSAGE-----\n\n,;
	    $text =~ s,--\Q$bound\E\nContent-Type: application/pgp-signature\n\n,,;
	    $text =~ s,\n\n--\Q$bound\E--\n,,;
	    $self->set('Mail Body Text', $text);
	    if ($self->prepare_for_upload($package,
					  $self->get('Mail Body Text'))) {
		$self->purge_pkg( $package, $dist_config );
	    }
	}
	else {
	    $self->set('Mail Short Error',
		       $self->get('Mail Short Error') .
		       "Bad keyword in answer $keyword\n");
	    $self->set('Mail Error',
		       $self->get('Mail Error') .
		       "Answer not understood (expected retry, failed, manual,\n".
		       "dep-wait, giveback, not-for-us, purge, upload-rem,\n".
		       "newvers, or a signed changes file)\n");
	}
    }
    elsif ($subject =~ /^Re: Should I build (\S+) \(dist=(\S+)\)/i) {
	# reply whether a prev-failed package should be built
	my( $package, $dist_name ) = ( $1, $2 );

	my $dist_config = $self->get_dist_config_by_name($dist_name);
	return if (!$dist_config); #get_dist_config sets the error mail
	
	$self->get('Mail Body Text') =~ /^(\S+)/;
	my $keyword = $1;
	$self->log("Should-build reply for $package($dist_name)\n");
	if ($self->check_is_outdated( $dist_config, $package )) {
	    # Error has been set already -> no action here
	}
	elsif (!$self->check_state( $package, $dist_config, "Building" )) {
	    # Error already set
	}
	elsif ($keyword =~ /^(build|ok)/) {
	    $self->append_to_REDO( $package, $dist_config );
	}
	elsif ($keyword =~ /^fail/) {
	    my $text = $self->get_fail_msg( $package, $dist_config );
	    $self->set_to_failed( $package, $dist_config, $text );
	}
	elsif ($keyword =~ /^(not|no-b)/) {
	    $self->no_build( $package, $dist_config );
	}
	elsif ($keyword =~ /^(give|back)/) {
	    $self->give_back( $package, $dist_config );
	}
	else {
	    $self->set('Mail Short Error',
		       $self->get('Mail Short Error') .
		       "Bad keyword in answer $keyword\n");
	    $self->set('Mail Error',
		       $self->get('Mail Error') .
		       "Answer not understood (expected build, ok, fail, ".
		       "give-back, or no-build)\n");
	}
    }
    elsif ($subject =~ /^Processing of (\S+)/) {
	my $job = $1;
	# mail from Erlangen queue daemon: forward all non-success messages
	my $text = $self->get('Mail Body Text');
	goto forward_mail if $text !~ /uploaded successfully/mi;
	$self->log("$job processed by upload queue\n")
	    if $self->get_conf('LOG_QUEUED_MESSAGES');
    }
    elsif ($subject =~ /^([-+~\.\w]+\.changes) (INSTALL|ACCEPT)ED/) {
	# success mail from dinstall
	my $changes_f = $1;
	my( @to_remove, $upload_f, $pkgv );
	my @upload_dirs = $self->find_upload_dirs_for_changes_file($changes_f);

	if ((scalar @upload_dirs) < 1) {
	    $self->log("Can't identify upload directory for $changes_f!\n");
	    return 0;
	} elsif ((scalar @upload_dirs) > 1) {
	    $self->log("Found more than one upload directory for $changes_f - not deleting binaries!\n");
	    return 0;
	}
	my $upload_dir = $upload_dirs[0];

	if (-f "$upload_dir/$changes_f" && open( F, "<$upload_dir/$changes_f" )) {
	    local($/); undef $/;
	    my $changetext = <F>;
	    close( F );
	    push( @to_remove, $self->get_files_from_changes( $changetext ) );
	} else {
	    foreach (split( "\n", $self->get('Mail Body Text'))) {
		if (/^(\[-+~\.\w]+\.(u?deb))$/) {
		    my $f = $1;
		    push( @to_remove, $f ) if !grep { $_ eq $f } @to_remove;
		}
	    }
	}
	($upload_f = $changes_f) =~ s/\.changes$/\.upload/;
	push( @to_remove, $changes_f, $upload_f );
	($pkgv = $changes_f) =~ s/_(\S+)\.changes//;
	$self->log("$pkgv has been installed; removing from upload dir:\n",
		   "@to_remove\n");

	my @dists;
	if (open( F, "<$upload_dir/$changes_f" )) {
	    my $changes_text;
	    { local($/); undef $/; $changes_text = <F>; }
	    close( F );
	    @dists = $self->get_dists_from_changes( $changes_text );
	} else {
	    $self->log("Cannot get dists from $upload_dir/$changes_f: $! (assuming unstable)\n");
	    @dists = ( "unstable" );
	}

FILE:	foreach (@to_remove) {
    if (/\.deb$/) {
	# first listed wins
	foreach my $dist (@dists) {
	    if ( -d $self->get_conf('HOME') . "/build/chroot-$dist" &&
		 -w $self->get_conf('HOME') . "/build/chroot-$dist/var/cache/apt/archives/") {
		# TODO: send all of to_remove to perl-apt if it's available, setting a try_mv list
		# that only has build-depends in it.
		# if that's too much cpu, have buildd use perl-apt if avail to export the
		# build-depends list, which could then be read in at this point
		if (system "mv $upload_dir/$_ " .
		    $self->get_conf('HOME') .
		    "/build/chroot-$dist/var/cache/apt/archives/") {
		    $self->log("Cannot move $upload_dir/$_ to cache dir\n");
		} else {
		    next FILE;
		}
	    }
	}
    }
    unlink "$upload_dir/$_"
	or $self->log("Can't remove $upload_dir/$_: $!\n");
}
    }
    elsif ($subject =~ /^(\S+\.changes) is NEW$/) {
	# "is new" mail from dinstall
	my $changes_f = $1;
	my $pkgv;
	($pkgv = $changes_f) =~ s/_(\S+)\.changes//;
	$self->log("$pkgv must be manually dinstall-ed -- delayed\n");
    }
    elsif ($subject =~ /^new version of (\S+) \(dist=(\S+)\)$/) {
	# notice from wanna-build
	my ($pkg, $dist_name) = ($1, $2);
	my $dist_config = $self->get_dist_config_by_name($dist_name);
	goto forward if $self->get('Mail Body Text') !~ /^in version (\S+)\.$/m;
	my $pkgv = $pkg."_".$1;
	$self->get('Mail Body Text') =~ /new source version (\S+)\./m;
	my $newv = $1;
	$self->log("Build of $pkgv ($dist_name) obsolete -- new version $newv\n");
	$self->register_outdated( $dist_name, $pkgv, $pkg."_".$newv );

	my @ds;
	if (!(@ds = $self->check_building_any_dist( $pkgv ))) {
	    if (!$self->remove_from_REDO( $pkgv )) {
		$self->append_to_SKIP( $pkgv );
	    }
	    $self->purge_pkg( $pkgv, $dist_config );
	}
	else {
	    $self->log("Not deleting, still building for @ds\n");
	}
    }
    elsif ($self->get('Mail Body Text') =~ /^blacklist (\S+)\n$/) {
	my $pattern = "\Q$1\E";
	if (open( F, ">>mail-blacklist" )) {
	    print F "$pattern\n";
	    close( F );
	    $self->log("Added $pattern to blacklist.\n");
	}
	else {
	    $self->log("Can't open mail-blacklist for appending: $!\n");
	}
    }
    else {
	goto forward_mail;
    }


    if ($self->get('Mail Error')) {
	$self->log("Error: ",
		   $self->get('Mail Short Error') || $self->get('Mail Error'));
	$self->reply("Your mail could not be processed:\n" .
		     $self->get('Mail Error'));
    }
    return;

forward_mail:
    my $header = $self->get('Mail Header');
    $self->log("Mail from $header->{'from'}\nSubject: $subject\n");
    if ($self->is_blacklisted( $self->get('Mail Header')->{'from'} )) {
	$self->log("Address is blacklisted, deleting mail.\n");
    }
    else {
	$self->log("Not for me, forwarding to admin\n");
	ll_send_mail( $self->get_conf('ADMIN_MAIL'),
		      "To: $header->{'to'}\n".
		      ($header->{'cc'} ? "Cc: $header->{'cc'}\n" : "").
		      "From: $header->{'from'}\n".
		      "Subject: $header->{'subject'}\n".
		      "Date: $header->{'date'}\n".
		      "Message-Id: $header->{'message-id'}\n".
		      ($header->{'reply-to'} ? "Reply-To: $header->{'reply-to'}\n" : "").
		      ($header->{'in-reply-to'} ? "In-Reply-To: $header->{'in-reply-to'}\n" : "").
		      ($header->{'references'} ? "References: $header->{'references'}\n" : "").
		      "Resent-From: $Buildd::gecos <$Buildd::username\@$Buildd::hostname>\n".
		      "Resent-To: " . $self->get_conf('ADMIN_MAIL') . "\n\n".
		      $self->get('Mail Body Text') );
    }
}


sub prepare_for_upload ($$) {
    my $self = shift;
    my $pkg = shift;
    my $changes = shift;

    my( @files, @md5, @missing, @md5fail, $i );

    my @to_dists = $self->get_dists_from_changes( $changes );
    if (!@to_dists) { # probably not a valid changes

	$self->set('Mail Short Error',
		   $self->get('Mail Error'));
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Couldn't find a valid Distribution: line.\n");
	return 0;
    }
    $changes =~ /^Files:\s*\n((^[ 	]+.*\n)*)/m;
    foreach (split( "\n", $1 )) {
	push( @md5, (split( /\s+/, $_ ))[1] );
	push( @files, (split( /\s+/, $_ ))[5] );
    }
    if (!@files) { # probably not a valid changes
	$self->set('Mail Short Error',
		   $self->get('Mail Error'));
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "No files listed in changes.\n");
	return 0;
    }
    my @wrong_dists = ();
    foreach my $d (@to_dists) {
	push( @wrong_dists, $d )
	    if !$self->check_state($pkg, $d, qw(Building Install-Wait Reupload-Wait));
    }
    if (@wrong_dists) {
	$self->set('Mail Short Error',
		   $self->get('Mail Error'));
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Package $pkg has target distributions @wrong_dists\n".
		   "for which it isn't registered as Building.\n".
		   "Please fix this by either modifying the Distribution: ".
		   "header or\n".
		   "taking the package in those distributions, too.\n");
	return 0;
    }

    for( $i = 0; $i < @files; ++$i ) {
	if (! -f $self->get_conf('HOME') . "/build/$files[$i]") {
	    push( @missing, $files[$i] ) ;
	}
	else {
	    my $home = $self->get_conf('HOME');
	    chomp( my $sum = `md5sum $home/build/$files[$i]` );
	    push( @md5fail, $files[$i] ) if (split(/\s+/,$sum))[0] ne $md5[$i];
	}
    }
    if (@missing) {
	$self->set('Mail Short Error',
		   $self->get('Mail Short Error') .
		   "Missing files for move: @missing\n");
    	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "While trying to move the built package $pkg to upload,\n".
		   "the following files mentioned in the .changes were not found:\n".
		   "@missing\n");
	return 0;
    }
    if (@md5fail) {
	$self->set('Mail Short Error',
		   $self->get('Mail Short Error') .
		   "md5 failure during move: @md5fail\n");
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "While trying to move the built package $pkg to upload,\n".
		   "the following files had bad md5 checksums:\n".
		   "@md5fail\n");
	return 0;
    }

    my @upload_dirs = $self->get_upload_queue_dirs ( $changes );

    my $pkg_noep = $pkg;
    $pkg_noep =~ s/_\d*:/_/;
    my $changes_name = "${pkg_noep}_" . $self->get_conf('ARCH') . ".changes";
    
    for my $upload_dir (@upload_dirs) {
    if (! -d $upload_dir &&!mkdir( $upload_dir, 0750 )) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Cannot create directory $upload_dir");
	$self->log("Cannot create dir $upload_dir\n");
	return 0;
    }
    }

    my $errs = 0;
    for my $upload_dir (@upload_dirs) {
	lock_file( $upload_dir );
	foreach (@files) {
	    if (system "cp " . $self->get_conf('HOME') . "/build/$_ $upload_dir/$_") {
		$self->log("Cannot copy $_ to $upload_dir/\n");
		++$errs;
	    }
	}

	open( F, ">$upload_dir/$changes_name" );
	print F $changes;
	close( F );
	unlock_file( $upload_dir );
	$self->log("Moved $pkg to ", basename($upload_dir), "\n");
    }

    foreach (@files) {
	if (system "rm " . $self->get_conf('HOME') . "/build/$_") {
	    $self->log("Cannot remove build/$_\n");
	    ++$errs;
	}
    }

    if ($errs) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Could not move all files to upload dir.");
	return 0;
    }

    unlink( $self->get_conf('HOME') . "/build/$changes_name" )
	or $self->log("Cannot remove " . $self->get_conf('HOME') . "/$changes_name: $!\n");
}

sub redo_new_version ($$$) {
    my $self = shift;
    my $dist_config = shift;
    my $oldv = shift;
    my $newv = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    my $err = 0;

	my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('-v', '--dist=' . $dist_name, $newv);
    if ($pipe) {
	while(<$pipe>) {
	    next if /^wanna-build Revision/ ||
		/^\S+: Warning: Older version / ||
		/^\S+: ok$/;
	    $self->set('Mail Error',
		       $self->get('Mail Error') . $_);
	    $err = 1;
	}
	close($pipe);
    } else {
	$self->log("Can't spawn wanna-build: $!\n");
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Can't spawn wanna-build: $!\n");
	return;
    }
    if ($err) {
	$self->log("Can't take newer version $newv due to wanna-build errors\n");
	return;
    }
    $self->log("Going to build $newv instead of $oldv\n");

    $self->append_to_REDO( $newv, $dist_config );
}

sub purge_pkg ($$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    my $dir;
    local( *F );

    $self->remove_from_REDO( $pkg );

    # remove .changes and .deb in build dir (if existing)
    my $pkg_noep = $pkg;
    $pkg_noep =~ s/_\d*:/_/;
    my $changes = "${pkg_noep}_" . $self->get_conf('ARCH') . ".changes";
    if (-f "build/$changes" && open( F, "<build/$changes" )) {
	local($/); undef $/;
	my $changetext = <F>;
	close( F );
	my @files = $self->get_files_from_changes( $changetext );
	push( @files, $changes );
	$self->log("Purging files: $changes\n");
	unlink( map { "build/$_" } @files );
    }

    # schedule dir for purging
    ($dir = $pkg_noep) =~ s/-[^-]*$//; # remove Debian revision
    $dir =~ s/_/-/; # change _ to -
    if (-d "build/chroot-$dist_name/build/$Buildd::username/$dir") {
	$dir = "build/chroot-$dist_name/build/$Buildd::username/$dir";
    }
    else {
	$dir = "build/$dir";
    }
    return if ! -d $dir;

    lock_file( "build/PURGE" );
    if (open( F, ">>build/PURGE" )) {
	print F "$dir\n";
	close( F );
	$self->log("Scheduled $dir for purging\n");
    }
    else {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Can't open build/PURGE: $!\n");
	$self->log("Can't open build/PURGE: $!\n");
    }
    unlock_file( "build/PURGE" );
}

sub remove_from_upload ($) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;

    my($changes_f, $upload_f, $changes_text, @to_remove);
    local( *F );

    $self->log("Remove $pkg from upload dir\n");
    my $pkg_noep = $pkg;
    $pkg_noep =~ s/_\d*:/_/;
    $changes_f = "${pkg_noep}_" . $self->get_conf('ARCH') . ".changes";

    my $upload_dir = $dist_config->get('DUPLOAD_LOCAL_QUEUE_DIR');

    if (!-f "$upload_dir/$changes_f") {
	$self->log("$changes_f does not exist\n");
	return;
    }
    if (!open( F, "<$upload_dir/$changes_f" )) {
	$self->log("Cannot open $upload_dir/$changes_f: $!\n");
	return;
    }
    { local($/); undef $/; $changes_text = <F>; }
    close( F );
    @to_remove = $self->get_files_from_changes( $changes_text );

    ($upload_f = $changes_f) =~ s/\.changes$/\.upload/;
    push( @to_remove, $changes_f, $upload_f );

    $self->log("Removing files:\n", "@to_remove\n");
    foreach (@to_remove) {
	unlink "$upload_dir/$_"
	    or $self->log("Can't remove $upload_dir/$_: $!\n");
    }
}

sub append_to_REDO ($$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    local( *F );

    lock_file( "build/REDO" );

    if (open( F, "build/REDO" )) {
	my @pkgs = <F>;
	close( F );
	if (grep( /^\Q$pkg\E\s/, @pkgs )) {
	    $self->log("$pkg is already in REDO -- not rescheduled\n");
	    goto unlock;
	}
    }

    if (open( F, ">>build/REDO" )) {
	print F "$pkg $dist_name\n";
	close( F );
	$self->log("Scheduled $pkg for rebuild\n");
    }
    else {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Can't open build/REDO: $!\n");
	$self->log("Can't open build/REDO: $!\n");
    }

  unlock:
    unlock_file( "build/REDO" );
}

sub remove_from_REDO ($) {
    my $self = shift;
    my $pkg = shift;

    local( *F );

    lock_file( "build/REDO" );
    goto unlock if !open( F, "<build/REDO" );
    my @pkgs = <F>;
    close( F );
    if (!open( F, ">build/REDO" )) {
	$self->log("Can't open REDO for writing: $!\n",
		   "Would write: @pkgs\nminus $pkg\n");
	goto unlock;
    }
    my $done = 0;
    foreach (@pkgs) {
	if (/^\Q$pkg\E\s/) {
	    ++$done;
	}
	else {
	    print F $_;
	}
    }
    close( F );
    $self->log("Deleted $pkg from REDO list.\n") if $done;
  unlock:
    unlock_file( "build/REDO" );
    return $done;
}

sub append_to_SKIP ($) {
    my $self = shift;
    my $pkg = shift;

    local( *F );

    return if !open( F, "<build/build-progress" );
    my @lines = <F>;
    close( F );

    if (grep( /^\s*\Q$pkg\E$/, @lines )) {
	# pkg is in build-progress, but without a suffix (failed,
	# successful, currently building), so it can be skipped
	lock_file( "build/SKIP" );
	if (open( F, ">>build/SKIP" )) {
	    print F "$pkg\n";
	    close( F );
	    $self->log("Told sbuild to skip $pkg\n");
	}
	unlock_file( "build/SKIP" );
    }
}

sub check_is_outdated ($$) {
    my $self = shift;
    my $dist_config = shift;
    my $package = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    my %newv;
    return 0 if !(%newv = $self->is_outdated( $dist_name, $package ));

    my $have_changes = 1 if $self->get('Mail Body Text') =~ /^---+\s*BEGIN PGP SIGNED MESSAGE/;

    # If we have a changes file, we can see which distributions that
    # package is aimed to. Otherwise, we're out of luck because we can't see
    # reliably anymore for which distribs the package was for. Let the user
    # find out this...
    #
    # If the package is outdated in all dists we have to consider,
    # send a plain error message. If only outdated in some of them, send a
    # modified error that tells to send a restricted changes (with
    # Distribution: only for those dists where it isn't outdated), or to do
    # the action manually, because it would be (wrongly) propagated.
    goto all_outdated if !$have_changes;

    my @check_dists = ();
    @check_dists = $self->get_dists_from_changes($self->get('Mail Body Text'));

    my @not_outdated = ();
    my @outdated = ();
    foreach (@check_dists) {
	if (!exists $newv{$_}) {
	    push( @not_outdated, $_ );
	}
	else {
	    push( @outdated, $_ );
	}
    }
    return 0 if !@outdated;
    if (@not_outdated) {
	$self->set('Mail Short Error',
		   $self->get('Mail Short Error') .
		   "$package ($dist_name) partially outdated ".
		   "(ok for @not_outdated)\n");
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Package $package ($dist_name) is partially outdated.\n".
		   "The following new versions have appeared in the meantime:\n ".
		   join( "\n ", map { "$_: $newv{$_}" } keys %newv )."\n\n".
		   "Please send a .changes for the following distributions only:\n".
		   " Distribution: ".join( " ", @not_outdated )."\n");
    }
    else {
      all_outdated:
	$self->set('Mail Short Error',
		   $self->get('Mail Short Error') .
		   "$package ($dist_name) outdated; new versions ".
		   join( ", ", map { "$_:$newv{$_}" } keys %newv )."\n");
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Package $package ($dist_name) is outdated.\n".
		   "The following new versions have appeared in the meantime:\n ".
		   join( "\n ", map { "$_: $newv{$_}" } keys %newv )."\n");
    }
    return 1;
}

sub is_outdated ($$) {
    my $self = shift;
    my $dist_name = shift;
    my $pkg = shift;

    my %result = ();
    local( *F );

    lock_file( "outdated-packages" );
    goto unlock if !open( F, "<outdated-packages" );
    while( <F> ) {
	my($oldpkg, $newpkg, $t, $d) = split( /\s+/, $_ );
	$d ||= "unstable";
	if ($oldpkg eq $pkg && $d eq $dist_name) {
	    $result{$d} = $newpkg;
	}
    }
    close( F );
  unlock:
    unlock_file( "outdated-packages" );
    return %result;
}

sub register_outdated ($$$) {
    my $self = shift;
    my $dist = shift;
    my $oldv = shift;
    my $newv = shift;

    my(@pkgs);
    local( *F );

    lock_file( "outdated-packages" );

    if (open( F, "<outdated-packages" )) {
	@pkgs = <F>;
	close( F );
    }

    if (!open( F, ">outdated-packages" )) {
	$self->log("Cannot open outdated-packages for writing: $!\n");
	goto unlock;
    }
    my $now = time;
    my @d = ();
    foreach (@pkgs) {
	my($oldpkg, $newpkg, $t, $d) = split( /\s+/, $_ );
	$d ||= "unstable";
	next if ($oldpkg eq $oldv && $d eq $dist) || ($now - $t) > 21*24*60*60;
	print F $_;
    }
    print F "$oldv $newv $now $dist\n";
    close( F );
  unlock:
    unlock_file( "outdated-packages" );
}

sub set_to_failed ($$$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $text = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    my $is_bugno = 0;

    $text =~  s/^\.$/../mg;
    $is_bugno = 1 if $text =~ /^\(see #\d+\)$/;
    return if !$self->check_state( $pkg, $dist_config, $is_bugno ? "Failed" : "Building" );

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query_out('--failed', "--dist=$dist_name", $pkg);
    if ($pipe) {
	print $pipe "${text}.\n";
	close($pipe);
    }
    if ($?) {
	my $t = "wanna-build --failed failed with status ".exitstatus($?)."\n";
	$self->log($t);
	$self->set('Mail Error',
		   $self->get('Mail Error') . $t);
    } elsif ($is_bugno) {
	$self->log("Bug# appended to fail message of $pkg ($dist_name)\n");
    }
    else {
	$self->log("Set package $pkg ($dist_name) to Failed\n");
	$self->write_stats("failed", 1);
    }
}

sub set_to_depwait ($$$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $deps = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

	my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query_out('--dep-wait', "--dist=$dist_name", $pkg);
    if ($pipe) {
	print $pipe "$deps\n";
	close($pipe);
    }
    if ($?) {
	my $t = "wanna-build --dep-wait failed with status ".exitstatus($?)."\n";
	$self->log($t);
	$self->set('Mail Error',
		   $self->get('Mail Error') . $t);
    }
    else {
	$self->log("Set package $pkg ($dist_name) to Dep-Wait\nDependencies: $deps\n");
    }
    $self->write_stats("dep-wait", 1);
}

sub give_back ($$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    my $answer;

	my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('--give-back', '--dist=' . $dist_name, $pkg);
    if ($pipe) {
	$answer = <$pipe>;
	close($pipe);
    }
    if ($?) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "wanna-build --give-back failed:\n$answer");
    }
    else {
	$self->log("Given back package $pkg ($dist_name)\n");
    }
}

sub no_build ($$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $dist_name = $dist_config->get('DIST_NAME');
    my $answer_cmd;

    my $answer;

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('--no-build', '--dist=' . $dist_name, $pkg);
    if ($pipe) {
	$answer = <$pipe>;
	close($pipe);
    }
    if ($?) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "no-build failed:\n$answer");
    }
    else {
	$self->log("Package $pkg ($dist_name) to set Not-For-Us\n");
    }
    $self->write_stats("no-build", 1);
}

sub get_fail_msg ($$) {
    my $self = shift;
    my $pkg = shift;
    my $dist_config = shift;
    my $dist_name = $dist_config->get('DIST_NAME');

    $pkg =~ s/_.*//;

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('--info', '--dist=' . $dist_name, $pkg);
    if ($pipe) {
	my $msg = "";
	while(<$pipe>) {
	    if (/^\s*Old-Failed\s*:/) {
		while(<$pipe>) {
		    last if /^  \S+\s*/;
		    $_ =~ s/^\s+//;
		    if (/^----+\s+\S+\s+----+$/) {
			last if $msg;
		    }
		    else {
			$msg .= $_;
		    }
		}
		last;
	    }
	}
	close($pipe);
	return $msg if $msg;
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Couldn't find Old-Failed in info for $pkg\n");
	return "Same as previous version (couldn't extract the text)\n";
    } else {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Couldn't start wanna-build --info: $!\n");
	return "Same as previous version (couldn't extract the text)\n";
    }
}

sub check_state ($$@) {
    my $self = shift;
    my $pkgv = shift;
    my $dist_config = shift;
    my @wanted_states = @_;
    my $dist_name = $dist_config->get('DIST_NAME');

    $pkgv =~ /^([^_]+)_(.+)/;
    my ($pkg, $vers) = ($1, $2);

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query('--info', "--dist=$dist_name", $pkg);
    if (!$pipe) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Couldn't start wanna-build --info: $!\n");
	return 0;
    }

    my ($av, $as, $ab, $an);
    while(<$pipe>) {
	$av = $1 if /^\s*Version\s*:\s*(\S+)/;
	$as = $1 if /^\s*State\s*:\s*(\S+)/;
	$ab = $1 if /^\s*Builder\s*:\s*(\S+)/;
	$an = $1 if /^\s*Binary-NMU-Version\s*:\s*(\d+)/;
    }
    close($pipe);

    my $msg = "$pkgv($dist_name) check_state(@wanted_states): ";
    $av = binNMU_version($av,$an,undef) if (defined $an);
    if ($av ne $vers) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   $msg."version $av registered as $as\n");
	return 0;
    }
    if (!Buildd::isin( $as, @wanted_states)) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   $msg."state is $as\n");
	return 0;
    }
    if ($as eq "Building" && $ab ne $self->get_conf('WANNA_BUILD_DB_USER')) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   $msg."is building by $ab\n");
	return 0;
    }
    return 1;
}

sub check_building_any_dist ($) {
    my $self = shift;
    my $pkgv = shift;

    my @dists;

    $pkgv =~ /^([^_]+)_(.+)/;
    my ($pkg, $vers) = ($1, $2);

    for my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	my $dist_name = $dist_config->get('DIST_NAME');

	my $db = $self->get_db_handle($dist_config);
	my $pipe = $db->pipe_query('--info', "--dist=$dist_name", $pkg);
    if (!$pipe) {
	$self->set('Mail Error',
		   $self->get('Mail Error') .
		   "Couldn't start wanna-build --info: $!\n");
	return 0;
    }

    my $text;
    { local ($/); $text = <$pipe>; }
    close($pipe);

    while( $text =~ /^\Q$pkg\E\((\w+)\):(.*)\n((\s.*\n)*)/mg ) {
	my ($dist, $rest, $info) = ($1, $2, $3);
	next if $rest =~ /not registered/;
	my ($av, $as, $ab);
	$av = $1 if $info =~ /^\s*Version\s*:\s*(\S+)/mi;
	$as = $1 if $info =~ /^\s*State\s*:\s*(\S+)/mi;
	$ab = $1 if $info =~ /^\s*Builder\s*:\s*(\S+)/mi;
	push( @dists, $dist )
	    if $av eq $vers && $as eq "Building" &&
	    $ab eq $self->get_conf('WANNA_BUILD_DB_USER');
    }
    }
    return @dists;
}

sub get_files_from_changes ($) {
    my $self = shift;
    my $changes_text = shift;

    my(@filelines, @files);

    $changes_text =~ /^Files:\s*\n((^[ 	]+.*\n)*)/m;
    @filelines = split( "\n", $1 );
    foreach (@filelines) {
	push( @files, (split( /\s+/, $_ ))[5] );
    }
    return @files;
}

sub get_dists_from_changes ($) {
    my $self = shift;
    my $changes_text = shift;

    $changes_text =~ /^Distribution:\s*(.*)\s*$/mi;
    return split( /\s+/, $1 );
}

sub get_upload_queue_dirs ($) {
    my $self = shift;
    my $changes_text = shift;

    my %upload_dirs;
    my @dists = $self->get_dists_from_changes( $changes_text );
    for my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	my $upload_dir = $self->get_conf('HOME') . $dist_config->get('DUPLOAD_LOCAL_QUEUE_DIR');

	if (grep { $dist_config->get('DIST_NAME') eq $_ } @dists) {
	    $upload_dirs{$upload_dir} = 1;
    }
    }
    return keys %upload_dirs;
}

sub find_upload_dirs_for_changes_file ($) {
    my $self = shift;
    my $changes_file_name = shift;

    my %dirs;

    for my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	my $upload_dir = $self->get_conf('HOME') . $dist_config->get('DUPLOAD_LOCAL_QUEUE_DIR');
	if (-f "$upload_dir/$changes_file_name") {
	    $dirs{$upload_dir} = 1;	
	}
    }

    return keys %dirs;
}

sub reply ($) {
    my $self = shift;
    my $text = shift;

    my( $to, $subj, $quoting );

    $to = $self->get('Mail Header')->{'reply-to'} ||
	$self->get('Mail Header')->{'from'};
    $subj = $self->get('Mail Header')->{'subject'};
    $subj = "Re: $subj" if $subj !~ /^Re\S{0,2}:/;
    ($quoting = $self->get('Mail Body Text')) =~ s/\n+$/\n/;
    $quoting =~ s/^/> /mg;

    send_mail( $to, $subj, "$quoting\n$text",
	       "In-Reply-To: ". $self->get('Mail Header')->{'message-id'}. "\n" );
}

sub is_blacklisted ($) {
    my $self = shift;
    my $addr = shift;

    local( *BL );

    $addr = $1 if $addr =~ /<(.*)>/;
    return 0 if !open( BL, "<mail-blacklist" );
    while( <BL> ) {
	chomp;
	if ($addr =~ /$_$/) {
	    close( BL );
	    return 1;
	}
    }
    close( BL );
    return 0;
}

sub add_error_mail () {
    my $self = shift;

    local( *F );
    my $now = time;
    my @em = ();

    if (open( F, "<mail-errormails" )) {
	chomp( @em = <F> );
	close( F );
    }
    push( @em, $now );
    shift @em while @em && ($now - $em[0]) > $self->get_conf('ERROR_MAIL_WINDOW');

    if (@em) {
	open( F, ">mail-errormails" );
	print F join( "\n", @em ), "\n";
	close( F );
    }
    else {
	unlink( "mail-errormails" );
    }

    return scalar(@em);
}

1;
