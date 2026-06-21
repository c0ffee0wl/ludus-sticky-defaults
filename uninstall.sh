#!/bin/bash
#
# uninstall.sh: remove the Ludus host patches (WireGuard callbacks + UTC timezone).
#
# This stops future re-patching only. It does NOT revert ranges: the host files
# keep their patched values (ACCEPT, Etc/UTC) until the next `ludus-server
# --update` re-extracts the defaults, and any range you've already deployed keeps
# its current behaviour until it's re-deployed. To go back to the stock defaults
# everywhere, re-run the update (or restore the files) and then re-deploy each
# range.
#
# Run as root: sudo ./uninstall.sh

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh: must run as root" >&2
    exit 1
fi

rm -f /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf
rm -f /etc/systemd/system/ludus.service.d/20-timezone.conf
rm -f /usr/local/sbin/ludus-wg-callbacks.sh
rm -f /usr/local/sbin/ludus-timezone.sh
# Remove the drop-in dir only if it's now empty; leave it if anything else uses it.
rmdir --ignore-fail-on-non-empty /etc/systemd/system/ludus.service.d 2>/dev/null || true

systemctl daemon-reload

echo "Ludus host patches removed. Ranges already deployed keep their current behaviour until re-deployed."
