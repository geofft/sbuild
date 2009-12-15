# BuildDepSatisfierBase.pm: build library for sbuild
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

package Sbuild::InternalBuildDepSatisfier;

use strict;
use warnings;
use Errno qw(:POSIX);
use POSIX ();

use Sbuild qw(isin debug version_compare);
use Sbuild::Base;
use Sbuild::BuildDepSatisfierBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::BuildDepSatisfierBase);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $builder = shift;

    my $self = $class->SUPER::new($builder);
    bless($self, $class);

    return $self;
}

sub install_deps {
    my $self = shift;
    my $builder = $self->get('Builder');

    $builder->log_subsection("Install build dependencies (internal resolver)");

    my $pkg = $builder->get('Package');
    my( @positive, @negative, @instd, @rmvd );

    my $dep = [];
    if (exists $builder->get('Dependencies')->{$pkg}) {
	$dep = $builder->get('Dependencies')->{$pkg};
    }
    debug("Source dependencies of $pkg: ", $builder->format_deps(@$dep), "\n");

  repeat:
    $builder->lock_file($builder->get('Session')->get('Install Lock'), 1);

    debug("Filtering dependencies\n");
    if (!$self->filter_dependencies($dep, \@positive, \@negative )) {
	$builder->log("Package installation not possible\n");
	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	return 0;
    }

    $builder->log("Checking for source dependency conflicts...\n");
    if (!$builder->run_apt("-s", \@instd, \@rmvd, @positive)) {
	$builder->log("Test what should be installed failed.\n");
	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	return 0;
    }
    # add negative deps as to be removed for checking srcdep conflicts
    push( @rmvd, @negative );
    my @confl;
    if (@confl = $self->check_srcdep_conflicts(\@instd, \@rmvd)) {
	$builder->log("Waiting for job(s) @confl to finish\n");

	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	$self->wait_for_srcdep_conflicts(@confl);
	goto repeat;
    }

    $self->write_srcdep_lock_file($dep);

    my $install_start_time = time;
    $builder->log("Installing positive dependencies: @positive\n");
    if (!$builder->run_apt("-y", \@instd, \@rmvd, @positive)) {
	$builder->log("Package installation failed\n");
	# try to reinstall removed packages
	$builder->log("Trying to reinstall removed packages:\n");
	debug("Reinstalling removed packages: @rmvd\n");
	my (@instd2, @rmvd2);
	$builder->log("Failed to reinstall removed packages!\n")
	    if !$builder->run_apt("-y", \@instd2, \@rmvd2, @rmvd);
	debug("Installed were: @instd2\n");
	debug("Removed were: @rmvd2\n");
	# remove additional packages
	$builder->log("Trying to uninstall newly installed packages:\n");
	$self->uninstall_debs($builder->get('Chroot Dir') ? "purge" : "remove",
			      @instd);
	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);

    $builder->log("Removing negative dependencies: @negative\n");
    if (!$self->uninstall_debs($builder->get('Chroot Dir') ? "purge" : "remove",
			       @negative)) {
	$builder->log("Removal of packages failed\n");
	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	return 0;
    }
    $self->set_removed(@negative);
    my $install_stop_time = time;
    $builder->write_stats('install-download-time',
		       $install_stop_time - $install_start_time);

    my $fail = $self->check_dependencies($dep);
    if ($fail) {
	$builder->log("After installing, the following source dependencies are ".
		   "still unsatisfied:\n$fail\n");
	$builder->unlock_file($builder->get('Session')->get('Install Lock'));
	return 0;
    }

    my $pipe = $builder->get('Session')->pipe_command(
	    { COMMAND => [$self->get_conf('DPKG'), '--set-selections'],
	      PIPE => 'out',
	      USER => 'root',
	      CHROOT => 1,
	      PRIORITY => 0,
	      DIR => '/' });

    if (!$pipe) {
	warn "Cannot open pipe: $!\n";
	return 0;
    }

    foreach my $tpkg (@instd) {
	print $pipe $tpkg . " purge\n";
    }
    close($pipe);
    if ($?) {
	$builder->log($self->get_conf('DPKG') . ' --set-selections failed\n');
    }

    $builder->unlock_file($builder->get('Session')->get('Install Lock'));

    $builder->prepare_watches($dep, @instd );
    return 1;
}

sub filter_dependencies {
    my $self = shift;
    my $dependencies = shift;
    my $pos_list = shift;
    my $neg_list = shift;
    my $builder = $self->get('Builder');

    my($dep, $d, $name, %names);

    $builder->log("Checking for already installed source dependencies...\n");

    @$pos_list = @$neg_list = ();
    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
    }
    my $status = $self->get_dpkg_status(keys %names);

    my $policy = undef;
    if ($self->get_conf('APT_POLICY')) {
	$policy = $self->get_apt_policy(keys %names);
    }

    foreach $dep (@$dependencies) {
	$name = $dep->{'Package'};
	next if !$name;

	my $stat = $status->{$name};
	if ($dep->{'Neg'}) {
	    if ($stat->{'Installed'}) {
		my ($rel, $vers) = ($dep->{'Rel'}, $dep->{'Version'});
		my $ivers = $stat->{'Version'};
		if (!$rel || version_compare( $ivers, $rel, $vers )){
		    debug("$name: neg dep, installed, not versioned or ",
				 "version relation satisfied --> remove\n");
		    $builder->log("$name: installed (negative dependency)");
		    $builder->log(" (bad version $ivers $rel $vers)")
			if $rel;
		    $builder->log("\n");
		    push( @$neg_list, $name );
		}
		else {
		    $builder->log("$name: installed (negative dependency) (but version ok $ivers $rel $vers)\n");
		}
	    }
	    else {
		debug("$name: neg dep, not installed\n");
		$builder->log("$name: already deinstalled\n");
	    }
	    next;
	}

	my $is_satisfied = 0;
	my $installable = "";
	my $upgradeable = "";
	foreach $d ($dep, @{$dep->{'Alternatives'}}) {
	    my ($name, $rel, $vers) =
		($d->{'Package'}, $d->{'Rel'}, $d->{'Version'});
	    my $stat = $status->{$name};
	    if (!$stat->{'Installed'}) {
		debug("$name: pos dep, not installed\n");
		$builder->log("$name: missing\n");

		if ($self->get_conf('APT_POLICY') &&
		    defined($policy->{$name}) &&
		    $rel) {
		    if (!version_compare($policy->{$name}->{defversion}, $rel, $vers)) {
			$builder->log("Default version of $name not sufficient, ");
			foreach my $cvers (@{$policy->{$name}->{versions}}) {
			    if (version_compare($cvers, $rel, $vers)) {
				$builder->log("using version $cvers\n");
				$installable = $name . "=" . $cvers if !$installable;
				last;
			    }
			}
			if(!$installable) {
			    $builder->log("no suitable version found. Skipping for now, maybe there are alternatives.\n");
			    next if ($self->get_conf('CHECK_DEPENDS_ALGORITHM') eq "alternatives");
			}
		    } else {
			$builder->log("Using default version " . $policy->{$name}->{defversion} . "\n");
		    }
		}
		$installable = $name if !$installable;
		next;
	    }
	    my $ivers = $stat->{'Version'};
	    if (!$rel || version_compare( $ivers, $rel, $vers )) {
		debug("$name: pos dep, installed, no versioned dep or ",
			     "version ok\n");
		$builder->log("$name: already installed ($ivers");
		$builder->log(" $rel $vers is satisfied")
		    if $rel;
		$builder->log(")\n");
		$is_satisfied = 1;
		last;
	    }
	    debug("$name: vers dep, installed $ivers ! $rel $vers\n");
	    $builder->log("$name: non-matching version installed ".
		       "($ivers ! $rel $vers)\n");
	    if ($rel =~ /^</ ||
		($rel eq '=' && version_compare($ivers, '>>', $vers))) {
		debug("$name: would be a downgrade!\n");
		$builder->log("$name: would have to downgrade!\n");
	    } elsif ($self->get_conf('APT_POLICY') &&
		     defined($policy->{$name})) {
		if (!version_compare($policy->{$name}->{defversion}, $rel, $vers)) {
		    $builder->log("Default version of $name not sufficient, ");
		    foreach my $cvers (@{$policy->{$name}->{versions}}) {
			if(version_compare($cvers, $rel, $vers)) {
			    $builder->log("using version $cvers\n");
			    $upgradeable = $name if ! $upgradeable;
			    last;
			}
		    }
		    $builder->log("no suitable alternative found. I probably should dep-wait this one.\n") if !$upgradeable;
		    return 0;
		} else {
		    $builder->log("Using default version " . $policy->{$name}->{defversion} . "\n");
		}
		$upgradeable = $name if !$upgradeable;
	    }
	}
	if (!$is_satisfied) {
	    if ($upgradeable) {
		debug("using $upgradeable for upgrade\n");
		push( @$pos_list, $upgradeable );
	    }
	    elsif ($installable) {
		debug("using $installable for install\n");
		push( @$pos_list, $installable );
	    }
	    else {
		$builder->log("This dependency could not be satisfied. Possible reasons:\n");
		$builder->log("* The package has a versioned dependency that is not yet available.\n");
		$builder->log("* The package has a versioned dependency on a package version that is\n  older than the currently-installed package. Downgrades are not implemented.\n");
		return 0;
	    }
	}
    }

    return 1;
}

sub check_dependencies {
    my $self = shift;
    my $dependencies = shift;
    my $builder = $self->get('Builder');
    my $fail = "";
    my($dep, $d, $name, %names);

    $builder->log("Checking correctness of source dependencies...\n");

    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
    }
    foreach $name (@{$builder->get('Toolchain Packages')}) {
	$names{$name} = 1;
    }
    my $status = $self->get_dpkg_status(keys %names);

    foreach $dep (@$dependencies) {
	$name = $dep->{'Package'};
	next if $name =~ /^\*/;
	my $stat = $status->{$name};
	if ($dep->{'Neg'}) {
	    if ($stat->{'Installed'}) {
		if (!$dep->{'Rel'}) {
		    $fail .= "$name(still installed) ";
		}
		elsif ($stat->{'Version'} eq '~*=PROVIDED=*=') {
		    # It's a versioned build-conflict, but we installed
		    # a package that provides the conflicted package. It's ok.
		}
		elsif (version_compare($stat->{'Version'}, $dep->{'Rel'},
				       $dep->{'Version'})) {
		    $fail .= "$name(inst $stat->{'Version'} $dep->{'Rel'} ".
			"conflicted $dep->{'Version'})\n";
		}
	    }
	}
	else {
	    my $is_satisfied = 0;
	    my $f = "";
	    foreach $d ($dep, @{$dep->{'Alternatives'}}) {
		my $name = $d->{'Package'};
		my $stat = $status->{$name};
		if (!$stat->{'Installed'}) {
		    $f =~ s/ $/\|/ if $f;
		    $f .= "$name(missing) ";
		}
		elsif ($d->{'Rel'} &&
		       !version_compare( $stat->{'Version'}, $d->{'Rel'},
					 $d->{'Version'} )) {
		    $f =~ s/ $/\|/ if $f;
		    $f .= "$name(inst $stat->{'Version'} ! $d->{'Rel'} ".
			"wanted $d->{'Version'}) ";
		}
		else {
		    $is_satisfied = 1;
		}
	    }
	    if (!$is_satisfied) {
		$fail .= $f;
	    }
	}
    }
    $fail =~ s/\s+$//;
    if (!$fail && @{$builder->get('Toolchain Packages')}) {
	my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
	my $arch = $builder->get('Arch');

	$builder->log("Kernel: $sysname $release $arch ($machine)\n");
	$builder->log("Toolchain package versions:");
	foreach $name (@{$builder->get('Toolchain Packages')}) {
	    if (defined($status->{$name}->{'Version'})) {
		$builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	    } else {
		$builder->log(' ' . $name . '_' . ' =*=NOT INSTALLED=*=');

	    }
	}
    }
    $builder->log("\n");

    $builder->log("Package versions:");
    foreach $name (sort keys %{$status}) {
	if (defined($status->{$name}->{'Version'})) {
	    $builder->log(' ' . $name . '_' . $status->{$name}->{'Version'});
	}
    }
    $builder->log("\n");

    return $fail;
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
	push @{$packages{$package}->{versions}}, "$2" if /^ (\*{3}| {3}) ([0-9a-zA-Z-.:~+]*) 0$/;
    }
    close($pipe);
    die $self->get_conf('APT_CACHE') . " exit status $?\n" if $?;

    return \%packages;
}

1;
