#!/bin/sh
# Apply (or revert) the offline guest-name fix on every online cluster node,
# including the APT hook that keeps it applied after pve-manager upgrades.
#
# Usage: sudo ./scripts/patch-show-hostnames-all.sh [--revert]
#
# Run on any node that has this repository checked out. Cluster nodes have
# passwordless root SSH between them, so the other nodes are driven over SSH.
# Offline nodes are skipped; rerun once they are back.
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
APPLY=scripts/patch-show-hostnames.sh
PATCH=patches/show-hostnames.patch
TMP_DIR=/root/.proxmox-show-hostnames

die() {
    echo "error: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "run as root on a Proxmox VE node"
command -v pvesh >/dev/null 2>&1 || die "pvesh not found (is this a Proxmox VE node?)"
[ -f "$REPO_DIR/$APPLY" ] || die "$REPO_DIR/$APPLY not found"
[ -f "$REPO_DIR/$PATCH" ] || die "$REPO_DIR/$PATCH not found"

case "${1:-}" in
    '') node_args=--persist ;;
    --revert) node_args=--revert ;;
    *) die "unknown option '$1' (expected --revert)" ;;
esac

status=$(pvesh get /cluster/status --output-format json) ||
    die "could not read /cluster/status"

nodes=$(printf '%s' "$status" |
    perl -MJSON::PP -e 'my $d = decode_json(do { local $/; <STDIN> });
        for (@$d) {
            next if $_->{type} ne "node" || !$_->{online};
            printf "%s %d %s\n", $_->{name}, $_->{"local"} ? 1 : 0, $_->{ip} // "";
        }') || die "could not parse /cluster/status"

offline=$(printf '%s' "$status" |
    perl -MJSON::PP -e 'my $d = decode_json(do { local $/; <STDIN> });
        print join(" ", map { $_->{name} }
            grep { $_->{type} eq "node" && !$_->{online} } @$d);') ||
    die "could not parse /cluster/status"

[ -n "$nodes" ] || die "no online nodes found"

ssh_node() {
    if [ "$use_pinned_key" = 1 ]; then
        ssh -o "UserKnownHostsFile=/etc/pve/nodes/$node/ssh_known_hosts" \
            -o "HostKeyAlias=$node" -o GlobalKnownHostsFile=/dev/null \
            -o BatchMode=yes -o ConnectTimeout=10 "$@"
    else
        ssh -o "HostKeyAlias=$node" -o BatchMode=yes -o ConnectTimeout=10 "$@"
    fi
}

printf '%s\n' "$nodes" | while read -r node is_local node_ip; do
    target=$node
    use_pinned_key=0
    if ! getent hosts "$node" >/dev/null 2>&1; then
        target=${node_ip:-$node}
        if [ "$target" != "$node" ] && [ -s "/etc/pve/nodes/$node/ssh_known_hosts" ]; then
            use_pinned_key=1
        fi
    fi
    if [ "$target" != "$node" ]; then
        echo "== $node (name not resolvable, using $target)"
    else
        echo "== $node"
    fi

    if [ "$is_local" -eq 1 ]; then
        "$REPO_DIR/$APPLY" "$node_args"
        continue
    fi

    tar -C "$REPO_DIR" -czf - "$APPLY" "$PATCH" |
        ssh_node "$target" "rm -rf $TMP_DIR && mkdir -p $TMP_DIR && tar -xzf - -C $TMP_DIR"
    ssh_node -n "$target" "$TMP_DIR/$APPLY" "$node_args"
done

if [ -n "$offline" ]; then
    echo "offline, skipped: $offline (rerun when they are back)" >&2
    exit 1
fi
