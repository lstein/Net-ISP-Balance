/*

(C) 2009-2019 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/


#ifndef __CONFIG_H__
#define __CONFIG_H__

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>

typedef enum status {
	DOWN = 0,
	UP = 1,
	UNKNOWN = 2,
	LONG_DOWN = 3
} STATUS;

typedef struct config {
	struct config *prev, *next;
	char *name;
	char *sourceip;
	struct addrinfo *srcinfo;
	char *checkip;
	struct addrinfo *dstinfo;
	char *eventscript;
	int unknown_up_notify;
	char *notifyscript;
	int max_packet_loss;
	int max_successive_pkts_lost;
	int min_packet_loss;
	int min_successive_pkts_rcvd;
	int interval_ms;
	int timeout_ms;
	char *warn_email;
	int long_down_time;
	char *long_down_email;
	char *long_down_notifyscript;
	char *long_down_eventscript;
	int check_arp;
	char *device;
	int ttl;
	STATUS status;
	char *queue;
	int startup_acceleration;
	int startup_burst_pkts;
	int startup_burst_interval;

	void *data;
} CONFIG;

typedef struct group_members {
	struct group_members *prev, *next;
	char *name;
	CONFIG *cfg_ptr;
} GROUP_MEMBERS;

typedef struct groups {
	struct groups *prev, *next;
	char *name;
	char *eventscript;
	char *notifyscript;
	int unknown_up_notify;
	char *warn_email;
	int logic; /* or = 0, and = 1 */
	char *device;
	STATUS status;
	char *queue;

	GROUP_MEMBERS *fgm, *lgm;
} GROUPS;

typedef struct global {
	int debug;
} GLOBAL;

extern GLOBAL cfg;

void init_config(void);
int read_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);
int reload_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);
void dump_config(CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);
void free_config(CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);

#endif

/* EOF */
