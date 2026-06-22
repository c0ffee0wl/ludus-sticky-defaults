# ludus-sticky-defaults

Two small patches for a [Ludus](https://gitlab.com/badsectorlabs/ludus) host. Each restores a
Ludus 1 default that Ludus 2 changed, and keeps it from reverting on the next upgrade:

- **WireGuard callbacks** — let a range call back to a WireGuard client (a reverse shell to your
  Kali box) again.
- **Default range timezone** — set range VMs to `Etc/UTC` instead of `America/New_York`.

They share one installer and are independent of each other. Ludus rebuilds its `ansible/` tree
from the server binary on every `ludus-server --update`, wiping any hand edit, so each patch is a
small script that a `ludus.service` drop-in re-runs on every (re)start. [How it works](#how-it-works)
has the details.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Install](#install)
- [What it does](#what-it-does)
  - [WireGuard callbacks](#wireguard-callbacks)
  - [Default range timezone](#default-range-timezone)
- [Apply to ranges you've already deployed](#apply-to-ranges-youve-already-deployed)
- [Verify](#verify)
- [Uninstall](#uninstall)
- [How it works](#how-it-works)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Install

On the Ludus host, as root:

```bash
sudo ./install.sh
```

That copies both patchers to `/usr/local/sbin/`, installs their drop-ins under
`/etc/systemd/system/ludus.service.d/`, reloads systemd, and patches the files already on disk.
From here on the drop-ins keep them patched.

<details>
<summary>Or install by hand</summary>

```bash
sudo install -d -m 755 /etc/systemd/system/ludus.service.d
sudo install -m 700 scripts/ludus-wg-callbacks.sh /usr/local/sbin/ludus-wg-callbacks.sh
sudo install -m 700 scripts/ludus-timezone.sh     /usr/local/sbin/ludus-timezone.sh
sudo install -m 644 systemd/ludus.service.d/10-wg-callbacks.conf \
  /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf
sudo install -m 644 systemd/ludus.service.d/20-timezone.conf \
  /etc/systemd/system/ludus.service.d/20-timezone.conf
sudo systemctl daemon-reload
sudo /usr/local/sbin/ludus-wg-callbacks.sh   # patch the current files once
sudo /usr/local/sbin/ludus-timezone.sh
```

</details>

Installing only patches the host. Ranges you've already deployed don't change until you re-deploy
them — see [below](#apply-to-ranges-youve-already-deployed).

## What it does

### WireGuard callbacks

Ludus 2 flipped the router's default rule for traffic from a range toward WireGuard clients (the
`198.51.100.0/24` subnet) from `ACCEPT` to `REJECT` (the
[callbacks-to-wireguard](https://docs.ludus.cloud/docs/troubleshooting/callbacks-to-wireguard)
note covers it). It's one line of
[`set-firewall-rules.yml`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/range-management/tasks/firewall/set-firewall-rules.yml):

```yaml
jump: "{{ network.wireguard_vlan_default | default('REJECT') }}"
```

That `default('REJECT')` is what a range gets unless it sets `network.wireguard_vlan_default`
itself, and it's what stops a range VM from opening a connection back to a WireGuard client — so
your reverse shell never lands. The patch changes the default to `ACCEPT`. Ranges that set the key
keep their own value.

You could set `network.wireguard_vlan_default: ACCEPT` per range in its config instead; this just
does it once, server-wide, and keeps it that way across upgrades.

### Default range timezone

Ludus configures every range VM with a default timezone from
[`server-config.yml`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/server-config.yml):

```yaml
timezone: "America/New_York"
```

The patch changes it to `Etc/UTC`. As with WireGuard, a range that sets `defaults.timezone` itself
keeps its own value.

The value has to be `Etc/UTC`, not bare `UTC`: the Windows path looks it up in `tz_mappings.csv`
(which has the row `Etc/UTC,UTC`) and fails the deploy if the value isn't a key there. Plain `UTC`
isn't, so it would break every Windows VM deploy. Linux and macOS take `Etc/UTC` fine.

## Apply to ranges you've already deployed

The host patch only affects the next deploy. A range that's already up keeps its old behaviour
until you re-run the relevant deploy:

```bash
ludus range deploy -t network    # WireGuard rule (network role only)
ludus range deploy               # timezone — set at VM-config time, so a full deploy
```

Admins can target another user's range with `--user <userID>`, or hit everyone at once:

```bash
for u in $(ludus user list --json | jq -r '.[].userID'); do
  ludus range deploy -t network --user "$u" || true
done
```

New ranges pick up both defaults from the start.

**Reboots and restores.** A network deploy doesn't just set the WireGuard rule live — it saves the
router's ruleset to `/etc/iptables/rules.v4`, which `netfilter-persistent` reloads on boot. So
rebooting or restoring your target VMs or the router itself is fine. The one way to lose the rule
is reverting the *router* to a snapshot taken before that deploy; re-run `ludus range deploy -t
network` and it's back.

## Verify

After installing, both drop-ins should show up under the unit, and each patcher logs a line
whenever it actually changes a file:

```bash
systemctl cat ludus                # 10-wg-callbacks.conf and 20-timezone.conf listed
journalctl -t ludus-wg-callbacks   # one line each time it patches the firewall file
journalctl -t ludus-timezone       # one line each time it patches server-config.yml
```

You can run a patcher yourself any time — it's exactly what the `ExecStartPre` hook does, doesn't
disturb the running server, and only logs when there's something to change:

```bash
sudo /usr/local/sbin/ludus-wg-callbacks.sh
```

Or try one off a Ludus host, against a copy:

```bash
cp /opt/ludus/ansible/server-config.yml /tmp/sc.yml
LUDUS_TZ_FILE=/tmp/sc.yml ./scripts/ludus-timezone.sh
grep timezone /tmp/sc.yml           # -> timezone: "Etc/UTC"
```

End to end: after `ludus range deploy -t network`, the router should show the rule —

```bash
iptables -S LUDUS_DEFAULTS | grep 198.51.100.0/24   # -j ACCEPT
```

— and a reverse shell from a range VM back to your Kali box over WireGuard should connect. For the
timezone, after a range re-deploy a Linux guest reports `Etc/UTC` (`timedatectl`) and a Windows
deploy finishes without the timezone-lookup failure.

Touching a script? Two checks, and both must be clean:

```bash
bash -n   scripts/ludus-wg-callbacks.sh scripts/ludus-timezone.sh
shellcheck scripts/ludus-wg-callbacks.sh scripts/ludus-timezone.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

This only stops the re-patching. It reverts nothing: the host files keep their patched values
until the next `ludus-server --update` restores the stock defaults, and deployed ranges keep their
behaviour until you re-deploy them.

## How it works

The patch lives in two layers that do different jobs:

- **Host** — the default a deploy *reads*: the line in `set-firewall-rules.yml` (or
  `server-config.yml`). The patcher edits this, and on its own it changes nothing already running.
- **Router** — the rule a deploy *writes*: `ludus range deploy -t network` reads the patched
  `ACCEPT` default and writes the matching iptables rule into the router's `LUDUS_DEFAULTS` chain.
  (The timezone has no router layer; it lands when a VM is configured, which is a full deploy.)

A one-time edit to the host file wouldn't last. Every `ludus-server --update` re-extracts the
whole `ansible/` tree from the server binary
([`update.go`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/update.go)), so the
edit is gone after the next upgrade. That's why each patch ships as a systemd drop-in: an update
stops `ludus`, re-extracts `ansible/`, then restarts it, and the drop-in hangs an `ExecStartPre`
on [`ludus.service`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/proxmox-install/templates/ludus.service.j2)
that re-applies the patch just before the server comes back — on every update, and on every boot.
The drop-ins live under `/etc/systemd/system/`, outside `/opt/ludus`, where the re-extraction
can't reach them.

Each patcher rewrites its file only when the exact unpatched default is still present
(`default('REJECT')` / `timezone: "America/New_York"`), and only on that one line. That guard does
a lot of work:

- Once patched it's a clean no-op, so re-running it can't churn the file or get stuck in a loop.
- If a later Ludus renames the line, reformats it, or fixes the default itself, nothing matches and
  the file is left untouched — the patch steps aside rather than fighting upstream or corrupting a
  file it doesn't recognise.
- The edit is scoped to the one line, so the WireGuard patch never touches the sibling
  `inter_vlan_default` and `external_default` rules, and the timezone patch never touches another
  `server-config.yml` default.

Two more safety details:

- The drop-in's `ExecStartPre` carries a `-+` prefix. The `+` runs the patcher as root, past the
  service sandbox, so it can write the file; the `-` tells systemd to ignore its exit status, so a
  missing or broken patcher can never keep `ludus` from starting.
- The patchers never touch the Ludus binary or its embedded source, and never restart or redeploy
  a range. Applying the change to a running range is always your own explicit `ludus range deploy`.
