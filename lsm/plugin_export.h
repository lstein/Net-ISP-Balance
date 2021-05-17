/*

(C) 2013 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef NO_PLUGIN_EXPORT

#ifndef __PLUGIN_EXPORT_H__
#define __PLUGIN_EXPORT_H__

#include "config.h"
#include "foolsm.h"

void plugin_export_init(void);
void plugin_export(CONFIG *first);

#ifndef NO_PLUGIN_EXPORT_STATUS
void plugin_export_status(CONFIG *first);
#endif

#endif

#endif

/* EOF */
