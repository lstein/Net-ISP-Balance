/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#ifndef __DEFS_H__
#define __DEFS_H__

#ifndef TRUE
#define TRUE	(1)
#define FALSE	(0)
#endif

#define MIN_PERHOST_INTERVAL (20000L) /* 20ms in between sends minimum */
#define DEFAULT_SELECT_WAIT  (10000L) /* wait at least 10ms for incoming packet */

#define FOLLOWED_PKTS (100) /* THIS ABSOLUTELY CAN'T EXCEED 0xffff (65535 decimal) OR THINGS BREAK */
#define SEQ_LIMITER   ((0x10000 / FOLLOWED_PKTS) * FOLLOWED_PKTS)

#define min(x, y) ((x)<(y) ? (x) : (y))

#define PLUGIN_EXPORT_DIR "/var/lib/foolsm"

#endif

/* EOF */
