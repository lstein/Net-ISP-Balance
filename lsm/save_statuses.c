/*

(C) 2013 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdlib.h>
#include <syslog.h>
#include <string.h>

#include "config.h"
#include "foolsm.h"
#include "save_statuses.h"

typedef struct status_data {
	char *name;
	STATUS status;
	struct status_data *next;
} STATUS_DATA;

static STATUS_DATA *first_status = NULL;
static STATUS_DATA *last_status = NULL;
static STATUS_DATA *cur_status = NULL;

void save_statuses(CONFIG *first)
{
	CONFIG *cur;

	if(first_status != NULL) {
		syslog(LOG_ERR, "%s: %s: statuses already saved?", __FILE__, __FUNCTION__);
		return;
	}

	/* store connection statuses temporarily */
	for(cur = first; cur; cur = cur->next) {
		if((cur_status = malloc(sizeof(STATUS_DATA))) == NULL) {
			syslog(LOG_ERR, "%s: %s: couldn't malloc for status_data", __FILE__, __FUNCTION__);
			exit(1);
		}
		cur_status->name = strdup(cur->name);
		cur_status->status = ((TARGET *)cur->data)->status;

		if(last_status) {
			last_status->next = cur_status;
			last_status = cur_status;
			cur_status->next = NULL;
		} else {
			first_status = cur_status;
			last_status = cur_status;
			cur_status->next = NULL;
		}
	}
}

void restore_statuses(CONFIG *first)
{
	CONFIG *cur;

	if(first_status == NULL) {
		syslog(LOG_ERR, "%s: %s: can't restore statuses, none saved?", __FILE__, __FUNCTION__);
		return;
	}

	/* restore connection statuses */
	for(cur_status = first_status; cur_status; cur_status = cur_status->next) {
		for(cur = first; cur; cur = cur->next) {
			if(strcmp(cur_status->name, cur->name) == 0) {
				((TARGET *)cur->data)->status = cur_status->status;
			}
		}
	}

	/* get rid of temporary statuses */
	cur_status = first_status;
	while(cur_status) {
		STATUS_DATA *tmp;

		tmp = cur_status->next;

		free(cur_status->name);
		free(cur_status);

		cur_status = tmp;
	}

	first_status = NULL;
	last_status = NULL;
	cur_status = NULL;
}

/* EOF */
