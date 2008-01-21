/*
 * buildd-mail-wrapper: wrapper for buildd-mail, does queuing
 * Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 ***********************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <sys/sysinfo.h>
#include <sys/types.h>
#include <signal.h>

#ifdef DEBUG
#define DPRINTF(fmt, args...)	printf("%d: " fmt, getpid() , ## args)
#else
#define DPRINTF(fmt, args...)
#endif

int check_mailer_running (const int file_size);

int main( int argc, char *argv[] )
{
  char *home, long_filename[128], *filename, *p;
  int i = 0, fd, n, pid;
  struct stat statbuf;
  char buf[4096];
  char newname[strlen(argv[0])+1];
  DIR *dir;
  struct dirent *de;
  int dir_was_empty;

#ifdef DEBUG
  int fdx;
  fdx = open( "/dev/ttyp1", O_WRONLY );
  close(1); dup(fdx);
  close(2); dup(fdx);
#endif

  home = getenv("HOME");
  if (!home || !*home) {
    fprintf( stderr, "No HOME defined\n" );
    exit( 1 );
  }

  if (chdir( home )) {
    fprintf( stderr, "chdir(\"%s\"): %s\n", home, strerror(errno) );
    exit( 1 );
  }
  if (chdir( "mqueue" )) {
    perror( "chdir(\"mqueue\")" );
    exit( 1 );
  }

  /* Check if directory is empty now (for later) */
  if (!(dir = opendir( "." ))) {
    perror( "opendir(\".\")" );
    exit( 1 );
  }
  dir_was_empty = 1;
  while( (de = readdir(dir)) ) {
    if (de->d_name[0] == '.' &&
	(de->d_name[1] == 0 ||
	 (de->d_name[1] == '.' && de->d_name[2] == 0)))
      continue;
    dir_was_empty = 0;
    break;
  }
  closedir( dir );

  /* Find a filename that can be opened exclusively (doesn't exist
   * yet), and where also the name with the initial '.' stripped also
   * doesn't exist.
   */
  strcpy( long_filename, "mqueue/" );
  filename = long_filename + strlen(long_filename);
  sprintf( filename, ".mail.%011u.%05d", (unsigned)time(NULL), i );
  p = filename + strlen(filename) - 5;
  while( stat( filename+1, &statbuf ) == 0 ||
	 ((fd = open( filename, O_WRONLY|O_CREAT|O_EXCL, 0644 )) == -1 &&
	  errno == EEXIST) ) {
    sprintf( p, "%05d", ++i );
  }
  if (fd == -1) {
    fprintf( stderr, "Cannot open %s: %s\n", filename, strerror(errno) );
    exit( 1 );
  }

  /* Copy whole stdin to that file */
  while( (n = read( 0, buf, sizeof(buf) )) > 0 ) {
    if (write( fd, buf, n ) != n) {
      fprintf( stderr, "Write error to %s: %s\n", filename,
	       strerror(errno) );
      close( fd );
      unlink( filename );
      exit( 1 );
    }
  }
  if (n == -1) {
    fprintf( stderr, "Read error from stdin: %s\n", strerror(errno) );
    close( fd );
    unlink( filename );
    exit( 1 );
  }
  close( fd );
  DPRINTF( "written mail to %s\n", filename );

  /* Now rename to with '.' stripped. Since rename() is atomic, we need not
   * lock the mail file during writing; the complete file appears
   * "magically" at once. */
  if (rename( filename, filename+1 )) {
    fprintf( stderr, "Cannot rename %s to %s: %s\n", filename,
	     filename+1, strerror(errno) );
    unlink( filename );
    exit( 1 );
  }

  if (chdir( ".." )) {
    perror( "chdir(\"..\")" );
    unlink( filename+1 );
    exit( 1 );
  }
  strcpy( filename, filename+1 );

  if (stat( "mailer-running", &statbuf ) == 0) {
    /* buildd-mail already running, it will pick up this mail, so no need
     * to start another instance. */
    DPRINTF( "mailer-running exists, checking it's alive\n" );
    if (check_mailer_running( statbuf.st_size ) == 0)
      return 0;
  }

  /* If there's no mailer-running, but there were mails in the queue (before
   * we've written our own one :-), it's still likely that a buildd-mail is
   * already running. Most likely it's still starting up and hasn't created
   * mailer-running yet. So, in this case, wait some time and then check for
   * mailer-running again. */
  if (!dir_was_empty) {
    struct sysinfo info;
    int waittime;
    sysinfo( &info );
    waittime = (info.loads[0] >> (SI_LOAD_SHIFT-2))*6 + 20;
    DPRINTF( "dir was not empty, sleeping\nload*4=%d waittime=%d\n",
	     (waittime-20)/6, waittime );
    sleep( waittime );
    if (stat( "mailer-running", &statbuf ) == 0) {
      /* buildd-mail no running */
      DPRINTF( "Now mailer-running exists, checking it's alive\n" );
      if (check_mailer_running( statbuf.st_size ) == 0)
	return 0;
    }
    if (stat( long_filename, &statbuf ) != 0) {
      /* Our mail already disappeared, probably has been processed by
       * the buildd-mail we waited for to start up. */
      DPRINTF( "Now %s disappeared, exiting\n", filename );
      return 0;
    }
  }
	
  /* Otherwise: Start buildd-mail */

  /* set real uid to the same things as the effective one, since sendmail
   * derives the user name from the real uid. */
  if (setreuid( geteuid(), -1 )) {
    perror( "setreuid" );
  }
  /* set umask to a reasonable value */
  umask( 022 );

  /* construct the name of the file to start */
  strcpy( newname, argv[0] );
  p = strrchr( newname, '-' );
  if (!p || strcmp( p, "-wrapper" ) != 0) {
    fprintf( stderr, "No -wrapper in name\n" );
    unlink( long_filename );
    exit( 1 );
  }
  *p = 0;

  DPRINTF( "forking\n" );
  if ((pid = fork()) == -1) {
    /* error */
    perror( "fork" );
    unlink( long_filename );
    exit( 1 );
  }
  else if (pid == 0) {
    /* child */
    DPRINTF( "forked, starting %s\n", newname );
    execv( newname, argv );
    unlink( long_filename );
    perror( "execv" );
    return 1;
  }
  /* parent */
  exit( 0 );
}

int
check_mailer_running (const int file_size)
{

  int fd, pid, size_to_read, n;
  char buf[256];

  if ((fd = open( "mailer-running", O_RDONLY )) == -1) {
    fprintf( stderr, "Cannot open mailer-running file: %s\n", 
	     strerror(errno) );
    exit ( 1 );
  }

  size_to_read = (sizeof(buf) < file_size) ? sizeof(buf) : file_size;

  if ((n = read( fd, buf, size_to_read )) == -1) {
    fprintf( stderr, "Cannot read pid from mailer-running file: %s\n", 
	     strerror(errno) );
    exit ( 1 );
  }

  close( fd );

  pid = atoi ( buf );

  if (kill ( pid, 0 ) == -1 && errno == ESRCH) {
    DPRINTF( "mailer-running exists but is *NOT* a valid PID!  Removing the file.\n" );
    unlink ( "mailer-running" );
    return -1;
  }

  DPRINTF( "mailer-running exists and is a valid PID; exiting.\n" );
  return 0;
}  
