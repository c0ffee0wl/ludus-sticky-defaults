#!/bin/bash
#
# ludus-wg-callbacks.sh: keep range -> WireGuard callbacks allowed by default on
# a Ludus host.
#
# Ludus 2 changed the router's default rule for traffic leaving a range toward
# WireGuard clients (the 198.51.100.0/24 subnet) from ACCEPT to REJECT. The whole
# change is one line of the firewall play:
#
#   jump: "{{ network.wireguard_vlan_default | default('REJECT') }}"
#
# in /opt/ludus/ansible/range-management/tasks/firewall/set-firewall-rules.yml.
# That default('REJECT') is the only thing making Ludus 2 restrictive: it's the
# value used for every range that doesn't set network.wireguard_vlan_default
# itself. With it, a range VM can't open a connection back to a client on
# WireGuard (a reverse shell to your Kali box, say). Flipping it back to
# default('ACCEPT') restores the Ludus 1 behaviour exactly: ranges that set the
# key keep their own value, ranges that don't now default to ACCEPT.
#
# This makes that one-word edit, and it's built to run over and over. Ludus
# re-extracts its whole ansible/ tree from the server binary on every
# `ludus-server --update`, so a hand edit is reverted on the next upgrade. The
# companion systemd drop-in (ludus.service.d/10-wg-callbacks.conf) runs this as
# an ExecStartPre, so it re-applies on the restart every update performs, and on
# every boot. See README.md.
#
# It's deliberately a no-op unless it has something to do:
#   - the file is missing (caught mid-extract): do nothing
#   - the line is already ACCEPT, or a future Ludus changed/renamed it: do nothing
# It only rewrites the file when the exact REJECT default is present, so it can't
# churn the file, can't loop, and can't corrupt a file it doesn't recognise.
#
# Override the target file from the environment (e.g. to test off a Ludus host):
#   LUDUS_FW_FILE=/path/to/set-firewall-rules.yml ludus-wg-callbacks.sh

set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

FILE="${LUDUS_FW_FILE:-/opt/ludus/ansible/range-management/tasks/firewall/set-firewall-rules.yml}"

# The exact, unpatched expression we replace. Matching the whole thing (not just
# "REJECT") is what makes this safe: if upstream renames the variable, reformats
# the line, or fixes the default itself, this string isn't found and we leave the
# file untouched.
OLD="network.wireguard_vlan_default | default('REJECT')"

# Nothing to do if the file isn't there (e.g. caught mid-extract during an
# upgrade) or the unpatched default isn't present (already ACCEPT, or upstream
# changed it). Either way: clean exit, no write, no log noise.
[ -f "$FILE" ] || exit 0
grep -qF "$OLD" "$FILE" || exit 0

# Scope the substitution to the wireguard line so the sibling inter_vlan_default
# and external_default rules are never touched. sed -i preserves the file's mode
# and replaces the path atomically *without* following a symlink, so it's
# symlink-safe on its own. We deliberately do NOT chown/chmod the path afterwards:
# a post-write metadata op on a path inside the ludus-writable /opt/ludus tree
# would be a symlink/TOCTOU foothold (root retargeting an arbitrary file's
# owner/mode) for a process running as the ludus user. Ownership may end up
# root:root here, which is harmless -- ansible only reads this file, and the next
# `ludus-server --update` re-extracts the tree and chowns it back to ludus.
if ! sed -i "/wireguard_vlan_default/ s/default('REJECT')/default('ACCEPT')/" "$FILE"; then
    logger -t ludus-wg-callbacks "ERROR: sed failed to patch $FILE; left unchanged"
    exit 1
fi

logger -t ludus-wg-callbacks "patched wireguard_vlan_default default REJECT->ACCEPT in $FILE"
