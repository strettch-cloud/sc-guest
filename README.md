# sc-guest

Guest integration for Ubuntu and Debian virtual machines on Strettch Cloud.
It's packaged as `sc-guest`, one architecture-independent `.deb` for every
supported system.

The package will:

- give cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- set the root password chosen when the VM was created
- report to the platform whether the VM finished booting

**Status:** early development. The package builds, installs and removes
cleanly, but doesn't do anything yet.

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
  apt-get install -y --no-install-recommends debhelper build-essential &&
  .github/scripts/build-deb.sh 0.0.0-dev.1'
```

The package lands in `dist/`, with `packages.sha256` next to it.

## Testing

Each test runs as root in a throwaway container of a supported system:

```bash
docker run --rm -v "$PWD":/src:ro -w /src debian:12 bash -c '
  tests/setup-cloud-init.sh archive &&
  tests/lifecycle.sh dist/sc-guest_*_all.deb'
```

`setup-cloud-init.sh proposed` installs the cloud-init update the system is
about to ship instead, as the nightly run does.

| Workflow | Runs on | Does |
|---|---|---|
| `pr.yml` | every pull request | shellcheck, build, lintian, tests on all four systems |
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
