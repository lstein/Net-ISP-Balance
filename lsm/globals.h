/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef __GLOBALS_H__
#define __GLOBALS_H__

void set_prog(char *val);
char *get_prog(void);
void set_cont(const int val);
int get_cont(void);
void set_dump(const int val);
int get_dump(void);
void set_ident(const int val);
int get_ident(void);
void set_reload_cfg(const int val);
int get_reload_cfg(void);
void set_dump_if_list(const int val);
int get_dump_if_list(void);

#endif

/* EOF */
