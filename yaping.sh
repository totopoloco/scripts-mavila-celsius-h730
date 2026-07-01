#!/bin/sh
# Purpose : Linux ping from specific source ip address.
# Ping three differnet ISPs and find out the fastest 
# ping round time for domain www.cyberciti.biz.
# --------------------------------------------------
# Tested on FreeBSD and Linux only.
# --------------------------------------------------
# License: GPL version 3.0
# Author: Vivek Gite {https://www.cyberciti.biz}
# --------------------------------------------------
d="www.yahoo.com" # set me 
 
#
# my three ISPs A, B, and C with their interfaces IPv4 
#
ifconfig -a | grep 'inet'


for e in A:192.168.1.67 B:192.168.1.80 C:192.168.1.128 D:10.23.0.3
do	
	IFS=':'
	set -- $e
	isp="$1"
	ipv4="$2"
	echo "****************************************"
	echo "Ping "$isp" ISP using $ipv4 IP... to $d"
	echo "****************************************"
	ping -c 10 "${d}" -I ${ipv4} 
done
