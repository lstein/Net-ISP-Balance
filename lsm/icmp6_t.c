/*

  (C) 2011 Mika Ilmaranta <ilmis@nullnet.fi>

*/

#include <stdio.h>

#include "icmp6_t.h"

struct icmp6msg icmp6msgs[] = {
	/* error messages */
	{ 0, 0, "Reserved", "" },

	{ 1, 0, "Destination Unreachable", "no route to destination" },
	{ 1, 1, "Destination Unreachable", "communication with destination administratively prohibited" },
	{ 1, 2, "Destination Unreachable", "beyond scope of source address" },
	{ 1, 3, "Destination Unreachable", "address unreachable" },
	{ 1, 4, "Destination Unreachable", "port unreachable" },
	{ 1, 5, "Destination Unreachable", "source address failed ingress/egress policy" },
	{ 1, 6, "Destination Unreachable", "reject route to destination" },
	{ 1, 7, "Destination Unreachable", "Error in Source Routing Header" },

	{ 2, 0, "Packet Too Big", "" },

	{ 3, 0, "Time Exceeded", "hop limit exceeded in transit" },
	{ 3, 1, "Time Exceeded", "fragment reassembly time exceeded" },

	{ 4, 0, "Parameter Problem", "erroneous header field encountered" },
	{ 4, 1, "Parameter Problem", "unrecognized Next Header type encountered" },
	{ 4, 2, "Parameter Problem", "unrecognized IPv6 option encountered" },

	{ 100, 0, "Private experimentation", "" },
	{ 101, 0, "Private experimentation", "" },
	{ 127, 0, "Reserved for expansion of ICMPv6 error messages", "" },

	/* infomational messages */
	{ 128, 0, "Echo Request", "" },

	{ 129, 0, "Echo Reply", "" },

	{ 130, 0, "Multicast Listener Query", "" },

	{ 131, 0, "Multicast Listener Report", "" },

	{ 132, 0, "Multicast Listener Done", "" },

	{ 133, 0, "Router Solicitation (NDP)", "" },

	{ 134, 0, "Router Advertisement (NDP)", "" },

	{ 135, 0, "Neighbor Solicitation (NDP)", "" },

	{ 136, 0, "Neighbor Advertisement (NDP)", "" },

	{ 137, 0, "Redirect Message (NDP)", "" },

	{ 138, 0, "Router Renumbering", "Router Renumbering Command" },
	{ 138, 1, "Router Renumbering", "Router Renumbering Result" },
	{ 138, 255, "Router Renumbering", "Sequence Number Reset" },

	{ 139, 0, "ICMP Node Information Query", "The Data field contains an IPv6 address which is the Subject of this Query." },
	{ 139, 1, "ICMP Node Information Query", "The Data field contains a name which is the Subject of this Query, or is empty, as in the case of a NOOP." },
	{ 139, 2, "ICMP Node Information Query", "The Data field contains an IPv4 address which is the Subject of this Query." },

	{ 140, 0, "ICMP Node Information Response", "A successful reply. The Reply Data field may or may not be empty." },
	{ 140, 1, "ICMP Node Information Response", "The Responder refuses to supply the answer. The Reply Data field will be empty." },
	{ 140, 2, "ICMP Node Information Response", "The Qtype of the Query is unknown to the Responder. The Reply Data field will be empty." },

	{ 141, 0, "Inverse Neighbor Discovery Solicitation Message", "" },

	{ 142, 0, "Inverse Neighbor Discovery Advertisement Message", "" },

	{ 143, 0, "Multicast Listener Discovery (MLDv2) reports (RFC 3810)", "" },

	{ 144, 0, "Home Agent Address Discovery Request Message", "" },

	{ 145, 0, "Home Agent Address Discovery Reply Message", "" },

	{ 146, 0, "Mobile Prefix Solicitation", "" },

	{ 147, 0, "Mobile Prefix Advertisement", "" },

	{ 148, 0, "Certification Path Solicitation (SEND)", "" },

	{ 149, 0, "Certification Path Advertisement (SEND)", "" },

	{ 151, 0, "Multicast Router Advertisement (MRD)", "" },

	{ 152, 0, "Multicast Router Solicitation (MRD)", "" },

	{ 153, 0, "Multicast Router Termination (MRD)", "" },

	{ 200, 0, "Private experimentation", "" },

	{ 201, 0, "Private experimentation", "" },

	{ 255, 0, "Reserved for expansion of ICMPv6 informational messages", "" },

	{ 256, 256, "impossible combination", "impossible combination" }
};

struct icmp6msg *stricmp6(int type, int code)
{
	int i;

	if(type > 255) return(&((struct icmp6msg) { 256, 256, "unknown", "unknown" }));

	for(i = 0; icmp6msgs[i].type <= type; i++)
		if(icmp6msgs[i].type == type && icmp6msgs[i].code == code) return(&(icmp6msgs[i]));

	for(i = 0; icmp6msgs[i].type <= type; i++)
		if(icmp6msgs[i].type == type) return(&(icmp6msgs[i]));

	return(&((struct icmp6msg) { 256, 256, "unknown", "unknown" }));
}

/* EOF */
