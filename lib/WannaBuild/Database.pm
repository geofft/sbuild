# Copyright © 1998      Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2005-2008 Ryan Murray <rmurray@debian.org>
# Copyright © 2008      Roger Leigh <rleigh@debian.org
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

package Wannabuild::Database;

use strict;
use warnings;

use POSIX;
use Sbuild qw(isin usage_error version_less version_lesseq version_compare);
use WannaBuild::Conf;
use Sbuild::Sysconfig;
use Sbuild::DB::Info;
use Sbuild::DB::MLDBM;
use Sbuild::DB::Postgres;
use WannaBuild::Options;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Current Database', undef);
    $self->set('Databases', {});

    $self->set('Mail Logs', '');

    my @curr_time = gmtime();
    my $ctime = time();

    $self->set('Current Date', strftime("%Y %b %d %H:%M:%S", @curr_time));
    $self->set('Short Date', strftime("%m/%d/%y", @curr_time));
    $self->set('Current Time', $ctime);

    # Note: specific contents are only incremented, never initially set.
    # This might be a bug.
    $self->set('New Version', {});

    $self->set('Merge Src Version', {});
    $self->set('Merge Bin Src', {});

    $self->set('Priority Values', {
	required	=> -5,
	important	=> -4,
	standard	=> -3,
	optional	=> -2,
	extra		=> -1,
	unknown		=> -1});

    my $sectval = {
	libs			=> -200,
	'debian-installer'	=> -199,
	base			=> -198,
	devel			=> -197,
	shells			=> -196,
	perl			=> -195,
	python			=> -194,
	graphics		=> -193,
	admin			=> -192,
	utils			=> -191,
	x11			=> -190,
	editors			=> -189,
	net			=> -188,
	mail			=> -187,
	news			=> -186,
	tex			=> -185,
	text			=> -184,
	web			=> -183,
	doc			=> -182,
	interpreters		=> -181,
	gnome			=> -180,
	kde			=> -179,
	games			=> -178,
	misc			=> -177,
	otherosfs		=> -176,
	oldlibs			=> -175,
	libdevel		=> -174,
	sound			=> -173,
	math			=> -172,
	science			=> -171,
	comm			=> -170,
	electronics		=> -169,
	hamradio		=> -168,
	embedded		=> -166
    };
    foreach my $i (keys %{$sectval}) {
	$sectval->{"contrib/$i"} = $sectval->{$i}+40;
	$sectval->{"non-free/$i"} = $sectval->{$i}+80;
    }
    $sectval->{'unknown'}	= -165;
    $self->set('Section Values', $sectval);

    $self->set('Category Values', {
	"none"			=> -20,
	"uploaded-fixed-pkg"	=> -19,
	"fix-expected"		=> -18,
	"reminder-sent"		=> -17,
	"nmu-offered"		=> -16,
	"easy"			=> -15,
	"medium"		=> -14,
	"hard"			=> -13,
	"compiler-error"	=> -12});

    return $self;
}

sub run {
    my $self = shift;

    $self->set_conf('DB_OPERATION', $self->get_conf('DB_CATEGORY') ? "set-failed" : "set-building")
	if !$self->get_conf('DB_OPERATION'); # default operation
    $self->set_conf('DB_LIST_ORDER', $self->get_conf('DB_LIST_STATE') eq "failed" ? 'fPcpasn' : 'PScpasn')
	if (!$self->get_conf('DB_LIST_ORDER') &&
	    (defined($self->get_conf('DB_LIST_STATE')) && $self->get_conf('DB_LIST_STATE')));
    $self->set_conf('DISTRIBUTION', 'unstable')
	if !defined($self->get_conf('DISTRIBUTION'));

    die "Bad distribution '" . $self->get_conf('DISTRIBUTION') . "'\n"
	if !isin($self->get_conf('DISTRIBUTION'), keys %{$self->get_conf('DB_DISTRIBUTIONS')});

    if ($self->get_conf('VERBOSE')) {
	print "wanna-build (Debian sbuild) $Sbuild::Sysconfig::version ($Sbuild::Sysconfig::release_date) on " . $self->get_conf('HOSTNAME') . "\n";
	print "Using database " . $self->get_conf('DB_BASE_NAME') . '/' . $self->get_conf('DISTRIBUTION') . "\n"
    }

    if (!@ARGV && !isin($self->get_conf('DB_OPERATION'),
			qw(list merge-quinn merge-partial-quinn import
 			   export merge-packages manual-edit
 			   maintlock-create merge-sources
 			   maintlock-remove clean-db))) {
	usage_error("wanna-build", "No packages given.");
    }

    if (!$self->get_conf('DB_FAIL_REASON')) {
	if ($self->get_conf('DB_OPERATION') eq "set-failed" && !$self->get_conf('DB_CATEGORY')) {
	    print "Enter reason for failing (end with '.' alone on ".
		"its line):\n";
	    my $log = "";
	    my $line;
	    while(!eof(STDIN)) {
		$line = <STDIN>;
		last if $line eq ".\n";
		$line = ".\n" if $line eq "\n";
		$log .= $line;
	    }
	    chomp($log);
	    $self->set_conf('DB_FAIL_REASON', $log);
	} elsif ($self->get_conf('DB_OPERATION') eq "set-dep-wait") {
	    print "Enter dependencies (one line):\n";
	    my $line;
	    while( !$line && !eof(STDIN) ) {
		chomp( $line = <STDIN> );
	    }
	    die "No dependencies given\n" if !$line;
	    $self->set_conf('DB_FAIL_REASON'. $line);
	} elsif ($self->get_conf('DB_OPERATION') eq "set-binary-nmu" and $self->get_conf('DB_BIN_NMU_VERSION') > 0) {
	    print "Enter changelog entry (one line):\n";
	    my $line;
	    while( !$line && !eof(STDIN) ) {
		chomp( $line = <STDIN> );
	    }
	    die "No changelog entry given\n" if !$line;
	    $self->set_conf('DB_FAIL_REASON', $line);
	}
    }
    if ($self->get_conf('DB_OPERATION') eq "maintlock-create") {
	$self->create_maintlock();
	exit 0;
    }
    if ($self->get_conf('DB_OPERATION') eq "maintlock-remove") {
	$self->remove_maintlock();
	exit 0;
    }
    $self->waitfor_maintlock() if $self->get_conf('DB_OPERATION') !~ /^(?:merge-|clean-db$)/;

    if (!-f $self->db_filename( $self->get_conf('DISTRIBUTION') ) && !$self->get_conf('DB_CREATE')) {
	die "Database for " . $self->get_conf('DISTRIBUTION') . " doesn't exist\n";
    }

    # TODO: Use 'Databases' only.
    $self->set('Current Database',
	       $self->open_db($self->get_conf('DISTRIBUTION')));

    $self->process();

    if ($self->get('Mail Logs') &&
	defined($self->get_conf('DB_LOG_MAIL')) && $self->get_conf('DB_LOG_MAIL')) {
	$self->send_mail($self->get_conf('DB_LOG_MAIL'),
			 "wanna-build " . $self->get_conf('DISTRIBUTION') .
			 " state changes " . $self->get('Current Date'),
			 "State changes at " . $self->get('Current Date') .
			 " for distribution ".
			 $self->get_conf('DISTRIBUTION') . ":\n\n".
			 $self->get('Mail Logs') . "\n");
    }

    return 0;
}

sub process {
    my $self = shift;

  SWITCH: foreach ($self->get_conf('DB_OPERATION')) {
      /^set-(.+)/ && do {
	  $self->add_packages( $1, @ARGV );
	  last SWITCH;
      };
      /^list/ && do {
	  $self->list_packages($self->get_conf('DB_LIST_STATE'));
	  last SWITCH;
      };
      /^info/ && do {
	  $self->info_packages( @ARGV );
	  last SWITCH;
      };
      /^forget-user/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->forget_users( @ARGV );
	  last SWITCH;
      };
      /^forget/ && do {
	  $self->forget_packages( @ARGV );
	  last SWITCH;
      };
      /^merge-partial-quinn/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->parse_quinn_diff(1);
	  last SWITCH;
      };
      /^merge-quinn/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->parse_quinn_diff(0);
	  last SWITCH;
      };
      /^merge-packages/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->parse_packages();
	  last SWITCH;
      };
      /^merge-sources/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->parse_sources(0);
	  last SWITCH;
      };
      /^pretend-avail/ && do {
	  $self->pretend_avail( @ARGV );
	  last SWITCH;
      };
      /^merge-all/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  my @ARGS = @ARGV;
	  @ARGV = ( $ARGS[0] );
	  my $pkgs = $self->parse_packages();
	  @ARGV = ( $ARGS[1] );
	  $self->parse_quinn_diff(0);
	  @ARGV = ( $ARGS[2] );
	  my $build_deps = $self->parse_sources(1);
	  $self->auto_dep_wait( $build_deps, $pkgs );
	  $self->get('Current Database')->clean();
	  last SWITCH;
      };
      /^import/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->get('Current Database')->clear(); # clear all current contents
	  $self->get('Current Database')->restore($self->get_conf('DB_IMPORT_FILE'));
	  last SWITCH;
      };
      /^export/ && do {
	  $self->get('Current Database')->dump($self->get_conf('DB_EXPORT_FILE'));
	  last SWITCH;
      };
      /^manual-edit/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  my $tmpfile_pattern = "/tmp/wanna-build-" . $self->get_conf('DISTRIBUTION') . ".$$-";
	  my ($tmpfile, $i);
	  for( $i = 0;; ++$i ) {
	      $tmpfile = $tmpfile_pattern . $i;
	      last if ! -e $tmpfile;
	  }
	  $self->get('Current Database')->dump($tmpfile);
	  my $editor = $ENV{'VISUAL'} ||
	      "/usr/bin/sensible-editor";
	  system "$editor $tmpfile";
	  $self->get('Current Database')->clear(); # clear all current contents
	  $self->get('Current Database')->restore($tmpfile);
	  unlink( $tmpfile );
	  last SWITCH;
      };
      /^clean-db/ && do {
	  die "This operation is restricted to admin users\n"
	      if (defined @{$self->get_conf('DB_ADMIN_USERS')} and
		  !isin( $self->get_conf('USERNAME'), @{$self->get_conf('DB_ADMIN_USERS')}));
	  $self->get('Current Database')->clean();
	  last SWITCH;
      };

      die "Unexpected operation mode " . $self->get_conf('DB_OPERATION') . "\n";
  }
    if (not -t and $self->get_conf('DB_USER') =~ /-/) {
	my $ui = $self->get('Current Database')->get_user($self->get_conf('DB_USER'));
	$ui = {} if (!defined($ui));

	$ui->{'Last-Seen'} = $self->get('Current Date');
	$ui->{'User'} = $self->get_conf('DB_USER');

	$self->get('Current Database')->set_user($ui);
    }

}

sub add_packages {
    my $self = shift;
    my $newstate = shift;

    my( $package, $name, $version, $ok, $reason );

    foreach $package (@_) {
	$package =~ s,^.*/,,; # strip path
	$package =~ s/\.(dsc|diff\.gz|tar\.gz|deb)$//; # strip extension
	$package =~ s/_[a-zA-Z\d-]+\.changes$//; # strip extension
	if ($package =~ /^([\w\d.+-]+)_([\w\d:.+~-]+)/) {
	    ($name,$version) = ($1,$2);
	}
	else {
	    warn "$package: can't extract package name and version ".
		"(bad format)\n";
	    next;
	}

	if ($self->get_conf('DB_OPERATION') eq "set-building") {
	    $self->add_one_building( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-built") {
	    $self->add_one_built( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-attempted") {
	    $self->add_one_attempted( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-uploaded") {
	    $self->add_one_uploaded( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-failed") {
	    $self->add_one_failed( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-not-for-us") {
	    $self->add_one_notforus( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-needs-build") {
	    $self->add_one_needsbuild( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-dep-wait") {
	    $self->add_one_depwait( $name, $version );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-build-priority") {
	    $self->set_one_buildpri( $name, $version, 'BuildPri' );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-permanent-build-priority") {
	    $self->set_one_buildpri( $name, $version, 'PermBuildPri' );
	}
	elsif ($self->get_conf('DB_OPERATION') eq "set-binary-nmu") {
	    $self->set_one_binnmu( $name, $version );
	}
    }
}

sub add_one_building {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my( $ok, $reason );

    $ok = 1;
    my $pkg = $self->get('Current Database')->get_package($name);
    if (defined($pkg)) {
	if ($pkg->{'State'} eq "Not-For-Us") {
	    $ok = 0;
	    $reason = "not suitable for this architecture";
	}
	elsif ($pkg->{'State'} =~ /^Dep-Wait/) {
	    $ok = 0;
	    $reason = "not all source dependencies available yet";
	}
	elsif ($pkg->{'State'} eq "Uploaded" &&
	       (version_lesseq($version, $pkg->{'Version'}))) {
	    $ok = 0;
	    $reason = "already uploaded by $pkg->{'Builder'}";
	    $reason .= " (in newer version $pkg->{'Version'})"
		if !version_eq($pkg, $version);
	}
	elsif ($pkg->{'State'} eq "Installed" &&
	       version_less($version,$pkg->{'Version'})) {
	    if ($self->get_conf('DB_OVERRIDE')) {
		print "$name: Warning: newer version $pkg->{'Version'} ".
		    "already installed, but overridden.\n";
	    }
	    else {
		$ok = 0;
		$reason = "newer version $pkg->{'Version'} already in ".
		    "archive; doesn't need rebuilding";
		print "$name: Note: If the following is due to an epoch ",
		" change, use --override\n";
	    }
	}
	elsif ($pkg->{'State'} eq "Installed" &&
	       $self->pkg_version_eq($pkg,$version)) {
	    $ok = 0;
	    $reason = "is up-to-date in the archive; doesn't need rebuilding";
	}
	elsif ($pkg->{'State'} eq "Needs-Build" &&
	       version_less($version,$pkg->{'Version'})) {
	    if ($self->get_conf('DB_OVERRIDE')) {
		print "$name: Warning: newer version $pkg->{'Version'} ".
		    "needs building, but overridden.";
	    }
	    else {
		$ok = 0;
		$reason = "newer version $pkg->{'Version'} needs building, ".
		    "not $version";
	    }
	}
	elsif (isin($pkg->{'State'},qw(Building Built Build-Attempted))) {
	    if (version_less($pkg->{'Version'},$version)) {
		print "$name: Warning: Older version $pkg->{'Version'} ",
		"is being built by $pkg->{'Builder'}\n";
		if ($pkg->{'Builder'} ne $self->get_conf('DB_USER')) {
		    $self->send_mail(
			$pkg->{'Builder'},
			"package takeover in newer version",
			"You are building package '$name' in ".
			"version $version\n".
			"(as far as I'm informed).\n".
			$self->get_conf('DB_USER') . " now has taken the newer ".
			"version $version for building.".
			"You can abort the build if you like.\n");
		}
	    }
	    else {
		if ($self->get_conf('DB_OVERRIDE')) {
		    print "User $pkg->{'Builder'} had already ",
		    "taken the following package,\n",
		    "but overriding this as you request:\n";
		    $self->send_mail(
			$pkg->{'Builder'}, "package takeover",
			"The package '$name' (version $version) that ".
			"was locked by you\n".
			"has been taken over by " . $self->get_conf('DB_USER') . "\n");
		}
		elsif ($pkg->{'Builder'} eq $self->get_conf('DB_USER')) {
		    print "$name: Note: already taken by you.\n";
		    print "$name: ok\n" if $self->get_conf('VERBOSE');
		    return;
		}
		else {
		    $ok = 0;
		    $reason = "already taken by $pkg->{'Builder'}";
		    $reason .= " (in newer version $pkg->{'Version'})"
			if !version_eq($pkg->{'Version'}, $version);
		}
	    }
	}
	elsif ($pkg->{'State'} =~ /^Failed/ &&
	       $self->pkg_version_eq($pkg, $version)) {
	    if ($self->get_conf('DB_OVERRIDE')) {
		print "The following package previously failed ",
		"(by $pkg->{'Builder'})\n",
		"but overriding this as you request:\n";
		$self->send_mail(
		    $pkg->{'Builder'}, "failed package takeover",
		    "The package '$name' (version $version) that ".
		    "is locked by you\n".
		    "and has failed previously has been taken over ".
		    "by " . $self->get_conf('DB_USER') . "\n")
		    if $pkg->{'Builder'} ne $self->get_conf('DB_USER');
	    }
	    else {
		$ok = 0;
		$reason = "build of $version failed previously:\n    ";
		$reason .= join( "\n    ", split( "\n", $pkg->{'Failed'} ));
		$reason .= "\nalso the package doesn't need builing"
		    if $pkg->{'State'} eq 'Failed-Removed';
	    }
	}
    }
    if ($ok) {
	my $ok = 'ok';
	if ($pkg->{'Binary-NMU-Version'}) {
	    print "$name: Warning: needs binary NMU $pkg->{'Binary-NMU-Version'}\n" .
		"$pkg->{'Binary-NMU-Changelog'}\n";
	    $ok = 'aok';
	} else {
	    print "$name: Warning: Previous version failed!\n"
		if $pkg->{'Previous-State'} =~ /^Failed/ ||
		$pkg->{'State'} =~ /^Failed/;
	}
	$self->change_state( $pkg, 'Building' );
	$pkg->{'Package'} = $name;
	$pkg->{'Version'} = $version;
	$pkg->{'Builder'} = $self->get_conf('DB_USER');
	$self->log_ta( $pkg, "--take" );
	$self->get('Current Database')->set_package($pkg);
	print "$name: $ok\n" if $self->get_conf('VERBOSE');
    }
    else {
	print "$name: NOT OK!\n  $reason\n";
    }
}

sub add_one_attempted {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $pkg = $self->get('Current Database')->get_package($name);

	if (!defined($pkg)) {
		print "$name: not registered yet.\n";
		return;
	}

	if ($pkg->{'State'} ne "Building" ) {
		print "$name: not taken for building (state is $pkg->{'State'}). ",
			  "Skipping.\n";
		return;
	}
	if ($pkg->{'Builder'} ne $self->get_conf('USERNAME')) {
		print "$name: not taken by you, but by $pkg->{'Builder'}. Skipping.\n";
		return;
	}
	elsif ( !$self->pkg_version_eq($pkg, $version) ) {
		print "$name: version mismatch ".
			  "$(pkg->{'Version'} ".
			  "by $pkg->{'Builder'})\n";
		return;
	}

	$self->change_state( $pkg, 'Build-Attempted' );
	$self->log_ta( $pkg, "--attempted" );
	$self->get('Current Database')->set_package($pkg);
	print "$name: registered as uploaded\n" if $self->get_conf('VERBOSE');
}

sub add_one_built {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $pkg = $self->get('Current Database')->get_package($name);

	if (!defined($pkg)) {
		print "$name: not registered yet.\n";
		return;
	}

	if ($pkg->{'State'} ne "Building" ) {
		print "$name: not taken for building (state is $pkg->{'State'}). ",
			  "Skipping.\n";
		return;
	}
	if ($pkg->{'Builder'} ne $self->get_conf('USERNAME')) {
		print "$name: not taken by you, but by $pkg->{'Builder'}. Skipping.\n";
		return;
	}
	elsif ( !$self->pkg_version_eq($pkg, $version) ) {
		print "$name: version mismatch ".
			  "$(pkg->{'Version'} ".
			  "by $pkg->{'Builder'})\n";
		return;
	}
	$self->change_state( $pkg, 'Built' );
	$self->log_ta( $pkg, "--built" );
	$self->get('Current Database')->set_package($pkg);
	print "$name: registered as built\n" if $self->get_conf('VERBOSE');
}

sub add_one_uploaded {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $pkg = $self->get('Current Database')->get_package($name);

    if (!defined($pkg)) {
	print "$name: not registered yet.\n";
	return;
    }

    if ($pkg->{'State'} eq "Uploaded" &&
	$self->pkg_version_eq($pkg,$version)) {
	print "$name: already uploaded\n";
	return;
    }
    if (!isin( $pkg->{'State'}, qw(Building Built Build-Attempted))) {
	print "$name: not taken for building (state is $pkg->{'State'}). ",
	"Skipping.\n";
	return;
    }
    if ($pkg->{'Builder'} ne $self->get_conf('DB_USER')) {
	print "$name: not taken by you, but by $pkg->{'Builder'}. Skipping.\n";
	return;
    }
    # strip epoch -- buildd-uploader used to go based on the filename.
    # (to remove at some point)
    my $pkgver;
    ($pkgver = $pkg->{'Version'}) =~ s/^\d+://;
    $version =~ s/^\d+://; # for command line use
    if ($pkg->{'Binary-NMU-Version'} ) {
	my $nmuver = binNMU_version($pkgver, $pkg->{'Binary-NMU-Version'});
	if (!version_eq( $nmuver, $version )) {
	    print "$name: version mismatch ($nmuver registered). ",
	    "Skipping.\n";
	    return;
	}
    } elsif (!version_eq($pkgver, $version)) {
	print "$name: version mismatch ($pkg->{'Version'} registered). ",
	"Skipping.\n";
	return;
    }

    $self->change_state( $pkg, 'Uploaded' );
    $self->log_ta( $pkg, "--uploaded" );
    $self->get('Current Database')->set_package($pkg);
    print "$name: registered as uploaded\n" if $self->get_conf('VERBOSE');
}

sub add_one_failed {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my ($state, $cat);
    my $pkg = $self->get('Current Database')->get_package($name);

    if (!defined($pkg)) {
	print "$name: not registered yet.\n";
	return;
    }
    $state = $pkg->{'State'};

    if ($state eq "Not-For-Us") {
	print "$name: not suitable for this architecture anyway. Skipping.\n";
	return;
    }
    elsif ($state eq "Failed-Removed") {
	print "$name: failed previously and doesn't need building. Skipping.\n";
	return;
    }
    elsif ($state eq "Installed") {
	print "$name: Is already installed in archive. Skipping.\n";
	return;
    }
    elsif ($pkg->{'Builder'} &&
	   (($self->get_conf('DB_USER') ne $pkg->{'Builder'}) &&
	    !($pkg->{'Builder'} =~ /^(\w+)-\w+/ && $1 eq $self->get_conf('DB_USER')))) {
	print "$name: not taken by you, but by ".
	    "$pkg->{'Builder'}. Skipping.\n";
	return;
    }
    elsif ( !$self->pkg_version_eq($pkg, $version) ) {
	print "$name: version mismatch ".
	    "$(pkg->{'Version'} ".
	    "by $pkg->{'Builder'})\n";
	return;
    }

    $cat = $self->get_conf('DB_CATEGORY');
    if (!$cat && $self->get_conf('DB_FAIL_REASON') =~ /^\[([^\]]+)\]/) {
	$cat = $1;
	$cat = category($cat);
	$cat = "" if !defined($cat);
	my $fail_reason = $self->get_conf('DB_FAIL_REASON');
	$fail_reason =~ s/^\[[^\]]+\][ \t]*\n*//;
	$self->set_conf('DB_FAIL_REASON', $fail_reason);
    }

    if ($state eq "Needs-Build") {
	print "$name: Warning: not registered for building previously, ".
	    "but processing anyway.\n";
    }
    elsif ($state eq "Uploaded") {
	print "$name: Warning: marked as uploaded previously, ".
	    "but processing anyway.\n";
    }
    elsif ($state eq "Dep-Wait") {
	print "$name: Warning: marked as waiting for dependencies, ".
	    "but processing anyway.\n";
    }
    elsif ($state eq "Failed") {
	print "$name: already registered as failed; will append new message\n"
	    if $self->get_conf('DB_FAIL_REASON');
	print "$name: already registered as failed; changing category\n"
	    if $cat;
    }

    if (($cat eq "reminder-sent" || $cat eq "nmu-offered") &&
	exists $pkg->{'Failed-Category'} &&
	$pkg->{'Failed-Category'} ne $cat) {
	(my $action = $cat) =~ s/-/ /;
	$self->set_conf('DB_FAIL_REASON',
			$self->get_conf('DB_FAIL_REASON') . "\n" .
			$self->get('Short Date') . ": $action");
    }

    $self->change_state( $pkg, 'Failed' );
    $pkg->{'Builder'} = $self->get_conf('DB_USER');
    $pkg->{'Failed'} .= "\n" if $pkg->{'Failed'};
    $pkg->{'Failed'} .= $self->get_conf('DB_FAIL_REASON');
    $pkg->{'Failed-Category'} = $cat if $cat;
    if (defined $pkg->{'PermBuildPri'}) {
	$pkg->{'BuildPri'} = $pkg->{'PermBuildPri'};
    } else {
	delete $pkg->{'BuildPri'};
    }
    $self->log_ta( $pkg, "--failed" );
    $self->get('Current Database')->set_package($pkg);
    print "$name: registered as failed\n" if $self->get_conf('VERBOSE');
}

sub add_one_notforus {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $pkg = $self->get('Current Database')->get_package($name);

    if ($pkg->{'State'} eq 'Not-For-Us') {
	# reset Not-For-Us state in case it's called twice; this is
	# the only way to get a package out of this state...
	# There is no really good state in which such packages should
	# be put :-( So use Failed for now.
	$self->change_state( $pkg, 'Failed' );
	$pkg->{'Package'} = $name;
	$pkg->{'Failed'} = "Was Not-For-Us previously";
	delete $pkg->{'Builder'};
	delete $pkg->{'Depends'};
	$self->log_ta( $pkg, "--no-build(rev)" );
	print "$name: now not unsuitable anymore\n";

	$self->send_mail(
	    $self->get_conf('DB_NOTFORUS_MAINTAINER_EMAIL'),
	    "$name moved out of Not-For-Us state",
	    "The package '$name' has been moved out of the Not-For-Us ".
	    "state by " . $self->get_conf('DB_USER') . ".\n".
	    "It should probably also be removed from ".
	    "Packages-arch-specific or\n".
	    "the action was wrong.\n")
	    if $self->get_conf('DB_NOTFORUS_MAINTAINER_EMAIL');
    }
    else {
	$self->change_state( $pkg, 'Not-For-Us' );
	$pkg->{'Package'} = $name;
	delete $pkg->{'Builder'};
	delete $pkg->{'Depends'};
	delete $pkg->{'BuildPri'};
	delete $pkg->{'Binary-NMU-Version'};
	delete $pkg->{'Binary-NMU-Changelog'};
	$self->log_ta( $pkg, "--no-build" );
	print "$name: registered as unsuitable\n" if $self->get_conf('VERBOSE');

	$self->send_mail(
	    $self->get_conf('DB_NOTFORUS_MAINTAINER_EMAIL'),
	    "$name set to Not-For-Us",
	    "The package '$name' has been set to state Not-For-Us ".
	    "by " . $self->get_conf('DB_USER') . ".\n".
	    "It should probably also be added to ".
	    "Packages-arch-specific or\n".
	    "the Not-For-Us state is wrong.\n")
	    if $self->get_conf('DB_NOTFORUS_MAINTAINER_EMAIL');
    }
    $self->get('Current Database')->set_package($pkg);
}

sub add_one_needsbuild {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $state;
    my $pkg = $self->get('Current Database')->get_package($name);

    if (!defined($pkg)) {
	print "$name: not registered; can't give back.\n";
	return;
    }
    $state = $pkg->{'State'};

    if ($state eq "Dep-Wait") {
	if ($self->get_conf('DB_OVERRIDE')) {
	    print "$name: Forcing source dependency list to be cleared\n";
	}
	else {
	    print "$name: waiting for source dependencies. Skipping\n",
	    "  (use --override to clear dependency list and ",
	    "give back anyway)\n";
	    return;
	}
    }
    elsif (!isin( $state, qw(Building Built Build-Attempted))) {
	print "$name: not taken for building (state is $state).";
	if ($self->get_conf('DB_OVERRIDE')) {
	    print "\n$name: Forcing give-back\n";
	}
	else {
	    print " Skipping.\n";
	    return;
	}
    }
    if (defined ($pkg->{'Builder'}) && $self->get_conf('DB_USER') ne $pkg->{'Builder'} &&
	!($pkg->{'Builder'} =~ /^(\w+)-\w+/ && $1 eq $self->get_conf('DB_USER'))) {
	print "$name: not taken by you, but by ".
	    "$pkg->{'Builder'}. Skipping.\n";
	return;
    }
    if (!$self->pkg_version_eq($pkg, $version)) {
	print "$name: version mismatch ($pkg->{'Version'} registered). ",
	"Skipping.\n";
	return;
    }
    $self->change_state( $pkg, 'Needs-Build' );
    delete $pkg->{'Builder'};
    delete $pkg->{'Depends'};
    $self->log_ta( $pkg, "--give-back" );
    $self->get('Current Database')->set_package($pkg);
    print "$name: given back\n" if $self->get_conf('VERBOSE');
}

sub set_one_binnmu {
    my $self = shift;
    my $name = shift;
    my $version = shift;

    my $pkg = $self->get('Current Database')->get_package($name);
    my $state;

    if (!defined($pkg)) {
	print "$name: not registered; can't register for binNMU.\n";
	return;
    }
    my $db_ver = $pkg->{'Version'};

    if (!version_eq($db_ver, $version)) {
	print "$name: version mismatch ($db_ver registered). ",
	"Skipping.\n";
	return;
    }
    $state = $pkg->{'State'};

    if (defined $pkg->{'Binary-NMU-Version'}) {
	if ($self->get_conf('DB_BIN_NMU_VERSION') == 0) {
	    $self->change_state( $pkg, 'Installed' );
	    delete $pkg->{'Builder'};
	    delete $pkg->{'Depends'};
	    delete $pkg->{'Binary-NMU-Version'};
	    delete $pkg->{'Binary-NMU-Changelog'};
	} elsif ($self->get_conf('DB_BIN_NMU_VERSION') <= $pkg->{'Binary-NMU-Version'}) {
	    print "$name: already building binNMU $pkg->{'Binary-NMU-Version'}\n";
	    return;
	} else {
	    $pkg->{'Binary-NMU-Version'} = $self->get_conf('DB_BIN_NMU_VERSION');
	    $pkg->{'Binary-NMU-Changelog'} = $self->get_conf('DB_FAIL_REASON');
	    $pkg->{'Notes'} = 'out-of-date';
	    $pkg->{'BuildPri'} = $pkg->{'PermBuildPri'}
	    if (defined $pkg->{'PermBuildPri'});
	}
	$self->log_ta( $pkg, "--binNMU" );
	$self->get('Current Database')->set_package($pkg);
	return;
    } elsif ($self->get_conf('DB_BIN_NMU_VERSION')) {
	print "${name}_$version: no scheduled binNMU to cancel.\n";
	return;
    }

    if ($state ne 'Installed') {
	print "${name}_$version: not installed; can't register for binNMU.\n";
	return;
    }

    my $fullver = binNMU_version($version,$self->get_conf('DB_BIN_NMU_VERSION'));
    if (version_lesseq($fullver, $pkg->{'Installed-Version'})) {
	print "$name: binNMU $fullver is not newer than current version $pkg->{'Installed-Version'}\n";
	return;
    }

    $self->change_state( $pkg, 'Needs-Build' );
    delete $pkg->{'Builder'};
    delete $pkg->{'Depends'};
    $pkg->{'Binary-NMU-Version'} = $self->get_conf('DB_BIN_NMU_VERSION');
    $pkg->{'Binary-NMU-Changelog'} = $self->get_conf('DB_FAIL_REASON');
    $pkg->{'Notes'} = 'out-of-date';
    $self->log_ta( $pkg, "--binNMU" );
    $self->get('Current Database')->set_package($pkg);
    print "${name}: registered for binNMU $fullver\n" if $self->get_conf('VERBOSE');
}

sub set_one_buildpri {
    my $self = shift;
    my $name = shift;
    my $version = shift;
    my $key = shift;
    my $pkg = $self->get('Current Database')->get_package($name);
    my $state;

    if (!defined($pkg)) {
	print "$name: not registered; can't set priority.\n";
	return;
    }
    $state = $pkg->{'State'};

    if ($state eq "Not-For-Us") {
	print "$name: not suitable for this architecture. Skipping.\n";
	return;
    } elsif ($state eq "Failed-Removed") {
	print "$name: failed previously and doesn't need building. Skipping.\n";
	return;
    }
    if (!$self->pkg_version_eq($pkg, $version)) {
	print "$name: version mismatch ($pkg->{'Version'} registered). ",
	"Skipping.\n";
	return;
    }
    if ( $self->get_conf('DB_BUILD_PRIORITY') == 0 ) {
	delete $pkg->{'BuildPri'}
	if $key eq 'PermBuildPri' and defined $pkg->{'BuildPri'}
	and $pkg->{'BuildPri'} == $pkg->{$key};
	delete $pkg->{$key};
    } else {
	$pkg->{'BuildPri'} = $self->get_conf('DB_BUILD_PRIORITY')
	    if $key eq 'PermBuildPri';
	$pkg->{$key} = $self->get_conf('DB_BUILD_PRIORITY');
    }
    $self->get('Current Database')->set_package($pkg);
    print "$name: set to build priority " .
	$self->get_conf('DB_BUILD_PRIORITY') . "\n" if $self->get_conf('VERBOSE');
}

sub add_one_depwait {
    my $self = shift;
    my $name = shift;
    my $version = shift;
    my $state;
    my $pkg = $self->get('Current Database')->get_package($name);

    if (!defined($pkg)) {
	print "$name: not registered yet.\n";
	return;
    }
    $state = $pkg->{'State'};

    if ($state eq "Dep-Wait") {
	print "$name: merging with previously registered dependencies\n";
    }

    if (isin( $state, qw(Needs-Build Failed))) {
	print "$name: Warning: not registered for building previously, ".
	    "but processing anyway.\n";
    }
    elsif ($state eq "Not-For-Us") {
	print "$name: not suitable for this architecture anyway. Skipping.\n";
	return;
    }
    elsif ($state eq "Failed-Removed") {
	print "$name: failed previously and doesn't need building. Skipping.\n";
	return;
    }
    elsif ($state eq "Installed") {
	print "$name: Is already installed in archive. Skipping.\n";
	return;
    }
    elsif ($state eq "Uploaded") {
	print "$name: Is already uploaded. Skipping.\n";
	return;
    }
    elsif ($pkg->{'Builder'} &&
	   $self->get_conf('DB_USER') ne $pkg->{'Builder'}) {
	print "$name: not taken by you, but by ".
	    "$pkg->{'Builder'}. Skipping.\n";
	return;
    }
    elsif ( !$self->pkg_version_eq($pkg,$version)) {
	print "$name: version mismatch ".
	    "($pkg->{'Version'} ".
	    "by $pkg->{'Builder'})\n";
	return;
    }
    elsif ($self->get_conf('DB_FAIL_REASON') =~ /^\s*$/ ||
	   !$self->parse_deplist( $self->get_conf('DB_FAIL_REASON'), 1 )) {
	print "$name: Bad dependency list\n";
	return;
    }
    $self->change_state( $pkg, 'Dep-Wait' );
    $pkg->{'Builder'} = $self->get_conf('DB_USER');
    if (defined $pkg->{'PermBuildPri'}) {
	$pkg->{'BuildPri'} = $pkg->{'PermBuildPri'};
    } else {
	delete $pkg->{'BuildPri'};
    }
    my $deplist = $self->parse_deplist( $pkg->{'Depends'}, 0 );
    my $new_deplist = $self->parse_deplist( $self->get_conf('DB_FAIL_REASON'), 0 );
    # add new dependencies, maybe overwriting old entries
    foreach (keys %$new_deplist) {
	$deplist->{$_} = $new_deplist->{$_};
    }
    $pkg->{'Depends'} = $self->build_deplist($deplist);
    $self->log_ta( $pkg, "--dep-wait" );
    $self->get('Current Database')->set_package($pkg);
    print "$name: registered as waiting for dependencies\n" if $self->get_conf('VERBOSE');
}


sub parse_sources {
    my $self = shift;
    my $full = shift;

    my %pkgs;
    my %srcver;
    my $name;

    local($/) = ""; # read in paragraph mode
    while( <> ) {
	my( $version, $arch, $section, $priority, $builddep, $buildconf, $binaries );
	s/\s*$//m;
	/^Package:\s*(\S+)$/mi and $name = $1;
	/^Version:\s*(\S+)$/mi and $version = $1;
	/^Architecture:\s*(\S+)$/mi and $arch = $1;
	/^Section:\s*(\S+)$/mi and $section = $1;
	/^Priority:\s*(\S+)$/mi and $priority = $1;
	/^Build-Depends:\s*(.*)$/mi and $builddep = $1;
	/^Build-Conflicts:\s*(.*)$/mi and $buildconf = $1;
	/^Binary:\s*(.*)$/mi and $binaries = $1;

	next if (defined $srcver{$name} and version_less( $version, $srcver{$name} ));
	$srcver{$name} = $version;
	if ($buildconf) {
	    $buildconf = join( ", ", map { "!$_" } split( /\s*,\s*/, $buildconf ));
	    if ($builddep) {
		$builddep .= "," . $buildconf;
	    } else {
		$builddep = $buildconf;
	    }
	}

	$pkgs{$name}{'dep'} = defined $builddep ? $builddep : "";
	$pkgs{$name}{'ver'} = $version;
	$pkgs{$name}{'bin'} = $binaries;
	my $pkg = $self->get('Current Database')->get_package($name);

	if (defined $pkg) {
	    my $change = 0;

	    if ($arch eq "all" && !version_less( $version, $pkg->{'Version'} )) {
		# package is now Arch: all, delete it from db
		$self->change_state( $pkg, 'deleted' );
		$self->log_ta( $pkg, "--merge-sources" );
		print "$name ($pkg->{'Version'}): deleted ".
		    "from database, because now Arch: all\n"
		    if $self->get_conf('VERBOSE');
		$self->get('Current Database')->del_package($pkg);
		next;
	    }

	    # The "Version" should always be the source version --
	    # not a possible binNMU version number.
	    $pkg->{'Version'} = $version, $change++
		if ($pkg->{'State'} eq 'Installed' and
		    !version_eq( $pkg->{'Version'}, $version));
	    # Always update priority and section, if available
	    $pkg->{'Priority'} = $priority, $change++
		if defined $priority && (!defined($pkg->{'Priority'}) ||
					 $pkg->{'Priority'} ne $priority);
	    $pkg->{'Section'} = $section, $change++
		if defined $section && (!defined($pkg->{'Section'}) ||
					$pkg->{'Section'} ne $section);
	    $self->get('Current Database')->set_package($pkg) if $change;
	}
    }
    # Now that we only have the latest source version, build the list
    # of binary packages from the Sources point of view
    foreach $name (keys %pkgs) {
	foreach my $bin (split( /\s*,\s*/, $pkgs{$name}{'bin'} ) ) {
	    $self->get('Merge Bin Src')->{$bin} = $name;
	}
    }
    # remove installed packages that no longer have source available
    # or binaries installed
    foreach $name ($self->get('Current Database')->list_packages()) {
	my $pkg = $self->get('Current Database')->get_package($name);
	if (not defined($pkgs{$name})) {
	    $self->change_state( $pkg, 'deleted' );
	    $self->log_ta( $pkg, "--merge-sources" );
	    print "$name ($pkg->{'Version'}): ".
		"deleted from database, because ".
		"not in Sources anymore\n"
		if $self->get_conf('VERBOSE');
	    $self->get('Current Database')->del_package($name);
	} else {
	    next if !isin( $pkg->{'State'}, qw(Installed) );
	    if ($full && not defined $self->get('Merge Src Version')->{$name}) {
		$self->change_state( $pkg, 'deleted' );
		$self->log_ta( $pkg, "--merge-sources" );
		print "$name ($pkg->{'Version'}): ".
		    "deleted from database, because ".
		    "binaries don't exist anymore\n"
		    if $self->get_conf('VERBOSE');
		$self->get('Current Database')->del_package($name);
	    } elsif ($full && version_less( $self->get('Merge Src Version')->{$name}, $pkg->{'Version'})) {
		print "$name ($pkg->{'Version'}): ".
		    "package is Installed but binaries are from ".
		    $self->get('Merge Src Version')->{$name}. "\n"
		    if $self->get_conf('VERBOSE');
	    }
	}
    }
    return \%pkgs;
}

# This function looks through a Packages file and sets the state of
# packages to 'Installed'
sub parse_packages {
    my $self = shift;

    my $installed;

    local($/) = ""; # read in paragraph mode
    while( <> ) {
	my( $name, $version, $depends, $source, $sourcev, $architecture, $provides, $binaryv, $binnmu );
	s/\s*$//m;
	/^Package:\s*(\S+)$/mi and $name = $1;
	/^Version:\s*(\S+)$/mi and $version = $1;
	/^Depends:\s*(.*)$/mi and $depends = $1;
	/^Source:\s*(\S+)(\s*\((\S+)\))?$/mi and ($source,$sourcev) = ($1, $3);
	/^Architecture:\s*(\S+)$/mi and $architecture = $1;
	/^Provides:\s*(.*)$/mi and $provides = $1;

	next if !$name || !$version;
	next if ($self->get_conf('ARCH') ne $architecture and $architecture ne "all");
	next if (defined ($installed->{$name}) and $installed->{$name}{'Version'} ne "" and
		 version_lesseq( $version, $installed->{$name}{'Version'} ));
	$installed->{$name}{'Version'} = $version;
	$installed->{$name}{'Depends'} = $depends;
	$installed->{$name}{'all'} = 1 if $architecture eq "all";
	undef $installed->{$name}{'Provider'};
	$installed->{$name}{'Source'} = $source ? $source : $name;

	if ($provides) {
	    foreach (split( /\s*,\s*/, $provides )) {
		if (not defined ($installed->{$_})) {
		    $installed->{$_}{'Version'} = "";
		    $installed->{$_}{'Provider'} = $name;
		}
	    }
	}
	if ( $version =~ /\+b(\d+)$/ ) {
	    $binnmu = $1;
	}
	$version = $sourcev if $sourcev;
	$binaryv = $version;
	$binaryv =~ s/\+b\d+$//;
	$installed->{$name}{'Sourcev'} = $sourcev ? $sourcev : $binaryv;
	$binaryv .= "+b$binnmu" if defined($binnmu);

	next if $architecture ne $self->get_conf('ARCH');
	$name = $source if $source;
	next if defined($self->get('Merge Src Version')->{$name}) and $self->get('Merge Src Version')->{$name} eq $version;

	$self->get('Merge Src Version')->{$name} = $version;

	my $pkg = $self->get('Current Database')->get_package($name);

	if (defined $pkg) {
	    if (isin( $pkg->{'State'}, qw(Not-For-Us)) ||
		(isin($pkg->{'State'}, qw(Installed)) &&
		 version_lesseq($binaryv, $pkg->{'Installed-Version'}))) {
		print "Skipping $name because State == $pkg->{'State'}\n"
		    if $self->get_conf('VERBOSE') >= 2;
		next;
	    }
	    if ($pkg->{'Binary-NMU-Version'} ) {
		my $nmuver = binNMU_version($pkg->{'Version'}, $pkg->{'Binary-NMU-Version'});
		if (version_less( $binaryv, $nmuver )) {
		    print "Skipping $name ($version) because have newer ".
			"version ($nmuver) in db.\n"
			if $self->get_conf('VERBOSE') >= 2;
		    next;
		}
	    } elsif (version_less($version, $pkg->{'Version'})) {
		print "Skipping $name ($version) because have newer ".
		    "version ($pkg->{'Version'}) in db.\n"
		    if $self->get_conf('VERBOSE') >= 2;
		next;
	    }

	    if (!$self->pkg_version_eq($pkg, $version) &&
		$pkg->{'State'} ne "Installed") {
		warn "Warning: $name: newer version than expected appeared ".
		    "in archive ($version vs. $pkg->{'Version'})\n";
		delete $pkg->{'Builder'};
	    }

	    if (!isin( $pkg->{'State'}, qw(Uploaded) )) {
		warn "Warning: Package $name was not in uploaded state ".
		    "before (but in '$pkg->{'State'}').\n";
		delete $pkg->{'Builder'};
		delete $pkg->{'Depends'};
	    }
	} else {
	    $pkg = {};
	    $pkg->{'Version'} = $version;
	}

	$self->change_state( $pkg, 'Installed' );
	$pkg->{'Package'} = $name;
	$pkg->{'Installed-Version'} = $binaryv;
	if (defined $pkg->{'PermBuildPri'}) {
	    $pkg->{'BuildPri'} = $pkg->{'PermBuildPri'};
	} else {
	    delete $pkg->{'BuildPri'};
	}
	$pkg->{'Version'} = $version
	    if version_less( $pkg->{'Version'}, $version);
	delete $pkg->{'Binary-NMU-Version'};
	delete $pkg->{'Binary-NMU-Changelog'};
	$self->log_ta( $pkg, "--merge-packages" );
	$self->get('Current Database')->set_package($name) = $pkg;
	print "$name ($version) is up-to-date now.\n" if $self->get_conf('VERBOSE');
    }

    $self->check_dep_wait( "--merge-packages", $installed );
    return $installed;
}

sub pretend_avail {
    my $self = shift;

    my ($package, $name, $version, $installed);

    foreach $package (@_) {
	$package =~ s,^.*/,,; # strip path
	$package =~ s/\.(dsc|diff\.gz|tar\.gz|deb)$//; # strip extension
	$package =~ s/_[\w\d]+\.changes$//; # strip extension
	if ($package =~ /^([\w\d.+-]+)_([\w\d:.+~-]+)/) {
	    ($name,$version) = ($1,$2);
	}
	else {
	    warn "$package: can't extract package name and version ".
		"(bad format)\n";
	    next;
	}
	$installed->{$name}{'Version'} = $version;
    }

    $self->check_dep_wait( "--pretend-avail", $installed );
}

sub check_dep_wait {
    my $self = shift;
    my $action = shift;
    my $installed = shift;

    # check all packages in state Dep-Wait if dependencies are all
    # available now
    my $name;
    foreach $name ($self->get('Current Database')->list_packages()) {
	my $pkg = $self->get('Current Database')->get_package($name);
	next if $pkg->{'State'} ne "Dep-Wait";
	my $deps = $pkg->{'Depends'};
	if (!$deps) {
	    print "$name: was in state Dep-Wait, but with empty ",
	    "dependencies!\n";
	    goto make_needs_build;
	}
	my $deplist = $self->parse_deplist($deps, 0);
	my $new_deplist;
	my $allok = 1;
	my @removed_deps;
	foreach (keys %$deplist) {
	    if (!exists $installed->{$_} ||
		($deplist->{$_}->{'Rel'} && $deplist->{$_}->{'Version'} &&
		 !version_compare( $installed->{$_}{'Version'},
				   $deplist->{$_}->{'Rel'},
				   $deplist->{$_}->{'Version'}))) {
		$allok = 0;
		$new_deplist->{$_} = $deplist->{$_};
	    }
	    else {
		push( @removed_deps, $_ );
	    }
	}
	if ($allok) {
	  make_needs_build:
	    $self->change_state( $pkg, 'Needs-Build' );
	    $self->log_ta( $pkg, $action );
	    delete $pkg->{'Builder'};
	    delete $pkg->{'Depends'};
	    print "$name ($pkg->{'Version'}) has all ",
	    "dependencies available now\n" if $self->get_conf('VERBOSE');
	    $self->get('New Version')->{$name}++;
	    $self->get('Current Database')->set_package($pkg);
	}
	elsif (@removed_deps) {
	    $pkg->{'Depends'} = $self->build_deplist( $new_deplist );
	    print "$name ($pkg->{'Version'}): some dependencies ",
	    "(@removed_deps) available now, but not all yet\n"
		if $self->get_conf('VERBOSE');
	    $self->get('Current Database')->set_package($pkg);
	}
    }
}

# This function accepts quinn-diff output (either from a file named on
# the command line, or on stdin) and sets the packages named there to
# state 'Needs-Build'.
sub parse_quinn_diff {
    my $self = shift;
    my $partial = shift;

    my %quinn_pkgs;
    my $dubious = "";

    while( <> ) {
	my $change = 0;
	next if !m,^([-\w\d/]*)/                        # section
		   ([-\w\d.+]+)_                        # package name
		   ([\w\d:.~+-]+)\.dsc\s*		# version
		   \[([^:]*):				# priority
		   ([^]]+)\]\s*$,x;			# rest of notes
	my($section,$name,$version,$priority,$notes) = ($1, $2, $3, $4, $5);
	$quinn_pkgs{$name}++;
	$section ||= "unknown";
	$priority ||= "unknown";
	$priority = "unknown" if $priority eq "-";
	$priority = "standard" if ($name eq "debian-installer");

	my $pkg = $self->get('Current Database')->get_package($name);

	# Always update section and priority.
	if (defined($pkg)) {

	    $pkg->{'Section'}  = $section, $change++ if not defined
		$pkg->{'Section'} or $section ne "unknown";
	    $pkg->{'Priority'} = $priority, $change++ if not defined
		$pkg->{'Priority'} or $priority ne "unknown";
	}

	if (defined($pkg) &&
	    $pkg->{'State'} =~ /^Dep-Wait/ &&
	    version_less( $pkg->{'Version'}, $version )) {
	    $self->change_state( $pkg, 'Dep-Wait' );
	    $pkg->{'Version'}  = $version;
	    delete $pkg->{'Binary-NMU-Version'};
	    delete $pkg->{'Binary-NMU-Changelog'};
	    $self->log_ta( $pkg, "--merge-quinn" );
	    $change++;
	    print "$name ($version) still waiting for dependencies.\n"
		if $self->get_conf('VERBOSE');
	}
	elsif (defined($pkg) &&
	       $pkg->{'State'} =~ /-Removed$/ &&
	       version_eq($pkg->{'Version'}, $version)) {
	    # reinstantiate a package that has been removed earlier
	    # (probably due to a quinn-diff malfunction...)
	    my $newstate = $pkg->{'State'};
	    $newstate =~ s/-Removed$//;
	    $self->change_state( $pkg, $newstate );
	    $pkg->{'Version'}  = $version;
	    $pkg->{'Notes'}    = $notes;
	    $self->log_ta( $pkg, "--merge-quinn" );
	    $change++;
	    print "$name ($version) reinstantiated to $newstate.\n"
		if $self->get_conf('VERBOSE');
	}
	elsif (defined($pkg) &&
	       $pkg->{'State'} eq "Not-For-Us" &&
	       version_less( $pkg->{'Version'}, $version )) {
	    # for Not-For-Us packages just update the version etc., but
	    # keep the state
	    $self->change_state( $pkg, "Not-For-Us" );
	    $pkg->{'Package'}  = $name;
	    $pkg->{'Version'}  = $version;
	    $pkg->{'Notes'}    = $notes;
	    delete $pkg->{'Builder'};
	    $self->log_ta( $pkg, "--merge-quinn" );
	    $change++;
	    print "$name ($version) still Not-For-Us.\n" if $self->get_conf('VERBOSE');
	}
	elsif (!defined($pkg) ||
	       $pkg->{'State'} ne "Not-For-Us" &&
	       (version_less( $pkg->{'Version'}, $version ) ||
		($pkg->{'State'} eq "Installed" && version_less($pkg->{'Installed-Version'}, $version)))) {
	    if (defined( $pkg->{'State'} ) &&
		isin($pkg->{'State'}, qw(Building Built Build-Attempted))) {
		$self->send_mail(
		    $pkg->{'Builder'},
		    "new version of $name (dist=" . $self->get_conf('DISTRIBUTION') . ")",
		    "As far as I'm informed, you're currently ".
		    "building the package $name\n".
		    "in version $pkg->{'Version'}.\n\n".
		    "Now there's a new source version $version. ".
		    "If you haven't finished\n".
		    "compiling $name yet, you can stop it to ".
		    "save some work.\n".
		    "Just to inform you...\n".
		    "(This is an automated message)\n");
		print "$name: new version ($version) while building ".
		    "$pkg->{'Version'} -- sending mail ".
		    "to builder ($pkg->{'Builder'})\n"
		    if $self->get_conf('VERBOSE');
	    }
	    $self->change_state( $pkg, 'Needs-Build' );
	    $pkg->{'Package'}  = $name;
	    $pkg->{'Version'}  = $version;
	    $pkg->{'Section'}  = $section;
	    $pkg->{'Priority'} = $priority;
	    $pkg->{'Notes'}    = $notes;
	    delete $pkg->{'Builder'};
	    delete $pkg->{'Binary-NMU-Version'};
	    delete $pkg->{'Binary-NMU-Changelog'};
	    $self->log_ta( $pkg, "--merge-quinn" );
	    $self->get('New Version')->{$name}++;
	    $change++;
	    print "$name ($version) needs rebuilding now.\n" if $self->get_conf('VERBOSE');
	}
	elsif (defined($pkg) &&
	       !version_eq( $pkg->{'Version'}, $version ) &&
	       isin( $pkg->{'State'}, qw(Installed Not-For-Us) )) {
	    print "$name: skipping because version in db ".
		"($pkg->{'Version'}) is >> than ".
		"what quinn-diff says ($version) ".
		"(state is $pkg->{'State'})\n"
		if $self->get_conf('VERBOSE');
	    $dubious .= "$pkg->{'State'}: ".
		"db ${name}_$pkg->{'Version'} >> ".
		"quinn $version\n" if !$partial;
	}
	elsif ($self->get_conf('VERBOSE') >= 2) {
	    if ($pkg->{'State'} eq "Not-For-Us") {
		print "Skipping $name because State == ".
		    "$pkg->{'State'}\n";
	    }
	    elsif (!version_less($pkg->{'Version'}, $version)) {
		print "Skipping $name because version in db ".
		    "($pkg->{'Version'}) is >= than ".
		    "what quinn-diff says ($version)\n";
	    }
	}
	$self->get('Current Database')->set_package($pkg) if $change;
    }

    if ($dubious) {
	$self->send_mail(
	    $self->get_conf('DB_MAINTAINER_EMAIL'),
	    "Dubious versions in " . $self->get_conf('DISTRIBUTION') . " " .
	    $self->get_conf('DB_BASE_NAME') . " database",
	    "The following packages have a newer version in the ".
	    "wanna-build database\n".
	    "than what quinn-diff says, and this is strange for ".
	    "their state\n".
	    "It could be caused by a lame mirror, or the version ".
	    "in the database\n".
	    "is wrong.\n\n".
	    $dubious);
    }

    # Now re-check the DB for packages in states Needs-Build, Failed,
    # or Dep-Wait and remove them if they're not listed anymore by quinn-diff.
    if ( !$partial ) {
	my $name;
	foreach $name ($self->get('Current Database')->list_packages()) {
	    my $pkg = $self->get('Current Database')->get_package($name);
	    next if defined $pkg->{'Binary-NMU-Version'};
	    next if !isin($pkg->{'State'},
			  qw(Needs-Build Building Built
			     Build-Attempted Uploaded Failed
			     Dep-Wait));
	    my $virtual_delete = $pkg->{'State'} eq 'Failed';

	    if (!$quinn_pkgs{$name}) {
		$self->change_state( $pkg, $virtual_delete ?
			      $pkg->{'State'}."-Removed" :
			      'deleted' );
		$self->log_ta( $pkg, "--merge-quinn" );
		print "$name ($pkg->{'Version'}): ".
		    ($virtual_delete ? "(virtually) " : "") . "deleted ".
		    "from database, because not in quinn-diff anymore\n"
		    if $self->get_conf('VERBOSE');
		if ($virtual_delete) {
		    $self->get('Current Database')->set_package($pkg);
		} else {
		    $self->get('Current Database')->set_package($name);
		}
	    }
	}
    }
}

# Unused?
sub send_reupload_mail {
    my $self = shift;
    my $to = shift;
    my $pkg = shift;
    my $version = shift;
    my $dist = shift;
    my $other_dist = shift;

    $self->send_mail(
	$to,
	"Please reupload ${pkg}_${'Version'} for $dist",
	"You have recently built (or are currently building)\n".
	"${pkg}_${'Version'} for $other_dist.\n".
	"This version is now also needed in the $dist distribution.\n".
	"Please reupload the files now present in the Debian archive\n".
	"(best with buildd-reupload).\n");
}

sub sort_list_func {
    my $self = shift;

    my $sortfunc = sub {
	my($letter, $x);

	foreach $letter (split( "", $self->get_conf('DB_LIST_ORDER') )) {
	  SWITCH: foreach ($letter) {
	      /P/ && do {
		  my $ap = $a->{'BuildPri'};
		  my $bp = $b->{'BuildPri'};
		  $ap = 0 if !defined($ap);
		  $bp = 0 if !defined($bp);
		  $x = $bp <=> $ap;
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /p/ && do {
		  $x = $self->get('Priority Values')->{$a->{'Priority'}} <=> $self->get('Priority Values')->{$b->{'Priority'}};
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /s/ && do {
		  $self->get('Section Values')->{$a->{'Section'}} = -125 if(!$self->get('Section Values')->{$a->{'Section'}});
		  $self->get('Section Values')->{$b->{'Section'}} = -125 if(!$self->get('Section Values')->{$b->{'Section'}});
		  $x = $self->get('Section Values')->{$a->{'Section'}} <=> $self->get('Section Values')->{$b->{'Section'}};
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /n/ && do {
		  $x = $a->{'Package'} cmp $b->{'Package'};
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /b/ && do {
		  my $ab = $a->{'Builder'};
		  my $bb = $b->{'Builder'};
		  $ab = "" if !defined($ab);
		  $bb = "" if !defined($bb);
		  $x = $ab cmp $bb;
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /c/ && do {
		  my $ax = 0;
		  my $bx = 0;
		  if (defined($a->{'Notes'})) {
		      $ax = ($a->{'Notes'} =~ /^(out-of-date|partial)/) ? 0 :
			  ($a->{'Notes'} =~ /^uncompiled/) ? 2 : 1;
		  }
		  if (defined($b->{'Notes'})) {
		      $bx = ($b->{'Notes'} =~ /^(out-of-date|partial)/) ? 0 :
			  ($b->{'Notes'} =~ /^uncompiled/) ? 2 : 1;
		      $x = $ax <=> $bx;
		  }
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /f/ && do {
		  my $ca = exists $a->{'Failed-Category'} ?
		      $a->{'Failed-Category'} : "none";
		  my $cb = exists $b->{'Failed-Category'} ?
		      $b->{'Failed-Category'} : "none";
		  $x = $self->get('Category Values')->{$ca} <=> $self->get('Category Values')->{$cb};
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /S/ && do {
		  my $pa = $self->get('Priority Values')->{$a->{'Priority'}} >
		      $self->get('Priority Values')->{'standard'};
		  my $pb = $self->get('Priority Values')->{$b->{'Priority'}} >
		      $self->get('Priority Values')->{'standard'};
		  $x = $pa <=> $pb;
		  return $x if $x != 0;
		  last SWITCH;
	      };
	      /a/ && do {
		  my $x = $self->get('Current Time') - $self->parse_date($a->{'State-Change'}) <=>
		      $self->get('Current Time') - $self->parse_date($b->{'State-Change'});
		  return $x if $x != 0;
		  last SWITCH;
	      };
	  }
	}
	return 0;
    };

    return $sortfunc;
}

sub list_packages {
    my $self = shift;
    my $state = shift;

    my( $name, $pkg, @list );
    my $cnt = 0;
    my %scnt;
    my $user = $self->get_conf('DB_USER');

    foreach $name ($self->get('Current Database')->list_packages()) {
	$pkg = $self->get('Current Database')->get_package($name);
	next if $state ne "all" && $pkg->{'State'} !~ /^\Q$state\E$/i;
	next if $user && (lc($state) ne 'needs-build' &&
			  defined($pkg->{'Builder'}) &&
			  $pkg->{'Builder'} ne $self->get_conf('DB_USER'));
	next if $self->get_conf('DB_CATEGORY') && $pkg->{'State'} eq "Failed" &&
	    $pkg->{'Failed-Category'} ne $self->get_conf('DB_CATEGORY');
	next if ($self->get_conf('DB_LIST_MIN_AGE') > 0 &&
		 ($self->get('Current Time') - $self->parse_date($pkg->{'State-Change'})) < $self->get_conf('DB_LIST_MIN_AGE'))||
		 ($self->get_conf('DB_LIST_MIN_AGE') < 0 &&
		  ($self->get('Current Time') - $self->parse_date($pkg->{'State-Change'})) > -$self->get_conf('DB_LIST_MIN_AGE'));
	push( @list, $pkg );
    }

    my $sortfunc = $self->sort_list_func();
    foreach $pkg (sort $sortfunc @list) {
	print "$pkg->{'Section'}/$pkg->{'Package'}_$pkg->{'Version'}";
	print ": $pkg->{'State'}"
	    if $state eq "all";
	print " by $pkg->{'Builder'}"
	    if $pkg->{'State'} ne "Needs-Build" && $pkg->{'Builder'};
	print " [$pkg->{'Priority'}:";
	print "$pkg->{'Notes'}"
	    if defined($pkg->{'Notes'});
	print ":PREV-FAILED"
	    if defined($pkg->{'Previous-State'}) &&
	    $pkg->{'Previous-State'} =~ /^Failed/;
	print ":bp{" . $pkg->{'BuildPri'} . "}"
	    if exists $pkg->{'BuildPri'};
	print ":binNMU{" . $pkg->{'Binary-NMU-Version'} . "}"
	    if exists $pkg->{'Binary-NMU-Version'};
	print "]\n";
	print "  Reasons for failing:\n",
	"    [Category: ",
	exists $pkg->{'Failed-Category'} ? $pkg->{'Failed-Category'} : "none",
	"]\n    ",
	join("\n    ",split("\n",$pkg->{'Failed'})), "\n"
	    if $pkg->{'State'} =~ /^Failed/;
	print "  Dependencies: $pkg->{'Depends'}\n"
	    if $pkg->{'State'} eq "Dep-Wait" &&
	    defined $pkg->{'Depends'};
	print "  Previous state was $pkg->{'Previous-State'} until ",
	"$pkg->{'State-Change'}\n"
	    if $self->get_conf('VERBOSE') && $pkg->{'Previous-State'};
	print "  Previous failing reasons:\n    ",
	join("\n    ",split("\n",$pkg->{'Old-Failed'})), "\n"
	    if $self->get_conf('VERBOSE') && $pkg->{'Old-Failed'};
	++$cnt;
	$scnt{$pkg->{'State'}}++ if $state eq "all";
    }
    if ($state eq "all") {
	foreach (sort keys %scnt) {
	    print "Total $scnt{$_} package(s) in state $_.\n";
	}
    }
    print "Total $cnt package(s)\n";
}

sub info_packages {
    my $self = shift;

    my( $name, $pkg, $key, $dist );
    my @firstkeys = qw(Package Version Builder State Section Priority
		       Installed-Version Previous-State State-Change);
    my @dists = $self->get_conf('DB_INFO_ALL_DISTS') ? keys %{$self->get_conf('DB_DISTRIBUTIONS')} : ($self->get_conf('DISTRIBUTION'));

    foreach $dist (@dists) {
	if ($dist ne $self->get_conf('DISTRIBUTION')) {
	    if (!$self->open_db($dist)) {
		warn "Cannot open database for $dist!\n";
		@dists = grep { $_ ne $dist } @dists;
	    }
	}
    }

    foreach $name (@_) {
	$name =~ s/_.*$//; # strip version
	foreach $dist (@dists) {
	    my $self->get('Current Database') = $self->get('Databases')->{$dist};
	    my $pname = "$name" . ($self->get_conf('DB_INFO_ALL_DISTS') ? "($dist)" : "");

	    $pkg = $self->get('Current Database')->get_package($name);
	    if (!defined( $pkg )) {
		print "$pname: not registered\n";
		next;
	    }

	    print "$pname:\n";
	    foreach $key (@firstkeys) {
		next if !exists $pkg->{$key};
		my $val = $pkg->{$key};
		chomp( $val );
		$val = "\n$val" if isin( $key, qw(Failed Old-Failed));
		$val =~ s/\n/\n /g;
		printf "  %-20s: %s\n", $key, $val;
	    }
	    foreach $key (sort keys %$pkg) {
		next if isin( $key, @firstkeys );
		my $val = $pkg->{$key};
		chomp( $val );
		$val = "\n$val" if isin( $key, qw(Failed Old-Failed));
		$val =~ s/\n/\n /g;
		printf "  %-20s: %s\n", $key, $val;
	    }
	}
    }
}

sub forget_packages {
    my $self = shift;

    my( $name, $pkg, $key, $data );

    foreach $name (@_) {
	$name =~ s/_.*$//; # strip version
	$pkg = $self->get('Current Database')->get_package($name);
	if (!defined( $pkg )) {
	    print "$name: not registered\n";
	    next;
	}

	$data = "";
	foreach $key (sort keys %$pkg) {
	    my $val = $pkg->{$key};
	    chomp( $val );
	    $val =~ s/\n/\n /g;
	    $data .= sprintf "  %-20s: %s\n", $key, $val;
	}
	$self->send_mail(
	    $self->get_conf('DB_MAINTAINER_EMAIL'),
	    "$name deleted from DB " . $self->get_conf('DB_BASE_NAME'),
	    "The package '$name' has been deleted from the database ".
	    "by " . $self->get_conf('DB_USER') . ".\n\n".
	    "Data registered about the deleted package:\n".
	    "$data\n")
	    if $self->get_conf('DB_MAINTAINER_EMAIL');
	$self->change_state( $pkg, 'deleted' );
	$self->log_ta( $pkg, "--forget" );
	$self->get('Current Database')->set_package($name);
	print "$name: deleted from database\n" if $self->get_conf('VERBOSE');
    }
}

sub forget_users {
    my $self = shift;

    my( $name, $ui );

    foreach $name (@_) {
	if (!$self->get('Current Database')->del_user($name)) {
	    print "$name: not registered\n";
	    next;
	}

	print "$name: deleted from database\n" if $self->get_conf('VERBOSE');
    }
}

sub create_maintlock {
    my $self = shift;

    my $lockfile = $self->db_filename("maintenance") . ".lock";
    my $try = 0;
    local( *F );

    print "Creating maintenance lock\n" if $self->get_conf('VERBOSE') >= 2;
  repeat:
    if (!sysopen( F, $lockfile, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL, 0644 )){
	if ($! == EEXIST) {
	    # lock file exists, wait
	    goto repeat if !open( F, "<$lockfile" );
	    my $line = <F>;
	    close( F );
	    if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
		warn "Bad maintenance lock file contents -- still trying\n";
	    }
	    else {
		my($pid, $usr) = ($1, $2);
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    # process doesn't exist anymore, remove stale lock
		    print "Removing stale lock file (pid $pid, user $usr)\n";
		    unlink( $lockfile );
		    goto repeat;
		}
		warn "Maintenance lock already exists by $usr -- ".
		    "please wait\n" if $try == 0;
	    }
	    if (++$try > 120) {
		die "Lock still present after 120 * 60 seconds.\n";
	    }
	    sleep 60;
	    goto repeat;
	}
	die "Can't create maintenance lock $lockfile: $!\n";
    }
    F->print(getppid(), " " . $self->get_conf('USERNAME') . "\n");
    F->close();
}

sub remove_maintlock {
    my $self = shift;

    my $lockfile = $self->db_filename("maintenance") . ".lock";

    print "Removing maintenance lock\n" if $self->get_conf('VERBOSE') >= 2;
    unlink $lockfile;
}

sub waitfor_maintlock {
    my $self = shift;

    my $lockfile = $self->db_filename("maintenance") . ".lock";
    my $try = 0;
    local( *F );

    print "Checking for maintenance lock\n" if $self->get_conf('VERBOSE') >= 2;
  repeat:
    if (open( F, "<$lockfile" )) {
	my $line = <F>;
	close( F );
	if ($line !~ /^(\d+)\s+([\w\d.-]+)$/) {
	    warn "Bad maintenance lock file contents -- still trying\n";
	}
	else {
	    my($pid, $usr) = ($1, $2);
	    if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		# process doesn't exist anymore, remove stale lock
		print "Removing stale maintenance lock (pid $pid, user $usr)\n";
		unlink( $lockfile );
		return;
	    }
	    warn "Databases locked for general maintenance by $usr -- ".
		"please wait\n" if $try == 0;
	}
	if (++$try > 120) {
	    die "Lock still present after 120 * 60 seconds.\n";
	}
	sleep 60;
	goto repeat;
    }
}

sub change_state {
    my $self = shift;
    my $pkg = shift;
    my $newstate = shift;

    my $state = $pkg->{'State'};

    return if defined($state) and $state eq $newstate;
    $pkg->{'Previous-State'} = $state if defined($state);

    $pkg->{'State-Change'} = $self->get('Current Date');

    if (defined($state) and $state eq 'Failed') {
	$pkg->{'Old-Failed'} =
	    "-"x20 . " $pkg->{'Version'} " . "-"x20 . "\n" .
	    $pkg->{'Failed'} . "\n" .
	    $pkg->{'Old-Failed'};
	delete $pkg->{'Failed'};
	delete $pkg->{'Failed-Category'};
    }

    $pkg->{'State'} = $newstate;
}

sub open_db {
    my $self = shift;
    my $dist = shift;

    my $newdb = $self->get('Databases')->{$dist};

    if (!defined($newdb)) {
	if ($self->get_conf('DB_TYPE') eq 'mldbm') {
	    $newdb = Sbuild::DB::MLDBM->new($self->get('Config'));
	} elsif ($self->get_conf('DB_TYPE') eq 'postgres') {
	    $newdb = Sbuild::DB::Postgres->new($self->get('Config'));
	} else {
	    die "Unsupported database type '" . $self->get_conf('DB_TYPE') . "'\n";
        }

	$newdb->open($self->db_filename($dist));
	$newdb->lock();

	$self->get('Databases')->{$dist} = $newdb;
    }

    return $newdb;
}

sub log_ta {
    my $self = shift;
    my $pkg = shift;
    my $action = shift;

    my $dist = $self->get_conf('DISTRIBUTION');
    my $str;
    my $prevstate;

    $prevstate = $pkg->{'Previous-State'};
    $str = "$action($dist): $pkg->{'Package'}_$pkg->{'Version'} ".
	"changed from $prevstate to $pkg->{'State'} ".
	"by " . $self->get_conf('USERNAME'). " as " . $self->get_conf('DB_USER') . ".";

    my $dbbase = $self->get_conf('DB_BASE_NAME');
    $dbbase =~ m#^([^/]+/)#;

    my $transactlog = $self->get_conf('DB_BASE_DIR') . "/$1" .
	$self->get_conf('DB_TRANSACTION_LOG');
    if (!open( LOG, ">>$transactlog" )) {
	warn "Can't open log file $transactlog: $!\n";
	return;
    }
    print LOG $self->get('Current Date') . ": $str\n";
    close( LOG );

    if (!($prevstate eq 'Failed' && $pkg->{'State'} eq 'Failed')) {
	$str .= " (with --override)"
	    if $self->get_conf('DB_OVERRIDE');
	$self->set('Mail Logs',
		   $self->get('Mail Logs') . "$str\n");
    }
}

# Unused?
sub dist_cmp {
    my $self = shift;
    my $d1 = shift;
    my $d2 = shift;

    my $dist_order = $self->get_conf('DB_DISTRIBUTIONS');

    return $dist_order->{$d1}->{'priority'} <=> $dist_order->{$d2}->{'priority'};
}

sub send_mail {
    my $self = shift;
    my $to = shift;
    my $subject = shift;
    my $text = shift;

    my $from = $self->get_conf('DB_MAINTAINER_EMAIL');
    my $domain = $self->get_conf('DB_MAIL_DOMAIN');

    if (defined($domain)) {
	$from .= "\@$domain" if $from !~ /\@/;
	$to .= '@$domain' if $to !~ /\@/;
    } else {
	$from .= "\@" . $self->get_conf('HOSTNAME') if $from !~ /\@/;
	$to .= '@' . $self->get_conf('HOSTNAME') if $to !~ /\@/;
    }

    $text =~ s/^\.$/../mg;
    local $SIG{'PIPE'} = 'IGNORE';
    open( PIPE,  "| " . $self->get_conf('MAILPROG') . " -oem $to" )
	or die "Can't open pipe to " . $self->get_conf('MAILPROG') . ": $!\n";
    chomp $text;
    print PIPE "From: $from\n";
    print PIPE "Subject: $subject\n\n";
    print PIPE "$text\n";
    close( PIPE );
}

sub db_filename {
    my $self = shift;
    my $dist = shift;

    return $self->get_conf('DB_BASE_DIR') . '/' . $self->get_conf('DB_BASE_NAME') . "-$dist";
}

# for parsing input to dep-wait
sub parse_deplist {
    my $self = shift;
    my $deps = shift;
    my $verify = shift;
    my %result;

    foreach (split( /\s*,\s*/, $deps )) {
        if ($verify) {
            # verification requires > starting prompts, no | crap
            if (!/^(\S+)\s*(\(\s*(>(?:[>=])?)\s*(\S+)\s*\))?\s*$/) {
                return 0;
            }
            next;
        }
        my @alts = split( /\s*\|\s*/, $_ );
        # Anything with an | is ignored, as it can be configured on a
        # per-buildd basis what will be installed
        next if $#alts != 0;
        $_ = shift @alts;

        if (!/^(\S+)\s*(\(\s*(>=|=|==|>|>>|<<|<=)\s*(\S+)\s*\))?\s*$/) {
            warn( "parse_deplist: bad dependency $_\n" );
            next;
        }
        my($dep, $rel, $relv) = ($1, $3, $4);
        $rel = ">>" if defined($rel) and $rel eq ">";
        $result{$dep}->{'Package'} = $dep;
        if ($rel && $relv) {
            $result{$dep}->{'Rel'} = $rel;
            $result{$dep}->{'Version'} = $relv;
        }
    }
    return 1 if $verify;
    return \%result;
}

# for parsing Build-Depends from Sources
sub parse_srcdeplist {
    my $self = shift;
    my $pkg = shift;
    my $deps = shift;
    my $arch = shift;

    my $dep;
    my @results;

    foreach $dep (split( /\s*,\s*/, $deps )) {
	my @alts = split( /\s*\|\s*/, $dep );
        # Anything with an | is ignored, as it can be configured on a
        # per-buildd basis what will be installed
        next if $#alts != 0;
	$_ = shift @alts;
        if (!/^([^\s([]+)\s*(\(\s*([<=>]+)\s*(\S+)\s*\))?(\s*\[([^]]+)\])?/) {
            warn( "parse_srcdeplist: bad dependency $_\n" );
            next;
        }
        my($dep, $rel, $relv, $archlist) = ($1, $3, $4, $6);
        if ($archlist) {
            $archlist =~ s/^\s*(.*)\s*$/$1/;
            my @archs = split( /\s+/, $archlist );
            my ($use_it, $ignore_it, $include) = (0, 0, 0);
            foreach (@archs) {
                if (/^!/) {
                    $ignore_it = 1 if substr($_, 1) eq $arch;
                } else {
                    $use_it = 1 if $_ eq $arch;
                    $include = 1;
                }
            }
            warn "Warning: inconsistent arch restriction on ",
	    "$pkg: $dep depedency\n"
		if $ignore_it && $use_it;
            next if $ignore_it || ($include && !$use_it);
        }
        my $neg = 0;
        if ($dep =~ /^!/) {
            $dep =~ s/^!\s*//;
            $neg = 1;
        }
        my $result;
        $result->{'Package'} = $dep;
        $result->{'Neg'} = $neg;
        if ($rel && $relv) {
            $result->{'Rel'} = $rel;
            $result->{'Version'} = $relv;
        }
        push @results, $result;

    }
    return \@results;
}

sub build_deplist {
    my $self = shift;
    my $list = shift;

    my($key, $result);

    foreach $key (keys %$list) {
	$result .= ", " if $result;
	$result .= $key;
	$result .= " ($list->{$key}->{'Rel'} $list->{$key}->{'Version'})"
	    if $list->{$key}->{'Rel'} && $list->{$key}->{'Version'};
    }
    return $result;
}

sub get_unsatisfied_dep {
    my $self = shift;
    my $bd  = shift;
    my $pkgs = shift;
    my $dep = shift;
    my $savedep = shift;

    my $pkgname = $dep->{'Package'};

    if (defined $pkgs->{$pkgname}{'Provider'}) {
        # provides.  leave them for buildd/sbuild.
        return "";
    }

    # check cache
    return $pkgs->{$pkgname}{'Unsatisfied'} if $savedep and defined($pkgs->{$pkgname}{'Unsatisfied'});

    # Return unsatisfied deps to a higher caller to process
    if ((!defined($pkgs->{$pkgname})) or
        (defined($dep->{'Rel'}) and !version_compare( $pkgs->{$pkgname}{'Version'}, $dep->{'Rel'}, $dep->{'Version'} ) ) ) {
        my %deplist;
        $deplist{$pkgname} = $dep;
        my $deps = $self->build_deplist(\%deplist);
        $pkgs->{$pkgname}{'Unsatisfied'} = $deps if $savedep;
        return $deps;
    }

    # set cache to "" to avoid infinite recursion
    $pkgs->{$pkgname}{'Unsatisfied'} = "" if $savedep;

    if (defined $pkgs->{$dep->{'Package'}}{'Depends'}) {
        my $deps = $self->parse_deplist( $pkgs->{$dep->{'Package'}}{'Depends'} );
        foreach (keys %$deps) {
            $dep = $$deps{$_};
            # recur on dep.
            my $ret = $self->get_unsatisfied_dep($bd,$pkgs,$dep,1);
            if ($ret ne "") {
                my $retdep = $self->parse_deplist( $ret );
                foreach (keys %$retdep) {
                    $dep = $$retdep{$_};

                    $dep->{'Rel'} = '>=' if defined($dep->{'Rel'}) and $dep->{'Rel'} =~ '^=';

                    if (defined($dep->{'Rel'}) and $dep->{'Rel'} =~ '^>' and defined ($pkgs->{$dep->{'Package'}}) and
                        version_compare($bd->{$pkgs->{$dep->{'Package'}}{'Source'}}{'ver'},'>>',$pkgs->{$dep->{'Package'}}{'Sourcev'})) {
                        if (not defined($self->get('Merge Bin Src')->{$dep->{'Package'}})) {
                            # the uninstallable package doesn't exist in the new source; look for something else that does.
                            delete $$retdep{$dep->{'Package'}};
                            foreach (sort (split( /\s*,\s*/, $bd->{$pkgs->{$dep->{'Package'}}{'Source'}}{'bin'}))) {
                                next if ($pkgs->{$_}{'all'} or not defined $pkgs->{$_}{'Version'});
                                $dep->{'Package'} = $_;
                                $dep->{'Rel'} = '>>';
                                $dep->{'Version'} = $pkgs->{$_}{'Version'};
                                $$retdep{$_} = $dep;
                                last;
                            }
                        }
                    } else {
                        # sanity check to make sure the depending binary still exists, and the depended binary exists and dep-wait on a new version of it
                        if ( defined($self->get('Merge Bin Src')->{$pkgname}) and defined($pkgs->{$dep->{'Package'}}{'Version'}) ) {
                            delete $$retdep{$dep->{'Package'}};
                            $dep->{'Package'} = $pkgname;
                            $dep->{'Rel'} = '>>';
                            $dep->{'Version'} = $pkgs->{$pkgname}{'Version'};
                            $$retdep{$pkgname} = $dep;
                        }
                        delete $$retdep{$dep->{'Package'}} if (defined ($dep->{'Rel'}) and $dep->{'Rel'} =~ '^>');
                    }
                }
                $ret = $self->build_deplist($retdep);
                $pkgs->{$pkgname}{'Unsatisfied'} = $ret if $savedep;
                return $ret;
            }
        }
    }
    return "";
}

sub auto_dep_wait {
    my $self = shift;
    my $bd = shift;
    my $pkgs = shift;
    my $key;

    my $distribution = $self->get_conf('DISTRIBUTION');

    return if (defined ($self->get_conf('DB_DISTRIBUTIONS')->{'$distribution'}) &&
	       defined ($self->get_conf('DB_DISTRIBUTIONS')->{'$distribution'}->{'noadw'}));

    # We need to walk all of needs-build, as any new upload could make
    # something in needs-build have uninstallable deps
    foreach $key ($self->get('Current Database')->list_packages()) {
	my $pkg = $self->get('Current Database')->get_package($key);
	next
	    if not defined $pkg or $pkg->{'State'} ne "Needs-Build";
	my $srcdeps = $self->parse_srcdeplist($key,$bd->{$key}{'dep'},
					      $self->get_conf('ARCH'));
        foreach my $srcdep (@$srcdeps) {
            next if $srcdep->{'Neg'} != 0; # we ignore conflicts atm
            my $rc = $self->get_unsatisfied_dep($bd,$pkgs,$srcdep,0);
            if ($rc ne "") {
                # set dep-wait
                my $deplist = $self->parse_deplist( $pkg->{'Depends'} );
                my $newdeps = $self->parse_deplist( $rc );
                my $change = 0;
                foreach (%$newdeps) {
                    my $dep = $$newdeps{$_};
                    # ensure we're not waiting on ourselves, or a package that has been removed
                    next if (not defined($self->get('Merge Bin Src')->{$dep->{'Package'}})) or ($self->get('Merge Bin Src')->{$dep->{'Package'}} eq $key);
                    if ($dep->{'Rel'} =~ '^>') {
                        $deplist->{$dep->{'Package'}} = $dep;
                        $change++;
                    }
                }
                if ($change) {
                    $pkg->{'Depends'} = $self->build_deplist($deplist);
                    $self->change_state( $pkg, 'Dep-Wait' );
                    $self->log_ta( $pkg, "--merge-all" );
                    $self->get('Current Database')->set_package($pkg);
                    print "Auto-Dep-Waiting ${key}_$pkg->{'Version'} to $pkg->{'Depends'}\n" if $self->get_conf('VERBOSE');
                }
                last;
            }
	}
    }
}

sub pkg_version_eq {
    my $self = shift;
    my $pkg = shift;
    my $version = shift;

    return 1
	if (defined $pkg->{'Binary-NMU-Version'}) and
	version_compare(binNMU_version($pkg->{'Version'},
				       $pkg->{'Binary-NMU-Version'}),'=', $version);
    return version_compare( $pkg->{'Version'}, "=", $version );
}

1;
