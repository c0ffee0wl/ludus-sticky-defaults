# ludus-sticky-defaults

Two small patches for a [Ludus](https://gitlab.com/badsectorlabs/ludus) host. Each
one restores a Ludus 1 default and makes it stick across upgrades. They share one
installer and don't depend on each other:

1. **WireGuard callbacks**: keep range &rarr; WireGuard client callbacks allowed by
   default. This is what the repo started as.
2. **Default range timezone**: set the default timezone for range VMs to `Etc/UTC`.

Both work the same way. Ludus re-extracts its `ansible/` tree from the server binary
on every `ludus-server --update`, which reverts any hand edit, so each patch is a
tiny idempotent script that a `ludus.service` drop-in re-applies on every (re)start.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [WireGuard callbacks](#wireguard-callbacks)
- [How it works (two layers)](#how-it-works-two-layers)
- [Default range timezone (Etc/UTC)](#default-range-timezone-etcutc)
- [Install](#install)
- [Force a re-apply](#force-a-re-apply)
- [Apply to ranges you've already deployed](#apply-to-ranges-youve-already-deployed)
- [Does it survive restoring or rebooting VMs?](#does-it-survive-restoring-or-rebooting-vms)
- [Verify](#verify)
- [Uninstall](#uninstall)
- [Safety notes](#safety-notes)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## WireGuard callbacks

Keep callbacks from a range to a WireGuard client working by default, the way they
did in Ludus 1.

Ludus 2 changed the router's default rule for traffic leaving a range toward
WireGuard clients (the `198.51.100.0/24` subnet) from `ACCEPT` to `REJECT` (see the
[callbacks-to-wireguard](https://docs.ludus.cloud/docs/troubleshooting/callbacks-to-wireguard)
note). The whole change is one line of the firewall play,
[`set-firewall-rules.yml`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/range-management/tasks/firewall/set-firewall-rules.yml):

```yaml
jump: "{{ network.wireguard_vlan_default | default('REJECT') }}"
```

That `default('REJECT')` is the value used for any range that doesn't set
`network.wireguard_vlan_default` itself. With it, a range VM can't open a
connection back to a client on WireGuard, so a reverse shell to your Kali box
never lands. This flips the default back to `default('ACCEPT')`, which is how
Ludus 1 behaved: ranges that set the key keep their own value, ranges that don't
fall back to `ACCEPT`.

You can make the same edit per range (`network.wireguard_vlan_default: ACCEPT` in
the range config). This is the server-wide version: change the default once, for
everyone, and keep it changed across upgrades.

## How it works (two layers)

The rule lives in two places, and it helps to keep them apart.

On the host (your Ludus controller) is the default a deploy *reads*: the line in
`set-firewall-rules.yml`. `ludus-wg-callbacks.sh` patches that line, and patching
it on its own changes nothing that's already running.

On the router VM is the rule a deploy *writes*: `ludus range deploy -t network`
reads the (now `ACCEPT`) default and inserts the matching iptables rule into the
router's `LUDUS_DEFAULTS` chain.

The host layer is why a one-time `sed` isn't enough. Ludus re-extracts its whole
`ansible/` tree from the server binary on every `ludus-server --update`
([`update.go`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/update.go)),
so any hand edit is back to `REJECT` after the next upgrade. The patch has to put
itself back.

A systemd drop-in handles that. An update stops `ludus`, re-extracts `ansible/`,
swaps the binary, and restarts `ludus`. The drop-in hangs an `ExecStartPre` on
[`ludus.service`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/proxmox-install/templates/ludus.service.j2)
that runs the patcher just before the server comes back up, so the default is
`ACCEPT` again before any deploy can run. It fires on every boot too, and it lives
in `/etc/systemd/system/ludus.service.d/`, outside `/opt/ludus`, where the
re-extraction can't reach it.

The patcher does nothing unless there's something to do. It rewrites the file only
when the exact `REJECT` default is still there, and it touches only the WireGuard
line. If a later Ludus renames that line, reformats it, or fixes the default on its
own, the patcher matches nothing and leaves the file alone. It won't corrupt a file
it doesn't recognise, and it won't fight an upstream fix.

## Default range timezone (Etc/UTC)

Ludus ships a default timezone for range VMs in
[`server-config.yml`](https://gitlab.com/badsectorlabs/ludus/-/blob/main/ludus-server/ansible/server-config.yml):

```yaml
timezone: "America/New_York"
```

That `defaults.timezone` is applied during VM configuration to every range that
doesn't set the key itself, so it's the clock each guest inherits. `ludus-timezone.sh`
flips that one default to `Etc/UTC`; ranges that set the key keep their own value,
ranges that don't now default to UTC.

It's `Etc/UTC`, **not** bare `UTC`, on purpose. The Windows path looks the value up in
`tz_mappings.csv` (which has a row `Etc/UTC,UTC`) and *fails the deploy* if the value
isn't a key there. Plain `UTC` isn't a key, so it would break every Windows VM deploy;
`Etc/UTC` is the spelling that resolves correctly. Linux and macOS accept it too.

This rides on the same machinery as the WireGuard patch. `server-config.yml` is part
of the `ansible/` tree that `ludus-server --update` re-extracts, so a hand edit (e.g.
`nano /opt/ludus/ansible/server-config.yml`) is reverted on the next upgrade. The
companion drop-in (`20-timezone.conf`) re-applies the edit on every `ludus` (re)start.
Like the WireGuard patcher, it rewrites the file only when the exact
`America/New_York` default is present, touches only the `timezone:` line, and is
otherwise a clean no-op.

## Install

On the Ludus host, as root, from this repo:

```bash
sudo ./install.sh
```

That copies both patchers to `/usr/local/sbin/`, installs their drop-ins to
`/etc/systemd/system/ludus.service.d/`, runs `systemctl daemon-reload`, and patches
the files that are on disk right now.

Doing it by hand instead:

```bash
sudo install -d -m 755 /etc/systemd/system/ludus.service.d
sudo install -m 700 ludus-wg-callbacks.sh /usr/local/sbin/ludus-wg-callbacks.sh
sudo install -m 700 ludus-timezone.sh     /usr/local/sbin/ludus-timezone.sh
sudo install -m 644 ludus.service.d/10-wg-callbacks.conf \
  /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf
sudo install -m 644 ludus.service.d/20-timezone.conf \
  /etc/systemd/system/ludus.service.d/20-timezone.conf
sudo systemctl daemon-reload
sudo /usr/local/sbin/ludus-wg-callbacks.sh   # patch the current files once
sudo /usr/local/sbin/ludus-timezone.sh
```

## Force a re-apply

You rarely need to. `install.sh` patches the file once, and the drop-in puts it back
on the next `ludus` start anyway (every boot, and the restart `ludus-server --update`
does). If you want to run it now, just call the patcher yourself. It does the same
thing the `ExecStartPre` hook does, and it doesn't touch the running server:

```bash
sudo /usr/local/sbin/ludus-wg-callbacks.sh
```

It only logs when it actually changes something, so you'll see nothing if the file is
already `ACCEPT`:

```bash
journalctl -t ludus-wg-callbacks
```

To restart the ludus server itself, the lightest option is the single service that
carries the drop-in:

```bash
sudo systemctl restart ludus
```

## Apply to ranges you've already deployed

Patching the host files only changes the next deploy. A range that's already up
keeps its `REJECT` rule until the network role runs again:

```bash
ludus range deploy -t network                    # your own range
ludus range deploy -t network --user <userID>    # admin, someone else's range
```

The timezone is set when a VM is configured, not by the network role, so an
existing guest keeps its old clock until it's re-deployed (`ludus range deploy`,
no `-t network`). New ranges pick up `Etc/UTC` from the start.

For every user at once, as an admin:

```bash
for u in $(ludus user list --json | jq -r '.[].userID'); do
  ludus range deploy -t network --user "$u" || true
done
```

## Does it survive restoring or rebooting VMs?

Yes, with one caveat. The deploy doesn't just set the rule live, it saves the
router's whole ruleset to `/etc/iptables/rules.v4`, and the router runs
`netfilter-persistent`, which reloads that file on boot. So:

- Restoring or rebooting the range member VMs (your targets, the Kali box) is fine.
  The rule lives on the router, which you never touched, so it sticks.
- Rebooting the router VM is fine too: `netfilter-persistent` reloads `rules.v4`.
- The one case you lose it is reverting the router VM itself to a snapshot from
  before you ran `ludus range deploy -t network`. Its saved `rules.v4` rolls back
  with it. Run the network deploy again and you're set; the host-side patch means
  the re-deploy still produces `ACCEPT`.

## Verify

```bash
bash -n ludus-wg-callbacks.sh ludus-timezone.sh      # syntax
shellcheck ludus-wg-callbacks.sh ludus-timezone.sh   # lint

systemctl cat ludus                # both drop-ins should appear under the unit
journalctl -t ludus-wg-callbacks   # a line each time it patches the firewall file
journalctl -t ludus-timezone       # a line each time it patches server-config.yml
```

You can exercise the timezone patcher off a Ludus host against a copy:

```bash
cp /opt/ludus/ansible/server-config.yml /tmp/sc.yml
LUDUS_TZ_FILE=/tmp/sc.yml ./ludus-timezone.sh
grep timezone /tmp/sc.yml          # -> timezone: "Etc/UTC"
```

End to end, WireGuard: after `ludus range deploy -t network`, on the router VM,

```bash
iptables -S LUDUS_DEFAULTS | grep 198.51.100.0/24   # should show -j ACCEPT
```

then fire a reverse shell from a range VM back to your Kali box over WireGuard.

End to end, timezone: after a range (re)deploy, a Linux guest reports `Etc/UTC`
(`timedatectl`) and a Windows guest gets the `UTC` zone with no timezone-lookup
failure during the deploy.

## Uninstall

```bash
sudo ./uninstall.sh
```

This stops the re-patching, nothing more. It doesn't revert ranges: the host files
keep their patched values (`ACCEPT`, `Etc/UTC`) until the next `ludus-server
--update` brings back the stock defaults, and any range you've already deployed
keeps its current behaviour until you re-deploy it.

## Safety notes

- Each patcher rewrites its file only when the exact unpatched default is present
  (`REJECT` / `America/New_York`), so re-running it is a clean no-op that can't loop
  or churn the file.
- Each drop-in's `ExecStartPre` uses the `-+` prefix. The `+` runs it as root, past
  the service sandbox, so it can write the file; the `-` tells systemd to ignore
  the exit status, so a missing or broken patcher can never stop `ludus` from
  starting.
- They never touch the Ludus binary or the embedded source, never restart a range,
  and each scopes its edit to a single line: the WireGuard patch leaves the sibling
  `inter_vlan_default` and `external_default` rules alone, and the timezone patch
  leaves every other `server-config.yml` default alone.
