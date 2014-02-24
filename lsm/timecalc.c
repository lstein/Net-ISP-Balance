/*

  (C) 2011 Mika Ilmaranta

*/

#include <syslog.h>

#include "defs.h"
#include "timecalc.h"

int timeval_diff_cmp(struct timeval *a, struct timeval *b, int operation, time_t sec, suseconds_t usec) {
	time_t diff_sec;
	suseconds_t diff_usec;

	diff_sec = a->tv_sec - b->tv_sec;
	diff_usec = a->tv_usec - b->tv_usec;

	if(diff_usec < 0) {
		diff_sec--;
		diff_usec = 1000000L + diff_usec;
	}

	switch(operation) {
	case TIMEVAL_DIFF_CMP_GT:
		if(diff_sec > sec) return(TRUE);
		if(diff_sec == sec && diff_usec > usec) return(TRUE);
		return(FALSE);
		break;
	case TIMEVAL_DIFF_CMP_LT:
		if(diff_sec < sec) return(TRUE);
		if(diff_sec == sec && diff_usec < usec) return(TRUE);
		return(FALSE);
		break;
	default:
		syslog(LOG_ERR, "%s: %s: warning: unknown timeval_diff_cmp operation requested %d", __FILE__, __FUNCTION__, operation);
		return(FALSE);
	}
}

long timeval_diff(struct timeval *a, struct timeval *b)
{
	return( ((a->tv_sec - b->tv_sec) * 1000000L) + (a->tv_usec - b->tv_usec) );
}

void timeval_add(struct timeval *a, time_t sec, suseconds_t usec)
{
	a->tv_sec += sec;
	a->tv_usec += usec;
	if(a->tv_usec >= 1000000L) {
		a->tv_sec++;
		a->tv_usec -= 1000000L;
	}
}

/* EOF */
