/*

(C) 2013 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef NO_PLUGIN_EXPORT

#include <stdio.h>
#include <stdlib.h>
#include <syslog.h>
#include <sys/time.h>
#include <string.h>
#include <ctype.h>

#include "plugin_export.h"
#include "timecalc.h"
#include "defs.h"

static char *munin_data_src_name(const char *src);

static struct timeval export_time = {0, 0};

void plugin_export_init(void)
{
	gettimeofday(&export_time, NULL);
}

void plugin_export(CONFIG *first)
{
	struct timeval current_time = {0, 0};
	FILE *fp;
	char buf[BUFSIZ];
	CONFIG *cur;
	TARGET *t;

	gettimeofday(&current_time, NULL);

	/* export every 300s */
	if(timeval_diff_cmp(&current_time, &export_time, TIMEVAL_DIFF_CMP_GT, 300, 0) == FALSE) return;

	/* next export after 300 sec */
	timeval_add(&export_time, 300, 0);

#ifndef NO_PLUGIN_EXPORT_MUNIN
	/* export avg_rtt graph config */
	snprintf(buf, BUFSIZ - 1, "%s/%s", PLUGIN_EXPORT_DIR, "config.rtt");

	if((fp = fopen(buf, "w")) == NULL) {
		syslog(LOG_ERR, "%s: %s: failed to open file %s for write", __FILE__, __FUNCTION__, buf);
		return;
	}

	fprintf(fp, "graph_title LSM Average Ping Latency\n");
	fprintf(fp, "graph_vlabel ms\n");
	fprintf(fp, "graph_info This graph shows LSM status\n");
	fprintf(fp, "graph_category network\n");
	fprintf(fp, "graph_args --base 1000 -l 0\n");

	for(cur = first; cur; cur = cur->next) {
		char *name = munin_data_src_name(cur->name);

		fprintf(fp, "%s_rtt.label %s rtt\n", name, cur->name);
		fprintf(fp, "%s_rtt.type GAUGE\n", name);
	}

	fclose(fp);

	/* export avg_rtt values */
	snprintf(buf, BUFSIZ - 1, "%s/%s", PLUGIN_EXPORT_DIR, "status.rtt");

	if((fp = fopen(buf, "w")) == NULL) {
		syslog(LOG_ERR, "%s: %s: failed to open file %s for write", __FILE__, __FUNCTION__, buf);
		return;
	}

	for(cur = first; cur; cur = cur->next) {
		char *name = munin_data_src_name(cur->name);
		t = cur->data;

		fprintf(fp, "%s_rtt.value %.2f\n", name, (t->status == DOWN || t->status == LONG_DOWN) ? 0.0 : t->avg_rtt / 1000.0);
	}

	fclose(fp);

	/* export other counts config */
	snprintf(buf, BUFSIZ - 1, "%s/%s", PLUGIN_EXPORT_DIR, "config.counts");

	if((fp = fopen(buf, "w")) == NULL) {
		syslog(LOG_ERR, "%s: %s: failed to open file %s for write", __FILE__, __FUNCTION__, buf);
		return;
	}

	fprintf(fp, "graph_title LSM packet counts\n");
	fprintf(fp, "graph_vlabel percent\n");
	fprintf(fp, "graph_info This graph shows LSM status\n");
	fprintf(fp, "graph_category network\n");
	fprintf(fp, "graph_args --base 1000 -l 0\n");

	for(cur = first; cur; cur = cur->next) {
		char *name = munin_data_src_name(cur->name);

		fprintf(fp, "%s_timeout.label %s Timed out\n", name, cur->name);
		fprintf(fp, "%s_timeout.type GAUGE\n", name);

		fprintf(fp, "%s_replied.label %s Replied\n", name, cur->name);
		fprintf(fp, "%s_replied.type GAUGE\n", name);

		fprintf(fp, "%s_waiting.label %s Waiting\n", name, cur->name);
		fprintf(fp, "%s_waiting.type GAUGE\n", name);

		fprintf(fp, "%s_latereply.label %s Late replied\n", name, cur->name);
		fprintf(fp, "%s_latereply.type GAUGE\n", name);

		fprintf(fp, "%s_cwait.label %s Consecutive waiting\n", name, cur->name);
		fprintf(fp, "%s_cwait.type GAUGE\n", name);

		fprintf(fp, "%s_cmiss.label %s Consecutive missing\n", name, cur->name);
		fprintf(fp, "%s_cmiss.type GAUGE\n", name);

		fprintf(fp, "%s_crcvd.label %s Consecutive received\n", name, cur->name);
		fprintf(fp, "%s_crcvd.type GAUGE\n", name);
	}

	fclose(fp);

	/* export other counts values */
	snprintf(buf, BUFSIZ - 1, "%s/%s", PLUGIN_EXPORT_DIR, "status.counts");

	if((fp = fopen(buf, "w")) == NULL) {
		syslog(LOG_ERR, "%s: %s: failed to open file %s for write", __FILE__, __FUNCTION__, buf);
		return;
	}

	for(cur = first; cur; cur = cur->next) {
		char *name = munin_data_src_name(cur->name);
		t = cur->data;

		fprintf(fp, "%s_timeout.value %d\n", name, t->timeout);

		fprintf(fp, "%s_replied.value %d\n", name, t->replied);

		fprintf(fp, "%s_waiting.value %d\n", name, t->waiting);

		fprintf(fp, "%s_latereply.value %d\n", name, t->reply_late);

		fprintf(fp, "%s_cwait.value %d\n", name, t->consecutive_waiting);

		fprintf(fp, "%s_cmiss.value %d\n", name, t->consecutive_missing);

		fprintf(fp, "%s_crcvd.value %d\n", name, t->consecutive_rcvd);
	}

	fclose(fp);
#endif
}

static char *munin_data_src_name(const char *src)
{
	static char buf[BUFSIZ];
	char *p;

	strcpy(buf, "_");

	strncat(buf, src, BUFSIZ - 1);

	for(p = buf; *p; p++) {
		if(*p == '-') *p = '_';
		if(*p == ' ') *p = '_';
	}
	return(buf);
}

#endif

/* EOF */
