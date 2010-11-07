# ResolverBase.pm: build library for sbuild
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

package Sbuild::InternalResolver;

use strict;
use warnings;
use Errno qw(:POSIX);
use POSIX ();

use Dpkg::Deps;
use Sbuild qw(isin debug version_compare);
use Sbuild::Base;
use Sbuild::ResolverBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::ResolverBase);

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
    my $name = shift;
    my @pkgs = @_;

    my $builder = $self->get('Builder');

    $builder->log_subsection("Install $name build dependencies (internal resolver)");

    my @apt_positive;
    my @apt_negative;

    for my $pkg (@pkgs) {
	my $deps = $self->get('AptDependencies')->{$pkg};

	push(@apt_positive, $deps->{'Build Depends'})
	    if (defined($deps->{'Build Depends'}) &&
		$deps->{'Build Depends'} ne "");
	push(@apt_negative, $deps->{'Build Conflicts'})
	    if (defined($deps->{'Build Conflicts'}) &&
		$deps->{'Build Conflicts'} ne "");
	if ($self->get_conf('BUILD_ARCH_ALL')) {
	    push(@apt_positive, $deps->{'Build Depends Indep'})
		if (defined($deps->{'Build Depends Indep'}) &&
		    $deps->{'Build Depends Indep'} ne "");
	    push(@apt_negative, $deps->{'Build Conflicts Indep'})
		if (defined($deps->{'Build Conflicts Indep'}) &&
		    $deps->{'Build Conflicts Indep'} ne "");
	}
    }

    my $positive = deps_parse(join(", ", @apt_positive),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));
    my $negative = deps_parse(join(", ", @apt_negative),
			      reduce_arch => 1,
			      host_arch => $builder->get('Arch'));

    my $build_depends = $positive;
    my $build_conflicts = $negative;

    $builder->log("Build-Depends: $build_depends\n") if $build_depends;
    $builder->log("Build-Conflicts: $build_conflicts\n") if $build_conflicts;

    $build_conflicts = join( ", ", map { "!$_" } split( /\s*,\s*/, $build_conflicts ));

    my $mdeps = $build_depends . ", " . $build_conflicts;
    debug("Merging pkg deps: $mdeps\n");
    my @dependencies = @{$self->parse_one_srcdep($mdeps)};

    my( @positive, @negative, @instd, @rmvd );

    debug("Dependencies: ", $self->format_deps(@dependencies), "\n");

  repeat:
    debug("Filtering dependencies\n");
    if (!$self->filter_dependencies(\@dependencies, \@positive, \@negative )) {
	$builder->log("Package installation not possible\n");
	return 0;
    }

    if ($self->get_conf('RESOLVE_VIRTUAL')) {
	debug("Finding virtual packages\n");
	if (!$self->virtual_dependencies(\@positive)) {
	    $builder->log("Package installation not possible\n");
	    return 0;
	}
    }

    $builder->log("Checking for dependency conflicts...\n");
    if (!$self->run_apt("-s", \@instd, \@rmvd, 'install', @positive)) {
	$builder->log("Test what should be installed failed.\n");
	return 0;
    }

    # add negative deps as to be removed for checking srcdep conflicts
    push( @rmvd, @negative );


    my $install_start_time = time;
    $builder->log("Installing positive dependencies: @positive\n");
    if (!$self->run_apt("-y", \@instd, \@rmvd, 'install', @positive)) {
	$builder->log("Package installation failed\n");
	if (defined ($builder->get('Session')->get('Session Purged')) &&
        $builder->get('Session')->get('Session Purged') == 1) {
	    $builder->log("Not removing build depends: cloned chroot in use\n");
	} else {
	    $self->set_installed(@instd);
	    $self->set_removed(@rmvd);
	    $self->uninstall_deps();
	}
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);

    $builder->log("Removing negative dependencies: @negative\n");
    if (!$self->run_apt("-y", \@instd, \@rmvd, 'remove', @negative)) {
	$builder->log("Removal of packages failed\n");
	return 0;
    }
    $self->set_installed(@instd);
    $self->set_removed(@rmvd);
    my $install_stop_time = time;
    $builder->write_stats('install-download-time',
		       $install_stop_time - $install_start_time);

    my $fail = $self->check_dependencies(\@dependencies);
    if ($fail) {
	$builder->log("After installing, the following dependencies are ".
		   "still unsatisfied:\n$fail\n");
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

    $builder->prepare_watches(\@dependencies, @instd );
    return 1;
}

sub parse_one_srcdep {
    my $self = shift;
    my $deps = shift;

    my $builder = $self->get('Builder');

    my @res;

    $deps =~ s/^\s*(.*)\s*$/$1/;
    foreach (split( /\s*,\s*/, $deps )) {
	my @l;
	my @alts = split( /\s*\|\s*/, $_ );
	my $neg_seen = 0;
	foreach (@alts) {
	    if (!/^([^\s([]+)\s*(\(\s*([<=>]+)\s*(\S+)\s*\))?(\s*\[([^]]+)\])?/) {
		$builder->log_warning("syntax error in dependency '$_'\n");
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
		$builder->log_warning("inconsistent arch restriction: $dep depedency\n")
		    if $ignore_it && $use_it;
		next if $ignore_it || ($include && !$use_it);
	    }
	    my $neg = 0;
	    if ($dep =~ /^!/) {
		$dep =~ s/^!\s*//;
		$neg = 1;
		$neg_seen = 1;
	    }
	    my $h = { Package => $dep, Neg => $neg };
	    if ($rel && $relv) {
		$h->{'Rel'} = $rel;
		$h->{'Version'} = $relv;
	    }
	    push( @l, $h );
	}
	if (@alts > 1 && $neg_seen) {
	    $builder->log_warning("alternatives with negative dependencies forbidden -- skipped\n");
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

sub filter_dependencies {
    my $self = shift;
    my $dependencies = shift;
    my $pos_list = shift;
    my $neg_list = shift;
    my $builder = $self->get('Builder');

    my($dep, $d, $name, %names);

    $builder->log("Checking for already installed dependencies...\n");

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
		    $upgradeable = $name if !$upgradeable;
		    last;
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

sub virtual_dependencies {
    my $self = shift;
    my $pos_list = shift;

    my $builder = $self->get('Builder');

    # The first returned package only is used.
    foreach my $pkg (@$pos_list) {
	my @virtuals = $self->get_virtual($pkg);
	return 0
	    if (scalar(@virtuals) == 0);
	$pkg = $virtuals[0];
    }

    return 1;
}

sub check_dependencies {
    my $self = shift;
    my $dependencies = shift;
    my $builder = $self->get('Builder');
    my $fail = "";
    my($dep, $d, $name, %names);

    $builder->log("Checking correctness of dependencies...\n");

    foreach $d (@$dependencies) {
	my $name = $d->{'Package'};
	$names{$name} = 1 if $name !~ /^\*/;
	foreach (@{$d->{'Alternatives'}}) {
	    my $name = $_->{'Package'};
	    $names{$name} = 1 if $name !~ /^\*/;
	}
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

    return $fail;
}

# Return a list of packages which provide a package.
# Note: will return both concrete and virtual packages.
sub get_virtual {
    my $self = shift;
    my $pkg = shift;

    my $builder = $self->get('Builder');

    my $pipe = $builder->get('Session')->pipe_apt_command(
	{ COMMAND => [$self->get_conf('APT_CACHE'),
		      '-q', '--names-only', 'search', "^$pkg\$"],
	  USER => $self->get_conf('USERNAME'),
	  PRIORITY => 0,
	  DIR => '/'});
    if (!$pipe) {
	$self->log("Can't open pipe to $conf::apt_cache: $!\n");
	return ();
    }

    my @virtuals;

    while( <$pipe> ) {
	my $virtual = $1 if /^(\S+)\s+\S+.*$/mi;
	push(@virtuals, $virtual);
    }
    close($pipe);

    if ($?) {
	$self->log($self->get_conf('APT_CACHE') . " exit status $?: $!\n");
	return ();
    }

    return sort(@virtuals);
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

1;
