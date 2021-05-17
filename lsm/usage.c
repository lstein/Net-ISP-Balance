/*

  (C) 2014 Mika Ilmaranta <ilmis@nullnet.fi>

  License: GPLv2

*/

#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

#include "globals.h"
#include "usage.h"

void usage_and_exit(void) {
#if defined(FOOLSM_VERSION)
        printf("%s version %s\n", get_prog(), FOOLSM_VERSION);
#endif
	printf("usage: %s\n"
	       "       [-h|--help|-v|--version]\n"
	       "       [-c|--config <config_file>]\n"
	       "       [-p|--pidfile <pid_file>]\n"
	       "       [-f|--no-fork]\n", get_prog());
	printf("check syslog for debug/error messages\n");

	exit(2);
}

/* EOF */
