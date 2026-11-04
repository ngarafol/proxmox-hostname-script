#!/bin/sh
# Fail if /cluster/resources lists a qemu/lxc guest without a name.
#
# The bug appears only after the guest's node has been offline for more than
# 5 minutes (pmxcfs drops stale RRD entries then). Run this on a node that
# answers the GUI while the other node is down; it needs root on the PVE node.
set -eu

pvesh get /cluster/resources --type vm --output-format json |
perl -MJSON::PP -e '
    my $data = decode_json(do { local $/; <STDIN> });
    my @missing = map { "$_->{type} $_->{vmid} on $_->{node}" }
        grep { !defined($_->{name}) || $_->{name} eq "" } @$data;
    if (@missing) {
        print "guests without name (API/GUI can only show IDs):\n";
        print "  $_\n" for @missing;
        exit 1;
    }
    printf "OK: %d guests, all with names\n", scalar @$data;
'
