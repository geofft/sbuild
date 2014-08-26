#
# Options.pm: options parser for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
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

package Sbuild::Options;

use strict;
use warnings;

use Sbuild::OptionsBase;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::OptionsBase);

    @EXPORT = qw();
}

sub set_options {
    my $self = shift;

    $self->add_options("arch=s" => sub {
			   $self->set_conf('HOST_ARCH', $_[1]);
			   $self->set_conf('BUILD_ARCH', $_[1]);
		       },
		       "build=s" => sub {
			   $self->set_conf('BUILD_ARCH', $_[1]);
		       },
		       "host=s" => sub {
			   $self->set_conf('HOST_ARCH', $_[1]);
		       },
		       "A|arch-all" => sub {
			   $self->set_conf('BUILD_ARCH_ALL', 1);
		       },
		       "no-arch-all" => sub {
			   $self->set_conf('BUILD_ARCH_ALL', 0);
		       },
		       "add-depends=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS')}, $_[1]);
		       },
		       "add-conflicts=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS')}, $_[1]);
		       },
		       "add-depends-arch=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS_ARCH')}, $_[1]);
		       },
		       "add-conflicts-arch=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS_ARCH')}, $_[1]);
		       },
		       "add-depends-indep=s" => sub {
			   push(@{$self->get_conf('MANUAL_DEPENDS_INDEP')}, $_[1]);
		       },
		       "add-conflicts-indep=s" => sub {
			   push(@{$self->get_conf('MANUAL_CONFLICTS_INDEP')}, $_[1]);
		       },
		       "b|batch" => sub {
			   $self->set_conf('BATCH_MODE', 1);
		       },
		       "make-binNMU=s" => sub {
			   $self->set_conf('BIN_NMU', $_[1]);
			   $self->set_conf('BIN_NMU_VERSION', 1)
			       if (!defined $self->get_conf('BIN_NMU_VERSION'));
		       },
		       "binNMU=i" => sub {
			   $self->set_conf('BIN_NMU_VERSION', $_[1]);
		       },
		       "append-to-version=s" => sub {
			   $self->set_conf('APPEND_TO_VERSION', $_[1]);
		       },
		       "c|chroot=s" => sub {
			   $self->set_conf('CHROOT', $_[1]);
		       },
		       "apt-clean" => sub {
			   $self->set_conf('APT_CLEAN', 1);
		       },
		       "apt-update" => sub {
			   $self->set_conf('APT_UPDATE', 1);
		       },
		       "apt-upgrade" => sub {
			   $self->set_conf('APT_UPGRADE', 1);
		       },
		       "apt-distupgrade" => sub {
			   $self->set_conf('APT_DISTUPGRADE', 1);
		       },
		       "no-apt-clean" => sub {
			   $self->set_conf('APT_CLEAN', 0);
		       },
		       "no-apt-update" => sub {
			   $self->set_conf('APT_UPDATE', 0);
		       },
		       "no-apt-upgrade" => sub {
			   $self->set_conf('APT_UPGRADE', 0);
		       },
		       "no-apt-distupgrade" => sub {
			   $self->set_conf('APT_DISTUPGRADE', 0);
		       },
		       "d|dist=s" => sub {
			   $self->set_conf('DISTRIBUTION', $_[1]);
			   $self->set_conf('DISTRIBUTION', "oldstable")
			       if $self->get_conf('DISTRIBUTION') eq "o";
			   $self->set_conf('DISTRIBUTION', "stable")
			       if $self->get_conf('DISTRIBUTION') eq "s";
			   $self->set_conf('DISTRIBUTION', "testing")
			       if $self->get_conf('DISTRIBUTION') eq "t";
			   $self->set_conf('DISTRIBUTION', "unstable")
			       if $self->get_conf('DISTRIBUTION') eq "u";
			   $self->set_conf('DISTRIBUTION', "experimental")
			       if $self->get_conf('DISTRIBUTION') eq "e";
			   $self->set_conf('OVERRIDE_DISTRIBUTION', 1);
		       },
		       "force-orig-source" => sub {
			   $self->set_conf('FORCE_ORIG_SOURCE', 1);
		       },
		       "m|maintainer=s" => sub {
			   $self->set_conf('MAINTAINER_NAME', $_[1]);
		       },
		       "k|keyid=s" => sub {
			   $self->set_conf('KEY_ID', $_[1]);
		       },
		       "e|uploader=s" => sub {
			   $self->set_conf('UPLOADER_NAME', $_[1]);
		       },
		       "debbuildopts=s" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "debbuildopt=s" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				$_[1]);
		       },
		       "j|jobs=i" => sub {
			   push(@{$self->get_conf('DPKG_BUILDPACKAGE_USER_OPTIONS')},
				'-j'.$_[1])
		       },
		       "dpkg-source-opts=s" => sub {
			   push(@{$self->get_conf('DPKG_SOURCE_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "dpkg-source-opt=s" => sub {
			   push(@{$self->get_conf('DPKG_SOURCE_OPTIONS')},
				$_[1]);
		       },
		       "mail-log-to=s" => sub {
			   $self->set_conf('MAILTO', $_[1]);
			   $self->set_conf('MAILTO_FORCED_BY_CLI', "yes");
		       },
		       "n|nolog" => sub {
			   $self->set_conf('NOLOG', 1);
		       },
		       "p|purge=s" => sub {
			   $self->set_conf('PURGE_BUILD_DEPS', $_[1]);
			   $self->set_conf('PURGE_BUILD_DIRECTORY', $_[1]);
			   $self->set_conf('PURGE_SESSION', $_[1]);
		       },
		       "purge-build=s" => sub {
			   $self->set_conf('PURGE_BUILD_DIRECTORY', $_[1]);
		       },
		       "purge-deps=s" => sub {
			   $self->set_conf('PURGE_BUILD_DEPS', $_[1]);
		       },
		       "purge-session=s" => sub {
			   $self->set_conf('PURGE_SESSION', $_[1]);
		       },
		       "s|source" => sub {
			   $self->set_conf('BUILD_SOURCE', 1);
		       },
		       "no-source" => sub {
			   $self->set_conf('BUILD_SOURCE', 0);
		       },
		       "archive=s" => sub {
			   $self->set_conf('ARCHIVE', $_[1]);
		       },
		       "stats-dir=s" => sub {
			   $self->set_conf('STATS_DIR', $_[1]);
		       },
		       "setup-hook=s" => sub {
			my @command = split(/\s+/, $_[1]);
			push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
			\@command);
			   $self->set_conf('CHROOT_SETUP_SCRIPT', $_[1]);
		       },
		       "use-snapshot" => sub {
			   my $newldpath = '/usr/lib/gcc-snapshot/lib';
			   my $ldpath = $self->get_conf('LD_LIBRARY_PATH');
			   if (defined($ldpath) && $ldpath ne '') {
			       $newldpath .= ':' . $ldpath;
			   }

			   $self->set_conf('GCC_SNAPSHOT', 1);
			   $self->set_conf('LD_LIBRARY_PATH', $newldpath);
			   $self->set_conf('PATH',
					   '/usr/lib/gcc-snapshot/bin' .
					   $self->get_conf('PATH') ne '' ? ':' . $self->get_conf('PATH') : '');
		       },
		       "build-dep-resolver=s" => sub {
			   $self->set_conf('BUILD_DEP_RESOLVER', $_[1]);
		       },
		       "resolve-alternatives" => sub {
			   $self->set_conf('RESOLVE_ALTERNATIVES', 1);
		       },
		       "no-resolve-alternatives" => sub {
			   $self->set_conf('RESOLVE_ALTERNATIVES', 0);
		       },
			"run-lintian" => sub {
			    $self->set_conf('RUN_LINTIAN', 1);
		       },
		       "no-run-lintian" => sub {
			    $self->set_conf('RUN_LINTIAN', 0);
		       },
		       "lintian-opts=s" => sub {
			   push(@{$self->get_conf('LINTIAN_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "lintian-opt=s" => sub {
			   push(@{$self->get_conf('LINTIAN_OPTIONS')},
				$_[1]);
		       },
		       "run-piuparts" => sub {
			    $self->set_conf('RUN_PIUPARTS', 1);
		       },
		       "no-run-piuparts" => sub {
			    $self->set_conf('RUN_PIUPARTS', 0);
		       },
		       "piuparts-opts=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_OPTIONS')},
				split(/\s+/, $_[1]));
		       },
		       "piuparts-opt=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_OPTIONS')},
				$_[1]);
		       },
		       "piuparts-root-args=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_ROOT_ARGS')},
				split(/\s+/, $_[1]));
		       },
		       "piuparts-root-arg=s" => sub {
			   push(@{$self->get_conf('PIUPARTS_ROOT_ARGS')},
				$_[1]);
		       },
			"pre-build-commands=s" => sub {
			   my @command = split(/\s+/, $_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"pre-build-commands"}},
				\@command);
		       },
			"chroot-setup-commands=s" => sub {
			   my @command = split(/\s+/, $_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-setup-commands"}},
				\@command);
		       },
			"chroot-cleanup-commands=s" => sub {
			   my @command = split(/\s+/, $_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"chroot-cleanup-commands"}},
				\@command);
		       },
			"post-build-commands=s" => sub {
			   my @command = split(/\s+/, $_[1]);
			   push(@{${$self->get_conf('EXTERNAL_COMMANDS')}{"post-build-commands"}},
				\@command);
		       },
			"log-external-command-output" => sub {
			    $self->set_conf('LOG_EXTERNAL_COMMAND_OUTPUT', 1);
		       },
			"log-external-command-error" => sub {
			    $self->set_conf('LOG_EXTERNAL_COMMAND_ERROR', 1);
		       },
			"extra-package=s" => sub {
			   push(@{$self->get_conf('EXTRA_PACKAGES')}, $_[1]);
		       },
	);
}

1;
