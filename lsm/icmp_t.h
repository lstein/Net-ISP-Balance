/*

  (C) 2009 Mika Ilmaranta <ilmis@nullnet.fi>

*/

#ifndef __ICMP_T_H__
#define __ICMP_T_H__

struct icmpmsg
{
	int type;
	int code;
	char *type_msg;
	char *code_msg;
};

struct icmpmsg *stricmp(int type, int code);

#endif

/* EOF */
