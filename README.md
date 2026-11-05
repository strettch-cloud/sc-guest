# sc-guest

Guest integration for Ubuntu and Debian virtual machines on Strettch Cloud.
It's packaged as `sc-guest`, one architecture-independent `.deb` for every
supported system.

The package:

- gives cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- will set the root password chosen when the VM was created (not built yet)
- will report to the platform whether the VM finished booting (not built yet)

## What it installs

| Path | What it is |
|---|---|
| `/usr/lib/python3/dist-packages/DataSourceStrettchCloud.py` | the cloud-init datasource |
| `/usr/lib/python3/dist-packages/sc_guest/` | helpers that don't need cloud-init, such as `sc_guest.metadata` for reading the metadata service |
| `/etc/cloud/cloud.cfg.d/95_sc-guest.cfg` | `datasource_list: [ StrettchCloud ]` and `network: {config: disabled}` |
| `/etc/cloud/ds-identify.cfg` | `policy: enabled` |

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

Each test runs as root in a throwaway container of a supported system:

```bash
docker run --rm -v "$PWD":/src:ro -w /src debian:12 bash -c '
  tests/setup-cloud-init.sh archive &&
  tests/datasource.sh dist/sc-guest_*_all.deb &&
  tests/lifecycle.sh dist/sc-guest_*_all.deb'
```

- `datasource.sh` installs the package and runs `test_datasource.py` against
  the system's own cloud-init. The metadata service is a local HTTP server,
  and `ip` and `/sys/class/net` are faked. The tests run under coverage, and
  fail if they run less than 98% of the installed code's statements and
  branches.
- `lifecycle.sh` installs, removes and purges the package. After the remove,
  it runs cloud-init's local stage with the settings that stay.

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
