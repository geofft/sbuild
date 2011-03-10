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

#ifndef SBUILD_UTIL_H
#define SBUILD_UTIL_H

#include <string>
#include <vector>

#include <sys/types.h>
#include <pwd.h>
#include <grp.h>

namespace sbuild
{

  /**
   * System passwd database entry
   */
  class passwd : public ::passwd
  {
  public:
    /// A buffer for reentrant passwd functions.
    typedef std::vector<char> buffer_type;

    /// The contructor.
    passwd ();

    /**
     * The constructor.
     *
     * @param uid the UID to search for.
     */
    passwd (uid_t uid);

    /**
     * The constructor.
     *
     * @param name the user name to search for.
     */
    passwd (const char *name);

    /**
     * The constructor.
     *
     * @param name the user name to search for.
     */
    passwd (std::string const& name);

    /**
     * Clear search result.  The query result is undefined following
     * this operation.
     */
    void
    clear ();

    /**
     * Query using a UID.
     *
     * @param uid the UID to search for.
     */
    void
    query_uid (uid_t uid);

    /**
     * Query using a name.
     *
     * @param name the user name to search for.
     */
    void
    query_name (const char *name);

    /**
     * Query using a name.
     *
     * @param name the user name to search for.
     */
    void
    query_name (std::string const& name);

    /**
     * Check if the query result is valid.
     */
    bool
    operator ! () const;

  private:
    /// Query result buffer.
    buffer_type buffer;
    /// Object validity.
    bool        valid;
  };

  /**
   * System group database entry
   */
  class group : public ::group
  {
  public:
    /// A buffer for reentrant group functions.
    typedef std::vector<char> buffer_type;

    /// The constructor.
    group ();

    /**
     * The constructor.
     *
     * @param gid the GID to search for.
     */
    group (gid_t gid);

    /**
     * The constructor.
     *
     * @param name the group name to search for.
     */
    group (const char *name);

    /**
     * The constructor.
     *
     * @param name the group name to search for.
     */
    group (std::string const& name);

    /**
     * Clear search result.  The query result is undefined following
     * this operation.
     */
    void
    clear ();

    /**
     * Query using a GID.
     *
     * @param gid the GID to search for.
     */
    void
    query_gid (gid_t gid);

    /**
     * Query using a name.
     *
     * @param name the group name to search for.
     */
    void
    query_name (const char *name);

    /**
     * Query using a name.
     *
     * @param name the group name to search for.
     */
    void
    query_name (std::string const& name);

    /**
     * Check if the query result is valid.
     */
    bool
    operator ! () const;

  private:
    /// Query result buffer.
    buffer_type buffer;
    /// Object validity.
    bool        valid;
  };

}

#endif /* SBUILD_UTIL_H */

/*
 * Local Variables:
 * mode:C++
 * End:
 */
