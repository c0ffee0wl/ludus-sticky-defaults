#!/bin/bash
#
# install.sh: install the Ludus host patches (WireGuard callbacks + UTC timezone).
#
#   - copies both patchers to /usr/local/sbin
#   - installs their ludus.service ExecStartPre drop-ins
#   - reloads systemd and patches the currently-extracted files once
#
# Run as root from the repo directory: sudo ./install.sh

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root" >&2
    exit 1
fi

src_dir="$(cd "$(dirname "$0")" && pwd)"
wg_sbin="/usr/local/sbin/ludus-wg-callbacks.sh"
tz_sbin="/usr/local/sbin/ludus-timezone.sh"
dropin_dir="/etc/systemd/system/ludus.service.d"

install -d -m 755 "$dropin_dir"
install -m 700 "$src_dir/scripts/ludus-wg-callbacks.sh" "$wg_sbin"
install -m 700 "$src_dir/scripts/ludus-timezone.sh" "$tz_sbin"
install -m 644 "$src_dir/systemd/ludus.service.d/10-wg-callbacks.conf" "$dropin_dir/10-wg-callbacks.conf"
install -m 644 "$src_dir/systemd/ludus.service.d/20-timezone.conf" "$dropin_dir/20-timezone.conf"

systemctl daemon-reload

# Patch whatever is on disk right now; the drop-ins handle future restarts and
# upgrades.
"$wg_sbin"
"$tz_sbin"

cat <<'EOF'

Ludus host patches installed.

  patchers : /usr/local/sbin/ludus-wg-callbacks.sh
             /usr/local/sbin/ludus-timezone.sh
  drop-ins : /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf
             /etc/systemd/system/ludus.service.d/20-timezone.conf

The host-side WireGuard default is now ACCEPT and the default range timezone is
now Etc/UTC. Both are re-applied on every ludus (re)start, including the restart
that `ludus-server --update` performs.

Ranges you've already deployed keep their current behaviour until you re-deploy.
The WireGuard rule re-applies with the network role; the timezone is applied when
a VM is (re)configured. For one range:

  ludus range deploy -t network    # WireGuard callback rule
  ludus range deploy               # picks up the new timezone on VM config

For every user (run as an admin):

  for u in $(ludus user list --json | jq -r '.[].userID'); do
    ludus range deploy -t network --user "$u" || true
  done
EOF
