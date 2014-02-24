/*

(C) 2009-2011 Mika Ilmaranta <ilmis@nullnet.fi>

License: GPLv2

*/

#include "cksum.h"

int in_cksum(u_short *p, int n)
{
	register u_short answer;
	register long sum = 0;
	u_short odd_byte = 0;

	while(n > 1) {
		sum += *p++;
		n -= 2;
	}

	/* mop up an odd byte, if necessary */
	if(n == 1){
		*(u_char*)(&odd_byte) = *(u_char*)p;
		sum += odd_byte;
	}

	sum = (sum >> 16) + (sum & 0xffff);	/* add hi 16 to low 16 */
	sum += (sum >> 16);			/* add carry */
	answer = ~sum;				/* ones-complement, truncate */

	return(answer);
}

/* EOF */
