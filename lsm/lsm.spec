#define devel 1

Summary: The Link Status Monitor
Name: lsm
Version: 0.163
Release: 1%{?dist}
License: GPLv2
Group: System Environment/Daemons
URL: http://lsm.foobar.fi/
Source: %{name}-%{version}.tar.gz
Requires(post): chkconfig
Requires(postun): /sbin/service
Requires(preun): /sbin/service
Requires(preun): chkconfig
Requires: mailx
%if 0%{?devel}
BuildRequires: ElectricFence
%endif
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

%description
Lsm is the link status monitor.

Lsm can ping multiple targets and when up or down event happens
it will execute user configured external script so it can be used
as poor man's routing protocol.

%prep
%setup -q

%build
EFENCE=
%if 0%{?devel}
# Disable -O2 temporarily
RPM_OPT_FLAGS="$(echo "$RPM_OPT_FLAGS" | sed 's/-O.\ / /')"
EFENCE="-lefence"
%endif
%{__make} CFLAGS="$RPM_OPT_FLAGS" LDFLAGS=${EFENCE} %{?_smp_mflags}

%install
%{__rm} -rf $RPM_BUILD_ROOT

%{__mkdir_p} $RPM_BUILD_ROOT%{_sysconfdir}/%{name}
%{__mkdir_p} $RPM_BUILD_ROOT%{_initrddir}
%{__mkdir_p} $RPM_BUILD_ROOT%{_sbindir}
%{__mkdir_p} $RPM_BUILD_ROOT%{_datadir}/%{name}
%{__mkdir_p} $RPM_BUILD_ROOT%{_var}/lib/%{name}

%{__install} -m0755 lsm $RPM_BUILD_ROOT%{_sbindir}
%{__install} -m0644 lsm.conf $RPM_BUILD_ROOT%{_sysconfdir}/%{name}
%{__install} -m0755 default_script $RPM_BUILD_ROOT%{_datadir}/%{name}
%{__install} -m0755 shorewall_script $RPM_BUILD_ROOT%{_datadir}/%{name}
%{__install} -m0755 lsm.init $RPM_BUILD_ROOT%{_initrddir}/%{name}

%clean
%{__rm} -rf $RPM_BUILD_ROOT

%post
/sbin/chkconfig --add lsm

%preun
if [ $1 -eq 0 ]; then
    /sbin/service lsm stop >/dev/null 2>&1 || :
    /sbin/chkconfig --del lsm
fi

%postun
if [ $1 -ge 1 ]; then
    /sbin/service lsm condrestart >/dev/null 2>&1 || :
fi


%files
%defattr(-,root,root)
%doc README lsm.conf.sample default_script.sample rsyslog-lsm.conf.sample
%{_initrddir}/%{name}
%dir %{_sysconfdir}/lsm
%config(noreplace) %{_sysconfdir}/lsm/lsm.conf
%{_datadir}/lsm/default_script
%{_datadir}/lsm/shorewall_script
%{_sbindir}/lsm
%{_var}/lib/%{name}

%changelog
* Fri Aug  9 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.163-1
- don't suppress all up notifies when unknown_up_notify is off

* Thu Jul 25 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.162-1
- option to skip executing notify script on unknown to up event for groups
  also

* Thu Jul 25 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.161-1
- added option to skip executing notify script on unknown to up event

* Thu Jul 25 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.160-1
- moved save/restore statuses to their own file from lsm.c

* Wed Jul 24 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.159-1
- updated shorewall_script with new parameters

* Wed Jul 24 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.158-1
- clean up munin titles

* Tue Jul 23 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.157-1
- use connection names in munin labels

* Fri Jul 19 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.156-1
- plugin_export: changed strlower to munin_src_name

* Thu Jul 18 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.155-1
- plugin_export: export statistics for munin

* Wed Jul 17 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.154-1
- fixed divide error

* Wed Jul 17 2013 Mika Ilamranta <ilmis@nullnet.fi> - 0.153-1
- lsm.c: drop casts and keep avg_rtt in usec, divide by 1000.0 if needed as
  float

* Wed Jul 17 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.152-1
- lsm.c: cast avg_rtt for fork_exec

* Wed Jul 17 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.151-1
- prepare for exporting statistics to zabbix and munin

* Wed Jul 10 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.150-1
- lsm.c: change status to up directly from long_down

* Tue Jul  9 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.149-1
- default_script: added missing closing curly bracket

* Mon Jul  8 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.148-1
- pass event timestamp from lsm to scripts

* Mon Jul  8 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.147-1
- pass empty warn_email addr to script as hyphen
- if script gets hyphen for email addr do not send mail

* Thu Jul  4 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.146-1
- long_down_to down -> long_down_to_down

* Thu Jul  4 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.145-1
- check also for nul-string email addr

* Mon Jul  1 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.144-1
- use enum for status
- new config options for reporting only longer down time:
- long_down_time = how many seconds down time is considered long
- long_down_email = where to report long down time
- long_down_notifyscript = script to use when reporting long down time
- long_down_eventscript = script to use when reacting to long down time

* Fri May 10 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.143-1
- discard probed src addr if bind fails

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.142-1
- free exec_queue on exit

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.141-1
- make exec_queue_dump activate with -DDEBUG
- rsyslog-lsm.conf.sample by Dimitar Angelov

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.140-1
- debug with exec_queue_dump

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.139-1
- forkexec.c: check that eq is set in exec_queue_process

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.138-1
- config.c: defaults.queue NULL

* Thu Mar 28 2013 Mika Ilmaranta <ilmis@nullnet.fi> - 0.137-1
- exec queue, run event scripts sychronously

* Thu Oct 11 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.136-1
- lsm.c: clean up debugging and add check that reply addr matches
  original destination addr

* Thu Oct 11 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.135-1
- lsm.c: more debugging when pdp->id is out of range

* Thu Oct 11 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.134-1
- lsm.c: do bounds check on pdp->id before use as ctable index

* Mon Aug 13 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.133-1
- lsm.c: rethought group up/down logic. (original was wrong up event on
  transition to unknown state and 0.132 fix reported both up and down
  events)

* Mon Aug 13 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.132-1
- default_script: better english for timeout packets
- config.c: recognise status for group, use default start status for group
- lsm.c: report group prevstate textually

* Sat May 12 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.131-1
- close socket on recvfrom fail

* Tue May  8 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.130-1
- initialize cmsgbuf and cmsglen in open_icmp_sock as socket may be
  closed and reopened

* Sun May  6 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.129-1
- close socket also when sendmsg fails

* Sun May  6 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.128-1
- cleanup debugging
- don't SO_BINDTODEVICE for AF_INET6 when device is specified as it uses
  sendmsg instead of sendto

* Sun May  6 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.127-1
- debug sendmsg a little

* Sun May  6 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.126-1
- set v6 filter

* Sun May  6 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.125-1
- handle v6 device setting like ping6 does

* Sat May  5 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.124-1
- v6 sequence now correct?
- set v6 sockopts also if ttl is not set

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.123-1
- removed unnesessary debugging
- v6 src ip addr autodiscovery works now

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.122-1
- debug memcpy t->src6 results

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.121-1
- check t->src6 contents

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.120-1
- debug v6 getsockname unconditionally

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.119-1
- debug getsockname for v6 conn

* Thu Apr 19 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.118-1
- no SO_DONTROUTE for v6 probe

* Fri Apr 13 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.117-1
- lsm.c: set more v6 socket options
- TODO: check why probe_src_ip_addr doesn't work for v6

* Sat Mar 10 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.116-2
- fix forkexec format str

* Sat Mar 10 2012 Mika Ilmaranta <ilmis@nullnet.fi> - 0.116-1
- report prevstate as string up/down/unknown

* Wed Mar  7 2012 Tuomo Soini <tis@foobar.fi> - 0.115-2
- fix %%postun not to fail

* Wed Dec 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.115-1
- forkexec.c: remove space after func name
- lsm.c: free_config_data: don't close t->sock if it is -1

* Wed Dec 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.114-1
- moved time calculation functions to their own files

* Wed Dec 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.113-1
- decode all icmp and icmp6 types and codes

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.112-1
- Andrew Beverley's signal child handler
- made static functions static

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.111-1
- moved children handling from forkexec to main loop

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.110-1
- lsm.c: use t->dst6 in v6 probe not cur->dstinfo

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.109-1
- rebuild with efence

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.108-1
- ipv6 support seems now stable enough

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.107-1
- lsm.c: debug probe_src_ip_addr call

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.106-1
- lsm.c: debug open_icmp_sock socket call removed
- lsm.c: debug setting v6 src addr

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.105-1
- lsm.c: debug open_icmp_sock socket call

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.104-1
- lsm.c: more sin6_family fixes

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.103-1
- lsm.c: set sin6_family and show also v4 addr in debug

* Tue Dec 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.102-1
- lsm.c: debug reply pkts more

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.101-1
- lsm.c: fix inet_pton parameters

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.100-1
- lsm.c: fail if device can not be bound to by Andrew Beverley
- lsm.c: bind also to ipv6 sourceip

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.99-1
- lsm.c: fix ping6 sendto params

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.98-1
- initial ipv6 support

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.97-1
- include version information in directory name inside tar pkg

* Mon Dec 19 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.96-1
- lsm.c: initialize last decision outside main loop. fixes decide call
  interval. patch by Andrew Beverley
- config.c: debugging information added for unmatched config option by
  Andrew Beverley. strcpy changed to memmove in strip leading space
- lsm.c: show correct usage
- config.c: clean up config file lines harder before parsing

* Fri Dec  9 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.95-1
- shorewall_script: removed email notification, use it as eventscript and
  default_script as notifyscript for example

* Fri Dec  9 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.94-1
- added support for worker script (= eventscript) and notify script
  (= notifyscript) differentiation, both are called with same parameters.
  new script parameter previous state

* Thu Dec  8 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.93-1
- for the following two patches thanks to Pablo Gomez
- lsm.c: use sourceip from config for icmp pkts if set
- lsm.c,config.c: new default state is unknown, which can be overridden in
  config. this allows lsm to run event script "on startup" after connection
  statuses are discovered. same rules apply as for actual events.

* Thu Oct 20 2011 Mika Ilmaranta <ilmis@nullnet.fi>> - 0.92-1
- report same seq status only once

* Thu Oct 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.91-1
- dump conn status to syslog every maxseq when status is down only
  if no status change

* Thu Oct 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.90-1
- dump conn status to syslog every maxseq when status is down

* Tue Sep 27 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.89-1
- added comment to shrewall_script about shorewall version requirement

* Tue Sep 27 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.88-1
- added shorewall_script

* Fri Jul 15 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.87-1
- production setting for compilation (no efence and use optimization)

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.86-1
- protect FD_ISSET also from closed socket

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.85-1
- compile with ElectricFence

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.84-1
- revert to v0.64 base
- Makefile: merge v0.83 changeset
- lsm.spec: v0.83 spec
- config: removed reopen_on_enodev and added patch for double free
- lsm.c: removed reopen_on_enodev handling
- lsm.conf: removed reopen_on_enodev
- added cksum files
- lsm.c: use external cksum
- v0.83 forkexec, globals and signal_handler
- lsm.c: separate defs.h, merged fixes from v0.83
- lsm.c: close socket on fail and reopen just before next ping
- spec: version and changelog

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.83-1
- check that device names match

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.82-1
- compile with ElectricFence depending on devel define

* Wed Jun 22 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.81-1
- check arp header differently

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.80-1
- further debugging of disappearing arp replies

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.79-1
- try to find out where arp replies vanish

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.78-1
- config.c: fix double free on warn_email and other group parameters

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.77-1
- fix BuildRequires for -lefence

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.76-1
- compile with -lefence

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.75-1
- check packet from addr to determine which connection it
  belongs to

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.74-1
- moved rest of io functions to io.c
- io.c: split icmp and arp reply handling
- io.c: differentiate ping_rcv error logging on find_interface use

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.73-1
- bind SIGUSR2 to signal_handler

* Tue Jun 21 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.72-1
- dump interface list on SIGUSR2

* Mon Jun 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.71-1
- io.c: due to function splitting add missing gettimeofday call in icmp_send

* Mon Jun 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.70-1
- timeval_diff_[lt,gt] fix diff_usec calculation

* Mon Jun 20 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.69-1
- removed sock from target structure
- added interface handling to interface.c and made other parts use it

* Fri Jun 17 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.68-1
- broke timeval_diff_cmp to two functions
- globals.c: check for unset prog
- lsm.c: removed handle_odd_icmp function as it did nothing
- interface.c: made probe for src ip address function probe_addresses

* Fri Jun 17 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.67-1
- moved global variable handling to its own block
- moved decision functions to their own block
- moved signal_handler to its own block
- moved ping function to its own file
- lsm.c: reset reload_cfg after reloading config, not before
- Makefile: clean also ~ files starting with dot

* Fri Jun 17 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.66-1
- moved structure definitions to lsm.h
- lsm.c: moved socket opening functionality to interface.c
- Makefile: use Makefile.depend
- .gitignore: ignore Makefile.depend, obj files and lsm binary

* Wed Jun 15 2011 Mika Ilmaranta <ilmis@nullnet.fi> - 0.65-1
- started rewrite
- moved forkexec function and defines to their own files
- added interface handling src files
- moved cksum function to its own file
- moved timeval functions to their own files

* Fri Dec 31 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.64-1
- fill up target struct src address for ping also
  do it at startup (should this be done every time we send ping packet?)

* Fri Dec 31 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.63-1
- Added src ip to script parameters
  src ip paramater is the last one so that every single old config
  doesn't have to be rewritten.

* Fri Dec 10 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.62-1
- check for valid ip-address in checkip parameter

* Fri Dec 10 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.61-1
- changed lsm.c init_config to init_config_data
- added init_config to config.c which is then called before read_config
- added a warning when checkip is not set

* Sat Oct  9 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.60-1
- fix recursive read_config use. set default values only once.
- use cfg.debug only after config is read
- added default_script.sample

* Mon Sep 27 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.59-1
- remember connection statuses after config reload

* Mon Sep 27 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.58-1
- reopen_on_enodev support. set this to 1 so lsm will try to reopen ping
  device when it encounters ENODEV error when sending ping packet

* Sun Sep 19 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.57-1
- added defaults status to give initial assumption of the connection status
- added config status for connections. is it assumed down = 0 or up = 1
  at lsm start

* Sat Sep 18 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.56-1
- fixed rpmlint-v0.91 warnings.

* Sat Apr 24 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.53-1
- added error checking to ftruncate and write so that mock build doesn't
  complain
- introduced timeval_diff_cmp function as it seems quite problematic to
  really compare times in usec since epoch using integer values.
  especially 32bit systems were seeing 99% CPU loads because of this.

* Thu Apr 22 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.52-1
- initialize all struct timeval structures to tv_sec = 0 and tv_usec = 0
- added use of error flag to arping sending

* Fri Mar  5 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.51-1
- fix avg rtt calculation comment
- show in the default mail template avg rtt unit [usec]
- in syslog avg rtt is reported in [msec] as of v0.50 like ping does

* Fri Mar  5 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.50-1
- report rtt with three decimals accuracy

* Thu Mar  4 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.49-1
- count average rtt in milliseconds not in microseconds

* Thu Mar  4 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.48-1
- don't count timeouted late replies in cons rcvd

* Thu Mar  4 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.47-1
- added some missing fields to lsm.init

* Thu Mar  4 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.46-1
- dump all statuses only if requested by SIGUSR1
- otherwise dump only connection status data of connection whose status changed

* Wed Mar  3 2010 Mika Ilmaranta <ilmis@nullnet.fi> - 0.45-1
- use LOG_PID openlog option

* Thu Dec 17 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.44-1
- added some parameter sanity checking. if max_packet_loss <= min_packet_loss then there can be a flip-flop effect
  and many many and still a few reports mailed to warn_email address.

* Mon Nov  9 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.43-1
- convert all tabs to spaces before processing config line

* Sun Sep 27 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.42-1
- changed action script to event script to follow suite with config

* Sun Sep 27 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.41-1
- added action_script_check() to check for valid action script

* Wed Sep  2 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.40-1
- lseek to start of pid file and ftruncate it to zero size before writing
  our new pid. this prevents us having two pids in the file if previous
  lsm crashed or exited and did not remove the file (fcntl lock is cleared
  by kernel as process dies "prematurely").

* Mon Jun 29 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.39-1
- set close on exec flag for fds and sockets
- call closelog() within forked child before exec

* Thu Jun 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.38-1
- require mailx for /bin/mail as default_script uses it

* Thu Jun 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.37-1
- when dumping config log also group's warn_email and logic
- set last previous last group members next to the new last member

* Thu Jun 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.36-1
- apply sane defaults to group parameters

* Thu Jun  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.35-1
- only log sendto errors with debug >= 9

* Thu Jun  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.34-1
- better sendto error ignore fix
- changed syslog calls for Mandrake

* Thu Jun  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.33-1
- ping_send: don't care about sendto errors

* Wed Apr 29 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.32-1
- split long debug explanation line in lsm.conf

* Wed Apr 29 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.31-1
- left only defaults in lsm.conf and moved examples to
  lsm.conf.sample

* Tue Apr 28 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.30-1
- timeval_diff calculation order change to prevent
  long overflow. nobody has encoutered that but just to be
  sure
- use default ttl=0 which uses system default ttl

* Sat Apr 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.29-1
- Added decision making section to README written by Dean Takemori
  he suggested to include it in lsm.conf but I thought it was
  long enough already

* Sat Apr 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.28-1
- Tom Eastep's fix for last_sent_time initialization
- added time stamp to default_script mail body

* Fri Apr 10 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.27-1
- added checks for missing group members

* Fri Apr 10 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.26-1
- added connection grouping

* Thu Apr  9 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.25-1
- gettimeofday failure patch from Dean Takemori

* Sun Apr  5 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.24-1
- add support for SIGHUP to reload config

* Tue Mar 24 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.23-1
- changed ping packets to use own socket for each target.
  looks like setsockopt SO_BINDTOINTERFACE is not reversible and
  according to documentation I found using it multiple times
  may lead to unpredicted results due to kernel caching.

* Tue Mar 24 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.22-1
- changed indentation to tabs

* Mon Mar 16 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.21-1
- added LSM: to default_script mail subject

* Tue Mar 10 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.20-1
- handle ENODEV as if the ping packet was sent, but do barf to syslog
  about it. this will eventually cause a down event. added
  an error flag which is set if sendto returns with value < 0.
- dump connection statuses to syslog when up/down-event happens.
- moved status dump's "header" -line above the pkt status bits.
- added error flag dumping.

* Fri Mar  6 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.19-1
- fix pid file write order

* Thu Mar  5 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.18-1
- added pid file handling

* Thu Mar  5 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.17-1
- rebuild because of mystical i386 build problems

* Wed Mar  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.16-1
- pass only LANG, PATH and TERM environment variables to
  scripts

* Wed Mar  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.15-1
- fixed all rpmlint errors reported in binary pkg
  which means that default_script is moved to /usr/share/lsm

* Wed Mar  4 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.14-1
- added ipv6 support to TODO list
- fixed rpmlint errors in lsm.spec

* Tue Feb 24 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.13-1
- typos: lisence -> license
- mention SIGUSR1 behaviour in README
- added a check for ENODEV for ping packets

* Fri Feb 20 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.12-1
- don't define device= in defaults

* Wed Feb 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.11-1
- if device is not specified return NA

* Wed Feb 18 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.10-1
- added device to script parameters
- first try on binding ping packets to device

* Thu Feb 12 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.9-1
- fixed rtt comments in default_script

* Thu Feb 12 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.8-1
- init script reload fix

* Sat Feb  7 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.7-1
- fixed typos
- init script reload was missing

* Sun Feb  1 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.6-1
- fixed comments and readme to correspond current status

* Sun Feb  1 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.6-1
- now each target has its own ttl setting

* Sat Jan 31 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-8
- check for no targets specified in conf

* Sat Jan 31 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-7
- all except DEBUG is now syslogged

* Sat Jan 31 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-4
- added ttl setting handling for ping packets. currently all
  ping monitored links share a common ttl value which is
  taken from the first config entry's ttl value.
- when SIGUSR1 is received lsm dumps current packet info to
  syslog ...

* Sat Jan 31 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-3
- changed avg rtt calculation so that only replied packets'
  rtt is counted

* Sat Jan 31 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-2
- Added a ping reply packet min size check

* Fri Jan 30 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.5-1
- started adding support for arp check which is actually
  using arp packets rather than ping packets in case
  your gw administrators have blocked ping

* Thu Jan 29 2009 Mika Ilmaranta <ilmis@nullnet.fi> - 0.4-1
- Initial build

#EOF
