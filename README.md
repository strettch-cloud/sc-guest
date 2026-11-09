# sc-guest

Boot-time integration for Ubuntu and Debian virtual machines on Strettch
Cloud. It comes installed on Strettch Cloud images, runs on its own at boot,
and has nothing to configure.

**Only for Strettch Cloud VMs.** It limits cloud-init to its own datasource,
so on any other cloud, cloud-init finds no datasource and sets up nothing, not
even the network.

## What it does

- gives cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- lets root log in over SSH with the VM's SSH keys
- on the first boot of a VM created with a root password, sets that password
  and allows password login over SSH, root included
- tells the platform on every boot whether the VM finished booting

Two systemd units do the last two. Both run only when cloud-init does.

| Unit | Runs |
|---|---|
| `sc-guest-password.service` | every boot, after cloud-init's local stage and before its network stage |
| `sc-guest-report.service` | every boot, in the background once the network is up |

## Supported systems

Ubuntu 22.04 and 24.04, Debian 12 and 13. One architecture-independent `.deb`
works on all four.

## Install

Strettch Cloud images come with `sc-guest`, and `apt` upgrades it from the
Strettch Cloud APT repository like any other package.

To add it to an image you build yourself, download the `.deb` from
[Releases](https://github.com/strettch-cloud/sc-guest/releases), check that
this repository's release workflow built it, and install it in the image:

```bash
gh attestation verify sc-guest_1.2.0_all.deb -R strettch-cloud/sc-guest
sudo apt install ./sc-guest_1.2.0_all.deb
```

## Check it on a VM

```bash
cloud-init status --long
sudo cat /var/lib/sc-guest/password.json
```

- `cloud-init status --long` names `DataSourceStrettchCloud` under `detail`.
- `password.json` says `none` for a VM created with SSH keys only, `set` once
  the password is set, and `acked` once the platform has been told.

## Logs

```bash
journalctl -b -u sc-guest-password -u sc-guest-report
```

The password unit also prints to the VM's console, so its messages show there
even when SSH doesn't work. The datasource logs to cloud-init's log,
`/var/log/cloud-init.log`.

## Troubleshooting

**No network after the first boot.** The datasource couldn't reach the
metadata service, or the service has no document for this VM, so cloud-init
found no datasource and left the network alone. `cloud-init status --long`
and `/var/log/cloud-init.log` say which. cloud-init caches nothing in this
case, so a reboot tries again.

**The root password doesn't work.**

- A VM created with SSH keys only gets no password. `password.json` says
  `none`.
- A password in your user data replaces the one chosen at creation.
- Otherwise, the password unit's log says what failed. The platform isn't told
  until the password is set, so the next boot tries again.

**SSH refuses password login.** `ssh_pwauth` in your user data wins over this
package's setting. To see what sshd uses:

```bash
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
```

**The boot report says `error`.** The boot report carries errors
from cloud-init's local and network stages and from the password unit.
`cloud-init status --long` lists cloud-init's. Failures of your own scripts
don't count.

## Configuration

There's nothing to configure. A root password or `ssh_pwauth` in your user
data wins over this package's. For SSH, that's because sshd keeps the first
value it reads, and cloud-init's `50-cloud-init.conf` sorts before
`55-sc-guest-password.conf`.

The package sets cloud-init's `disable_root: false`, so root can log in over
SSH with the VM's keys. cloud-init's default, and the value in Ubuntu's and
Debian's `/etc/cloud/cloud.cfg`, is `true`: root's keys then only print a
message saying to log in as the default user, such as `ubuntu`. Your user
data can still set it back to `true`, because cloud-init ranks user data
above `/etc/cloud/cloud.cfg.d`.

## Files

Installed:

| Path | What it is |
|---|---|
| `/usr/lib/python3/dist-packages/DataSourceStrettchCloud.py` | the cloud-init datasource |
| `/usr/lib/python3/dist-packages/sc_guest/` | helpers that don't need cloud-init, such as `sc_guest.metadata` for reading the metadata service |
| `/etc/cloud/cloud.cfg.d/95_sc-guest.cfg` | `datasource_list: [ StrettchCloud ]`, `network: {config: disabled}` and `disable_root: false` |
| `/etc/cloud/ds-identify.cfg` | `policy: enabled` |
| `/usr/lib/sc-guest/sc-guest` | the password and boot-report commands |
| `/usr/lib/systemd/system/sc-guest-password.service`, `sc-guest-report.service` | the units that run them |

Written at boot:

| Path | Holds |
|---|---|
| `/var/lib/sc-guest/password.json` | the instance ID and whether its password was set, confirmed, or not needed |
| `/run/sc-guest/password-error` | this boot's password error, for this boot's report |
| `/etc/ssh/sshd_config.d/55-sc-guest-password.conf` | the SSH setting, on VMs created with a password |

The state is kept per instance ID, so a VM made from another VM's disk sets
its own password.

## How it works

**The datasource.** On a VM's first boot, the VM has no address and its
network has no DHCP. The datasource:

1. gives the first NIC the temporary address `169.254.10.10/16`
2. reads `/v1/metadata.json`, `/v1/user-data` and `/v1/vendor-data` from
   `http://169.254.169.254`, sending `Metadata-Flavor: StrettchCloud`. It
   never reads the password.
3. removes the temporary address
4. hands cloud-init the document's network config, which matches each NIC by
   MAC, with each NIC's entry keyed by that NIC's name

Each request waits up to 10 s for an answer. Without one, the datasource
retries 30 times, backing off from 1 s to 10 s: 275 s of waiting, plus up to
10 s for each attempt. If the service still hasn't answered, or answers 404
for `metadata.json`, cloud-init finds no datasource.

NICs keep the names udev gives them, such as `ens3`. The metadata service
keys each NIC's entry in the network config by the NIC's role, `public0` or
`private0`, and puts the default route and the nameservers on `public0`, or
on `private0` if the VM has no public NIC. The datasource replaces each role
with the name of the NIC that has the entry's MAC, because netplan uses the
key in the names of the files it writes. An entry keeps its role, and the
datasource logs a warning, if no NIC has its MAC or another entry already has
that name.

On later boots, cloud-init uses its cached copy while the VM's DMI serial
number is still the cached instance ID. The datasource doesn't read the
metadata service again, and the network written on the first boot stays.

**The password.** Only on a VM's first boot, and only when this package's
datasource found the VM, the password unit asks for `GET /v1/password`. It
sets root's password with `chpasswd`, writes the SSH setting, checks both, and
records the result in `password.json`. The reporter then confirms it with
`POST /v1/password/ack`, which lets the platform delete the password. A VM
created with SSH keys only gets `404`, and nothing is set.

The password unit retries exactly as the datasource does, because the rest of
the boot waits for it. If the service still hasn't answered, the unit sets
nothing, and the next boot tries again.

**The boot report.** `POST /v1/report/boot` says `done`, or `error` with the
errors from this boot's setup, read from cloud-init's
`/run/cloud-init/status.json`: its local and network stages, the password
unit, and, when no datasource loaded, the reason cloud-init gave. Failures of
your own scripts, `bootcmd`'s included, don't count. The reporter retries in
the background with no limit, backing off to 60 s, so it never holds up the
boot.

## Uninstall

`sudo apt remove sc-guest` is the tested way. It keeps the package's
cloud-init settings, so cloud-init then finds no datasource and leaves the
network as it is.

`sudo apt purge sc-guest` also deletes those settings and `/var/lib/sc-guest`.
What cloud-init does on the next boot after a purge isn't tested.

Neither removes `/etc/ssh/sshd_config.d/55-sc-guest-password.conf`, since the
VM may depend on password login. Delete it and reload sshd to go back to the
image's SSH settings.

## Reporting problems

- Bugs: [open an issue](https://github.com/strettch-cloud/sc-guest/issues)
  with the system, the version from `dpkg-query -W sc-guest`, and the logs
  above. Leave out passwords and user data.
- Security problems: see [SECURITY.md](SECURITY.md). Don't open a public
  issue.
- Building, testing and releasing: see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
