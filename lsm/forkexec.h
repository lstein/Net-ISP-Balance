/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef __FORKEXEC_H__
#define __FORKEXEC_H__

pid_t forkexec(char **argv, char **envp);
void create_sigchld_hdl(void);
void exec_queue_add(char *queue, char **argv, char **envp);
void exec_queue_process(void);
char **exec_queue_argv(char *fmt, ...);
void exec_queue_argv_free(char **argv);
char **exec_queue_envp(void);
void exec_queue_envp_free(char **envp);
void exec_queue_delete(pid_t pid);
void exec_queue_free(void);

#if defined(DEBUG)
void exec_queue_dump(void);
#endif

#endif

/* EOF */
