/*

  (C) 2014 Mika Ilmaranta <ilmis@nullnet.fi>

  License: GPLv2

*/

#ifndef __PIDFILE_H__
#define __PIDFILE_H__

int pidfile_open(void);
int pidfile_update(void);
void pidfile_close(void);

#endif

/* EOF */
