/* Copyright © 2005-2007  Roger Leigh <rleigh@debian.org>
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

#include <config.h>

#include "util.h"

#include <cerrno>
#include <cstring>
#include <cstdlib>

#include <unistd.h>

using namespace sbuild;

sbuild::passwd::passwd ():
  ::passwd(),
  buffer(),
  valid(false)
{
  clear();
}

sbuild::passwd::passwd (uid_t uid):
  ::passwd(),
  buffer(),
  valid(false)
{
  clear();

  query_uid(uid);
}

sbuild::passwd::passwd (const char *name):
  ::passwd(),
  buffer(),
  valid(false)
{
  clear();

  query_name(name);
}

sbuild::passwd::passwd (std::string const& name):
  ::passwd(),
  buffer(),
  valid(false)
{
  clear();

  query_name(name);
}

void
sbuild::passwd::clear ()
{
  valid = false;

  buffer.clear();

  ::passwd::pw_name = 0;
  ::passwd::pw_passwd = 0;
  ::passwd::pw_uid = 0;
  ::passwd::pw_gid = 0;
  ::passwd::pw_gecos = 0;
  ::passwd::pw_dir = 0;
  ::passwd::pw_shell = 0;
}

void
sbuild::passwd::query_uid (uid_t uid)
{
  buffer_type::size_type size = 1 << 7;
  buffer.reserve(size);
  int error;

  ::passwd *pwd_result;

  while ((error = getpwuid_r(uid, this,
			     &buffer[0], buffer.capacity(),
			     &pwd_result)))
    {
      size <<= 1;
      buffer.reserve(size);
    }

  if (pwd_result)
    valid = true;
  else
    errno = error;
}

void
sbuild::passwd::query_name (const char *name)
{
  buffer_type::size_type size = 1 << 8;
  buffer.reserve(size);
  int error;

  ::passwd *pwd_result;

  while ((error = getpwnam_r(name, this,
			     &buffer[0], buffer.capacity(),
			     &pwd_result)))
    {
      size <<= 1;
      buffer.reserve(size);
    }

  if (pwd_result)
    valid = true;
  else
    errno = error;
}

void
sbuild::passwd::query_name (std::string const& name)
{
  query_name(name.c_str());
}

bool
sbuild::passwd::operator ! () const
{
  return !valid;
}

sbuild::group::group ():
  ::group(),
  buffer(),
  valid(false)
{
  clear();
}

sbuild::group::group (gid_t gid):
  ::group(),
  buffer(),
  valid(false)
{
  clear();

  query_gid(gid);
}

sbuild::group::group (const char *name):
  ::group(),
  buffer(),
  valid(false)
{
  clear();

  query_name(name);
}

sbuild::group::group (std::string const& name):
  ::group(),
  buffer(),
  valid(false)
{
  clear();

  query_name(name);
}

void
sbuild::group::clear ()
{
  valid = false;

  buffer.clear();

  ::group::gr_name = 0;
  ::group::gr_passwd = 0;
  ::group::gr_gid = 0;
  ::group::gr_mem = 0;
}

void
sbuild::group::query_gid (gid_t gid)
{
  buffer_type::size_type size = 1 << 7;
  buffer.reserve(size);
  int error;

  ::group *grp_result;

  while ((error = getgrgid_r(gid, this,
			     &buffer[0], buffer.capacity(),
			     &grp_result)))
    {
      size <<= 1;
      buffer.reserve(size);
    }

  if (grp_result)
    valid = true;
  else
    errno = error;
}

void
sbuild::group::query_name (const char *name)
{
  buffer_type::size_type size = 1 << 8;
  buffer.reserve(size);
  int error;

  ::group *grp_result;

  while ((error = getgrnam_r(name, this,
			     &buffer[0], buffer.capacity(),
			     &grp_result)))
    {
      size <<= 1;
      buffer.reserve(size);
    }

  if (grp_result)
    valid = true;
  else
    errno = error;
}

void
sbuild::group::query_name (std::string const& name)
{
  query_name(name.c_str());
}

bool
sbuild::group::operator ! () const
{
  return !valid;
}
