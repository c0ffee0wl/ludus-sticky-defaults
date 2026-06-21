# ludus-wg-callbacks

Keep callbacks from a range to a WireGuard client working by default on a
[Ludus](https://gitlab.com/badsectorlabs/ludus) host, the way they did in Ludus 1.

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

## Install

On the Ludus host, as root, from this repo:

```bash
sudo ./install.sh
```

That copies the patcher to `/usr/local/sbin/ludus-wg-callbacks.sh`, installs the
drop-in to `/etc/systemd/system/ludus.service.d/10-wg-callbacks.conf`, runs
`systemctl daemon-reload`, and patches the file that's on disk right now.

Doing it by hand instead:

```bash
sudo install -m 700 ludus-wg-callbacks.sh /usr/local/sbin/ludus-wg-callbacks.sh
sudo install -d -m 755 /etc/systemd/system/ludus.service.d
sudo install -m 644 ludus.service.d/10-wg-callbacks.conf \
  /etc/systemd/system/ludus.service.d/10-wg-callbacks.conf
sudo systemctl daemon-reload
sudo /usr/local/sbin/ludus-wg-callbacks.sh   # patch the current file once
```

## Apply to ranges you've already deployed

Patching the host file only changes the next deploy. A range that's already up
keeps its `REJECT` rule until the network role runs again:

```bash
ludus range deploy -t network                    # your own range
ludus range deploy -t network --user <userID>    # admin, someone else's range
```

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
bash -n ludus-wg-callbacks.sh      # syntax
shellcheck ludus-wg-callbacks.sh   # lint

systemctl cat ludus                # the drop-in should appear under the unit
journalctl -t ludus-wg-callbacks   # a line each time it patches the file
```

End to end: after `ludus range deploy -t network`, on the router VM,

```bash
iptables -S LUDUS_DEFAULTS | grep 198.51.100.0/24   # should show -j ACCEPT
```

then fire a reverse shell from a range VM back to your Kali box over WireGuard.

## Uninstall

```bash
sudo ./uninstall.sh
```

This stops the re-patching, nothing more. It doesn't revert ranges: the host file
stays `ACCEPT` until the next `ludus-server --update` brings back the `REJECT`
default, and any range you've already deployed keeps `ACCEPT` until you re-deploy
it.

## Safety notes

- The patcher rewrites the file only when the exact unpatched `REJECT` default is
  present, so re-running it is a clean no-op that can't loop or churn the file.
- The drop-in's `ExecStartPre` uses the `-+` prefix. The `+` runs it as root, past
  the service sandbox, so it can write the file; the `-` tells systemd to ignore
  the exit status, so a missing or broken patcher can never stop `ludus` from
  starting.
- It never touches the Ludus binary or the embedded source, never restarts a range,
  and leaves the sibling `inter_vlan_default` and `external_default` rules alone.
