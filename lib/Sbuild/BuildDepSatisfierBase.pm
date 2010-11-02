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

    return $self;
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
	if !$self->uninstall_debs("purge", @pkgs);
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

sub uninstall_debs {
    my $self = shift;
    my $mode = shift;
    my $builder = $self->get('Builder');
    my $status;

    return 1 if !@_;
    debug("Uninstalling packages: @_\n");

  repeat:
    my $output;
    my $remove_start_time = time;

    my $pipe = $builder->get('Session')->pipe_command(
	{ COMMAND => [$self->get_conf('DPKG'), '--force-depends', "--$mode", @_],
	  ENV => {'DEBIAN_FRONTEND' => 'noninteractive'},
	  USER => 'root',
	  CHROOT => 1,
	  PRIORITY => 0,
	  DIR => '/' });

    if (!$pipe) {
	$builder->log("Can't open pipe to dpkg: $!\n");
	return 0;
    }

    while (<$pipe>) {
	$output .= $_;
	$builder->log($_);
    }
    close($pipe);
    $status = $?;

    if (defined($output) && $output =~ /status database area is locked/mi) {
	$builder->log("Another dpkg is running -- retrying later\n");
	$output = "";
	sleep( 2*60 );
	goto repeat;
    }
    my $remove_end_time = time;
    $builder->write_stats('remove-time',
		       $remove_end_time - $remove_start_time);
    $builder->log("dpkg run to remove packages (@_) failed!\n") if $?;
    return $status == 0;
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

    my ($exp_essential, $exp_pkgdeps, $filt_essential, $filt_pkgdeps);
    $exp_essential = $builder->expand_dependencies($builder->get('Dependencies')->{'ESSENTIAL'});
    debug("Dependency-expanded build essential packages:\n",
	  $self->format_deps(@$exp_essential), "\n");

    my @toolchain;
    foreach my $tpkg (@$exp_essential) {
        foreach my $regex (@{$self->get_conf('TOOLCHAIN_REGEX')}) {
	    push @toolchain,$tpkg->{'Package'}
	        if $tpkg->{'Package'} =~ m,^$regex,;
	}
    }

    if (@toolchain) {
	my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
	my $arch = $builder->get('Arch');

	$builder->log("Kernel: $sysname $release $arch ($machine)\n");
	$builder->log("Toolchain package versions:");
	foreach my $name (@toolchain) {
	    if (defined($status->{$name}->{'Version'})) {
		$builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    } else {
		$builder->log(' ' . $name . '_' . ' =*=NOT INSTALLED=*=');
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
