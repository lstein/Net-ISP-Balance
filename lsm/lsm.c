/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#define _GNU_SOURCE

#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <netinet/in_systm.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/select.h>
#include <syslog.h>
#include <sys/wait.h>
#include <stdarg.h>
#include <fcntl.h>

#include <sys/ioctl.h>
#include <linux/if.h>
#include <sys/uio.h>

#include "icmp_t.h"
#include "icmp6_t.h"
#include "config.h"
#include "cksum.h"
#include "globals.h"
#include "signal_handler.h"
#include "forkexec.h"
#include "timecalc.h"
#include "lsm.h"
#ifndef NO_PLUGIN_EXPORT
#include "plugin_export.h"
#endif
#include "save_statuses.h"

typedef struct ping_data {
	unsigned short id;       /* target id */
	long ping_count;         /* counts up to -c count or 1 */
	struct timeval ping_ts;  /* time sent */
} PING_DATA;

static void update_stats(CONFIG *first);
static void dump_statuses(CONFIG *first);
static void decide(CONFIG *first);
static void groups_decide(GROUPS *firstg);
static int wait_for_replies(CONFIG **ctable);
static int ping_send(CONFIG *cur);
static int ping_rcv(CONFIG *first, char *buf, int len, struct sockaddr_in6 *saddr, unsigned int *slen, long usec, CONFIG **arp);
static void usage(void);
static int event_script_check(const char *path);
static int open_arp_sock(CONFIG *cur);
static int open_icmp_sock(CONFIG *cur);
static int probe_src_ip_addr(CONFIG *cur);
static void init_config_data(CONFIG *first, CONFIG *last, CONFIG ***ctable);
static void free_config_data(CONFIG *first);
#if defined(DEBUG)
static void dump_pkt(const void *buf, size_t len);
#endif

static char *status_str[] = { "down", "up", "unknown", "long_down" };
static int num_hosts = 0;
static struct sockaddr_in bind_addr;

/* Main */
int main(int argc, char *argv[]) {
	TARGET *t = NULL;
	CONFIG *first = NULL, *last = NULL, *cur;
	GROUPS *firstg = NULL, *lastg = NULL;
	CONFIG **ctable = NULL;
	struct timeval last_sent_time = {0, 0};
	int start = 0;
	int lfp = 0;

	set_prog(argv[0]);
	set_ident(getpid() & 0xFFFF);

	openlog("lsm", LOG_PID, LOG_DAEMON);

	init_config();

	if(read_config(argv[1], &first, &last, &firstg, &lastg)) {
		usage();
		exit(2);
	}

	if(cfg.debug >= 9) syslog(LOG_INFO, "my ident is %d\n", get_ident());

	if(!first) {
		syslog(LOG_ERR, "no targets found in config file");
		exit(1);
	}

	if(cfg.debug >= 9) dump_config(&first, &last, &firstg, &lastg);

	/* check pid file */
	if(argc >= 3) {
		lfp = open(argv[2], O_RDWR|O_CREAT, 0640);

		if(lfp < 0) {
			syslog(LOG_ERR, "can't open pid file %s", argv[2]);
			exit(1); /* can not open */
		}
		if(fcntl(lfp, F_SETFD, FD_CLOEXEC) == -1) {
			syslog(LOG_ERR, "failed to set close on exec on pid file %s", argv[2]);
		}

		if(lockf(lfp, F_TLOCK, 0) < 0) {
			syslog(LOG_ERR, "can't lock pid file %s", argv[2]);
			exit(1); /* can not lock */
		}
		/* only first instance continues */
	}

	/* detach from controlling terminal if debug level is below 100 */
	if(cfg.debug < 100) {
		if(daemon(1, 0)) {
			syslog(LOG_ERR, "daemon failed while trying to detach");
			return(1);
		}
	}

	if(lfp) {
		char str[BUFSIZ];
		ssize_t n;

		lseek(lfp, 0, SEEK_SET);
		if(ftruncate(lfp, 0) == -1) {
			syslog(LOG_ERR, "ftruncate failed \"%s\"", strerror(errno));
			exit(1);
		}

		sprintf(str, "%d\n", getpid());
		n = write(lfp, str, strlen(str)); /* record pid to lockfile */
		if(n == -1) {
			syslog(LOG_ERR, "write failed \"%s\"", strerror(errno));
			exit(1);
		}
		if(n != strlen(str)) {
#if defined(__x86_64) || defined(__x86_64__) || defined(__amd64) || defined(__amd64__)
			syslog(LOG_ERR, "write failed, %ld bytes written of %ld bytes", n, strlen(str));
#else
			syslog(LOG_ERR, "write failed, %d bytes written of %d bytes", n, strlen(str));
#endif
			exit(1);
		}
	}

#ifndef NO_PLUGIN_EXPORT
	plugin_export_init();
#endif

	init_config_data(first, last, &ctable);

	signal(SIGINT, signal_handler);
	signal(SIGUSR1, signal_handler);
	signal(SIGUSR2, signal_handler);
	signal(SIGHUP, signal_handler);

	/*
	  Create the handler for child signals. This will clean up
	  any forked child after an event has occured.
	*/
	create_sigchld_hdl();

	struct timeval last_decision = {0, 0};

	/* the main loop */
	while(get_cont()) {
		struct timeval tv = {0, 0};

		if(get_reload_cfg()) {

			save_statuses(first);

			/* reload config */
			free(ctable);
			free_config_data(first);
			if(reload_config(argv[1], &first, &last, &firstg, &lastg)) {
				syslog(LOG_ERR, "reload config failed");
				exit(2);
			}
			init_config_data(first, last, &ctable);

			restore_statuses(first);

			set_reload_cfg(0);
		}

		for(cur = first; cur; cur = cur->next) {
			struct timeval current_time = {0, 0};

			if(start)
				while(wait_for_replies(ctable));

			if(gettimeofday(&current_time, NULL) == -1) {
				syslog(LOG_INFO, "gettimeofday failed \"%s\"", strerror(errno));
				sleep(1);
				continue;
			}

			t = cur->data;

			if(timeval_diff_cmp(&current_time, &last_sent_time, TIMEVAL_DIFF_CMP_LT, MIN_PERHOST_INTERVAL / 1000000L, MIN_PERHOST_INTERVAL % 1000000L)) continue;

			if(timeval_diff_cmp(&current_time, &(t->last_send_time), TIMEVAL_DIFF_CMP_LT, (cur->interval_ms * 1000) / 1000000L, (cur->interval_ms * 1000) % 1000000L)) continue;

			if(cur->check_arp) {
				open_arp_sock(cur);
			} else {
			  open_icmp_sock(cur);
			}

			if(ping_send(cur)) {
				if(cfg.debug >= 9) syslog(LOG_INFO, "ping_send failed to %s", cur->name);
			}
			else {
				gettimeofday(&last_sent_time, NULL);
				start = 1;
			}
		}

		gettimeofday(&tv, NULL);
		if(timeval_diff_cmp(&tv, &last_decision, TIMEVAL_DIFF_CMP_GT, 1, 0)) { /* make decisions at 1s intervals */
			gettimeofday(&last_decision, NULL);

			update_stats(first);
			decide(first);
			dump_statuses(first);

			groups_decide(firstg);

#if defined(DEBUG)
			exec_queue_dump();
#endif
			exec_queue_process();

#ifndef NO_PLUGIN_EXPORT
			plugin_export(first);
#endif
		}
	} /* while cont */

	/* if we wrote pid file then close and remove it */
	if(lfp) {
		close(lfp);
		unlink(argv[2]);
	}

	free(ctable);
	free_config_data(first);
	free_config(&first, &last, &firstg, &lastg);
	exec_queue_free();

	closelog();

	return(0);
}

static void free_config_data(CONFIG *first) {
	CONFIG *cur;

	for(cur = first; cur; cur = cur->next) {
		TARGET *t;

		t = cur->data;
		if(t->sock != -1) close(t->sock);
		free(t);
	}
}

static void update_stats(CONFIG *first) {
	struct timeval current_time = {0, 0};
	CONFIG *cur;

	gettimeofday(&current_time, NULL);

	for(cur = first; cur; cur = cur->next) {
		TARGET *t;
		int i, seq, ind;
		long rtt = 0;

		t = cur->data;

		t->timeout = 0;
		t->replied = 0;
		t->waiting = 0;
		t->reply_late = 0;
		t->used = 0;
		t->consecutive_waiting = 0;
		t->consecutive_missing = 0;
		t->consecutive_rcvd = 0;

		/* check consecutive pkts */
		seq = t->seq % FOLLOWED_PKTS;

		for(i = (seq - 2); i > (seq - 2) - FOLLOWED_PKTS; i--) {
			ind = (i >= 0) ? i : i + FOLLOWED_PKTS;
			if(!t->sentpkts[ind].flags.used) break;

			if(t->sentpkts[ind].flags.waiting) t->consecutive_waiting++;
			else break;
		}

		for(i = (seq - 2); i > (seq - 2) - FOLLOWED_PKTS; i--) {
			ind = (i >= 0) ? i : i + FOLLOWED_PKTS;
			if(!t->sentpkts[ind].flags.used) break;

			if(t->sentpkts[ind].flags.timeout || t->sentpkts[ind].flags.waiting) t->consecutive_missing++;
			else break;
		}

		for(i = (seq - 2); i > (seq - 2) - FOLLOWED_PKTS; i--) {
			ind = (i >= 0) ? i : i + FOLLOWED_PKTS;
			if(!t->sentpkts[ind].flags.used) break;

			if(t->sentpkts[ind].flags.replied && !t->sentpkts[ind].flags.timeout) t->consecutive_rcvd++;
			else break;
		}

		/* count pkt states */
		for(i = 0; i < FOLLOWED_PKTS; i++) {
			if(!t->sentpkts[i].flags.used) continue;

			if(timeval_diff_cmp(&current_time, &t->sentpkts[i].sent_time, TIMEVAL_DIFF_CMP_GT, (cur->timeout_ms * 1000) / 1000000L, (cur->timeout_ms * 1000) % 1000000L) && t->sentpkts[i].flags.waiting) {
				t->sentpkts[i].flags.timeout = 1;
			}

			if(t->sentpkts[i].flags.replied && t->sentpkts[i].flags.timeout) t->reply_late++;

			if(t->sentpkts[i].flags.replied) {
				t->replied++;
				rtt += t->sentpkts[i].rtt; /* count rtt sum in usec from replied pkts rtt which is in usec */
			}
			if(t->sentpkts[i].flags.timeout) t->timeout++;
			if(t->sentpkts[i].flags.waiting) t->waiting++;
			t->used++;
		}
		/* avg_rtt in usec */
		t->avg_rtt = rtt / (t->replied ? t->replied : 1);

		if(cfg.debug >= 9) syslog(LOG_INFO, "name = %s, replied = %d, waiting = %d, timeout = %d, late reply = %d, cons rcvd = %d, cons wait = %d, cons miss = %d, avg_rtt = %.3f, seq = %d", cur->name, t->replied, t->waiting, t->timeout, t->reply_late, t->consecutive_rcvd, t->consecutive_waiting, t->consecutive_missing, t->avg_rtt / 1000.0, t->seq);

	}
}

static void dump_statuses(CONFIG *first) {
	CONFIG *cur;

	for(cur = first; cur; cur = cur->next) {
		TARGET *t;

		t = cur->data;

		if((t->status == DOWN || t->status == LONG_DOWN) && t->downseq == (t->seq % FOLLOWED_PKTS) && t->seq != t->downseqreported && !t->status_change) syslog(LOG_INFO, "link %s still down", cur->name);

		/* dump is controlled by SIGUSR1 and then we should show all statuses anyway */
		if(get_dump() || t->status_change || ((t->status == DOWN || t->status == LONG_DOWN) && t->downseq == (t->seq % FOLLOWED_PKTS) && t->seq != t->downseqreported && !t->status_change)) {
			int i, seq;
			/* 100 should be enough for the comments and such, but I don't care to count */
			char buf[FOLLOWED_PKTS + 100];

			seq = t->seq % FOLLOWED_PKTS;

			syslog(LOG_INFO, "name = %s, replied = %d, waiting = %d, timeout = %d, late reply = %d, cons rcvd = %d, cons wait = %d, cons miss = %d, avg_rtt = %.3f, seq = %d\n", cur->name, t->replied, t->waiting, t->timeout, t->reply_late, t->consecutive_rcvd, t->consecutive_waiting, t->consecutive_missing, t->avg_rtt / 1000.0, t->seq);

			sprintf(buf, "seq        ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				if(i == seq) strcat(buf, "*");
				else strcat(buf, " ");
			}
			syslog(LOG_INFO, "%s", buf);

			sprintf(buf, "used       ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				sprintf(buf + strlen(buf), "%d", t->sentpkts[i].flags.used);
			}
			syslog(LOG_INFO, "%s", buf);

			sprintf(buf, "wait       ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				sprintf(buf + strlen(buf), "%d", t->sentpkts[i].flags.waiting);
			}
			syslog(LOG_INFO, "%s", buf);

			sprintf(buf, "replied    ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				sprintf(buf + strlen(buf), "%d", t->sentpkts[i].flags.replied);
			}
			syslog(LOG_INFO, "%s", buf);

			sprintf(buf, "timeout    ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				sprintf(buf + strlen(buf), "%d", t->sentpkts[i].flags.timeout);
			}
			syslog(LOG_INFO, "%s", buf);

			sprintf(buf, "error      ");
			for(i = 0; i < FOLLOWED_PKTS; i++) {
				sprintf(buf + strlen(buf), "%d", t->sentpkts[i].flags.error);
			}
			syslog(LOG_INFO, "%s", buf);

			t->downseqreported = t->seq;
		}
	}
	if(get_dump()) set_dump(0); /* if we just dumped then don't dump next time. flags don't change that frequently */
}

static void decide(CONFIG *first) {
	struct timeval current_time = {0, 0};
	CONFIG *cur;

	gettimeofday(&current_time, NULL);

	for(cur = first; cur; cur = cur->next) {
		TARGET *t;

		t = cur->data;

		/* reset any previous connection status_change state */
		t->status_change = 0;

		/* up or unknown */
		if(t->status == UP || t->status == UNKNOWN) {
			if(t->timeout >= cur->max_packet_loss || t->consecutive_missing >= cur->max_successive_pkts_lost) {
				/* change to down state */
				if(cfg.debug >= 8) syslog(LOG_INFO, "link %s down event", cur->name);
				if(event_script_check(cur->eventscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->eventscript,
							       "down",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->warn_email && *cur->warn_email) ? cur->warn_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       current_time.tv_sec);
					envp = exec_queue_envp();

					if(cur->queue && *cur->queue) {
						exec_queue_add(cur->queue, argv, envp);
					} else {
						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}

				if(event_script_check(cur->notifyscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->notifyscript,
							       "down",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->warn_email && *cur->warn_email) ? cur->warn_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       current_time.tv_sec);

					envp = exec_queue_envp();

					forkexec(argv, envp);

					exec_queue_argv_free(argv);
					exec_queue_envp_free(envp);
				}

				t->status_change = 1;
				t->status = DOWN;
				if(gettimeofday(&t->down_timestamp, NULL) == -1) {
					syslog(LOG_INFO, "gettimeofday failed \"%s\"", strerror(errno));
				}
				t->downseq = t->seq % FOLLOWED_PKTS;
				t->downseqreported = 0;
			}
		}

		/* has it been down long? */
		if(t->status == DOWN && cur->long_down_time) {
			if(timeval_diff_cmp(&current_time, &t->down_timestamp, TIMEVAL_DIFF_CMP_GT, cur->long_down_time, 0)) {
				if(cfg.debug >= 8) syslog(LOG_INFO, "link %s long down event", cur->name);
				if(event_script_check(cur->long_down_eventscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->long_down_eventscript,
							       "long_down",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->long_down_email && *cur->long_down_email) ? cur->long_down_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       t->down_timestamp.tv_sec);

					envp = exec_queue_envp();

					if(cur->queue && *cur->queue) {
						exec_queue_add(cur->queue, argv, envp);
					} else {
						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}

				if(event_script_check(cur->long_down_notifyscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->long_down_notifyscript,
							       "long_down",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->long_down_email && *cur->long_down_email) ? cur->long_down_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       t->down_timestamp.tv_sec);

					envp = exec_queue_envp();

					forkexec(argv, envp);

					exec_queue_argv_free(argv);
					exec_queue_envp_free(envp);
				}
				/* special, LONG_DOWN is considered DOWN thus no status_change */
				t->status = LONG_DOWN;
			}
		}

		/* down or unknown */
		if(t->status == DOWN || t->status == LONG_DOWN || t->status == UNKNOWN) {
			if(t->timeout <= cur->min_packet_loss && t->consecutive_rcvd >= cur->min_successive_pkts_rcvd) {
				/* report long_down to up */
				if(t->status == LONG_DOWN) {
					if(event_script_check(cur->long_down_eventscript)) {
						char sbuf[INET6_ADDRSTRLEN];
						char **argv;
						char **envp;

						argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
								       cur->long_down_eventscript,
								       "long_down_to_up",
								       cur->name,
								       cur->checkip,
								       (cur->device && *cur->device) ? cur->device : "NA",
								       (cur->long_down_email && *cur->long_down_email) ? cur->long_down_email : "-",
								       t->replied,
								       t->waiting,
								       t->timeout,
								       t->reply_late,
								       t->consecutive_rcvd,
								       t->consecutive_waiting,
								       t->consecutive_missing,
								       t->avg_rtt,
								       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
								       status_str[t->status],
								       current_time.tv_sec);

						envp = exec_queue_envp();

						if(cur->queue && *cur->queue) {
							exec_queue_add(cur->queue, argv, envp);
						} else {
							forkexec(argv, envp);

							exec_queue_argv_free(argv);
							exec_queue_envp_free(envp);
						}
					}

					if(event_script_check(cur->long_down_notifyscript)) {
						char sbuf[INET6_ADDRSTRLEN];
						char **argv;
						char **envp;

						argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
								       cur->long_down_notifyscript,
								       "long_down_to_up",
								       cur->name,
								       cur->checkip,
								       (cur->device && *cur->device) ? cur->device : "NA",
								       (cur->long_down_email && *cur->long_down_email) ? cur->long_down_email : "-",
								       t->replied,
								       t->waiting,
								       t->timeout,
								       t->reply_late,
								       t->consecutive_rcvd,
								       t->consecutive_waiting,
								       t->consecutive_missing,
								       t->avg_rtt,
								       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
								       status_str[t->status],
								       current_time.tv_sec);

						envp = exec_queue_envp();

						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}

				/* change to up state */
				if(cfg.debug >= 8) syslog(LOG_INFO, "link %s up event", cur->name);
				if(event_script_check(cur->eventscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->eventscript,
							       "up",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->warn_email && *cur->warn_email) ? cur->warn_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       current_time.tv_sec);

					envp = exec_queue_envp();

					if(cur->queue && *cur->queue) {
						exec_queue_add(cur->queue, argv, envp);
					} else {
						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}

				if((cur->unknown_up_notify || t->status != UNKNOWN) && event_script_check(cur->notifyscript)) {
					char sbuf[INET6_ADDRSTRLEN];
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       cur->notifyscript,
							       "up",
							       cur->name,
							       cur->checkip,
							       (cur->device && *cur->device) ? cur->device : "NA",
							       (cur->warn_email && *cur->warn_email) ? cur->warn_email : "-",
							       t->replied,
							       t->waiting,
							       t->timeout,
							       t->reply_late,
							       t->consecutive_rcvd,
							       t->consecutive_waiting,
							       t->consecutive_missing,
							       t->avg_rtt,
							       cur->dstinfo->ai_family == AF_INET ? inet_ntoa(t->src) : inet_ntop(AF_INET6, &t->src6, sbuf, INET6_ADDRSTRLEN),
							       status_str[t->status],
							       current_time.tv_sec);

					envp = exec_queue_envp();

					forkexec(argv, envp);

					exec_queue_argv_free(argv);
					exec_queue_envp_free(envp);
				}

				t->status_change = 1;
				t->status = UP;
			}
		}
	}
}

static void groups_decide(GROUPS *firstg){
	GROUPS *curg;
	GROUP_MEMBERS *curgm;
	TARGET *t;
	STATUS status;
	struct timeval current_time = {0, 0};

	gettimeofday(&current_time, NULL);

	curg = firstg;
	while(curg) {
		status = curg->logic;

		curgm = curg->fgm;
		while(curgm) {
			if(!curgm->cfg_ptr) break;

			t = curgm->cfg_ptr->data;

			/* if any one group member is in unknown status, group is in unknown status */
			if(t->status == UNKNOWN) {
				status = UNKNOWN;
				break;
			}

			if(!curg->logic) {
				status |= (t->status == DOWN || t->status == LONG_DOWN) ? DOWN : t->status;
			} else {
				status &= (t->status == DOWN || t->status == LONG_DOWN) ? DOWN : t->status;
			}

			curgm = curgm->next;
		}
		if(status != curg->status) {
			if(status == UP) {
				/* group up event */
				if(cfg.debug >= 8) syslog(LOG_INFO, "group %s up event", curg->name);
				if(event_script_check(curg->eventscript)) {
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       curg->eventscript,
							       "up",
							       curg->name,
							       "NA",
							       "NA",
							       (curg->warn_email && *curg->warn_email) ? curg->warn_email : "-",
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       "NA",
							       status_str[curg->status],
							       current_time.tv_sec);
					envp = exec_queue_envp();

					if(curg->queue && *curg->queue) {
						exec_queue_add(curg->queue, argv, envp);
					} else {
						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}
				if((curg->unknown_up_notify || curg->status != UNKNOWN) && event_script_check(curg->notifyscript)) {
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       curg->notifyscript,
							       "up",
							       curg->name,
							       "NA",
							       "NA",
							       (curg->warn_email && *curg->warn_email) ? curg->warn_email : "-",
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       "NA",
							       status_str[curg->status],
							       current_time.tv_sec);
					envp = exec_queue_envp();

					forkexec(argv, envp);

					exec_queue_argv_free(argv);
					exec_queue_envp_free(envp);
				}
			}

			if(status == DOWN) {
				/* group down event */
				if(cfg.debug >= 8) syslog(LOG_INFO, "group %s down event", curg->name);
				if(event_script_check(curg->eventscript)) {
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       curg->eventscript,
							       "down",
							       curg->name,
							       "NA",
							       "NA",
							       (curg->warn_email && *curg->warn_email) ? curg->warn_email : "-",
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       "NA",
							       status_str[curg->status],
							       current_time.tv_sec);
					envp = exec_queue_envp();

					if(curg->queue && *curg->queue) {
						exec_queue_add(curg->queue, argv, envp);
					} else {
						forkexec(argv, envp);

						exec_queue_argv_free(argv);
						exec_queue_envp_free(envp);
					}
				}
				if(event_script_check(curg->notifyscript)) {
					char **argv;
					char **envp;

					argv = exec_queue_argv("%s %s %s %s %s %s %d %d %d %d %d %d %d %d %s %s %d",
							       curg->notifyscript,
							       "down",
							       curg->name,
							       "NA",
							       "NA",
							       (curg->warn_email && *curg->warn_email) ? curg->warn_email : "-",
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       0,
							       "NA",
							       status_str[curg->status],
							       current_time.tv_sec);
					envp = exec_queue_envp();

					forkexec(argv, envp);

					exec_queue_argv_free(argv);
					exec_queue_envp_free(envp);
				}
			}
			curg->status = status;
		}
		curg = curg->next;
	}
}

static int wait_for_replies(CONFIG **ctable) {
	struct ip *ip;
	int hlen = 0;
	struct icmp *icp;
	struct icmp6_hdr *icp6;
	PING_DATA *pdp;
	int this_count;
	struct timeval sent_time = {0, 0};
	struct timeval current_time = {0, 0};
	long time_diff;
	char buf[BUFSIZ];
	union {
		struct sockaddr_in6 saddr6;
		struct sockaddr_in saddr;
		struct sockaddr_ll FROM;
	} from_addr;
	unsigned int slen;
	int result;
	TARGET *t;
	int seq;
	CONFIG *arp;

	slen = sizeof(from_addr);
	result = ping_rcv(ctable[0], buf, BUFSIZ, (struct sockaddr_in6 *)&from_addr, &slen, DEFAULT_SELECT_WAIT, &arp);

	if(result <= 0) {
		return(0);
	}

	gettimeofday(&current_time, NULL);

	if(arp) {
		struct sockaddr_ll *FROM = &from_addr.FROM;
		TARGET *t = arp->data;
		struct arphdr *ah = (struct arphdr*)buf;
		unsigned char *p = (unsigned char *)(ah+1);
		struct in_addr src_ip, dst_ip;
		int ind;

		/* Filter out wild packets */
		if(FROM->sll_pkttype != PACKET_HOST &&
		   FROM->sll_pkttype != PACKET_BROADCAST &&
		   FROM->sll_pkttype != PACKET_MULTICAST)
			return(1);

		/* Only these types are recognised */
#if 0
		if(ah->ar_op != htons(ARPOP_REQUEST) &&
		   ah->ar_op != htons(ARPOP_REPLY))
			return(1);
#else
		if(ah->ar_op != htons(ARPOP_REPLY))
			return(1);
#endif

		/* ARPHRD check and this darned FDDI hack here :-( */
		if(ah->ar_hrd != htons(FROM->sll_hatype) &&
		   (FROM->sll_hatype != ARPHRD_FDDI || ah->ar_hrd != htons(ARPHRD_ETHER)))
			return(1);

		/* Protocol must be IP. */
		if(ah->ar_pro != htons(ETH_P_IP))
			return(1);
		if(ah->ar_pln != 4)
			return(1);
		if(ah->ar_hln != t->me.sll_halen)
			return(1);

#if defined(DEBUG)
		for(ind = 0; ind < result; ind ++) {
			fprintf(stderr, "%02x", (unsigned char)buf[ind]);
			if(!((ind + 1) % 2)) fprintf(stderr, " ");
			if(!((ind + 1) % 32)) fprintf(stderr, "\n");
		}
		fprintf(stderr, "\n");
		for(ind = 0; ind < result; ind ++) {
			fprintf(stderr, "%3u", (unsigned char)buf[ind]);
			if(!((ind + 1) % 32)) fprintf(stderr, "\n");
			else fprintf(stderr, ",");
		}
		fprintf(stderr, "\n");
#endif

		if(result < sizeof(*ah) + 2*(4 + ah->ar_hln))
			return(1);

		memcpy(&src_ip, p+ah->ar_hln, 4);
		memcpy(&dst_ip, p+ah->ar_hln+4+ah->ar_hln, 4);

		if(src_ip.s_addr != t->dst.s_addr)
			return(1);
		if(t->src.s_addr != dst_ip.s_addr)
			return(1);
		if(memcmp(p+ah->ar_hln+4, &t->me.sll_addr, ah->ar_hln))
			return(1);

		/* update packet log here */
		/* there are no sequence numbers in arp replies so just mark seq - 1 replied */
		ind = ((t->seq - 1) >= 0 ? (t->seq - 1) : (FOLLOWED_PKTS + (t->seq - 1))) % FOLLOWED_PKTS;
		t->sentpkts[ind].flags.replied = 1;
		t->sentpkts[ind].flags.waiting = 0;
		t->sentpkts[ind].replied_time = current_time;
		t->sentpkts[ind].rtt = timeval_diff(&current_time, &t->sentpkts[ind].sent_time);

		return(1);
	}

#if defined(DEBUG)
	if(cfg.debug >= 9) {
		char sbuf[INET6_ADDRSTRLEN];

		syslog(LOG_INFO, "not arp: family = %d, AF_INET = %d, AF_INET6 = %d, inet_ntop addr = %s, inet_ntoa addr = %s", from_addr.saddr6.sin6_family, AF_INET, AF_INET6, inet_ntop(from_addr.saddr6.sin6_family, &from_addr.saddr6.sin6_addr, sbuf, INET6_ADDRSTRLEN), inet_ntoa(from_addr.saddr.sin_addr));
	}
#endif

	switch(from_addr.saddr6.sin6_family) {
	case AF_INET:
#if defined(DEBUG)
		syslog(LOG_INFO, "%s: %s: AF_INET reply", __FILE__, __FUNCTION__);
#endif
		ip = (struct ip *)buf;
		hlen = ip->ip_hl << 2;

		icp = (struct icmp *)(buf + hlen);

		if(icp->icmp_type == ICMP_ECHO) {
			return(1);
		}

		if(icp->icmp_type == ICMP_ECHOREPLY) {
			if(icp->icmp_id != get_ident()) {
				/* fprintf(stderr, "icmp_id = %d funny, got reply from %s to something else ...\n", icp->icmp_id, inet_ntoa(saddr.sin_addr)); */
				return(1);
			}

			if(result < sizeof(struct icmp) + sizeof(PING_DATA)) {
				/* fprintf(stderr, "too short ping reply\n"); */
				return(1);
			}

			pdp = (PING_DATA *)(buf + hlen + sizeof(struct icmp));

			this_count = pdp->ping_count;
			sent_time = pdp->ping_ts;
			time_diff = timeval_diff(&current_time, &sent_time);

			if(pdp->id >= num_hosts) {
#if defined(DEBUG)
				syslog(LOG_INFO, "out of range: pdp->id = %d >= num_hosts = %d from %s", pdp->id, num_hosts, inet_ntoa(from_addr.saddr.sin_addr));
				dump_pkt(buf, sizeof(struct ip) + sizeof(struct icmp) + sizeof(PING_DATA));
				set_dump(1);
#endif
				return(1);
			}

			t = ctable[pdp->id]->data;

			if(memcmp(&ip->ip_src, &t->dst, sizeof(struct in_addr) != 0)) {
				return(1);
			}

			seq = icp->icmp_seq % FOLLOWED_PKTS;
			if(t->sentpkts[seq].seq == icp->icmp_seq) {
				t->sentpkts[seq].flags.replied = 1;
				t->sentpkts[seq].flags.waiting = 0;
				t->sentpkts[seq].replied_time = current_time;
				t->sentpkts[seq].rtt = timeval_diff(&current_time, &t->sentpkts[seq].sent_time);
			}
			else
				if(cfg.debug >= 9) syslog(LOG_INFO, "sentpkts seq != icmp_seq");

			if(cfg.debug >= 9) syslog(LOG_INFO, "received seq = %d from %s, id = %d, num_sent = %d, target id = %u, time_diff = %ld", icp->icmp_seq, inet_ntoa(from_addr.saddr.sin_addr), icp->icmp_id, this_count, pdp->id, time_diff);

			return(1);

		} else {
			struct icmpmsg *msg;

			msg = stricmp(icp->icmp_type, icp->icmp_code);

			if(cfg.debug >= 9) syslog(LOG_INFO, "got odd reply from %s, icmp_type = %d %s, icmp_code = %d %s", inet_ntoa(from_addr.saddr.sin_addr), icp->icmp_type, msg->type_msg, icp->icmp_code, msg->code_msg);

			return(1);
		}
		break;
	case AF_INET6:
#if defined(DEBUG)
		syslog(LOG_INFO, "%s: %s: AF_INET6 reply", __FILE__, __FUNCTION__);
#endif
		icp6 = (struct icmp6_hdr *)buf;

		if(icp6->icmp6_type == ICMP6_ECHO_REQUEST) {
			return(1);
		}

		if (icp6->icmp6_type == ICMP6_ECHO_REPLY) { /* v6 reply */
			char sbuf[INET6_ADDRSTRLEN];
#if defined(DEBUG)
			dump_pkt(buf, sizeof(struct icmp6_hdr) + sizeof(PING_DATA));
#endif
			/* syslog(LOG_INFO, "sizeof struct icmp6_hdr = %ld\n", sizeof(struct icmp6_hdr)); */

			if(icp6->icmp6_id != get_ident()) {
				return(1);
			}

			if(result < sizeof(struct icmp6_hdr) + sizeof(PING_DATA)) {
				return(1);
			}

			/* pdp = (PING_DATA *)(buf + hlen + sizeof(struct icmp6_hdr)); */
			/* pdp = (PING_DATA *)(buf + sizeof(struct icmp6_hdr)); */
			pdp = (PING_DATA *)(buf + sizeof(struct icmp6_hdr));

			this_count = pdp->ping_count;
			sent_time = pdp->ping_ts;
			time_diff = timeval_diff(&current_time, &sent_time);

#if defined(DEBUG)
			syslog(LOG_INFO, "%s: %s: this_count = %d, sent_time = %ld,%ld, pdp->id = %d", __FILE__, __FUNCTION__, this_count, sent_time.tv_sec, sent_time.tv_usec, pdp->id);
#endif

			if(pdp->id >= num_hosts) {
#if defined(DEBUG)
				syslog(LOG_INFO, "out of range: pdp->id = %d >= num_hosts = %d from %s", pdp->id, num_hosts, inet_ntop(AF_INET6, &from_addr.saddr6.sin6_addr, sbuf, INET6_ADDRSTRLEN));
				dump_pkt(buf, sizeof(struct icmp6_hdr) + sizeof(PING_DATA));
				set_dump(1);
#endif
				return(1);
			}

			t = ctable[pdp->id]->data;

			if(memcmp(&from_addr.saddr6.sin6_addr, &t->dst6, sizeof(struct in6_addr)) != 0) {
				return(1);
			}

			seq = ntohs(icp6->icmp6_seq) % FOLLOWED_PKTS;
			if(t->sentpkts[seq].seq == ntohs(icp6->icmp6_seq)) {
				t->sentpkts[seq].flags.replied = 1;
				t->sentpkts[seq].flags.waiting = 0;
				t->sentpkts[seq].replied_time = current_time;
				t->sentpkts[seq].rtt = timeval_diff(&current_time, &t->sentpkts[seq].sent_time);
			}
			else
				if (cfg.debug >= 9) syslog(LOG_INFO, "sentpkts seq != icmp_seq");

			if(cfg.debug >= 9) syslog(LOG_INFO, "received seq = %d from %s, id = %d, num_sent = %d, target id = %u, time_diff = %ld", ntohs(icp6->icmp6_seq), inet_ntop(AF_INET6, &from_addr.saddr6.sin6_addr, sbuf, INET6_ADDRSTRLEN), icp6->icmp6_id, this_count, pdp->id, time_diff);

			return(1);
		} else {
			char sbuf[INET6_ADDRSTRLEN];
			struct icmp6msg *msg;

			msg = stricmp6(icp6->icmp6_type, icp6->icmp6_code);

			if(cfg.debug >= 9) syslog(LOG_INFO, "got odd reply from %s, icmp_type = %d %s, icmp_code = %d %s", inet_ntop(from_addr.saddr6.sin6_family, &from_addr.saddr6.sin6_addr, sbuf, INET6_ADDRSTRLEN), icp6->icmp6_type, msg->type_msg, icp6->icmp6_code, msg->code_msg);

			return(1);
		}
		break;
	default:
		syslog(LOG_INFO, "%s: %s: unknown family reply", __FILE__, __FUNCTION__);
		break;
	}

	return(1);
}

static int ping_rcv(CONFIG *first, char *buf, int len, struct sockaddr_in6 *saddr, unsigned int *slen, long usec, CONFIG **arp) {
	int nfound, n;
	fd_set readset;
	struct timeval to = {0, 0};
	int max;
	CONFIG *cur;
	TARGET *t;
	int cnt_targets = 0;

	FD_ZERO(&readset);
	max = 0;

	for(cur = first; cur; cur = cur->next) {
		t = cur->data;
		if(t->sock == -1) continue;
		if(t->sock > max) max = t->sock;
		FD_SET(t->sock, &readset);
		cnt_targets++;
	}

	/* no point in calling select if we didn't find any open sockets. so sleep and return ... */
	if(cnt_targets == 0) {
		sleep(1);
		return(0);
	}

	to.tv_sec = usec / 1000000;
	to.tv_usec = (usec - (to.tv_sec * 1000000));

#if defined(DEBUG)
	printf("to.tv_sec = %ld, to.tv_usec = %ld\n", to.tv_sec, to.tv_usec);
#endif

	nfound = select(max + 1, &readset, NULL, NULL, &to);

	if(nfound < 0) {
		if(errno != EINTR) syslog(LOG_INFO, "select failed \"%s\"", strerror(errno));
		return(0);
	}

	if(nfound == 0) return(-1);

	for(cur = first; cur; cur = cur->next) {
		t = cur->data;
		if(t->sock == -1) continue;
		if(FD_ISSET(t->sock, &readset)) {
			if(!cur->check_arp) {
				*arp = (CONFIG *)NULL;
			} else {
				*arp = cur;
			}

			n = recvfrom(t->sock, buf, len, 0, (struct sockaddr *)saddr, slen);

			if(n < 0) {
				syslog(LOG_INFO, "recvfrom failed with %s \"%s\"\n", cur->name, strerror(errno));
				close(t->sock);
				t->sock = -1;
				return(0);
			}

			return(n);
		}
	}
	return(0);
}

static int ping_send(CONFIG *cur) {
	char buf[BUFSIZ];
	struct icmp *icp;
	PING_DATA *pdp;
	TARGET *t;
	int n;
	int ping_pkt_size;

	t = cur->data;

	gettimeofday(&t->last_send_time, NULL);

	if(cur->check_arp) {
		int err;
		unsigned char buf[256];
		struct arphdr *ah = (struct arphdr*)buf;
		unsigned char *p = (unsigned char *)(ah+1);

		if(cur->dstinfo->ai_family == AF_INET6) {
			syslog(LOG_ERR, "%s: %s: ipv6 arping not supported", __FILE__, __FUNCTION__);
			return(-1);
		}

		ah->ar_hrd = htons(t->me.sll_hatype);
		if(ah->ar_hrd == htons(ARPHRD_FDDI))
			ah->ar_hrd = htons(ARPHRD_ETHER);
		ah->ar_pro = htons(ETH_P_IP);
		ah->ar_hln = t->me.sll_halen;
		ah->ar_pln = 4;
		ah->ar_op = htons(ARPOP_REQUEST);

		memcpy(p, &t->me.sll_addr, ah->ar_hln);
		p += t->me.sll_halen;

		memcpy(p, &t->src, 4);
		p += 4;

		memcpy(p, &t->he.sll_addr, ah->ar_hln);
		p += ah->ar_hln;

		memcpy(p, &t->dst, 4);
		p += 4;

#if defined(DEBUG)
		{
			int ind;
			for(ind = 0; ind < p - buf; ind ++) {
				fprintf(stderr, "%02x", (unsigned char)buf[ind]);
				if(!((ind + 1) % 2)) fprintf(stderr, " ");
				if(!((ind + 1) % 32)) fprintf(stderr, "\n");
			}
			fprintf(stderr, "\n");
			for(ind = 0; ind < p - buf; ind ++) {
				fprintf(stderr, "%3u", (unsigned char)buf[ind]);
				if(!((ind + 1) % 32)) fprintf(stderr, "\n");
				else fprintf(stderr, ",");
			}
			fprintf(stderr, "\n");
		}
#endif

		if(t->sock != -1) {
			err = sendto(t->sock, buf, p - buf, 0, (struct sockaddr*)&t->he, sizeof(t->he));
			if(err < 0) {
				if(cfg.debug >= 9) syslog(LOG_ERR, "arping sendto failed to %s on %s reason \"%s\"", cur->name, cur->device, strerror(errno));
				close(t->sock);
				t->sock = -1;
			}
		} else {
			if(cfg.debug >= 9) syslog(LOG_INFO, "arping sendto socket not open for %s", cur->name);
			err = -1;
		}

		{ /* we don't care what the error was just advance with seq */
			int seq;

			seq = t->seq % FOLLOWED_PKTS;
			t->sentpkts[seq].seq = t->seq;
			t->sentpkts[seq].sent_time = t->last_send_time;
			t->sentpkts[seq].flags.replied = 0;
			t->sentpkts[seq].flags.timeout = 0;
			t->sentpkts[seq].flags.waiting = 1;
			t->sentpkts[seq].flags.used = 1;
			t->sentpkts[seq].flags.error = (err == -1) ? 1 : 0;

			t->seq = (t->seq + 1) % SEQ_LIMITER; /* limit seq so that consecutive missing and received pkt counting doesn't get confused when seq "overflows" */
			t->num_sent++;

		}
		if(err == (p - buf)) {
			return(0);
		}
		return(err);
	}

	if(cur->dstinfo->ai_family == AF_INET6) {
		struct icmp6_hdr *icp6;

		ping_pkt_size = sizeof(struct icmp6_hdr) + sizeof(PING_DATA);

		memset(buf, 0, ping_pkt_size);

		icp6 = (struct icmp6_hdr *)buf;

		icp6->icmp6_type = ICMP6_ECHO_REQUEST;
		icp6->icmp6_code = 0;
		icp6->icmp6_seq = htons(t->seq); /* I saw a tcpdump suggesting that there is something wrong with seq thus htons() */
		icp6->icmp6_id = get_ident();

		pdp = (PING_DATA *)(buf + sizeof(struct icmp6_hdr));
		pdp->ping_count = t->num_sent;
		pdp->ping_ts = t->last_send_time;
		pdp->id = t->id;

		icp6->icmp6_cksum = 0; /* the ipv6 stack calculates the checksum for us */

		if(t->sock != -1) {
			if(cfg.debug >= 9) syslog(LOG_INFO, "cmsglen = %d", t->cmsglen);

			if(t->cmsglen == 0) {
				n = sendto(t->sock, buf, ping_pkt_size, 0, (struct sockaddr *)&t->dst_addr6, sizeof(t->dst_addr6));
				if(n < 0) {
					if(errno == ENODEV) {
						if(cfg.debug >= 9) syslog(LOG_ERR, "connection %s no such device %s \"%s\"", cur->name, cur->device, strerror(errno));
					} else
						if (cfg.debug >= 9) syslog(LOG_ERR, "ping6 sendto failed to %s on %s reason \"%s\"", cur->name, cur->device, strerror(errno));

					if(t->sock != -1) {
						close(t->sock);
						t->sock = -1;
					}
				}
			} else {
				struct msghdr mhdr;
				struct iovec iov;
				int confirm = 0;

				iov.iov_len = ping_pkt_size;
				iov.iov_base = buf;

				mhdr.msg_name = &t->dst_addr6;
				mhdr.msg_namelen = sizeof(struct sockaddr_in6);
				mhdr.msg_iov = &iov;
				mhdr.msg_iovlen = 1;
				mhdr.msg_control = t->cmsgbuf;
				mhdr.msg_controllen = t->cmsglen;

				n = sendmsg(t->sock, &mhdr, confirm);
				if(cfg.debug >= 9 && n < 0) syslog(LOG_INFO, "sendmsg failed for %s %s", cur->name, strerror(errno));
				if(n < 0) {
					close(t->sock);
					t->sock = -1;
				}
			}
		} else {
			if(cfg.debug >= 9) syslog(LOG_INFO, "ping sendto socket not open for %s", cur->name);
			n = -1;
		}
		{
			/* we don't care what the error was just advance with seq */
			int seq;

			seq = t->seq % FOLLOWED_PKTS;
#if defined(DEBUG)
			fprintf(stderr, "ping_send seq = %ld to %s, num_sent = %ld, %ld, pkt_size = %d\n", t->seq, inet_ntoa(t->saddr.sin_addr), t->num_sent, pdp->ping_count, ping_pkt_size);
#endif
			t->sentpkts[seq].seq = t->seq;
			t->sentpkts[seq].sent_time = t->last_send_time;
			t->sentpkts[seq].flags.replied = 0;
			t->sentpkts[seq].flags.timeout = 0;
			t->sentpkts[seq].flags.waiting = 1;
			t->sentpkts[seq].flags.used = 1;
			t->sentpkts[seq].flags.error = (n < 1) ? 1 : 0;

			t->seq = (t->seq + 1) % SEQ_LIMITER;
			/* limit seq so that consecutive missing and received pkt counting doesn't get confused when seq "overflows" */
			t->num_sent++;
		}
		if(n == ping_pkt_size) {
			return(0);
		}

		return(n);
	}

	/* send a ping packet */
	ping_pkt_size = sizeof(struct icmp) + sizeof(PING_DATA);

	memset(buf, 0, ping_pkt_size);

	icp = (struct icmp *)buf;

	icp->icmp_type = ICMP_ECHO;
	icp->icmp_code = 0;
	icp->icmp_cksum = 0;
	icp->icmp_seq = t->seq;
	icp->icmp_id = get_ident();

	pdp = (PING_DATA *)(buf + sizeof(struct icmp));
	pdp->ping_count = t->num_sent;
	pdp->ping_ts = t->last_send_time;
	pdp->id = t->id;

	icp->icmp_cksum = in_cksum((u_short *)icp, ping_pkt_size);

	if(t->sock != -1) {
		n = sendto(t->sock, buf, ping_pkt_size, 0, (struct sockaddr *)&t->dst_addr, sizeof(struct sockaddr));

		if(n < 0) {
			if(errno == ENODEV) {
				if(cfg.debug >= 9) syslog(LOG_ERR, "connection %s no such device %s \"%s\"", cur->name, cur->device, strerror(errno));
				/* exit(2); */ /* commented out. handle this situation like the packet had been sent. see below.  */
			}
			else
				if(cfg.debug >= 9) syslog(LOG_ERR, "ping sendto failed to %s on %s reason \"%s\"", cur->name, cur->device, strerror(errno));

			if(t->sock != -1) {
				close(t->sock);
				t->sock = -1;
			}
		}
	} else {
		if(cfg.debug >= 9) syslog(LOG_INFO, "ping sendto socket not open for %s", cur->name);
		n = -1;
	}

	{ /* we don't care what the error was just advance with seq */
		int seq;

		seq = t->seq % FOLLOWED_PKTS;
#if defined(DEBUG)
		fprintf(stderr, "ping_send seq = %ld to %s, num_sent = %ld, %ld, pkt_size = %d\n", t->seq, inet_ntoa(t->saddr.sin_addr), t->num_sent, pdp->ping_count, ping_pkt_size);
#endif
		t->sentpkts[seq].seq = t->seq;
		t->sentpkts[seq].sent_time = t->last_send_time;
		t->sentpkts[seq].flags.replied = 0;
		t->sentpkts[seq].flags.timeout = 0;
		t->sentpkts[seq].flags.waiting = 1;
		t->sentpkts[seq].flags.used = 1;
		t->sentpkts[seq].flags.error = (n < 1) ? 1 : 0;

		t->seq = (t->seq + 1) % SEQ_LIMITER; /* limit seq so that consecutive missing and received pkt counting doesn't get confused when seq "overflows" */
		t->num_sent++;
	}

	if(n == ping_pkt_size) {
		return(0);
	}
	return(n);
}

static void usage(void) {
#if defined(LSM_VERSION)
        printf("    %s version %s\n", get_prog(), LSM_VERSION);
#endif
	printf("    usage: %s <config_file> [pid_file]\n", get_prog()); /* ... */
	printf("    check syslog for debug/error messages\n");
}

static int event_script_check(const char *path)
{
	struct stat statbuf;

	if(!path) {
		if(cfg.debug >= 9) syslog(LOG_ERR, "NULL pointer event script");
		return(0);
	}

	if(!*path) {
		if(cfg.debug >= 9) syslog(LOG_ERR, "null string event script");
		return(0);
	}

	/* check that the script is owner executable */
	if(stat(path, &statbuf) == -1) {
		syslog(LOG_ERR, "failed to stat event script \"%s\" reason \"%s\"", path, strerror(errno));
		return(0);
	}

	if((statbuf.st_mode & S_IXUSR) == 0) {
		syslog(LOG_ERR, "event script \"%s\" is not executable by owner, please check permissions", path);
		return(0);
	}

	return(1);
}

static void init_config_data(CONFIG *first, CONFIG *last, CONFIG ***ctable)
{
	int i;
	CONFIG *cur;
	TARGET *t = NULL;

	/* initialize config->data */
	for(cur = first, num_hosts = 0; cur; cur = cur->next, num_hosts++) {
		u_int ipaddress;

		if((t = malloc(sizeof(TARGET))) == NULL) {
			syslog(LOG_ERR, "main: initializing targets failed to malloc");
			exit(1);
		}
		memset(t, 0, sizeof(TARGET));

		cur->data = t;

		/* protocol family independent init */
		t->seq = 0;
		t->downseq = 0;
		t->downseqreported = 0;
		t->last_send_time.tv_sec = 0;
		t->last_send_time.tv_usec = 0;
		t->num_sent = 0;

		memset(t->cmsgbuf, 0, sizeof(t->cmsgbuf));
		t->cmsglen = 0;

		t->id = num_hosts;

		/* get initial connection state assumption from config */
		t->status = cur->status;

		t->sock = -1;

		if(cur->dstinfo->ai_family == AF_INET6) {
			/* ipv6 init */
			if(cur->srcinfo) {
				if(inet_pton(AF_INET6, cur->sourceip, &t->src6) != 1) {
					syslog(LOG_ERR, "%s: %s: src6 inet_pton failed for %s", __FILE__, __FUNCTION__, cur->name);
				}

				t->src_addr6.sin6_family = cur->srcinfo->ai_family;
				if(inet_pton(AF_INET6, cur->sourceip, &t->src_addr6.sin6_addr) != 1) {
					syslog(LOG_ERR, "%s: %s: src6 inet_pton failed for %s", __FILE__, __FUNCTION__, cur->name);
				}
			}

			if(inet_pton(AF_INET6, cur->checkip, &t->dst6) != 1) {
				syslog(LOG_ERR, "%s: %s: dst6 inet_pton failed for %s", __FILE__, __FUNCTION__, cur->name);
			}

			t->dst_addr6.sin6_family = cur->dstinfo->ai_family;
			if(inet_pton(AF_INET6, cur->checkip, &t->dst_addr6.sin6_addr) != 1) {
				syslog(LOG_ERR, "%s: %s: dst6 inet_pton failed for %s", __FILE__, __FUNCTION__, cur->name);
			}
		} else {
			/* ipv4 init */
			ipaddress = inet_addr(cur->checkip);
			t->dst_addr.sin_family = AF_INET;
			t->dst_addr.sin_addr = *((struct in_addr *)&ipaddress);
			t->dst = *((struct in_addr *)&ipaddress);
		}
	}

	if(((*ctable) = (CONFIG **)malloc(sizeof(CONFIG *) * num_hosts)) == NULL) {
		syslog(LOG_ERR, "main: can't malloc for ctable");
		exit(1);
	}

	/* create pointer table */
	for(cur = first, i = 0; cur; cur = cur->next, i++) {
		(*ctable)[i] = cur;
	}

}

static int open_arp_sock(CONFIG *cur)
{
	int ifindex = 0;
	TARGET *t = (TARGET *)cur->data;

	if(t->sock != -1) return(0);

	if(cur->dstinfo->ai_family == AF_INET6) {
		syslog(LOG_ERR, "%s: %s: protocol family is ipv6?", __FILE__, __FUNCTION__);
		return(1);
	}

	t->sock = socket(PF_PACKET, SOCK_DGRAM, 0);
	if(t->sock < 0) {
		syslog(LOG_ERR, "could not open socket for %s arp ping \"%s\"", cur->name, strerror(errno));
		t->sock = -1;
		return(1);
	}
	if(fcntl(t->sock, F_SETFD, FD_CLOEXEC) == -1) {
		syslog(LOG_ERR, "failed to set close on exec on socket %s reason \"%s\"", cur->name, strerror(errno));
	}

	if(cur->device && *cur->device) {
		struct ifreq ifr;

		memset(&ifr, 0, sizeof(ifr));
		strncpy(ifr.ifr_name, cur->device, IFNAMSIZ-1);
		if(ioctl(t->sock, SIOCGIFINDEX, &ifr) < 0) {
			syslog(LOG_ERR, "unknown iface \"%s\"", cur->device);
			close(t->sock);
			t->sock = -1;
			return(2);
		}
		ifindex = ifr.ifr_ifindex;

		if(ioctl(t->sock, SIOCGIFFLAGS, (char*)&ifr)) {
			syslog(LOG_ERR, "ioctl(SIOCGIFFLAGS) \"%s\"", strerror(errno));
			close(t->sock);
			t->sock = -1;
			return(2);
		}
		if(!(ifr.ifr_flags&IFF_UP)) {
			syslog(LOG_ERR, "Interface \"%s\" is down", cur->device);
			close(t->sock);
			t->sock = -1;
			return(2);
		}
		if(ifr.ifr_flags&(IFF_NOARP|IFF_LOOPBACK)) {
			syslog(LOG_ERR, "Interface \"%s\" is not ARPable", cur->device);
			close(t->sock);
			t->sock = -1;
			return(2);
		}
	}

	if(inet_aton(cur->checkip, &t->dst) != 1) {
	  struct hostent *hp;
	  hp = gethostbyname2(cur->checkip, AF_INET);
	  if(!hp) {
	    syslog(LOG_ERR, "unknown host %s\n", cur->checkip);
	    close(t->sock);
	    t->sock = -1;
	    return(2);
	  }
	  memcpy(&t->dst, hp->h_addr, 4);
	}

	if(cur->sourceip && *cur->sourceip)
		if(inet_aton(cur->sourceip, &t->src) != 1) {
		  syslog(LOG_ERR, "invalid source %s\n", cur->sourceip);
		  close(t->sock);
		  t->sock = -1;
		  return(2);
		}

	syslog(LOG_INFO,"attempting to probe IP address of device \"%s\"",cur->device);
	if(probe_src_ip_addr(cur) != 0) {
	  close(t->sock);
	  t->sock = -1;
	  return(2);
	}
	syslog(LOG_INFO,"successfully probed IP address of device \"%s\": got \"%s\"",cur->device,inet_ntoa(t->src));

	t->me.sll_family = AF_PACKET;
	t->me.sll_ifindex = ifindex;
	t->me.sll_protocol = htons(ETH_P_ARP);
	if(bind(t->sock, (struct sockaddr*)&t->me, sizeof(t->me)) == -1) {
		syslog(LOG_ERR, "bind \"%s\"", strerror(errno));
		close(t->sock);
		t->sock = -1;
		return(2);
	}

	{
		int alen = sizeof(t->me);
		if(getsockname(t->sock, (struct sockaddr*)&t->me, (socklen_t*)&alen) == -1) {
			syslog(LOG_ERR, "getsockname \"%s\"", strerror(errno));
			close(t->sock);
			t->sock = -1;
			return(2);
		}
	}
	if(t->me.sll_halen == 0) {
		syslog(LOG_ERR, "Interface \"%s\" is not ARPable (no ll address)", cur->device);
		close(t->sock);
		t->sock = -1;
		return(2);
	}

	t->he = t->me;
	memset(t->he.sll_addr, -1, min(t->he.sll_halen, sizeof t->he.sll_addr));

#if 0
	printf("ARPING %s ", inet_ntoa(t->dst));
	printf("from %s %s\n",  inet_ntoa(t->src), cur->device ? : "");
#endif

	if(!t->src.s_addr) {
		syslog(LOG_ERR, "no source address for %s", cur->name);
		close(t->sock);
		t->sock = -1;
		return(2);
	}
	if(cur->ttl) {
		int ittl = cur->ttl;
		if(setsockopt(t->sock, IPPROTO_IP, IP_MULTICAST_TTL,
			      &cur->ttl, 1) == -1) {
			syslog(LOG_ERR, "can't set multicast time-to-live \"%s\"", strerror(errno));
			close(t->sock);
			t->sock = -1;
			return(2);
		}
		if(setsockopt(t->sock, IPPROTO_IP, IP_TTL,
			      &ittl, sizeof(ittl)) == -1) {
			syslog(LOG_ERR, "can't set unicast time-to-live \"%s\"", strerror(errno));
			close(t->sock);
			t->sock = -1;
			return(2);
		}
	}

	return(0);
}

static int open_icmp_sock(CONFIG *cur)
{
	TARGET *t = (TARGET *)cur->data;
	struct protoent *proto;
	int pf = cur->dstinfo->ai_family;

	if(t->sock != -1) return(0);

	if(pf == AF_INET6) {
		if((proto = getprotobyname("ipv6-icmp")) == NULL) {
			syslog(LOG_ERR, "no ipv6-icmp proto found");
			return(1);
		}
	} else {
		if((proto = getprotobyname("icmp")) == NULL) {
			syslog(LOG_ERR, "no icmp proto found");
			return(1);
		}
	}

	t->sock = socket(pf, SOCK_RAW, proto->p_proto);

	if(t->sock < 0) {
		syslog(LOG_ERR, "could not open socket for ping target \"%s\" reason \"%s\"\n", cur->name, strerror(errno));
		t->sock = -1;
		return(1);
	}
	if(fcntl(t->sock, F_SETFD, FD_CLOEXEC) == -1) {
		syslog(LOG_ERR, "failed to set close on exec on socket %s reason \"%s\"", cur->name, strerror(errno));
	}

	if(pf == AF_INET6) {
		int opton = 1;

#ifdef IPV6_RECVHOPOPTS
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVHOPOPTS, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVHOPOPTS)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#else  /* old adv. API */
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_HOPOPTS, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_HOPOPTS)");
			close(t->sock);
			t->sock = -1;
			return(s);
		}
#endif
#ifdef IPV6_RECVDSTOPTS
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVDSTOPTS, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVDSTOPTS)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#else  /* old adv. API */
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_DSTOPTS, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_DSTOPTS)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
#ifdef IPV6_RECVRTHDRDSTOPTS
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVRTHDRDSTOPTS, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVRTHDRDSTOPTS)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
#ifdef IPV6_RECVRTHDR
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVRTHDR, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVRTHDR)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#else  /* old adv. API */
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RTHDR, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RTHDR)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
#ifndef USE_SIN6_SCOPE_ID
#ifdef IPV6_RECVPKTINFO
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVPKTINFO, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVPKTINFO)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#else  /* old adv. API */
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_PKTINFO, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_PKTINFO)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
#endif /* USE_SIN6_SCOPE_ID */
#ifdef IPV6_RECVHOPLIMIT
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_RECVHOPLIMIT, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_RECVHOPLIMIT)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#else  /* old adv. API */
		if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_HOPLIMIT, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(IPV6_HOPLIMIT)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
#ifdef IPV6_CHECKSUM
#ifndef SOL_RAW
#define SOL_RAW IPPROTO_IPV6
#endif
		opton = 2;

		if(setsockopt(t->sock, SOL_RAW, IPV6_CHECKSUM, &opton,
			      sizeof(opton))) {
			syslog(LOG_ERR, "setsockopt(SOL_RAW,IPV6_CHECKSUM)");
			close(t->sock);
			t->sock = -1;
			return(2);
		}
#endif
	}

	if(pf == AF_INET6) {
		int hold = 1;

		ICMP6_FILTER_SETBLOCKALL(&t->filter);

		if (setsockopt(t->sock, SOL_IPV6, IPV6_RECVERR, (char *)&hold, sizeof(hold))) {
			syslog(LOG_INFO, "WARNING: your kernel is veeery old. No problems.");

			ICMP6_FILTER_SETPASS(ICMP6_DST_UNREACH, &t->filter);
			ICMP6_FILTER_SETPASS(ICMP6_PACKET_TOO_BIG, &t->filter);
			ICMP6_FILTER_SETPASS(ICMP6_TIME_EXCEEDED, &t->filter);
			ICMP6_FILTER_SETPASS(ICMP6_PARAM_PROB, &t->filter);
		}

		ICMP6_FILTER_SETPASS(ICMP6_ECHO_REPLY, &t->filter);

		if(setsockopt(t->sock, IPPROTO_ICMPV6, ICMP6_FILTER, &t->filter, sizeof(struct icmp6_filter)) < 0) {
			syslog(LOG_ERR, "setsockopt(ICMP6_FILTER)");
			return(2);
		}
	}

	if(cur->ttl) {
		if(pf == AF_INET6) {
			if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_MULTICAST_HOPS,
				       &cur->ttl, sizeof(cur->ttl)) == -1) {
				syslog(LOG_ERR, "can't set multicast hop limit \"%s\"", strerror(errno));
				close(t->sock);
				t->sock = -1;
				return(2);
			}
			if(setsockopt(t->sock, IPPROTO_IPV6, IPV6_UNICAST_HOPS,
				       &cur->ttl, sizeof(cur->ttl)) == -1) {
				syslog(LOG_ERR, "can't set unicast hop limit \"%s\"", strerror(errno));
				close(t->sock);
				t->sock = -1;
				return(2);
			}
		} else if(pf == AF_INET) { /* AF_INET */
			int ittl = cur->ttl;
			if(setsockopt(t->sock, IPPROTO_IP, IP_MULTICAST_TTL,
			      &cur->ttl, 1) == -1) {
				syslog(LOG_ERR, "can't set multicast time-to-live \"%s\"", strerror(errno));
				close(t->sock);
				t->sock = -1;
				return(2);
			}
			if(setsockopt(t->sock, IPPROTO_IP, IP_TTL,
				      &ittl, sizeof(ittl)) == -1) {
				syslog(LOG_ERR, "can't set unicast time-to-live \"%s\"", strerror(errno));
				close(t->sock);
				t->sock = -1;
				return(2);
			}
		}
	}

	/* LS -- doesn't work with virtual devices!
	   We achieve the same effect by binding to the device's IP address later in probe_src_ip_addr().
	*/
	if(pf == AF_INET && cur->device && *cur->device && !strchr(cur->device,':')) {
	  syslog(LOG_INFO,"calling setsockopt to bind to device \"%s\"",cur->device);
	  if(setsockopt(t->sock, SOL_SOCKET, SO_BINDTODEVICE, cur->device, strlen(cur->device) + 1) == -1) {
	    syslog(LOG_INFO, "failed to bind to ping interface device \"%s\", \"%s\"", cur->device, strerror(errno));
	    close(t->sock);
	    t->sock = -1;
	    return(2);
	  }
	  syslog(LOG_INFO,"calling setsockopt was successful");
	}

#if defined(DEBUG)
	if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: probing for src ip for %s", __FILE__, __FUNCTION__, cur->name);
#endif
	if(probe_src_ip_addr(cur) != 0) {
		close(t->sock);
		t->sock = -1;
		return(2);
	}
#if defined(DEBUG)
	if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: probing for src ip for %s done", __FILE__, __FUNCTION__, cur->name);
#endif

	// EXPERIMENTAL -LS
	if (t->dst_addr.sin_family == AF_INET) {
	  syslog(LOG_INFO,"binding %s to %s\n",cur->device,inet_ntoa(t->src));
	  memset(&bind_addr, 0, sizeof(bind_addr));
	  bind_addr.sin_family = AF_INET;
	  bind_addr.sin_addr   = t->src;
	  if(bind(t->sock, &bind_addr, sizeof(bind_addr)) != 0) {
	    syslog(LOG_ERR, "ping can't bind \"%s\"", strerror(errno));
	    return(1);
	  }
	  syslog(LOG_INFO,"binding was successful");
	}
	
	// This seems unlikely to work....
	else if(cur->sourceip && *cur->sourceip) {
	  syslog(LOG_INFO,"using sourceip-based binding of %s to %s\n",cur->device,cur->sourceip);
	  if(cur->srcinfo->ai_family == AF_INET) {
	    memset(&bind_addr, 0, sizeof(bind_addr));
	    bind_addr.sin_family      = AF_INET;
	    bind_addr.sin_addr.s_addr = inet_addr(cur->sourceip);
	    if(bind(t->sock, &bind_addr, sizeof(bind_addr)) != 0) {
	      syslog(LOG_ERR, "ping can't bind \"%s\"", strerror(errno));
	      return(1);
	    }
	    syslog(LOG_INFO,"sourceip-based binding was successful");	    
	  } else {
	    struct sockaddr_in6 addr;
#if defined(DEBUG)
	    if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: setting v6 src addr", __FILE__, __FUNCTION__);
#endif
	    memset(&addr, 0, sizeof(addr));
	    addr.sin6_family = AF_INET6;
	    if(inet_pton(AF_INET6, cur->sourceip, &addr.sin6_addr) != 1) {
	      syslog(LOG_ERR, "ping6 failed to convert connection %s address %s", cur->name, cur->sourceip);
	      return(1);
	    }
	    if(bind(t->sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
	      syslog(LOG_ERR, "ping6 can't bind %s to %s, \"%s\"", cur->name, cur->sourceip, strerror(errno));
	      return(1);
	    }
#if defined(DEBUG)
	    if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: setting v6 src addr done", __FILE__, __FUNCTION__);
#endif
	  }
	}

	if(pf == AF_INET6 && cur->device && *cur->device) {
	  struct ifreq ifr;
	  struct cmsghdr *cmsg;
	  struct in6_pktinfo *ipi;
	  
	  memset(&ifr, 0, sizeof(ifr));
	  strncpy(ifr.ifr_name, cur->device, IFNAMSIZ-1);
	  if(ioctl(t->sock, SIOCGIFINDEX, &ifr) < 0) {
	    syslog(LOG_ERR, "ping6 unknown iface %s", cur->device);
	    return(2);
	  }

	  memset(&t->cmsgbuf, 0, sizeof(t->cmsgbuf));
	  t->cmsglen = 0;

	  cmsg = (struct cmsghdr *)t->cmsgbuf;
	  t->cmsglen += CMSG_SPACE(sizeof(*ipi));
	  cmsg->cmsg_len = CMSG_LEN(sizeof(*ipi));
	  cmsg->cmsg_level = SOL_IPV6;
	  cmsg->cmsg_type = IPV6_PKTINFO;
	  
	  ipi = (struct in6_pktinfo *)CMSG_DATA(cmsg);
	  memset(ipi, 0, sizeof(*ipi));
	  ipi->ipi6_ifindex = ifr.ifr_ifindex;
	}

	return(0);
}

static int probe_src_ip_addr(CONFIG *cur)
{ /* probe for src ip address */
	TARGET *t = (TARGET *)cur->data;
	int probe_fd;
	int pf = cur->dstinfo->ai_family;

	probe_fd = socket(pf, SOCK_DGRAM, 0);

	if(probe_fd < 0) {
		syslog(LOG_ERR, "ping probe socket for %s failed \"%s\"", cur->name, strerror(errno));
		return(2);
	}
	if(fcntl(t->sock, F_SETFD, FD_CLOEXEC) == -1) {
		syslog(LOG_ERR, "ping probe failed to set close on exec on probe socket for %s reason \"%s\"", cur->name, strerror(errno));
	}

	if(cur->device && *cur->device && !strchr(cur->device,':')) {
		if(setsockopt(probe_fd, SOL_SOCKET, SO_BINDTODEVICE, cur->device, strlen(cur->device) + 1) == -1)
			syslog(LOG_INFO, "WARNING: ping probe interface \"%s\" is ignored for %s reason \"%s\"", cur->device, cur->name, strerror(errno));
	}

	if(pf == AF_INET) {
		struct sockaddr_in saddr;
		memset(&saddr, 0, sizeof(saddr));
		saddr.sin_family = AF_INET;
		if(t->src.s_addr) {
		  syslog(LOG_INFO,"reusing previously assigned address for \"%s\"",cur->device);		  
		  saddr.sin_addr = t->src;
		  if(bind(probe_fd, (struct sockaddr*)&saddr, sizeof(saddr)) == -1) {
		    syslog(LOG_ERR, "ping probe bind failed for %s \"%s\"", cur->name, strerror(errno));
		    close(probe_fd);
		    /* earlier probed src addr is not usable, wipe it */
		    memset(&t->src, 0, sizeof(t->src));
		    return(2);
		  }
		}
		else { /* LS -- modified original logic to use SIOCGIFADDR ioctl to get interface address instead of relying on routing */
		  syslog(LOG_INFO,"using SIOCGIFADDR ioctl to get interface address for \"%s\"",cur->device);
		  struct ifreq ifr;
		  bzero((void*)&ifr,sizeof(struct ifreq));
		  strncpy(ifr.ifr_name,cur->device,IFNAMSIZ-1);
		  ifr.ifr_addr.sa_family = pf;
		  if (ioctl(probe_fd,SIOCGIFADDR,&ifr)) {
		    syslog(LOG_ERR,"ioctl probe of current ip address for device %s failed \"%s\"",cur->device,strerror(errno));
		    return(2);
		  }
		  t->src = ((struct sockaddr_in*) &ifr.ifr_addr)->sin_addr;
		}
	} else if (pf == AF_INET6) { /* not AF_INET */
		struct sockaddr_in6 saddr;
		unsigned char nulladdr[] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};

		memset(&saddr, 0, sizeof(saddr));
		saddr.sin6_family = AF_INET6;
		if(memcmp(&t->src6, nulladdr, sizeof(t->src6)) != 0) { /* is not null addr */
			memcpy(&saddr.sin6_addr, &t->src6, sizeof(t->src6));
			if(bind(probe_fd, (struct sockaddr *)&saddr, sizeof(saddr)) == -1) {
				syslog(LOG_ERR, "ping6 probe bind failed for %s \"%s\"", cur->name,strerror(errno));
				close(probe_fd);
				/* earlier probed src addr is not usable, wipe it */
				memset(&t->src6, 0, sizeof(t->src6));
				return(2);
			}
		} else { /* is null addr */
			socklen_t alen = sizeof(saddr);

			saddr.sin6_port = htons(1025);
			saddr.sin6_family = cur->dstinfo->ai_family;
			memcpy(&saddr.sin6_addr, &t->dst6, sizeof(t->dst6));
#if 0
			if(setsockopt(probe_fd, SOL_SOCKET, SO_DONTROUTE, (char *)&on, sizeof(on)) == -1)
				syslog(LOG_INFO, "WARNING: ping6 probe setsockopt(SO_DONTROUTE) for %s \"%s\"", cur->name, strerror(errno));
#endif
			if(connect(probe_fd, (struct sockaddr *)&saddr, sizeof(saddr)) == -1) {
				syslog(LOG_ERR, "ping6 probe connect for %s failed \"%s\"", cur->name, strerror(errno));
				close(probe_fd);
				return(2);
			}
			if(getsockname(probe_fd, (struct sockaddr *)&saddr, &alen) == -1) {
				syslog(LOG_ERR, "ping6 probe getsockname for %s failed \"%s\"", cur->name, strerror(errno));
				close(probe_fd);
				return(2);
			}
			memcpy(&t->src6, &saddr.sin6_addr, sizeof(saddr.sin6_addr));
		}
	} /* if AF_INET */

	close(probe_fd);

	return(0);
}

#if defined(DEBUG)
static void dump_pkt(const void *buf, size_t len)
{
	int i;
	unsigned char *s;
	char obuf[BUFSIZ];
	char *pad;

	memset(obuf, 0, BUFSIZ);

	s = (unsigned char *)buf;
	pad = "";
	for(i = 0; i < len && i < BUFSIZ; i++) {
		snprintf(obuf + strlen(obuf), BUFSIZ, "%s%02x", pad, s[i]);
		pad = " ";
	}

	syslog(LOG_INFO, "%s: %s: hexdump %s", __FILE__, __FUNCTION__, obuf);

	memset(obuf, 0, BUFSIZ);

	s = (unsigned char *)buf;
	pad = "";
	for(i = 0; i < len && i < BUFSIZ; i++) {
		snprintf(obuf + strlen(obuf), BUFSIZ, "%s%03d", pad, s[i]);
		pad = " ";
	}

	syslog(LOG_INFO, "%s: %s: decdump %s", __FILE__, __FUNCTION__, obuf);
}
#endif

/* EOF */
