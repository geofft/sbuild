#!/usr/bin/perl
#
# wanna-build-mail: mail interface to wanna-build
# Copyright (C) 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
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
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# $Id$
#

use strict;

$ENV{'PATH'} = "/bin:/usr/bin:/usr/local/bin";
$main::tempfile = "/bin/tempfile";
$main::wanna_build = -f "/usr/local/bin/wanna-build" ?
	"/usr/local/bin/wanna-build" : "/usr/bin/wanna-build";
$main::pgp = "/usr/bin/pgp";
$main::gpp = "/usr/bin/gpg";
$main::sendmail = "/usr/sbin/sendmail";
$main::libdir = "/usr/local/var/debbuild";
$main::pgp_keyring = "$main::libdir/mail-keyring.pgp";
$main::gpg_keyring = "$main::libdir/mail-keyring.gpg";
$main::userdb = "$main::libdir/mail-users";
$main::logfile = "$main::libdir/mail-processor.log";
chomp( $main::date = `/bin/date '+%Y %b %d %H:%M:%S'` );

my $tmpf = `$main::tempfile -p .wanna-build-mail -m 600`;
chomp( $tmpf );
$tmpf =~ /^(.*)$/; $tmpf = $1; # untaint
open( F, ">$tmpf" ) or fatal( "Can't create temp file $tmpf: $!" );
END { unlink( $tmpf ); }

my $in_headers = 1;
my $lastheader = "";
while( <> ) {
	print F;
	chomp;
	next if !$in_headers;
	if (/^$/) {
		$in_headers = 0;
		next;
	}
	elsif (/^\s/ && $lastheader) {
		s/^\s+//;
		$_ = "$lastheader $_";
	}
	if (/^From:\s*/i) {
		$main::from_addr = $';
		chomp( $lastheader = $_ );
	}
	elsif (/^Reply-To:\s*/i) {
		$main::reply_to = $';
		chomp( $lastheader = $_ );
	}
	elsif (/^Subject:\s*/i) {
		$main::subject = $';
		chomp( $lastheader = $_ );
	}
	elsif (/^Message-Id:\s*/i) {
		$main::msgid = $';
		chomp( $lastheader = $_ );
	}
	else {
		$lastheader = "";
	}
}
close( F );
$main::reply_addr = $main::reply_to || $main::from_addr;
fatal( "No reply address known!" ) if !$main::reply_addr;
logger( "Mail from $main::reply_addr" );

my $signator;
fatal( "Your message cannot be processed because it is not ".
		"signed with PGP." )
	 if !($signator = pgp_check( $tmpf ));

read_users();
fatal( "The signator of this message\n($signator)\n".
		"is not authorized to use this mail interface." )
	 if !exists $main::users{$signator};
$main::user = $main::users{$signator};


my $in_sig = 0;
my $reply = "";
my $n_depwait = 0;
my $nn_depwait = 0;
my $n_failed = 0;
my $nn_failed = 0;
my( @wanna_args, @uploaded_args, @giveback_args, @depwait_args,
	@depwait_deps, @failed_args, @failed_msg, @info_args, @list_args,
	@vlist_args );
open( F, "<$tmpf" ) or fatal( "Can't open $tmpf: $!" );
while( <F> && !/^$/ ) {} # skip headers
while( <F> ) {
  repeat_outer:
	$in_sig = 1, next if /^---+\s*BEGIN PGP SIGNATURE/;
	$in_sig = 0, next if /^---+\s*END PGP SIGNATURE/;
	next if $in_sig || /^\s*$/ || /^---/;
	next if !/^([\w]+)\s+(.*)\s*$/;
	my( $command, $args ) = ($1, $2);
	if ($command =~ /^w/) {
		push( @wanna_args, split( /\s+/, $args ));
	}
	elsif ($command =~ /^u/) {
		push( @uploaded_args, split( /\s+/, $args ));
	}
	elsif ($command =~ /^g/) {
		push( @giveback_args, split( /\s+/, $args ));
	}
	elsif ($command =~ /^f/) {
		push( @{$failed_args[$n_failed]}, split( /\s+/, $args ));
		while( <F> ) {
			last if !/^\s+/;
			my $text = $';
			chomp( $text );
			$text =~ s/'/'\\''/g;
			$failed_msg[$n_failed] .= "$text\n";
		}
		if (!$failed_msg[$n_failed]) {
			$reply .= "Error on command \"$command $args\": ".
					  "no failure message specified\n";
		}
		else {
			chop( $failed_msg[$n_failed] );
			++$n_failed;
		}
		goto repeat_outer;
	}
	elsif ($command =~ /^d/) {
		push( @{$depwait_args[$n_depwait]}, split( /\s+/, $args ));
		my $deps = <F>;
		if ($deps !~ /^\s/) {
			$reply .= "Error on command \"$command $args\": ".
					  "no dependency line specified\n";
			$_ = $deps;
			goto repeat_outer;
		}
		chomp( $deps );
		$deps =~ s/^\s+//;
		$deps =~ s/\s+$//;
		$depwait_deps[$n_depwait] = $deps;
		++$n_depwait;
	}
	elsif ($command =~ /^i/) {
		push( @info_args, split( /\s+/, $args ));
	}
	elsif ($command =~ /^l/) {
		push( @list_args, split( /\s+/, $args ));
	}
	elsif ($command =~ /^v/) {
		push( @vlist_args, split( /\s+/, $args ));
	}
	else {
		$reply .= "Unknown command: \"$command\"\n";
	}
}
close( F );

if (@wanna_args) {
	$reply .= "\nRunning wanna-build:\n";
	logger( "take @wanna_args" );
	$reply .= `$main::wanna_build -U $main::user -v --take @wanna_args 2>&1`;
}
if (@uploaded_args) {
	$reply .= "\nRunning uploaded-build:\n";
	logger( "uploaded @uploaded_args" );
	$reply .= `$main::wanna_build -U $main::user -v --uploaded @uploaded_args 2>&1`;
}
if (@giveback_args) {
	$reply .= "\nRunning give-back-build:\n";
	logger( "giveback @uploaded_args" );
	$reply .= `$main::wanna_build -U $main::user -v --give-back @giveback_args 2>&1`;
}
if ($n_failed > 0) {
	my $i;
	$reply .= "\nRunning failed-build (may be different messages):\n";
	for( $i = 0; $i < $n_failed; ++$i ) {
		logger( "failed @{$failed_args[$i]}" );
		$reply .= `$main::wanna_build -U $main::user -v --failed -m'$failed_msg[$i]' @{$failed_args[$i]} 2>&1`;
		$nn_failed += @{$failed_args[$i]};
	}
}
if ($n_depwait > 0) {
	my $i;
	$reply .= "\nRunning dep-wait-build (may be different dependencies):\n";
	for( $i = 0; $i < $n_depwait; ++$i ) {
		logger( "dep-wait @{$depwait_args[$i]} ($depwait_deps[$i])" );
		$reply .= `$main::wanna_build -U $main::user -v --dep-wait -m'$depwait_deps[$i]' @{$depwait_args[$i]} 2>&1`;
		$nn_depwait += @{$depwait_args[$i]};
	}
}
if (@info_args) {
	$reply .= "\nRunning build-info:\n";
	logger( "info @info_args" );
	$reply .= `$main::wanna_build -v --info @info_args 2>&1`;
}
logger( "list @list_args" ) if @list_args;
foreach (@list_args) {
	$reply .= "\nRunning list-$_:\n";
	$reply .= `$main::wanna_build --list=$_ 2>&1`;
}
logger( "vlist @vlist_args" ) if @vlist_args;
foreach (@vlist_args) {
	$reply .= "\nRunning list-$_ -v:\n";
	$reply .= `$main::wanna_build -v --list=$_ 2>&1`;
}

$reply = "No commands, nothing done.\n" if !$reply;
$reply =~ s/^wanna-build Revision:.*\n//mg;
reply( $reply );

logger( "Processed: ",
		scalar(@wanna_args), " taken, ",
		scalar(@uploaded_args), " upl, ",
		scalar(@giveback_args), " giveb, ",
		$nn_depwait, " dwait, ",
		$nn_failed, " failed, ",
		scalar(@info_args), " infos, ",
		scalar(@list_args)+scalar(@vlist_args), " lists" );
	   
exit 0;


sub read_users {
	local( *F );

	open( F, "<$main::userdb" )
		or fatal( "Cannot open $main::userdb: $!" );
	while( <F> ) {
		next if !/^([\w\d]+)\s+(.+)\s*/;
		$main::users{$2} = $1;
	}
	close( F );
}

sub pgp_check {
	my $file = shift;
	my $output = "";
	my $signator;
	my $is_tmpfile = 0;
	my $found = 0;
	my $stat;
	local( *PIPE );
	
	fatal( "No keyring (PGP or GnuPG) exists!" )
		if ! -f $main::pgp_keyring && ! -f $main::gpg_keyring;
	
	if ($main::content_type &&
		$main::content_type =~ m,multipart/signed, &&
		$main::content_type =~ /pgp/i &&
		(my ($bound) = ($main::content_type =~ /boundary=(\S+);/i))) {
		my $file2 = "$file.pgptmp";
		local( *F, *F2 );
		if (!open( F, "<$file" )) {
			fatal( "Can't open $file: $!" );
			return "LOCAL ERROR";
		}
		if (!open( F2, ">$file2" )) {
			fatal( "Can't open $file2: $!" );
			return "LOCAL ERROR";
		}
		my $state = 0;
		while( <F> ) {
			if (/^--\Q$bound\E(--)?$/) {
				if ($state == 0) {
					print F2 "-----BEGIN PGP SIGNED MESSAGE-----\n\n";
					$state = 1;
					next;
				}
				elsif ($state == 1) {
					while( ($_ = <F>) !~ /^---+BEGIN PGP SIGNATURE---+$/ ) {}
					$state = 2;
				}
				elsif ($state == 2) {
					next;
				}
			}
			print F2;
		}
		close( F2 );
		close( F );
		$file = $file2;
		$is_tmpfile = 1;
	}

	$stat = 1;
	if (-x $main::pgp && -f $main::pgp_keyring) {
		if (!open( PIPE, "$main::pgp -f +batchmode +verbose=0 ".
				   "+pubring=$main::pgp_keyring <'$file' 2>&1 >/dev/null |" )) {
			fatal( "Can't open pipe to $main::pgp: $!" );
			unlink( $file ) if $is_tmpfile;
			return "LOCAL ERROR";
		}
		$output .= $_ while( <PIPE> );
		close( PIPE );
		$stat = $?;
		$found = 1 if !$stat || $output =~ /^(good|bad) signature from/im
	}

	if (!$found && -x $main::gpg && -f $main::gpg_keyring) {
		if (!open( PIPE, "$main::gpg --no-options --batch ".
				   "--no-default-keyring --keyring $main::gpg_keyring ".
				   " --verify '$file' 2>&1 |" )) {
			fatal( "Can't open pipe to $main::gpg: $!" );
			unlink( $file ) if $is_tmpfile;
			return "LOCAL ERROR";
		}
		$output .= $_ while( <PIPE> );
		close( PIPE );
		$stat = $?;
	}

	unlink( $file ) if $is_tmpfile;
	return "" if $stat;
	$output =~ /^(gpg: )?good signature from (user )?"(.*)"\.?$/im;
	($signator = $3) ||= "unknown signator";
	return $signator;
}


sub reply {
	my $subject;

	if (!$main::reply_addr) {
		logger( "no reply address set" );
		return;
	}
	
	$main::no_reply = 1;
	if (!open( MAIL, "|$main::sendmail -t -oem" )) {
		fatal( "Could not open pipe to $conf::mail: $!" );
		goto out;
	}

	$subject = $main::subject ? "Re: $main::subject" : "Re: your request";
	print MAIL <<"EOF";
From: wanna-build mail processor <wanna-build\@kullervo.infodrom.north.de>
To: $main::reply_addr
Subject: $subject
EOF
	print MAIL "In-Reply-To: $main::msgid\n" if $main::msgid;
	print MAIL "\n";
	
	print MAIL @_;
	print MAIL "\nGreetings,\n\n\tYour wanna-build mail processor\n";
	if (!close( MAIL )) {
		fatal( "$main::sendmail failed (exit status ", $? >> 8, ")\n" );
		goto out;
	}

  out:
	$main::no_reply = 0;
}


sub fatal {
	logger( @_ );
	if ($main::reply_addr && !$main::no_reply) {
		reply( "FATAL ERROR: ", @_, "\n" );
		exit 1;
	}
	else {
		die "wanna-build-mail: FATAL ERROR: ", @_, "\n";
	}
}

sub logger {
	local( *F );
	my( $str, @lines );
	
	open( F, ">>$main::logfile" ) or return;
	foreach (@_) {
		$str .= $_;
	}
	@lines = split( "\n", $str );
	foreach (@lines) {
		print F "$main::date: ", $_, "\n";
	}
	close( F );
}
