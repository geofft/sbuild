#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>

int main( int argc, char *argv[] )
{
	char *home, filename[128], *p;
	int fd, n, pid;
	char buf[4096];
	char newname[strlen(argv[0])+1];

	home = getenv("HOME");
	if (!home || !*home) {
		fprintf( stderr, "No HOME defined\n" );
		exit( 1 );
	}
	
	if (chdir( home )) {
		fprintf( stderr, "chdir(\"%s\"): %s\n", home, strerror(errno) );
		exit( 1 );
	}

	sprintf( filename, "mail.%05d", getpid() );
	if ((fd = open( filename, O_WRONLY|O_CREAT|O_EXCL, 0644 )) == -1) {
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

	/* Start rbuilder */

	/* set real uid to the same things as the effective one, since sendmail
	 * derives the user name from the real uid. */
	if (setreuid( geteuid(), -1 )) {
		perror( "setreuid" );
	}
	umask( 027 );

	/* construct the name of the file to start */
	strcpy( newname, argv[0] );
	p = strrchr( newname, '-' );
	if (!p || strcmp( p, "-wrapper" ) != 0) {
		fprintf( stderr, "No -wrapper in name\n" );
		unlink( filename );
		exit( 1 );
	}
	*p = 0;

	if ((pid = fork()) == -1) {
		/* error */
		perror( "fork" );
		unlink( filename );
		exit( 1 );
	}
	else if (pid == 0) {
		/* child */
		execl( newname, newname, filename, NULL );
		unlink( filename );
		perror( "execl" );
		return 1;
	}
	/* parent */
	exit( 0 );
}
