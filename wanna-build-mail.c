#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

int main( int argc, char *argv[] )
{
	char newname[strlen(argv[0])+4];

	strcpy( newname, argv[0] );
	strcat( newname, ".pl" );
	execv( newname, argv );
	perror( "execv" );
	return errno;

}
