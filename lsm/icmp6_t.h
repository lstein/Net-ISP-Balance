/*

  (C) 2011 Mika Ilmaranta <ilmis@nullnet.fi>

*/

#ifndef __ICMP6_T_H__
#define __ICMP6_T_H__

struct icmp6msg
{
	int type;
	int code;
	char *type_msg;
	char *code_msg;
};

struct icmp6msg *stricmp6(int type, int code);

#endif

/* EOF */
