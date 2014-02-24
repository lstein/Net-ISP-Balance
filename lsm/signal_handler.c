/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdio.h>
#include <errno.h>
#include <signal.h>

#include "globals.h"

void signal_handler(int signo) {
	int errno_save;

	errno_save = errno;

	switch(signo) {
	case SIGINT:
		set_cont(0);
		break;
	case SIGUSR1:
		set_dump(1);
		break;
	case SIGUSR2:
		set_dump_if_list(1);
		break;
	case SIGHUP:
		set_reload_cfg(1);
		break;
	}

	errno = errno_save;
}

/* EOF */
