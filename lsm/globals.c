/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdio.h>
#include <syslog.h>

#include "globals.h"
#include "defs.h"

#define FOOLSM_CONFIG_FILE ETCDIR "/foolsm.conf"

static char *prog = NULL;
static int cont = TRUE;
static int dump = FALSE;
static int ident = 0;
static int reload_cfg = FALSE;
static int dump_if_list = FALSE;
static char *configfile = FOOLSM_CONFIG_FILE;
static char *pidfile = "/var/run/foolsm.pid";
static int nodaemon = 0;
static char *status_str[] = { "down", "up", "unknown", "long_down" };

void set_prog(char *val)
{
	prog = val;
}

char *get_prog(void)
{
	if(prog == NULL) {
		syslog(LOG_ERR, "%s: called with prog unset", __FUNCTION__);
		return("prog unset");
	}

	return(prog);
}

void set_cont(const int val)
{
	cont = val;
}

int get_cont(void)
{
	return(cont);
}

void set_dump(const int val)
{
	dump = val;
}

int get_dump(void)
{
	return(dump);
}

void set_ident(const int val)
{
	ident = val;
}

int get_ident(void)
{
	return(ident);
}

void set_reload_cfg(const int val)
{
	reload_cfg = val;
}

int get_reload_cfg(void)
{
	return(reload_cfg);
}

void set_dump_if_list(const int val)
{
	dump_if_list = val;
}

int get_dump_if_list(void)
{
	return(dump_if_list);
}

void set_configfile(char *val)
{
	configfile = val;
}

char *get_configfile(void)
{
	return(configfile);
}

void set_pidfile(char *val)
{
	pidfile = val;
}

char *get_pidfile(void)
{
	return(pidfile);
}

void set_nodaemon(const int val)
{
	nodaemon = val;
}

int get_nodaemon(void)
{
	return(nodaemon);
}

char *get_status_str(STATUS val)
{
	return(status_str[val]);
}

/* EOF */
