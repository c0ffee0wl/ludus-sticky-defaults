# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small self-contained tool for a **Ludus** host (Debian 12 + Proxmox; https://gitlab.com/badsectorlabs/ludus) that keeps range &rarr; WireGuard callbacks allowed by default, the way they were in Ludus 1. It's a Bash patcher (`ludus-wg-callbacks.sh`), a systemd drop-in (`ludus.service.d/10-wg-callbacks.conf`), `install.sh` / `uninstall.sh`, and the docs. There is no build system, package manifest, or test suite — the project is the script, the unit drop-in, and their docs.

`install.sh` (root) lands the patcher at `/usr/local/sbin/ludus-wg-callbacks.sh` (mode 700) and the drop-in at `/etc/systemd/system/ludus.service.d/10-wg-callbacks.conf` (mode 644), runs `systemctl daemon-reload`, and patches the on-disk file once; `uninstall.sh` (root) removes both and stops future re-patching but reverts nothing.

## Working on the script

Validate after any change. These are the only checks, and both must pass clean (run them on whichever of the three shell scripts you touched — patcher, `install.sh`, `uninstall.sh`):

```bash
bash -n ludus-wg-callbacks.sh      # syntax
shellcheck ludus-wg-callbacks.sh   # lint
```

The patcher runs under `set -uo pipefail` — deliberately **not** `set -e`. Its no-op paths rely on explicit `|| exit 0` guards and an `if ! sed`, so keep new fallible commands guarded the same way rather than reaching for `set -e` (which `install.sh`/`uninstall.sh` do use, since they should abort on any failure).

It only does anything on a real Ludus host (needs root and the extracted ansible tree). To exercise it off-host, point it at a copy with the `LUDUS_FW_FILE` env var:

```bash
cp /path/to/set-firewall-rules.yml /tmp/fw.yml
LUDUS_FW_FILE=/tmp/fw.yml ./ludus-wg-callbacks.sh   # patches the copy, logs to syslog
```

`README.md` has the install/uninstall steps and the end-to-end check on the router.

## Why this exists (the non-obvious part)

Ludus 2 changed one line of `set-firewall-rules.yml`, `network.wireguard_vlan_default | default('REJECT')` (was `ACCEPT`). That default is applied to every range that doesn't set the key, and it's what blocks a range VM from connecting back to a client on WireGuard (a reverse shell to a Kali box). Flipping it to `default('ACCEPT')` restores Ludus 1 behaviour without affecting ranges that set the key explicitly.

Two layers, kept deliberately apart:

- **Host layer** — the default a deploy *uses*: the line in `/opt/ludus/ansible/.../set-firewall-rules.yml`. This script patches it. Patching alone changes nothing already running.
- **Router layer** — the live rule a deploy *produces*: `ludus range deploy -t network` reads the default and writes the iptables rule into the router's `LUDUS_DEFAULTS` chain, then saves it to the router's `/etc/iptables/rules.v4` (restored on boot by `netfilter-persistent`).

The reason this is a re-applying daemon hook and not a one-time `sed`: Ludus re-extracts its whole `ansible/` tree from the server binary on every `ludus-server --update`, reverting the edit. The update restarts `ludus`, so a `ludus.service` `ExecStartPre` drop-in re-applies the patch on that restart and on every boot.

## Invariants that must not break

Breaking any of these risks corrupting a Ludus file, fighting a future upstream change, or stopping the Ludus server from starting:

- **Only rewrite the file when the exact unpatched string is present.** The `grep -qF "network.wireguard_vlan_default | default('REJECT')"` guard is what makes the script idempotent (a clean no-op when already patched) and self-deactivating (if upstream renames/reformats the line or fixes the default, nothing matches and the file is left untouched). Never blindly `sed -i` — that rewrites the file every run, churns its mtime, and would corrupt a file it doesn't recognise.
- **Scope the substitution to the WireGuard line** (`sed` address `/wireguard_vlan_default/`). The sibling `inter_vlan_default` and `external_default` defaults must never be touched.
- **Don't `chown`/`chmod` the file by path after writing.** `sed -i` already preserves the mode and replaces the path atomically without following a symlink, so it's symlink-safe on its own. A post-write `chown`/`chmod` on a path inside the ludus-writable `/opt/ludus` tree would instead open a symlink/TOCTOU window — root retargeting an arbitrary file's owner/mode for a process running as the `ludus` user. Ownership drifting to `root:root` after the edit is harmless: ansible only reads this file, and the next `ludus-server --update` re-extracts and chowns the tree back to `ludus`.
- **Keep the drop-in's `-+` prefix.** `+` runs the patcher as root, past the service sandbox (`ProtectSystem=strict`, `ReadWritePaths=/opt/ludus`, `User=ludus`), so it can write the file. `-` makes systemd ignore the exit status, so a missing or failing patcher can never block `ludus` from starting. Dropping either is dangerous.
- **Exit 0 on every no-op path** (file absent, already patched, upstream changed). The script must be safe to run on any host at any time, including mid-upgrade.
- **Never edit the Ludus binary or its embedded source, and never restart or redeploy a range.** This tool only patches the extracted host file; applying it to running ranges is the operator's explicit `ludus range deploy -t network`.
