/*

(C) 2013 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef __LSM_H__
#define __LSM_H__

#include <netinet/in.h> /* for struct sockaddr_in */
#include <linux/if_arp.h> /* for struct sockadd_ll */
#include <netinet/icmp6.h> /* for struct icmp6_filter */

#include "defs.h"

typedef struct sentpkt {
	unsigned short seq;
	struct timeval sent_time;
	struct timeval replied_time;
	unsigned long rtt;
	struct {
		unsigned replied:1;
		unsigned timeout:1;
		unsigned waiting:1;
		unsigned used:1;
		unsigned error:1;
	} flags;
} SENTPKT;

typedef struct target {
	unsigned short id; /* target id */
	unsigned short seq;
	unsigned short downseq;
	unsigned short downseqreported;
	struct timeval down_timestamp;
	struct sockaddr_in src_addr;
	struct sockaddr_in dst_addr;
	struct sockaddr_in6 src_addr6;
	struct sockaddr_in6 dst_addr6;
	struct sockaddr_ll me; /* arping only */
	struct sockaddr_ll he; /* arping only */
	struct in_addr src;
	struct in_addr dst;
	struct in6_addr src6;
	struct in6_addr dst6;
	unsigned long num_sent;
	struct timeval last_send_time;
	STATUS status;
	int sock;
	unsigned char cmsgbuf[4096];
	int cmsglen;
	struct icmp6_filter filter;
	SENTPKT sentpkts[FOLLOWED_PKTS];
	int timeout;
	int replied;
	int waiting;
	int reply_late;
	int used;
	int consecutive_waiting;
	int consecutive_missing;
	int consecutive_rcvd;
	long avg_rtt;
	int status_change;
} TARGET;

#endif

/* EOF */
