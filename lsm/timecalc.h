/*

  (C) 2011 Mika Ilmaranta <ilmis@nullnet.fi>

*/

#ifndef __TIMECALC_H__
#define __TIMECALC_H__

#include <time.h>
#include <sys/time.h>

#define TIMEVAL_DIFF_CMP_GT (0)
#define TIMEVAL_DIFF_CMP_LT (1)

int timeval_diff_cmp(struct timeval *a, struct timeval *b, int operation, time_t sec, suseconds_t usec);
long timeval_diff(struct timeval *a, struct timeval *b);
void timeval_add(struct timeval *a, time_t sec, suseconds_t usec);

#endif

/* EOF */
