/* Copyright © 2005-2011  Roger Leigh <rleigh@debian.org>
 *
 * sbuild is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * sbuild is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 *********************************************************************/

#include <iostream>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <cstdlib>

#include "util.h"

using namespace sbuild;
/**
 * Check group membership.
 *
 * @param group the group to check for.
 * @returns true if the user is a member of group, otherwise false.
 */
bool
is_group_member (sbuild::group const& group)
{
  errno = 0;

  bool group_member = false;
  if (group.gr_gid == getgid())
    {
      group_member = true;
    }
  else
    {
      int supp_group_count = getgroups(0, 0);
      if (supp_group_count < 0)
	{
	  std::cerr << "Failed to get supplementary group count" << std::endl;
	  exit (1);
	}
      if (supp_group_count > 0)
	{
	  gid_t *supp_groups = new gid_t[supp_group_count];
	  assert (supp_groups);
	  if (getgroups(supp_group_count, supp_groups) < 1)
	    {
	      // Free supp_groups before throwing to avoid leak.
	      delete[] supp_groups;
	      std::cerr << "Failed to get supplementary groups: "
			<< strerror(errno) << std::endl;
	      exit(1);
	    }

	  for (int i = 0; i < supp_group_count; ++i)
	    {
	      if (group.gr_gid == supp_groups[i])
		group_member = true;
	    }
	  delete[] supp_groups;
	}
    }

  return group_member;
}

const char *sbuild_user = "sbuild";
const char *sbuild_group = "sbuild";

int
main (int argc, char *argv[])
{
  bool in_group = false;

  sbuild::group grp(sbuild_group);
  if (!grp)
    {
      if (errno == 0)
	{
	  std::cerr << "Group '" << sbuild_group << "' not found" << std::endl;
	}
      else
	{
	  std::cerr << "Group '" << sbuild_group << "' not found: "
		    << strerror(errno) << std::endl;
	}
      exit(1);
    }

  sbuild::passwd current_user(getuid());
  if (!current_user)
    {
      if (errno == 0)
	{
	  std::cerr << "User '" << getuid() << "' not found" << std::endl;
	}
      else
	{
	  std::cerr << "User '" << getuid() << "' not found: "
		    << strerror(errno) << std::endl;
	}
      exit(1);
    }

  sbuild::passwd new_user(sbuild_user);
  if (!new_user)
    {
      if (errno == 0)
	{
	  std::cerr << "User '" << sbuild_user << "' not found" << std::endl;
	}
      else
	{
	  std::cerr << "User '" << sbuild_user << "' not found: "
		    << strerror(errno) << std::endl;
	}
      exit(1);
    }

  sbuild::group new_group(new_user.pw_gid);
  if (!new_group)
    {
      if (errno == 0)
	{
	  std::cerr << "Group '" << new_user.pw_gid << "' not found" << std::endl;
	}
      else
	{
	  std::cerr << "Group '" << new_user.pw_gid << "' not found: "
		    << strerror(errno) << std::endl;
	}
      exit(1);
    }

  // Check primary group
  if (current_user.pw_gid == grp.gr_gid)
    in_group = true;

  // Check supplementary groups
  if (is_group_member(grp))
    in_group = true;

  // Root is allowed to skip the permissions checks, i.e. not be
  // required to be in the sbuild group.
  if (current_user.pw_uid != 0 && !in_group) {
      std::cerr << "Permission denied: not a member of group sbuild"  << std::endl;
      exit(1);
  }

  // Set primary group
  if (setgid (new_user.pw_gid))
    {
      std::cerr << "Failed to set group '" << new_group.gr_name << "': "
		<< strerror(errno) << std::endl;
      exit(1);
    }

  // Set supplementary groups
  if (initgroups (new_user.pw_name, new_user.pw_gid))
    {
      std::cerr << "Failed to set supplementary groups: "
		<< strerror(errno) << std::endl;
      exit(1);
    }

  // Set user
  if (setuid (new_user.pw_uid))
    {
      std::cerr << "Failed to set user '" << new_user.pw_name << "': "
		<< strerror(errno) << std::endl;
      exit(1);
    }

  // Check we're not still root
  if (!setuid (0))
    {
      std::cerr << "Failed to drop root permissions" << std::endl;
      exit(1);
    }

  // exec schroot under new identity
  execvp("schroot", argv);
  std::cerr << "Failed to exec 'schroot'" << std::endl;
  exit(1);
}
