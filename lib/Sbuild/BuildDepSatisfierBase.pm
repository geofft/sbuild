# BuildDepSatisfier.pm: build library for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2008 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package Sbuild::BuildDepSatisfierBase;

use strict;
use warnings;
use Errno qw(:POSIX);

use Dpkg::Deps;
use Sbuild::Base;
use Sbuild qw(isin debug);

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $builder = shift;

    my $self = $class->SUPER::new($builder->get('Config'));
    bless($self, $class);

    $self->set('Builder', $builder);
    $self->set('Changes', {});
    $self->set('Dependencies', {});
    $self->set('AptDependencies', {});

    return $self;
}

sub add_dependencies {
    my $self = shift;
    my $pkg = shift;
    my $build_depends = shift;
    my $build_depends_indep = shift;
    my $build_conflicts = shift;
    my $build_conflicts_indep = shift;

    my $builder = $self->get('Builder');

    $builder->log("Build-Depends: $build_depends\n") if $build_depends;
    $builder->log("Build-Depends-Indep: $build_depends_indep\n") if $build_depends_indep;
    $builder->log("Build-Conflicts: $build_conflicts\n") if $build_conflicts;
    $builder->log("Build-Conflicts-Indep: $build_conflicts_indep\n") if $build_conflicts_indep;

    my $deps = {
	'Build Depends' => $build_depends,
	'Build Depends Indep' => $build_depends_indep,
	'Build Conflicts' => $build_conflicts,
	'Build Conflicts Indep' => $build_conflicts_indep
    };

    $self->get('AptDependencies')->{$pkg} = $deps;

    my (@l, $dep);

    $self->get('Dependencies')->{$pkg} = []
	if (!defined $self->get('Dependencies')->{$pkg});

    foreach $dep (@{$self->get('Dependencies')->{$pkg}}) {
	if ($dep->{'Override'}) {
	    $builder->log("Added override: ",
			  (map { ($_->{'Neg'} ? "!" : "") .
				     $_->{'Package'} .
				     ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"") }
			   scalar($dep), @{$dep->{'Alternatives'}}), "\n");
	    push( @l, $dep );
	}
    }

    $build_conflicts = join( ", ", map { "!$_" } split( /\s*,\s*/, $build_conflicts ));
    $build_conflicts_indep = join( ", ", map { "!$_" } split( /\s*,\s*/, $build_conflicts_indep ));

    my $mdeps = $build_depends . ", " . $build_conflicts;
    $mdeps .= ", " . $build_depends_indep . ", " . $build_conflicts_indep
	if $self->get_conf('BUILD_ARCH_ALL');
    @{$self->get('Dependencies')->{$pkg}} = @l;
    debug("Merging pkg deps: $mdeps\n");
    my $parsed_pkg_deps = $self->parse_one_srcdep($pkg, $mdeps);
    push( @{$self->get('Dependencies')->{$pkg}}, @$parsed_pkg_deps );
}

sub parse_one_srcdep {
    my $self = shift;
    my $pkg = shift;
    my $deps = shift;

    my $builder = $self->get('Builder');

    my @res;

    $deps =~ s/^\s*(.*)\s*$/$1/;
    foreach (split( /\s*,\s*/, $deps )) {
	my @l;
	my $override;
	if (/^\&/) {
	    $override = 1;
	    s/^\&\s+//;
	}
	my @alts = split( /\s*\|\s*/, $_ );
	my $neg_seen = 0;
	foreach (@alts) {
	    if (!/^([^\s([]+)\s*(\(\s*([<=>]+)\s*(\S+)\s*\))?(\s*\[([^]]+)\])?/) {
		$builder->log_warning("syntax error in dependency '$_' of $pkg\n");
		next;
	    }
	    my( $dep, $rel, $relv, $archlist ) = ($1, $3, $4, $6);
	    if ($archlist) {
		$archlist =~ s/^\s*(.*)\s*$/$1/;
		my @archs = split( /\s+/, $archlist );
		my ($use_it, $ignore_it, $include) = (0, 0, 0);
		foreach (@archs) {
		    if (/^!/) {
			$ignore_it = 1 if Dpkg::Arch::debarch_is($builder->get('Arch'), substr($_, 1));
		    }
		    else {
			$use_it = 1 if Dpkg::Arch::debarch_is($builder->get('Arch'), $_);
			$include = 1;
		    }
		}
		$builder->log_warning("inconsistent arch restriction on $pkg: $dep depedency\n")
		    if $ignore_it && $use_it;
		next if $ignore_it || ($include && !$use_it);
	    }
	    my $neg = 0;
	    if ($dep =~ /^!/) {
		$dep =~ s/^!\s*//;
		$neg = 1;
		$neg_seen = 1;
	    }
	    if ($conf::srcdep_over{$dep}) {
		if ($self->get_conf('VERBOSE')) {
		    $builder->log("Replacing source dep $dep");
		    $builder->log(" ($rel $relv)") if $relv;
		    $builder->log(" with $conf::srcdep_over{$dep}[0]");
		    $builder->log(" ($conf::srcdep_over{$dep}[1] $conf::srcdep_over{$dep}[2])")
			if $conf::srcdep_over{$dep}[1];
		    $builder->log(".\n");
		}
		$dep = $conf::srcdep_over{$dep}[0];
		$rel = $conf::srcdep_over{$dep}[1];
		$relv = $conf::srcdep_over{$dep}[2];
	    }
	    my $h = { Package => $dep, Neg => $neg };
	    if ($rel && $relv) {
		$h->{'Rel'} = $rel;
		$h->{'Version'} = $relv;
	    }
	    $h->{'Override'} = $override if $override;
	    push( @l, $h );
	}
	if (@alts > 1 && $neg_seen) {
	    $builder->log_warning("$pkg: alternatives with negative dependencies forbidden -- skipped\n");
	}
	elsif (@l) {
	    my $l = shift @l;
	    foreach (@l) {
		push( @{$l->{'Alternatives'}}, $_ );
	    }
	    push @res, $l;
	}
    }
    return \@res;
}

sub uninstall_deps {
    my $self = shift;
    my $builder = $self->get('Builder');

    my( @pkgs, @instd, @rmvd );

    $builder->lock_file($builder->get('Session')->get('Install Lock'), 1);

    @pkgs = keys %{$self->get('Changes')->{'removed'}};
    debug("Reinstalling removed packages: @pkgs\n");
    $builder->log("Failed to reinstall removed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'install', @pkgs);
    debug("Installed were: @instd\n");
    debug("Removed were: @rmvd\n");
    $self->unset_removed(@instd);
    $self->unset_installed(@rmvd);

    @pkgs = keys %{$self->get('Changes')->{'installed'}};
    debug("Removing installed packages: @pkgs\n");
    $builder->log("Failed to remove installed packages!\n")
	if !$self->run_apt("-y", \@instd, \@rmvd, 'remove', @pkgs);
    $self->unset_installed(@pkgs);

    $builder->unlock_file($builder->get('Session')->get('Install Lock'));
}

sub check_srcdep_conflicts {
    my $self = shift;
    my $to_inst = shift;
    my $to_remove = shift;
    my $builder = $self->get('Builder');
    local( *F, *DIR );
    my $mypid = $$;
    my %conflict_builds;

    if (!opendir( DIR, $builder->get('Session')->{'Srcdep Lock Dir'} )) {
	$builder->log("Cannot opendir $builder->{'Session'}->{'Srcdep Lock Dir'}: $!\n");
	return 1;
    }
    my @files = grep { !/^\.\.?$/ && !/^install\.lock/ && !/^$mypid-\d+$/ }
    readdir(DIR);
    closedir(DIR);

    my $file;
    foreach $file (@files) {
	if (!open( F, "<$builder->{'Session'}->{'Srcdep Lock Dir'}/$file" )) {
	    $builder->log("Cannot open $builder->{'Session'}->{'Srcdep Lock Dir'}/$file: $!\n");
	    next;
	}
	<F> =~ /^(\S+)\s+(\S+)\s+(\S+)/;
	my ($job, $pid, $user) = ($1, $2, $3);

	# ignore (and remove) a lock file if associated process
	# doesn't exist anymore
	if (kill( 0, $pid ) == 0 && $! == ESRCH) {
	    close( F );
	    $builder->log("Found stale srcdep lock file $file -- removing it\n");
	    $builder->log("Cannot remove: $!\n")
		if !unlink( "$builder->{'Session'}->{'Srcdep Lock Dir'}/$file" );
	    next;
	}

	debug("Reading srclock file $file by job $job user $user\n");

	while( <F> ) {
	    my ($neg, $pkg) = /^(!?)(\S+)/;
	    debug("Found ", ($neg ? "neg " : ""), "entry $pkg\n");

	    if (isin( $pkg, @$to_inst, @$to_remove )) {
		$builder->log("Source dependency conflict with build of " .
		           "$job by $user (pid $pid):\n");
		$builder->log("  $job " . ($neg ? "conflicts with" : "needs") .
		           " $pkg\n");
		$builder->log("  " . $builder->get('Package_SVersion') .
			   " wants to " .
		           (isin( $pkg, @$to_inst ) ? "update" : "remove") .
		           " $pkg\n");
		$conflict_builds{$file} = 1;
	    }
	}
	close( F );
    }

    my @conflict_builds = keys %conflict_builds;
    if (@conflict_builds) {
	debug("Srcdep conflicts with: @conflict_builds\n");
    }
    else {
	debug("No srcdep conflicts\n");
    }
    return @conflict_builds;
}

sub wait_for_srcdep_conflicts {
    my $self = shift;
    my $builder = $self->get('Builder');
    my @confl = @_;

    for(;;) {
	sleep($self->get_conf('SRCDEP_LOCK_WAIT') * 60);
	my $allgone = 1;
	for (@confl) {
	    /^(\d+)-(\d+)$/;
	    my $pid = $1;
	    if (-f "$builder->{'Session'}->{'Srcdep Lock Dir'}/$_") {
		if (kill( 0, $pid ) == 0 && $! == ESRCH) {
		    $builder->log("Ignoring stale src-dep lock $_\n");
		    unlink( "$builder->{'Session'}->{'Srcdep Lock Dir'}/$_" ) or
			$builder->log("Cannot remove $builder->{'Session'}->{'Srcdep Lock Dir'}/$_: $!\n");
		}
		else {
		    $allgone = 0;
		    last;
		}
	    }
	}
	last if $allgone;
    }
}

sub write_srcdep_lock_file {
    my $self = shift;
    my $deps = shift;
    my $builder = $self->get('Builder');
    local( *F );

    ++$builder->{'Srcdep Lock Count'};
    my $f = "$builder->{'Session'}->{'Srcdep Lock Dir'}/$$-$builder->{'Srcdep Lock Count'}";
    if (!open( F, ">$f" )) {
	$builder->log_warning("cannot create srcdep lock file $f: $!\n");
	return;
    }
    debug("Writing srcdep lock file $f:\n");

    my $user = getpwuid($<);
    print F $builder->get('Package_SVersion') . " $$ $user\n";
    debug("Job " . $builder->get('Package_SVersion') . " pid $$ user $user\n");
    foreach (@$deps) {
	my $name = $_->{'Package'};
	print F ($_->{'Neg'} ? "!" : ""), "$name\n";
	debug("  ", ($_->{'Neg'} ? "!" : ""), "$name\n");
    }
    close( F );
}

sub remove_srcdep_lock_file {
    my $self = shift;
    my $builder = $self->get('Builder');

    my $f = $builder->{'Session'}->{'Srcdep Lock Dir'} . '/' . $$ . '-' . $builder->{'Srcdep Lock Count'};
    --$builder->{'Srcdep Lock Count'};

    debug("Removing srcdep lock file $f\n");
    if (!unlink( $f )) {
	$builder->log_warning("cannot remove srcdep lock file $f: $!\n")
	    if $! != ENOENT;
    }
}

sub set_installed {
    my $self = shift;

    foreach (@_) {
	$self->get('Changes')->{'installed'}->{$_} = 1;
    }
    debug("Added to installed list: @_\n");
}

sub set_removed {
    my $self = shift;
    foreach (@_) {
	$self->get('Changes')->{'removed'}->{$_} = 1;
	if (exists $self->get('Changes')->{'installed'}->{$_}) {
	    delete $self->get('Changes')->{'installed'}->{$_};
	    $self->get('Changes')->{'auto-removed'}->{$_} = 1;
	    debug("Note: $_ was installed\n");
	}
    }
    debug("Added to removed list: @_\n");
}

sub unset_installed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'installed'}->{$_};
    }
    debug("Removed from installed list: @_\n");
}

sub unset_removed {
    my $self = shift;
    foreach (@_) {
	delete $self->get('Changes')->{'removed'}->{$_};
	if (exists $self->get('Changes')->{'auto-removed'}->{$_}) {
	    delete $self->get('Changes')->{'auto-removed'}->{$_};
	    $self->get('Changes')->{'installed'}->{$_} = 1;
	    debug("Note: revived $_ to installed list\n");
	}
    }
    debug("Removed from removed list: @_\n");
}

sub get_dpkg_status {
    my $self = shift;
    my $builder = $self->get('Builder');
    my @interest = @_;
    my %result;
    local( *STATUS );

    debug("Requesting dpkg status for packages: @interest\n");
    my $dpkg_status_file = $builder->{'Chroot Dir'} . '/var/lib/dpkg/status';
    if (!open( STATUS, '<', $dpkg_status_file)) {
	$builder->log("Can't open $dpkg_status_file: $!\n");
	return ();
    }
    local( $/ ) = "";
    while( <STATUS> ) {
	my( $pkg, $status, $version, $provides );
	/^Package:\s*(.*)\s*$/mi and $pkg = $1;
	/^Status:\s*(.*)\s*$/mi and $status = $1;
	/^Version:\s*(.*)\s*$/mi and $version = $1;
	/^Provides:\s*(.*)\s*$/mi and $provides = $1;
	if (!$pkg) {
	    $builder->log_error("parse error in $dpkg_status_file: no Package: field\n");
	    next;
	}
	if (defined($version)) {
	    debug("$pkg ($version) status: $status\n") if $self->get_conf('DEBUG') >= 2;
	} else {
	    debug("$pkg status: $status\n") if $self->get_conf('DEBUG') >= 2;
	}
	if (!$status) {
	    $builder->log_error("parse error in $dpkg_status_file: no Status: field for package $pkg\n");
	    next;
	}
	if ($status !~ /\sinstalled$/) {
	    $result{$pkg}->{'Installed'} = 0
		if !(exists($result{$pkg}) &&
		     $result{$pkg}->{'Version'} eq '~*=PROVIDED=*=');
	    next;
	}
	if (!defined $version || $version eq "") {
	    $builder->log_error("parse error in $dpkg_status_file: no Version: field for package $pkg\n");
	    next;
	}
	$result{$pkg} = { Installed => 1, Version => $version }
	    if (isin( $pkg, @interest ) || !@interest);
	if ($provides) {
	    foreach (split( /\s*,\s*/, $provides )) {
		$result{$_} = { Installed => 1, Version => '~*=PROVIDED=*=' }
		if isin( $_, @interest ) and (not exists($result{$_}) or
					      ($result{$_}->{'Installed'} == 0));
	    }
	}
    }
    close( STATUS );
    return \%result;
}

sub get_apt_policy {
    my $self = shift;
    my $builder = $self->get('Builder');
    my @interest = @_;
    my $package;
    my $ver;
    my %packages;

    my $pipe =
	$builder->get('Session')->pipe_apt_command(
	    { COMMAND => [$self->get_conf('APT_CACHE'), 'policy', @interest],
	      ENV => {'LC_ALL' => 'C'},
	      USER => $self->get_conf('USERNAME'),
	      PRIORITY => 0,
	      DIR => '/' }) || die 'Can\'t start ' . $self->get_conf('APT_CACHE') . ": $!\n";

    while(<$pipe>) {
	$package=$1 if /^([0-9a-z+.-]+):$/;
	$packages{$package}->{curversion}=$1 if /^ {2}Installed: ([0-9a-zA-Z-.:~+]*)$/;
	$packages{$package}->{defversion}=$1 if /^ {2}Candidate: ([0-9a-zA-Z-.:~+]*)$/;
	if (/^ (\*{3}| {3}) ([0-9a-zA-Z-.:~+]*) 0$/) {
	    $ver = "$2";
	    push @{$packages{$package}->{versions}}, $ver;
	}
	if (/^ {5} *(-?\d+) /) {
	    my $prio = $1;
	    if (!defined $packages{$package}->{priority}{$ver} ||
	        $packages{$package}->{priority}{$ver} < $prio) {
		$packages{$package}->{priority}{$ver} = $prio;
	    }
	}
    }
    close($pipe);
    # Resort by priority keeping current version order if priority is the same
    use sort "stable";
    foreach my $package (keys %packages) {
	my $p = $packages{$package};
	if (exists $p->{priority}) {
	    $p->{versions} = [ sort(
		{ -($p->{priority}{$a} <=> $p->{priority}{$b}) } @{$p->{versions}}
	    ) ];
	}
    }
    no sort "stable";
    die $self->get_conf('APT_CACHE') . " exit status $?\n" if $?;

    return \%packages;
}

sub dump_build_environment {
    my $self = shift;
    my $builder = $self->get('Builder');

    my $status = $self->get_dpkg_status();

    my $arch = $builder->get('Arch');
    my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
    $builder->log("Kernel: $sysname $release $arch ($machine)\n");

    $builder->log("Toolchain package versions:");
    foreach my $name (sort keys %{$status}) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    if ($name =~ m,^$regex, && defined($status->{$name}->{'Version'})) {
		$builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    }
	}
    }
    $builder->log("\n");

    $builder->log("Package versions:");
    foreach my $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $builder->log("\n");

}


sub run_apt {
    my $self = shift;
    my $mode = shift;
    my $inst_ret = shift;
    my $rem_ret = shift;
    my $action = shift;
    my @packages = @_;
    my( $msgs, $status, $pkgs, $rpkgs );

    my $builder = $self->get('Builder');

    return 1 if !@packages;

    $msgs = "";
    # redirection of stdin from /dev/null so that conffile question
    # are treated as if RETURN was pressed.
    # dpkg since 1.4.1.18 issues an error on the conffile question if
    # it reads EOF -- hardwire the new --force-confold option to avoid
    # the questions.
    my $pipe =
	$builder->get('Session')->pipe_apt_command(
	{ COMMAND => [$builder->get_conf('APT_GET'), '--purge',
		      '-o', 'DPkg::Options::=--force-confold',
		      '-q', "$mode", $action, @packages],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  PRIORITY => 0,
	  DIR => '/' });
    if (!$pipe) {
	$builder->log("Can't open pipe to apt-get: $!\n");
	return 0;
    }

    while(<$pipe>) {
	$msgs .= $_;
	$builder->log($_) if $mode ne "-s" || debug($_);
    }
    close($pipe);
    $status = $?;

    $pkgs = $rpkgs = "";
    if ($msgs =~ /NEW packages will be installed:\n((^[ 	].*\n)*)/mi) {
	($pkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$pkgs =~ s/\*//g;
    }
    if ($msgs =~ /packages will be REMOVED:\n((^[ 	].*\n)*)/mi) {
	($rpkgs = $1) =~ s/^[ 	]*((.|\n)*)\s*$/$1/m;
	$rpkgs =~ s/\*//g;
    }
    @$inst_ret = split( /\s+/, $pkgs );
    @$rem_ret = split( /\s+/, $rpkgs );

    $builder->log("apt-get failed.\n") if $status && $mode ne "-s";
    return $mode eq "-s" || $status == 0;
}

sub format_deps {
    my $self = shift;

    return join( ", ",
		 map { join( "|",
			     map { ($_->{'Neg'} ? "!" : "") .
				       $_->{'Package'} .
				       ($_->{'Rel'} ? " ($_->{'Rel'} $_->{'Version'})":"")}
			     scalar($_), @{$_->{'Alternatives'}}) } @_ );
}

1;
