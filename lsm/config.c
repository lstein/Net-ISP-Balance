/*

(C) 2009-2019 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>

#include <dirent.h>
#include <fnmatch.h>

#include "config.h"
#include "defs.h"

#define DEFAULT_SCRIPT_FILE SCRIPTDIR "/default_script"

static CONFIG defaults;
static int errors = 0;

GLOBAL cfg;

static void read_one_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);
static int find_all_configs(char* fn, int mustexist, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg);
static void reassign(char **dst, char *src);
static void release(char **dst);
static int eqcmp(char *str, char *pat);
static int check_addrs(CONFIG *cur);

static void reassign(char **dst, char *src)
{
	if(*dst) free(*dst);
	*dst = strdup(src);
}

static void release(char **dst)
{
	if(*dst) free(*dst);
	*dst = NULL;
}

static int eqcmp(char *str, char *pat)
{
	int i;

	i = strlen(pat);
	if(!strncmp(str, pat, i) && str[i] == '=') return 0;
	return 1;
}

int reload_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg) {
	free_config(first, last, firstg, lastg);
	init_config();
	return(read_config(fn, first, last, firstg, lastg));
}

void free_config(CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg) {
	CONFIG *cur, *prev;
	GROUPS *curg, *prevg;
	GROUP_MEMBERS *curgm, *prevgm;

	cur = (*first);
	while(cur) {
		if(cur->name && cur->name != defaults.name)                            release(&cur->name);
		if(cur->sourceip && cur->sourceip != defaults.sourceip)                release(&cur->sourceip);
		if(cur->srcinfo)                                                       freeaddrinfo(cur->srcinfo);
		if(cur->checkip && cur->checkip != defaults.checkip)                   release(&cur->checkip);
		if(cur->dstinfo)                                                       freeaddrinfo(cur->dstinfo);
		if(cur->eventscript && cur->eventscript != defaults.eventscript)       release(&cur->eventscript);
		if(cur->notifyscript && cur->notifyscript != defaults.notifyscript)    release(&cur->notifyscript);
		if(cur->warn_email && cur->warn_email != defaults.warn_email)          release(&cur->warn_email);
		if(cur->device && cur->device != defaults.device)                      release(&cur->device);
		if(cur->queue && cur->queue != defaults.queue)                         release(&cur->queue);
		if(cur->long_down_email && cur->long_down_email != defaults.long_down_email) release(&cur->long_down_email);
		if(cur->long_down_notifyscript && cur->long_down_notifyscript != defaults.long_down_notifyscript) release(&cur->long_down_notifyscript);
		if(cur->long_down_eventscript && cur->long_down_eventscript != defaults.long_down_eventscript) release(&cur->long_down_eventscript);

		prev = cur;
		cur = cur->next;
		free(prev);
	}

	*first = NULL;
	*last = NULL;

	curg = (*firstg);
	while(curg) {
		curgm = curg->fgm;
		while(curgm) {
			free(curgm->name);

			prevgm = curgm;
			curgm = curgm->next;
			free(prevgm);
		}
		curg->fgm = NULL;
		curg->lgm = NULL;

		if(curg->name && curg->name != defaults.name)				release(&curg->name);
		if(curg->eventscript && curg->eventscript != defaults.eventscript)	release(&curg->eventscript);
		if(curg->notifyscript && curg->notifyscript != defaults.notifyscript)	release(&curg->notifyscript);
		if(curg->warn_email && curg->warn_email != defaults.warn_email)		release(&curg->warn_email);
		if(curg->device && curg->device != defaults.device)                     release(&curg->device);
		if(curg->queue && curg->queue != defaults.queue)                        release(&curg->queue);

		prevg = curg;
		curg = curg->next;
		free(prevg);
	}

	*firstg = NULL;
	*lastg = NULL;

	if(defaults.name)                   release(&defaults.name);
	if(defaults.checkip)                release(&defaults.checkip);
	if(defaults.eventscript)            release(&defaults.eventscript);
	if(defaults.notifyscript)           release(&defaults.notifyscript);
	if(defaults.warn_email)             release(&defaults.warn_email);
	if(defaults.sourceip)               release(&defaults.sourceip);
	if(defaults.device)                 release(&defaults.device);
	if(defaults.queue)                  release(&defaults.queue);

	if(defaults.long_down_email)        release(&defaults.long_down_email);
	if(defaults.long_down_notifyscript) release(&defaults.long_down_notifyscript);
	if(defaults.long_down_eventscript)  release(&defaults.long_down_eventscript);
}

void init_config(void)
{
	/* zero cfg and defaults */
	memset(&cfg, 0, sizeof(cfg));
	memset(&defaults, 0, sizeof(defaults));

	/* initialize to sane value */
	cfg.debug = 8;

	defaults.name = strdup("defaults");
	defaults.checkip = strdup("127.0.0.1");
	defaults.eventscript = NULL;
	defaults.notifyscript = strdup(DEFAULT_SCRIPT_FILE);
	defaults.max_packet_loss = 15;
	defaults.max_successive_pkts_lost = 7;
	defaults.min_packet_loss = 5;
	defaults.min_successive_pkts_rcvd = 10;
	defaults.interval_ms = 1000;
	defaults.timeout_ms = 1000;
	defaults.warn_email = strdup("root");
	defaults.check_arp = 0;
	defaults.sourceip = NULL;
	defaults.ttl = 0;

	/* assume default unknown state for connections unless user has stated otherwise later in config */
	defaults.status = UNKNOWN;

	/* no exec queue by default */
	defaults.queue = NULL;

	defaults.long_down_email = NULL;

	/* by default don't execute notify script on unkown to up event */
	defaults.unknown_up_notify = 0;

	/* by default no accelerated startup */
	defaults.startup_acceleration = 0;

	/* by default no startup burst */
	defaults.startup_burst_pkts = 0;
	defaults.startup_burst_interval = MIN_PERHOST_INTERVAL;
}

static int find_all_configs(char* fn, int mustexist, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg)
{
	struct dirent **namelist;
	char dir[BUFSIZ], pattern[128], *p, s[BUFSIZ];
	int n, i, found;

	/* Split fn to dir/pattern */
	strcpy(dir, fn);
	if((p = strrchr(dir, '/')) == NULL) {
		strcpy(dir, ".");
		strcpy(pattern, fn);
	} else {
		*p = 0;
		strcpy(pattern, p + 1);
	}

	/* Find list of all files */
	n = scandir(dir, &namelist, 0, alphasort);
	if (n < 0) {
		if (mustexist == 0)
			return(0);
		syslog(LOG_ERR, "%s: can't read directory \"%s\"", __FUNCTION__, dir);
		return(-1);
	}

	/* See if name matches pattern */
	found = 0;
	for (i = 0; i < n; i++) {
		if (fnmatch(pattern, namelist[i]->d_name, 0) == 0 &&
		    fnmatch("*~", namelist[i]->d_name, 0) != 0) {
			snprintf(s, BUFSIZ, "%s/%s", dir, namelist[i]->d_name);
			read_one_config(s, first, last, firstg, lastg);
			found++;
		}
		free(namelist[i]);
	}
	free(namelist);

	/* Fail if no matches found */
	if (found == 0) {
		if (mustexist == 0)
			return(0);
		syslog(LOG_ERR, "%s: no config files found for \"%s\"", __FUNCTION__, fn);
		return(-1);
	}

	return(0);
}

int read_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg)
{
	CONFIG *cur = NULL;
	GROUPS *curg = NULL;
	GROUP_MEMBERS *curgm = NULL;

	errors = 0;

	read_one_config(fn, first, last, firstg, lastg);

	for(curg = *firstg; curg; curg = curg->next) {
		for(curgm = curg->fgm; curgm; curgm = curgm->next) {
			int found = 0;

			for(cur = *first; cur; cur = cur->next) {
				if(!strcmp(cur->name, curgm->name)) {
					curgm->cfg_ptr = cur;
					found = 1;
					break;
				}
			}
			if(!found) {
				syslog(LOG_ERR, "%s: %s: connection group member \"%s\" not found", __FILE__, __FUNCTION__, curgm->name);
				errors++;
			}
		}
	}

	/* some parameter sanity checking */
	for(cur = *first; cur; cur = cur->next) {
		if(strlen(cur->checkip) == 0) {
			syslog(LOG_ERR, "WARNING: connection \"%s\" has no checkip parameter set", cur->name);
			errors++;
		} else {
			if(check_addrs(cur) < 0) {
				errors++;
			}
		}

		if(cur->max_packet_loss <= cur->min_packet_loss) {
			syslog(LOG_ERR, "WARNING: connection \"%s\" max_packet_loss (%d) <= min_packet_loss (%d). that would cause flip-flop effect", cur->name, cur->max_packet_loss, cur->min_packet_loss);
			errors++;
		}

	}
	if(errors) return(-1);

	return(0);
}

static void read_one_config(char *fn, CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg)
{
	CONFIG *cur = NULL;
	GROUPS *curg = NULL;
	GROUP_MEMBERS *curgm = NULL;
	FILE *fp;
	char buf[BUFSIZ];
	int mode = 0;
	int line = 1;

	if((fp = fopen(fn, "r")) == 0) {
		syslog(LOG_ERR, "%s: can't open config file \"%s\"", __FUNCTION__, fn);
		return;
	}

	while(fgets(buf, BUFSIZ, fp)) {
		char *p = NULL;

		if(*buf && buf[strlen(buf) - 1] == '\n') buf[strlen(buf) - 1] = '\0'; /* strip lf */
		if((p = strchr(buf, '#')) != NULL) *p = '\0'; /* strip comment */
		while((p = strchr(buf, '\t')) != NULL) *p = ' '; /* tabs -> spaces */
		while(*buf == ' ') memmove(buf, buf + 1, strlen(buf)); /* strip leading space */
		while((p = strstr(buf, "  ")) != NULL) memmove(p, p + 1, strlen(p)); /* strip multi white space */
		while((p = strstr(buf, " =")) != NULL) memmove(p, p + 1, strlen(p)); /* strip spaces before = */
		while((p = strstr(buf, "= ")) != NULL) memmove(p + 1, p + 2, strlen(p + 1)); /* strip spaces after = */
		while(*buf && buf[strlen(buf) - 1] == ' ') buf[strlen(buf) - 1] = '\0'; /* strip tailing space */

		if(!*buf) continue;

		if(mode) {
			if (!strcmp(buf, "}")) {
				mode=0;
				continue;
			}

			switch(mode) {
			case 1: /* defaults */
				if(!eqcmp(buf, "name"))
					reassign(&defaults.name, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "checkip"))
					reassign(&defaults.checkip, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "eventscript"))
					reassign(&defaults.eventscript, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "notifyscript"))
					reassign(&defaults.notifyscript, strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "unknown_up_notify"))
					defaults.unknown_up_notify = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "max_packet_loss"))
					defaults.max_packet_loss = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "max_successive_pkts_lost"))
					defaults.max_successive_pkts_lost = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "min_packet_loss"))
					defaults.min_packet_loss = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "min_successive_pkts_rcvd"))
					defaults.min_successive_pkts_rcvd = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "interval_ms"))
					defaults.interval_ms = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "timeout_ms"))
					defaults.timeout_ms = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "warn_email"))
					reassign(&defaults.warn_email, strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "check_arp"))
					defaults.check_arp = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "sourceip"))
					reassign(&defaults.sourceip, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "device"))
					reassign(&defaults.device, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "ttl"))
					defaults.ttl = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "status"))
					defaults.status = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "queue"))
					reassign(&defaults.queue, strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "long_down_time"))
					defaults.long_down_time = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "long_down_email"))
					reassign(&defaults.long_down_email, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "long_down_notifyscript"))
					reassign(&defaults.long_down_notifyscript, strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "long_down_eventscript"))
					reassign(&defaults.long_down_eventscript, strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "startup_acceleration"))
					defaults.startup_acceleration = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "startup_burst_pkts"))
					defaults.startup_burst_pkts = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "startup_burst_interval"))
					defaults.startup_burst_interval = atoi(strchr(buf, '=') + 1);
				else {
					syslog(LOG_ERR, "%s: %s: unrecognised "
					       "default config option on "
					       "line %d \"%s\"", __FILE__,
					       __FUNCTION__, line, buf);
					errors++;
				}
				break;
			case 2: /* connection */
				if(!cur) {
					syslog(LOG_ERR, "read_config: cur == NULL");
					break;
				}

				if(!eqcmp(buf, "name"))                            cur->name                          = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "checkip"))                    cur->checkip                       = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "eventscript"))                cur->eventscript                   = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "notifyscript"))               cur->notifyscript                  = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "unknown_up_notify"))          cur->unknown_up_notify             = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "max_packet_loss"))            cur->max_packet_loss               = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "max_successive_pkts_lost"))   cur->max_successive_pkts_lost      = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "min_packet_loss"))            cur->min_packet_loss               = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "min_successive_pkts_rcvd"))   cur->min_successive_pkts_rcvd      = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "interval_ms"))                cur->interval_ms                   = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "timeout_ms"))                 cur->timeout_ms                    = atoi(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "warn_email"))                 cur->warn_email                    = strdup(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "check_arp"))                  cur->check_arp                     = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "sourceip"))                   cur->sourceip                      = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "device"))                     cur->device                        = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "ttl"))                        cur->ttl                           = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "status"))                     cur->status                        = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "queue"))                      cur->queue                         = strdup(strchr(buf, '=') + 1);

				else if(!eqcmp(buf, "long_down_time"))             cur->long_down_time                = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "long_down_email"))            cur->long_down_email               = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "long_down_notifyscript"))     cur->long_down_notifyscript        = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "long_down_eventscript"))      cur->long_down_eventscript         = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "startup_acceleration"))       cur->startup_acceleration          = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "startup_burst_pkts"))         cur->startup_burst_pkts            = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "startup_burst_interval"))     cur->startup_burst_interval        = atoi(strchr(buf, '=') + 1);
				else {
					syslog(LOG_ERR, "%s: %s: unrecognised connection config option on line %d \"%s\"", __FILE__, __FUNCTION__, line, buf);
					errors++;
				}
				break;
			case 3: /* group */
				if(!eqcmp(buf, "name"))                            curg->name				= strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "eventscript"))                curg->eventscript			= strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "notifyscript"))               curg->notifyscript			= strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "unknown_up_notify"))          curg->unknown_up_notify              = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "warn_email"))                 curg->warn_email			= strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "logic"))                      curg->logic				= atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "device"))                     curg->device                         = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "status"))			   curg->status                         = atoi(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "queue"))                      curg->queue                          = strdup(strchr(buf, '=') + 1);
				else if(!eqcmp(buf, "member-connection")) {
					if((curgm = (GROUP_MEMBERS *)malloc(sizeof(GROUP_MEMBERS))) == NULL) {
						syslog(LOG_ERR, "%s: %s: can't malloc for group member", __FILE__, __FUNCTION__);
						fclose(fp);
						return;
					}
					curgm->name = strdup(strchr(buf, '=') + 1);
					curgm->cfg_ptr = NULL;

					if(curg->lgm) { /* insert as last */
						curgm->next = NULL;
						curgm->prev = curg->lgm;
						curg->lgm->next = curgm;
						curg->lgm = curgm;
					} else { /* empty member list */
						curgm->next = NULL;
						curgm->prev = NULL;
						curg->fgm = curgm;
						curg->lgm = curgm;
					}
				}
				else {
					syslog(LOG_ERR, "%s: %s: unrecognised group config option on line %d \"%s\"", __FILE__, __FUNCTION__, line, buf);
					errors++;
				}
				break;
			default:
				syslog(LOG_ERR, "%s: %s: switch(mode) hit default: should never happen. mode was %d", __FILE__, __FUNCTION__, mode);
				errors++;
				break;
			}
		}
		else {
			/* global config */
			if(!eqcmp(buf, "debug"))
				cfg.debug = atoi(strchr(buf, '=') + 1);

			/* per connection configs */
			else if(!strcmp(buf, "defaults {"))
				mode=1;
			else if(!strcmp(buf, "connection {")) {
				mode=2;
				if((cur = malloc(sizeof(CONFIG))) == NULL) {
					syslog(LOG_ERR, "%s: %s: can't malloc for config", __FILE__, __FUNCTION__);
					return;
				}

				if(*last) { /* not first */
					(*last)->next = cur;
					cur->prev = *last;
					cur->next = NULL;
					*last = cur;
				}
				else {
					*first = cur;
					*last = cur;
					cur->prev = NULL;
					cur->next = NULL;
				}
				/* fill in defaults */
				if(defaults.name) {
					cur->name                       = defaults.name;
					cur->sourceip                   = defaults.sourceip;
					cur->srcinfo                    = NULL;
					cur->checkip                    = defaults.checkip;
					cur->dstinfo                    = NULL;
					cur->eventscript                = defaults.eventscript;
					cur->notifyscript               = defaults.notifyscript;
					cur->unknown_up_notify          = defaults.unknown_up_notify;
					cur->max_packet_loss            = defaults.max_packet_loss;
					cur->max_successive_pkts_lost   = defaults.max_successive_pkts_lost;
					cur->min_packet_loss            = defaults.min_packet_loss;
					cur->min_successive_pkts_rcvd   = defaults.min_successive_pkts_rcvd;
					cur->interval_ms                = defaults.interval_ms;
					cur->timeout_ms                 = defaults.timeout_ms;
					cur->warn_email                 = defaults.warn_email;
					cur->check_arp                  = defaults.check_arp;
					cur->device                     = defaults.device;
					cur->ttl                        = defaults.ttl;
					cur->status			= defaults.status;
					cur->queue                      = defaults.queue;
					cur->long_down_time             = defaults.long_down_time;
					cur->long_down_email            = defaults.long_down_email;
					cur->long_down_notifyscript     = defaults.long_down_notifyscript;
					cur->long_down_eventscript      = defaults.long_down_eventscript;
					cur->startup_acceleration	= defaults.startup_acceleration;
					cur->startup_burst_pkts		= defaults.startup_burst_pkts;
					cur->startup_burst_interval     = defaults.startup_burst_interval;
				}
				else
					syslog(LOG_ERR, "%s: %s: defaults not set", __FILE__, __FUNCTION__);
			}
			else if(!strcmp(buf, "group {")) {
				mode = 3;

				if((curg = (GROUPS *)malloc(sizeof(GROUPS))) == NULL) {
					syslog(LOG_ERR, "read_config: can't malloc for group");
					return;
				}

				/* apply sane defaults for group */
				curg->name            = defaults.name;
				curg->eventscript     = defaults.eventscript;
				curg->notifyscript    = defaults.notifyscript;
				curg->unknown_up_notify = defaults.unknown_up_notify;
				curg->warn_email      = defaults.warn_email;
				curg->logic           = 0; /* default group logic or */
				curg->device          = defaults.device;
				curg->status          = defaults.status;
				curg->queue           = defaults.queue;

				curg->fgm = NULL;
				curg->lgm = NULL;

				if(*lastg) { /* not first group */
					(*lastg)->next = curg;
					curg->prev = *lastg;
					curg->next = NULL;
					*lastg = curg;
				} else {
					*firstg = curg;
					*lastg = curg;
					curg->prev = NULL;
					curg->next = NULL;
				}
			}
			else if(!strncmp(buf, "include ", 8)) {
				if(find_all_configs(strchr(buf, ' ') + 1, 1, first, last, firstg, lastg) != 0) {
					syslog(LOG_ERR, "%s: %s: failed to process included config file on line %d \"%s\"", __FILE__, __FUNCTION__, line, strchr(buf, ' ') + 1);
					errors++;
				}
				continue;
			}
			else if(!strncmp(buf, "-include ", 9)) {
				if(find_all_configs(strchr(buf, ' ') + 1, 0, first, last, firstg, lastg) != 0) {
					syslog(LOG_ERR, "%s: %s: failed to process included config file on line %d \"%s\"", __FILE__, __FUNCTION__, line, strchr(buf, ' ') + 1);
					errors++;
				}
				continue;
			}
			else {
				syslog(LOG_ERR, "%s: %s: unrecognised global config option in file \"%s\" on line %d \"%s\"", __FILE__, __FUNCTION__, fn, line, buf);
				errors++;
			}
		}
		line++;
	}

	if(mode != 0) {
		syslog(LOG_ERR, "%s: %s: missing closing bracket at the end of config file \"%s\"", __FILE__, __FUNCTION__, fn);
		errors++;
	}

	fclose(fp);
}

void dump_config(CONFIG **first, CONFIG **last, GROUPS **firstg, GROUPS **lastg)
{
	CONFIG *cur;
	GROUPS *curg;
	GROUP_MEMBERS *curgm;

	syslog(LOG_INFO,   "cfg.debug                     = \"%d\"", cfg.debug);

	for(cur = *first; cur; cur = cur->next) {
		syslog(LOG_INFO, "cur->name                     = \"%s\"", cur->name);
		syslog(LOG_INFO, "cur->sourceip                 = \"%s\"", cur->sourceip);
#if defined(DEBUG)
		if(cur->srcinfo) {
			char sbuf[INET6_ADDRSTRLEN];

			syslog(LOG_INFO, "cur->srcinfo                  = \"%s\"", inet_ntop(cur->srcinfo->ai_family, &cur->srcinfo->ai_addr, sbuf, INET6_ADDRSTRLEN));
		}
#endif
		syslog(LOG_INFO, "cur->checkip                  = \"%s\"", cur->checkip);
#if defined(DEBUG)
		if(cur->dstinfo) {
			char sbuf[INET6_ADDRSTRLEN];

			syslog(LOG_INFO, "cur->dstinfo                  = \"%s\"", inet_ntop(cur->dstinfo->ai_family, &cur->dstinfo->ai_addr, sbuf, INET6_ADDRSTRLEN));
		}
#endif
		syslog(LOG_INFO, "cur->eventscript              = \"%s\"", cur->eventscript);
		syslog(LOG_INFO, "cur->notifyscript             = \"%s\"", cur->notifyscript);
		syslog(LOG_INFO, "cur->unknown_up_notify        = \"%d\"", cur->unknown_up_notify);

		syslog(LOG_INFO, "cur->max_packet_loss          = \"%d\"", cur->max_packet_loss);
		syslog(LOG_INFO, "cur->max_successive_pkts_lost = \"%d\"", cur->max_successive_pkts_lost);
		syslog(LOG_INFO, "cur->min_packet_loss          = \"%d\"", cur->min_packet_loss);
		syslog(LOG_INFO, "cur->min_successive_pkts_rcvd = \"%d\"", cur->min_successive_pkts_rcvd);
		syslog(LOG_INFO, "cur->interval_ms              = \"%d\"", cur->interval_ms);
		syslog(LOG_INFO, "cur->timeout_ms               = \"%d\"", cur->timeout_ms);

		syslog(LOG_INFO, "cur->warn_email               = \"%s\"", cur->warn_email);

		syslog(LOG_INFO, "cur->check_arp                = \"%d\"", cur->check_arp);
		syslog(LOG_INFO, "cur->device                   = \"%s\"", cur->device);
		syslog(LOG_INFO, "cur->ttl                      = \"%d\"", cur->ttl);
		syslog(LOG_INFO, "cur->status                   = \"%d\"", cur->status);
		syslog(LOG_INFO, "cur->startup_acceleration     = \"%d\"", cur->startup_acceleration);
		syslog(LOG_INFO, "cur->startup_burst_pkts       = \"%d\"", cur->startup_burst_pkts);
		syslog(LOG_INFO, "cur->startup_burst_interval   = \"%d\"", cur->startup_burst_interval);
	}

	for(curg = *firstg; curg; curg = curg->next) {
		syslog(LOG_INFO, "curg->name                    = \"%s\"", curg->name);
		syslog(LOG_INFO, "curg->eventscript             = \"%s\"", curg->eventscript);
		syslog(LOG_INFO, "curg->notifyscript            = \"%s\"", curg->notifyscript);
		syslog(LOG_INFO, "curg->unknown_up_notify       = \"%d\"", curg->unknown_up_notify);
		syslog(LOG_INFO, "curg->warn_email              = \"%s\"", curg->warn_email);
		syslog(LOG_INFO, "curg->device                  = \"%s\"", curg->device);
		syslog(LOG_INFO, "curg->logic                   = \"%s\"", curg->logic == 0 ? "OR" : "AND");

		for(curgm = curg->fgm; curgm; curgm = curgm->next) {
			syslog(LOG_INFO, "curgm->name                   = \"%s\"", curgm->name);
		}
	}
}

static int check_addrs(CONFIG *cur)
{
	struct in6_addr serveraddr;
	struct addrinfo hints;
#if defined(DEBUG)
	struct addrinfo *rp;
#endif
	int rc;

	memset(&hints, 0, sizeof(hints));
	hints.ai_flags    = AI_NUMERICSERV;
	hints.ai_family   = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	if((rc = inet_pton(AF_INET, cur->checkip, &serveraddr)) == 1) { /* valid v4 addr */
		hints.ai_family = AF_INET;
		hints.ai_flags |= AI_NUMERICHOST;
	}
	else if((rc = inet_pton(AF_INET6, cur->checkip, &serveraddr)) == 1) { /* valid v6 addr */
		hints.ai_family = AF_INET6;
		hints.ai_flags |= AI_NUMERICHOST;
	}

	if((rc = getaddrinfo(cur->checkip, "1025", &hints, &(cur->dstinfo))) != 0) {
		syslog(LOG_ERR, "WARNING: connection \"%s\" checkip is invalid %s, %s", cur->name, cur->checkip, gai_strerror(rc));
		return(-1);
	}

#if defined(DEBUG)
	for(rp = cur->dstinfo; rp; rp = rp->ai_next) {
		unsigned char *s;
		char buf[BUFSIZ];
		char sbuf[INET6_ADDRSTRLEN];
		int i;

		memset(buf, 0, BUFSIZ);
		s = (unsigned char *)rp;

		strcat(buf, "hex dump:");
		for(i = 0; i < sizeof(struct addrinfo); i++)
			sprintf(buf + strlen(buf), " %2x", s[i]);
		syslog(LOG_INFO, "%s: %s: dst %s", __FILE__, __FUNCTION__, buf);

		memset(buf, 0, BUFSIZ);
		s = (unsigned char *)rp;

		strcat(buf, "dec dump:");
		for(i = 0; i < sizeof(struct addrinfo); i++)
			sprintf(buf + strlen(buf), " %3d", s[i]);
		syslog(LOG_INFO, "%s: %s: dst %s", __FILE__, __FUNCTION__, buf);

		syslog(LOG_INFO, "%s: %s: dst %s = %s", __FILE__, __FUNCTION__, cur->checkip, inet_ntop(rp->ai_family, &rp->ai_addr, sbuf, INET6_ADDRSTRLEN));
	}
#endif

	if(cur->dstinfo->ai_family == AF_INET6 && cur->check_arp) {
		syslog(LOG_ERR, "WARNING: connection \"%s\" ipv6 and arping are not compatible", cur->name);
		return(-1);
	}

	if(!cur->sourceip || !*cur->sourceip) return(0); /* sourceip is not mandatory */

	memset(&hints, 0, sizeof(hints));
	hints.ai_flags    = AI_NUMERICSERV;
	hints.ai_family   = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;

	if((rc = inet_pton(AF_INET, cur->sourceip, &serveraddr)) == 1) { /* valid v4 addr */
		hints.ai_family = AF_INET;
		hints.ai_flags |= AI_NUMERICHOST;
	}
	else if((rc = inet_pton(AF_INET6, cur->sourceip, &serveraddr)) == 1) { /* valid v6 addr */
		hints.ai_family = AF_INET6;
		hints.ai_flags |= AI_NUMERICHOST;
	}

	if((rc = getaddrinfo(cur->sourceip, "1025", &hints, &(cur->srcinfo))) != 0) {
		syslog(LOG_ERR, "WARNING: connection \"%s\" sourceip is invalid %s, %s", cur->name, cur->sourceip, gai_strerror(rc));
		return(-1);
	}

#if defined(DEBUG)
	for(rp = cur->srcinfo; rp; rp = rp->ai_next) {
		unsigned char *s;
		char buf[BUFSIZ];
		char sbuf[INET6_ADDRSTRLEN];
		int i;

		memset(buf, 0, BUFSIZ);
		s = (unsigned char *)rp;

		strcat(buf, "hex dump:");
		for(i = 0; i < sizeof(struct addrinfo); i++)
			sprintf(buf + strlen(buf), " %2x", s[i]);
		syslog(LOG_INFO, "%s: %s: src %s", __FILE__, __FUNCTION__, buf);

		memset(buf, 0, BUFSIZ);
		s = (unsigned char *)rp;

		strcat(buf, "dec dump:");
		for(i = 0; i < sizeof(struct addrinfo); i++)
			sprintf(buf + strlen(buf), " %3d", s[i]);
		syslog(LOG_INFO, "%s: %s: src %s", __FILE__, __FUNCTION__, buf);

		syslog(LOG_INFO, "%s: %s: src %s = %s", __FILE__, __FUNCTION__, cur->checkip, inet_ntop(rp->ai_family, &rp->ai_addr, sbuf, INET6_ADDRSTRLEN));
	}
#endif

	if(cur->srcinfo->ai_family != cur->dstinfo->ai_family) {
		syslog(LOG_ERR, "WARNING: connection \"%s\" sourceip and checkip have unmatching protocol families", cur->name);
		return(-1);
	}

	return(0);
}

/* EOF */
