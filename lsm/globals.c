/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdio.h>
#include <syslog.h>

#include "globals.h"
#include "defs.h"

static char *prog = NULL;
static int cont = TRUE;
static int dump = FALSE;
static int ident = 0;
static int reload_cfg = FALSE;
static int dump_if_list = FALSE;

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

/* EOF */
