/*

  (C) 2014 Mika Ilmaranta <ilmis@nullnet.fi>

  License: GPLv2

 */

#include <stdio.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <syslog.h>
#include <unistd.h>
#include <string.h>

#include "pidfile.h"
#include "globals.h"

static int pidfilefh = 0;

int pidfile_open(void)
{
	if(get_nodaemon()) return(0);

	pidfilefh = open(get_pidfile(), O_RDWR|O_CREAT, 0640);

	if(pidfilefh < 0) {
		syslog(LOG_ERR, "can't open pid file %s", get_pidfile());
		return(1); /* can not open */
	}
	if(fcntl(pidfilefh, F_SETFD, FD_CLOEXEC) == -1) {
		syslog(LOG_ERR, "failed to set close on exec on pid file %s", get_pidfile());
	}

	if(lockf(pidfilefh, F_TLOCK, 0) < 0) {
		syslog(LOG_ERR, "can't lock pid file %s", get_pidfile());
		return(1); /* can not lock */
	}

	return(0);
}

int pidfile_update(void)
{
	if(get_nodaemon()) return(0);

	if(pidfilefh) {
		char str[BUFSIZ];
		ssize_t n;

		lseek(pidfilefh, 0, SEEK_SET);
		if(ftruncate(pidfilefh, 0) == -1) {
			syslog(LOG_ERR, "ftruncate failed \"%s\"", strerror(errno));
			return(1);
		}

		sprintf(str, "%d\n", getpid());
		n = write(pidfilefh, str, strlen(str)); /* record pid to lockfile */
		if(n == -1) {
			syslog(LOG_ERR, "write failed \"%s\"", strerror(errno));
			return(1);
		}
		if(n != strlen(str)) {
#if defined(__x86_64) || defined(__x86_64__) || defined(__amd64) || defined(__amd64__)
			syslog(LOG_ERR, "write failed, %ld bytes written of %ld bytes", n, strlen(str));
#else
			syslog(LOG_ERR, "write failed, %d bytes written of %d bytes", n, strlen(str));
#endif
			return(1);
		}
	}

	return(0);
}

void pidfile_close(void)
{
	if(get_nodaemon()) return;

	if(pidfilefh) {
		close(pidfilefh);
		pidfilefh = 0;
		unlink(get_pidfile());
	}
}

/* EOF */
