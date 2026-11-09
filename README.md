# sc-guest

Guest integration for Ubuntu and Debian virtual machines on Strettch Cloud.
It's packaged as `sc-guest`, one architecture-independent `.deb` for every
supported system.

The package:

- gives cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- sets the root password chosen when the VM was created
- reports to the platform whether the VM finished booting

## What it installs

| Path | What it is |
|---|---|
| `/usr/lib/python3/dist-packages/DataSourceStrettchCloud.py` | the cloud-init datasource |
| `/usr/lib/python3/dist-packages/sc_guest/` | helpers that don't need cloud-init, such as `sc_guest.metadata` for reading the metadata service |
| `/etc/cloud/cloud.cfg.d/95_sc-guest.cfg` | `datasource_list: [ StrettchCloud ]` and `network: {config: disabled}` |
| `/etc/cloud/ds-identify.cfg` | `policy: enabled` |
| `/usr/lib/sc-guest/sc-guest` | the password and boot-report commands |
| `/usr/lib/systemd/system/sc-guest-password.service`, `sc-guest-report.service` | the units that run them |

## How the datasource works

On a VM's first boot, the VM has no address and its network has no DHCP.
The datasource:

1. gives the first NIC the temporary address `169.254.10.10/16`
2. reads `/v1/metadata.json`, `/v1/user-data` and `/v1/vendor-data` from
   `http://169.254.169.254`, sending `Metadata-Flavor: StrettchCloud`. It
   never reads the password.
3. removes the temporary address
4. hands cloud-init the document's network config, which matches each NIC by
   MAC

Each request waits up to 10 s for an answer. Without one, the datasource
retries after 1, 2, 4 and 8 s, then every 10 s, 30 times in all: 275 s of
waiting, plus up to 10 s for each attempt. If the service still hasn't
answered, or answers 404 for `metadata.json` because there's no document for
this VM, cloud-init finds no datasource. On a first boot the VM then comes up
without a network. cloud-init caches nothing, so the next boot tries again.

Each NIC keeps the names udev gives it: one predictable name, such as `ens3`,
and the others, such as `enp0s3`, as alternative names. The roles `public0`
and `private0` are the keys of the network config, each matched to its NIC by
MAC. The metadata service puts the default route and the nameservers on
`public0`, or on `private0` if the VM has no public NIC.

On later boots, cloud-init uses its cached copy if the VM's DMI serial number
is still the cached instance id. The datasource never reads the metadata
service again, and the network written on the first boot stays.

The settings are chosen so that a failure leaves the VM as it was:

- **The datasource finds nothing.** `network: {config: disabled}` makes
  cloud-init leave the network alone, instead of writing DHCP for the first
  NIC only. The datasource ranks its own network config above this setting,
  so the first boot still gets the real network.
- **The package is removed but its settings stay** (as `apt remove` does).
  The datasource is a top-level module, so cloud-init reports that it found
  no datasource. A module inside a package named in `datasource_pkg_list`
  would make every cloud-init stage fail instead.
- **`datasource_list` stays on one line.** ds-identify only reads a
  single-line list. With `policy: enabled`, ds-identify runs cloud-init on
  every boot and leaves the list as written.

The datasource uses only the parts of cloud-init that are the same in every
supported version, so it does its own HTTP and sets the temporary address
with `ip`.

## What it does at boot

Two systemd units, both started only when cloud-init runs:

| Unit | Runs | Does |
|---|---|---|
| `sc-guest-password.service` | every boot, after cloud-init's local stage and before its network stage | on the first boot of a VM created with a root password, sets it |
| `sc-guest-report.service` | every boot, in the background once the network is up | tells the platform whether the VM finished booting, and confirms a password it set |

**The password.** The unit asks the metadata service for the password with
`GET /v1/password`. It does this only on a VM's first boot, and only when
cloud-init found the VM's metadata with this package's datasource. Then it:

1. sets root's password with `chpasswd`
2. checks root's entry in `/etc/shadow` with perl's `crypt()`
3. allows password login over SSH, root included, with
   `/etc/ssh/sshd_config.d/55-sc-guest-password.conf`
4. checks that `sshd -T` shows `passwordauthentication yes` and
   `permitrootlogin yes`, with a throwaway host key, since the VM has none
   yet
5. reloads sshd if it's running, and records the result in
   `/var/lib/sc-guest/password.json`

The reporter then confirms it with `POST /v1/password/ack`, on that boot or a
later one, which lets the platform delete the password. If a step fails,
nothing is confirmed, the boot report carries the error, and the next boot
tries again.

A VM created with SSH keys only gets `404` from `/v1/password`. Nothing is
set, the drop-in isn't written, and the VM never asks again.

Two settings decide which password and SSH setting win:

- **The unit runs before cloud-init's network stage**, where Ubuntu applies a
  password from the customer's user data, so the customer's wins. Debian
  applies it later, so the customer's wins there too.
- **sshd keeps the first value it reads, in filename order.** cloud-init
  writes a customer's `ssh_pwauth` to `50-cloud-init.conf`, which wins over
  `55-sc-guest-password.conf`. That in turn wins over image defaults such as
  Ubuntu's `60-cloudimg-settings.conf`.

**The boot report.** `POST /v1/report/boot` says `done`, or `error` with the
errors from this boot's setup, read from cloud-init's
`/run/cloud-init/status.json`:

- errors from cloud-init's local and network stages: the datasource, network,
  hostname and SSH keys
- the password unit's error, if it had one
- when no datasource loaded, the reason cloud-init gave. cloud-init 25.1 and
  26.x say why. Debian 12's 22.4.2 only says that none was found.

Failures of the customer's own scripts don't count, because a broken customer
script isn't a failed boot. Those run in cloud-init's later stages, except
`bootcmd`, which is left out too.

The reporter doesn't wait for cloud-init to finish, and it's never ordered
after `cloud-final.service`. That unit is ordered after `multi-user.target`,
so ordering a unit that `multi-user.target` wants after it would make a cycle,
and systemd silently drops a unit to break one.

**Retries.** The password unit retries exactly as the datasource does, 30
times, because the rest of the boot waits for it. If the metadata service
still hasn't answered, the unit sets nothing, the boot report carries the
error, and the next boot tries again. The reporter waits up to 6 s for each
answer, just longer than the metadata service's own 5 s. It retries in the
background with no limit, backing off to 60 s, so it never holds up the boot.

**Files it writes:**

| Path | Holds |
|---|---|
| `/var/lib/sc-guest/password.json` | the instance ID and whether its password was set, confirmed, or not needed |
| `/run/sc-guest/password-error` | this boot's password error, for this boot's report |
| `/etc/ssh/sshd_config.d/55-sc-guest-password.conf` | the SSH setting, on VMs created with a password |

The state is kept per instance ID, so a VM made from another VM's disk sets
its own password. Purging the package removes `/var/lib/sc-guest`, but leaves
the SSH setting in place, since the VM may depend on it.

**Why Python.** Both commands are one Python 3 script that uses only the
standard library. `python3` is on every supported system, because cloud-init
depends on it, and it can make HTTP requests and read JSON. perl-base, the
other interpreter that's always installed, can do neither without modules
from perl's full package, and curl isn't installed with cloud-init. The
script never imports cloud-init, so a cloud-init update can't break it.

## Supported systems

| System | cloud-init it ships |
|---|---|
| Ubuntu 22.04 | 26.1 |
| Ubuntu 24.04 | 26.2 |
| Debian 12 | 22.4.2 |
| Debian 13 | 25.1.4 |

Ubuntu releases new cloud-init versions into its LTS releases, so the
package is tested every night against the version each system is about to
ship, as well as on every pull request against the version it ships today.

## Installing

Strettch Cloud images come with `sc-guest` installed. It's published to the
Strettch Cloud APT repository, so `apt` upgrades it like any other package.

## Building

The package is built on Ubuntu 22.04, the oldest supported system, with
[debhelper](https://manpages.debian.org/debhelper). With Docker:

```bash
docker run --rm -v "$PWD":/src -w /src ubuntu:22.04 bash -c '
  apt-get update &&
  apt-get install -y --no-install-recommends debhelper dh-python build-essential &&
  .github/scripts/build-deb.sh 0.0.0-dev.1'
```

The package lands in `dist/`, with `packages.sha256` next to it.

## Testing

Each test runs as root in a throwaway container of a supported system. The
tests that talk to the fake metadata service put its address on the
container's loopback, which needs `--cap-add NET_ADMIN`:

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro -w /src debian:12 bash -c '
  tests/setup-cloud-init.sh archive &&
  tests/datasource.sh dist/sc-guest_*_all.deb &&
  tests/lifecycle.sh dist/sc-guest_*_all.deb &&
  tests/units.sh dist/sc-guest_*_all.deb &&
  tests/password.sh dist/sc-guest_*_all.deb &&
  tests/report.sh dist/sc-guest_*_all.deb'
```

- `datasource.sh` installs the package and runs `test_datasource.py` against
  the system's own cloud-init. The metadata service is a local HTTP server,
  and `ip` and `/sys/class/net` are faked. The tests run under coverage, and
  fail if they run less than 98% of the installed code's statements and
  branches.
- `lifecycle.sh` installs, removes and purges the package. After the remove,
  it runs cloud-init's local stage with the settings that stay.
- `units.sh` checks that the units are valid, and that
  `systemd-analyze verify` finds no ordering cycle at boot.
- `password.sh` runs the password unit and the ack against a fake metadata
  service: keys-only VMs, sshd's drop-in order, retries and reboots.
- `report.sh` checks the boot report from the system's real cloud-init:
  done, a failing `bootcmd`, and a datasource that's missing or fails.

`setup-cloud-init.sh proposed` installs the cloud-init update the system is
about to ship instead, as the nightly run does.

| Workflow | Runs on | Does |
|---|---|---|
| `pr.yml` | every pull request | shellcheck, pyflakes, build, lintian, tests with coverage on all four systems, then a comment with each system's coverage |
| `nightly.yml` | every night | the same tests with each system's proposed cloud-init |
| `beta.yml` | every merge to `main` | beta pre-release |
| `release.yml` | manual, from `main` | stable release |

## Versions and releases

Stable releases are tagged `X.Y.Z` and betas `X.Y.Z-beta.N`. Inside the
package, a beta's version is `X.Y.Z~beta.N`, because apt sorts `~` before
anything, so a beta is older than its stable release. Release files are named
after the tag, for example `sc-guest_1.2.0-beta.3_all.deb`.

Every release carries a build attestation. To check that a package was built
by this repository's release workflow:

```bash
gh attestation verify sc-guest_1.2.0_all.deb -R strettch-cloud/sc-guest
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
