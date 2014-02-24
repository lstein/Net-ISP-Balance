/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdarg.h>
#include <syslog.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "config.h"
#include "forkexec.h"

static void sigchld_hdl(int sig);

typedef struct exec_queue
{
	pid_t pid;
	char **argv;
	char **envp;
	struct exec_queue *next;
} EXEC_QUEUE;

typedef struct exec_queues
{
	char *name;
	EXEC_QUEUE *first;
	EXEC_QUEUE *last;
	struct exec_queues *next;
} EXEC_QUEUES;

static EXEC_QUEUES *exec_queues_first = NULL;
static EXEC_QUEUES *exec_queues_last = NULL;

pid_t forkexec(char **argv, char **envp)
{
	pid_t pid;
#if defined(DEBUG)
	int i;
#endif

	if((pid = fork()) == -1) {
		syslog(LOG_ERR, "%s: %s: %d: fork() failed \"%s\"", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
		return(0);
	}

	if(pid) {
		/* parent */
		if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: %d: child process forked with pid: %d", __FILE__, __FUNCTION__, __LINE__, pid);
		return(pid);
	}

	/* child */
	closelog(); /* openlog doesn't return a fd to set close on exec */

#if defined(DEBUG)
	for(i = 0; argv[i]; i++) {
		fprintf(stderr, "argv[%d] = \"%s\"\n", i, argv[i]);
	}
	for(i = 0; envp[i]; i++) {
		fprintf(stderr, "envp[%d] = \"%s\"\n", i, envp[i]);
	}
#endif

	execve(argv[0], argv, envp);
	syslog(LOG_ERR, "%s: %s: %d: child process failed to execute external command", __FILE__, __FUNCTION__, __LINE__);
	exit(1); /* exec failed ... */
}

/*
  Set up child signal handler to handle termination of children.
  This should be done once only for the main program.
*/
void create_sigchld_hdl(void)
{
	struct sigaction act;

	memset (&act, 0, sizeof(act));
	act.sa_handler = sigchld_hdl;
	if (sigaction(SIGCHLD, &act, 0)) {
		syslog(LOG_ERR, "%s: %s: %d: failed to set up child signal handler: %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
		return;
	} else {
		if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: %d: successfully set up child signal handler", __FILE__, __FUNCTION__, __LINE__);
	}
}

/*
  SIGCHLD handler. Will be called for all children.
*/
static void sigchld_hdl(int sig)
{
	/* Wait for the dead process.
	 * We use a non-blocking call to be sure this signal handler will not
	 * block if a child was cleaned up in another part of the program. */
	int exitval;
	pid_t pid;

	if((pid = waitpid(-1, &exitval, WNOHANG)) == -1) {
		if(cfg.debug >= 9 && errno != ECHILD) syslog(LOG_ERR, "%s: %s: %d: waitpid failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
	} else {
		if(cfg.debug >= 9 && exitval) syslog(LOG_ERR, "%s: %s: %d: child script with pid %d exited with non null exit value %d", __FILE__, __FUNCTION__, __LINE__, pid, exitval);
		else if(cfg.debug >= 9) syslog(LOG_ERR, "%s: %s: %d: child script with pid %d exited successfully", __FILE__, __FUNCTION__, __LINE__, pid);
		exec_queue_delete(pid);
	}
}

void exec_queue_add(char *queue, char **argv, char **envp)
{
	EXEC_QUEUES *eqs;
	EXEC_QUEUE *eq;

	if(!exec_queues_first) { /* first queue */
		if((eqs = malloc(sizeof(EXEC_QUEUES))) == NULL) {
			syslog(LOG_ERR, "%s: %s: %d: malloc failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
			return;
		}
		eqs->name = strdup(queue);
		eqs->next = NULL;

		if((eq = malloc(sizeof(EXEC_QUEUE))) == NULL) {
			syslog(LOG_ERR, "%s: %s: %d: malloc failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
			return;
		}
		eq->pid = 0;
		eq->argv = argv;
		eq->envp = envp;
		eq->next = NULL;

		eqs->first = eq;
		eqs->last = eq;

		exec_queues_first = eqs;
		exec_queues_last = eqs;

	} else { /* not first queue */
		for(eqs = exec_queues_first; eqs; eqs = eqs->next) {
			if(!strcmp(eqs->name, queue)) {
				/* queue exists, add to it */
				if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: %d: found queue %s", __FILE__, __FUNCTION__, __LINE__, eqs->name);

				if((eq = malloc(sizeof(EXEC_QUEUE))) == NULL) {
					syslog(LOG_ERR, "%s: %s: %d: malloc failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
					return;
				}

				eq->pid = 0;
				eq->argv = argv;
				eq->envp = envp;
				eq->next = NULL;

				if(!eqs->first) { /* empty queue */
					eqs->first = eq;
					eqs->last = eq;

				} else { /* add after last */
					eqs->last->next = eq;
					eqs->last = eq;
				}

				break;
			}
		}

		if(!eqs) { /* not found, create a new queue and add to it */
			if(cfg.debug >= 9) syslog(LOG_INFO, "%s: %s: %d: queue %s not found adding new queue", __FILE__, __FUNCTION__, __LINE__, queue);

			if((eqs = malloc(sizeof(EXEC_QUEUES))) == NULL) {
				syslog(LOG_ERR, "%s: %s: %d: malloc failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
				return;
			}
			eqs->name = strdup(queue);
			eqs->next = NULL;

			exec_queues_last->next = eqs;
			exec_queues_last = eqs;

			if((eq = malloc(sizeof(EXEC_QUEUE))) == NULL) {
				syslog(LOG_ERR, "%s: %s: %d: malloc failed %s", __FILE__, __FUNCTION__, __LINE__, strerror(errno));
				return;
			}

			eq->pid = 0;
			eq->argv = argv;
			eq->envp = envp;
			eq->next = NULL;

			eqs->first = eq;
			eqs->last = eq;
		}
	}
	return;
}

#if defined(DEBUG)
void exec_queue_dump(void)
{
	EXEC_QUEUES *eqs;
	EXEC_QUEUE *eq;
	int i;


	for(eqs = exec_queues_first; eqs; eqs = eqs->next) {
		syslog(LOG_INFO, "%s: %s: %d: eqs->name %s", __FILE__, __FUNCTION__, __LINE__, eqs->name);
		for(eq = eqs->first; eq; eq = eq->next) {
			syslog(LOG_INFO, "%s: %s: %d: eq->pid %d", __FILE__, __FUNCTION__, __LINE__, eq->pid);
			for(i = 0; eq->argv[i]; i++) {
				syslog(LOG_INFO, "%s: %s: %d: argv[%d] = %s", __FILE__, __FUNCTION__, __LINE__, i, eq->argv[i]);
			}
		}
	}
}
#endif

void exec_queue_process(void)
{
	EXEC_QUEUES *eqs;
	EXEC_QUEUE *eq;

	for(eqs = exec_queues_first; eqs; eqs = eqs->next) {
		eq = eqs->first;
		if(eq && eq->pid == 0) eq->pid = forkexec(eq->argv, eq->envp);
	}
}

void exec_queue_delete(pid_t pid)
{
	EXEC_QUEUES *eqs;
	EXEC_QUEUE *eq;

	for(eqs = exec_queues_first; eqs; eqs = eqs->next) {
		EXEC_QUEUE *prev = NULL;

		for(eq = eqs->first; eq; eq = eq->next) {
			if(eq->pid == pid) {
				if(!prev) { /* this is first */
					if(!eq->next) { /* last */
						eqs->first = NULL;
						eqs->last = NULL;
					} else { /* not last */
						eqs->first = eq->next;
					}
				} else { /* not first */
					prev->next = eq->next;
				}
				exec_queue_argv_free(eq->argv);
				exec_queue_envp_free(eq->envp);
				free(eq);
				return;
			}

			prev = eq;
		}
	}
	if(cfg.debug >= 9) syslog(LOG_ERR, "%s: %s: %d: child pid %d not found", __FILE__, __FUNCTION__, __LINE__, pid);
}

void exec_queue_free(void)
{
	EXEC_QUEUES *eqs;
	EXEC_QUEUE *eq;

	eqs = exec_queues_first;
	while(eqs) {
		EXEC_QUEUES *prev_eqs = eqs;

		eq = eqs->first;
		while(eq) {
			EXEC_QUEUE *prev_eq = eq;

			eq = eq->next;
			free(prev_eq);
		}

		eqs = eqs->next;
		free(prev_eqs);
	}

	exec_queues_first = NULL;
	exec_queues_last = NULL;
}

char **exec_queue_argv(char *fmt, ...)
{
	va_list vl;
	char **argv;
	char *s;
	int fmt_cnt;
	char buf[BUFSIZ];
	int i;

	s = fmt;
	fmt_cnt = 0;
	while(*s) {
		if(*s++ == '%') fmt_cnt++;
	}

	if((argv = malloc((fmt_cnt + 1) * sizeof(char *))) == NULL) {
		syslog(LOG_ERR, "%s: %s: failed to malloc %s", __FILE__, __FUNCTION__, strerror(errno));
		return(NULL);
	}

	s = fmt;
	i = 0;
	va_start(vl, fmt);
	while(*s) {
		if(*s == '%') {
			s++;
			switch(*s++) {
			case 's': /* string */
				argv[i] = strdup(va_arg(vl, char *));
				i++;
				break;

			case 'd': /* int */
				snprintf(buf, BUFSIZ - 1, "%d", va_arg(vl, int));
				argv[i] = strdup(buf);
				i++;
				break;

			default: /* skip unknown directives */
				break;
			}
		} else {
			s++;
		}
	}
	va_end(vl);

	argv[i] = NULL;

	return(argv);
}

void exec_queue_argv_free(char **argv)
{
	int i;

	for(i = 0; argv[i]; i++) {
		free(argv[i]);
	}

	free(argv);
}

char **exec_queue_envp(void)
{
	char **envp;
	char buf[BUFSIZ];

	if((envp = malloc(4 * sizeof(char *))) == NULL) {
		syslog(LOG_ERR, "%s: %s: malloc failed %s", __FILE__, __FUNCTION__, strerror(errno));
		return(NULL);
	}

	snprintf(buf, BUFSIZ - 1, "LANG=%s", getenv("LANG"));
	envp[0] = strdup(buf);

	snprintf(buf, BUFSIZ - 1, "PATH=%s", getenv("PATH"));
	envp[1] = strdup(buf);

	snprintf(buf, BUFSIZ - 1, "TERM=%s", getenv("TERM"));
	envp[2] = strdup(buf);

	envp[3] = NULL;

	return(envp);
}

void exec_queue_envp_free(char **envp)
{
	int i;

	for(i = 0; envp[i]; i++) {
		free(envp[i]);
	}

	free(envp);
}

/* EOF */
