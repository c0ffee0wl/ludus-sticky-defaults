#!/bin/bash
#
# install.sh: install ludus-wg-callbacks on a Ludus host.
#
#   - copies the patcher to /usr/local/sbin
#   - installs the ludus.service ExecStartPre drop-in
#   - reloads systemd and patches the currently-extracted file once
#
# Run as root from the repo directory: sudo ./install.sh

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root" >&2
    exit 1
fi

src_dir="$(cd "$(dirname "$0")" && pwd)"
sbin="/usr/local/sbin/ludus-wg-callbacks.sh"
dropin_dir="/etc/systemd/system/ludus.service.d"
dropin="$dropin_dir/10-wg-callbacks.conf"

install -m 700 "$src_dir/ludus-wg-callbacks.sh" "$sbin"
install -d -m 755 "$dropin_dir"
install -m 644 "$src_dir/ludus.service.d/10-wg-callbacks.conf" "$dropin"

systemctl daemon-reload

# Patch whatever is on disk right now; the drop-in handles future restarts and
# upgrades.
"$sbin"

cat <<'EOF'

ludus-wg-callbacks installed.

  patcher : /usr/local/sbin/ludus-wg-callbacks.sh
  drop-in : /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf

The host-side default is now ACCEPT and will be re-applied on every ludus
(re)start, including the restart that `ludus-server --update` performs.

Ranges you've already deployed keep their current REJECT rule until you re-run
the network role. For one range:

  ludus range deploy -t network

For every user (run as an admin):

  for u in $(ludus user list --json | jq -r '.[].userID'); do
    ludus range deploy -t network --user "$u" || true
  done
EOF
