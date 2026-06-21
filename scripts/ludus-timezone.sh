#!/bin/bash
#
# ludus-timezone.sh: keep the default range timezone at Etc/UTC on a Ludus host.
#
# Ludus ships a default timezone for range VMs in server-config.yml:
#
#   timezone: "America/New_York"
#
# in /opt/ludus/ansible/server-config.yml. That default is applied during VM
# configuration (configure-ip-and-hostname-{linux,windows,macos}.yml) to every
# range that doesn't set defaults.timezone itself, so it's the clock every guest
# inherits. This flips that one default to Etc/UTC; ranges that set the key keep
# their own value, ranges that don't now default to UTC.
#
# Etc/UTC, not bare UTC: the Windows path looks the value up in tz_mappings.csv
# (row `Etc/UTC,UTC`) and *fails the deploy* if it isn't a key there. Plain "UTC"
# isn't a key, so it would break every Windows VM deploy. Linux/macOS accept
# Etc/UTC too.
#
# This makes that one-line edit, and it's built to run over and over. Ludus
# re-extracts its whole ansible/ tree from the server binary on every
# `ludus-server --update`, so a hand edit is reverted on the next upgrade. The
# companion systemd drop-in (ludus.service.d/20-timezone.conf) runs this as an
# ExecStartPre, so it re-applies on the restart every update performs, and on
# every boot. See README.md.
#
# It's deliberately a no-op unless it has something to do:
#   - the file is missing (caught mid-extract): do nothing
#   - already Etc/UTC, or a future Ludus changed/renamed the default: do nothing
# It only rewrites the file when the exact America/New_York default is present, so
# it can't churn the file, can't loop, and can't corrupt a file it doesn't
# recognise.
#
# Override the target file from the environment (e.g. to test off a Ludus host):
#   LUDUS_TZ_FILE=/path/to/server-config.yml ludus-timezone.sh

set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

FILE="${LUDUS_TZ_FILE:-/opt/ludus/ansible/server-config.yml}"

# The exact, unpatched default we replace. Matching the whole assignment (not just
# the value) is what makes this safe: if upstream renames the key, reformats the
# line, or changes the default itself, this string isn't found and we leave the
# file untouched.
OLD='timezone: "America/New_York"'

# Nothing to do if the file isn't there (e.g. caught mid-extract during an
# upgrade) or the unpatched default isn't present (already Etc/UTC, or upstream
# changed it). Either way: clean exit, no write, no log noise.
[ -f "$FILE" ] || exit 0
grep -qF "$OLD" "$FILE" || exit 0

# Scope the substitution to the timezone line so no sibling default is touched.
# sed -i preserves the file's mode and replaces the path atomically *without*
# following a symlink, so it's symlink-safe on its own. We deliberately do NOT
# chown/chmod the path afterwards: a post-write metadata op on a path inside the
# ludus-writable /opt/ludus tree would be a symlink/TOCTOU foothold (root
# retargeting an arbitrary file's owner/mode) for a process running as the ludus
# user. Ownership may end up root:root here, which is harmless -- ansible only
# reads this file, and the next `ludus-server --update` re-extracts the tree and
# chowns it back to ludus.
if ! sed -i '/timezone:/ s|"America/New_York"|"Etc/UTC"|' "$FILE"; then
    logger -t ludus-timezone "ERROR: sed failed to patch $FILE; left unchanged"
    exit 1
fi

logger -t ludus-timezone "patched defaults.timezone America/New_York->Etc/UTC in $FILE"
