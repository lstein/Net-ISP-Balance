/*

  (C) 2014 Mika Ilmaranta <ilmis@nullnet.fi>

  License: GPLv2

*/

#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>

#include "globals.h"
#include "usage.h"
#include "cmdline.h"

void cmdline_parse(int argc, char *argv[])
{
	static struct option long_options[] = {
		{ "help",               0, 0, 'h' },
		{ "version",            0, 0, 'v' },
		{ "config",             1, 0, 'c' },
		{ "pidfile",            1, 0, 'p' },
		{ "no-fork",            0, 0, 'f' },
		{ 0, 0, 0, 0 },
	};

	set_prog(argv[0]);

	for(;;) {
		int i = getopt_long(argc, argv, "hvc:p:f", long_options, NULL);
		if(i == -1) break;
		switch(i) {
		case 'h':
		case 'v':
			usage_and_exit();

		case 'c':
			set_configfile(optarg);
			break;

		case 'p':
			set_pidfile(optarg);
			break;

		case 'f':
			set_nodaemon(1);
			break;

		default:
			usage_and_exit();
		}
	}

	if(optind < argc)
		usage_and_exit();
}

/* EOF */
