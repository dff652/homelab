#!/bin/sh
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
# 如果占用超过 90%
if [ "$COUNT" -gt "$((MAX * 90 / 100))" ]; then
    logger "Conntrack table near full ($COUNT/$MAX), clearing now..."
    /etc/init.d/firewall restart
fi
