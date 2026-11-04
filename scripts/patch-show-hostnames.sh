#!/bin/sh
# Apply (or revert) the offline guest-name fix on the local Proxmox VE node.
#
# Usage: sudo ./scripts/patch-show-hostnames.sh [--persist | --revert]
#
#   --persist  also install an APT hook that re-applies the patch after a
#              pve-manager upgrade (the hook runs an installed copy of this
#              script with the patch; log: /var/log/proxmox-show-hostnames.log)
#   --revert   remove the APT hook and revert the patch
#
# Without options it only applies the patch on this node.
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PATCH_FILE="$REPO_DIR/patches/show-hostnames.patch"
TARGET_DIR=/usr/share/perl5
TARGET="$TARGET_DIR/PVE/API2/Cluster.pm"

INSTALL_DIR=/usr/local/lib/proxmox-show-hostnames
INSTALLED_APPLY="$INSTALL_DIR/scripts/patch-show-hostnames.sh"
INSTALLED_PATCH="$INSTALL_DIR/patches/show-hostnames.patch"
APT_CONF=/etc/apt/apt.conf.d/86proxmox-show-hostnames
LOG_FILE=/var/log/proxmox-show-hostnames.log

die() {
    echo "error: $*" >&2
    exit 1
}

restart_services() {
    systemctl restart pvedaemon pveproxy
}

install_hook() {
    mkdir -p "$(dirname "$INSTALLED_APPLY")" "$(dirname "$INSTALLED_PATCH")"

    install -m 0755 "$0" "$INSTALLED_APPLY"
    install -m 0644 "$PATCH_FILE" "$INSTALLED_PATCH"

    cat > "$APT_CONF" <<'EOF'
// Re-apply the show-hostnames patch after a pve-manager upgrade.
DPkg::Pre-Install-Pkgs {
    "while read -r pkg; do case $pkg in *pve-manager*) touch /tmp/.proxmox-show-hostnames; break;; esac; done < /dev/stdin";
};

DPkg::Post-Invoke {
    "[ -f /tmp/.proxmox-show-hostnames ] && { /usr/local/lib/proxmox-show-hostnames/scripts/patch-show-hostnames.sh >> /var/log/proxmox-show-hostnames.log 2>&1; rm -f /tmp/.proxmox-show-hostnames; }; exit 0";
};
EOF

    chmod 0644 "$APT_CONF"
    echo "persistence hook installed: $APT_CONF (log: $LOG_FILE)"
}

remove_hook() {
    if [ -f "$APT_CONF" ] || [ -d "$INSTALL_DIR" ]; then
        rm -f "$APT_CONF"
        rm -rf "$INSTALL_DIR"
        echo "persistence hook removed"
    fi
}

[ "$(id -u)" -eq 0 ] || die "run as root on a Proxmox VE node"
[ -f "$PATCH_FILE" ] || die "$PATCH_FILE not found"
[ -f "$TARGET" ] || die "$TARGET not found (is pve-manager installed?)"
command -v patch >/dev/null 2>&1 || die "patch(1) is required: apt-get install patch"

case "${1:-}" in
    '') persist=0; revert=0 ;;
    --persist) persist=1; revert=0 ;;
    --revert) persist=0; revert=1 ;;
    *) die "unknown option '$1' (expected --persist or --revert)" ;;
esac

if [ "$revert" = 1 ]; then
    remove_hook
    if ! patch -R --forward -p1 -d "$TARGET_DIR" --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
        echo "fix is not applied to $TARGET"
        exit 0
    fi

    patch -R --forward -p1 -d "$TARGET_DIR" < "$PATCH_FILE" >/dev/null
    perl -c "$TARGET" >/dev/null 2>&1 || die "reverted file does not compile"
    restart_services
    echo "reverted; pvedaemon and pveproxy restarted"
    exit 0
fi

if [ "$persist" = 1 ]; then
    install_hook
fi

if grep -q 'name hostname' "$TARGET"; then
    echo "fix already applied to $TARGET"
    exit 0
fi

BACKUP="/root/Cluster.pm.pre-offline-names.$(date +%Y%m%d-%H%M%S)"
cp -a "$TARGET" "$BACKUP"

if ! patch -p1 -d "$TARGET_DIR" --forward < "$PATCH_FILE" >/dev/null; then
    cp -a "$BACKUP" "$TARGET"
    die "patch failed; restored $TARGET from $BACKUP"
fi

if ! perl -c "$TARGET" >/dev/null 2>&1; then
    cp -a "$BACKUP" "$TARGET"
    die "patched file does not compile; restored $TARGET from $BACKUP"
fi

restart_services
echo "applied to $TARGET"
echo "backup: $BACKUP"
echo "pvedaemon and pveproxy restarted"
if [ "$persist" = 0 ] && [ "$0" != "$INSTALLED_APPLY" ]; then
    echo "persistence not installed (use --persist)"
fi
