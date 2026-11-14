# Contributing

## Layout

| Path | What it is |
|---|---|
| `src/DataSourceStrettchCloud.py` | the cloud-init datasource |
| `src/sc_guest/` | helpers that don't need cloud-init |
| `src/sc-guest` | the password and boot-report commands |
| `systemd/` | the units that run them |
| `config/` | the cloud-init and ds-identify settings |
| `debian/` | the packaging |
| `tests/` | the tests, run in containers |
| `tests/contract/` | the contract test, run on its own |
| `.github/` | CI, and the build and release scripts |

The reasons behind each setting sit next to it, in the config files, the
units and the module docstrings.

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
container's loopback, which needs `--cap-add NET_ADMIN`. `dist/` keeps the
packages of earlier builds, so name the one you just built:

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro -w /src debian:12 bash -c '
  deb=dist/sc-guest_0.0.0-dev.1_all.deb &&
  tests/setup-cloud-init.sh archive &&
  tests/datasource.sh "$deb" &&
  tests/lifecycle.sh "$deb" &&
  tests/units.sh "$deb" &&
  tests/password.sh "$deb" &&
  tests/report.sh "$deb" &&
  tests/root-login.sh "$deb"'
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
  service: setting the password from its hash, logging in with it over SSH,
  keys-only VMs, sshd's drop-in order, retries and reboots.
- `report.sh` checks the boot report from the system's real cloud-init:
  done, a failing `bootcmd`, and a datasource that's missing or fails.
- `root-login.sh` runs the system's real cloud-init for a VM created with an
  SSH key, then logs in to a local sshd as root with that key. It also
  checks that a customer's `disable_root: true` still wins.

### The contract test

`tests/contract/test_metadata_contract.py` runs the package's own client code
against a [Pact](https://docs.pact.io) mock server, straight from the source
tree. Each test describes one request to the metadata service and the answer
the code relies on, and fails unless the code sends exactly that request.
Together they write `build/pacts/sc-guest-metadata-api.json`, the contract
the metadata service is checked against.

It needs pact-python, which needs Python 3.11 or later, so it doesn't run in
the containers above. The requests are the same on all four systems.

```bash
python3 -m venv /tmp/contract-venv
/tmp/contract-venv/bin/pip install --require-hashes --only-binary :all: \
  -r tests/contract/requirements.txt
/tmp/contract-venv/bin/python -I tests/contract/test_metadata_contract.py -v
```

A change to what the package sends, or to what it needs back, changes the
contract. Describe only what the code relies on: match answers by type, and
leave out error bodies and fields the code doesn't read.

Ubuntu releases new cloud-init versions into its LTS releases.
`setup-cloud-init.sh proposed` installs the version the system is about to
ship instead, as the nightly run does.

| Workflow | Runs on | Does |
|---|---|---|
| `pr.yml` | every pull request | shellcheck, pyflakes, build, lintian, tests with coverage on all four systems, the contract test, then a comment with each system's coverage |
| `nightly.yml` | every night | the same tests with each system's proposed cloud-init |
| `beta.yml` | every merge to `main` | beta pre-release |
| `release.yml` | manual, from `main` | stable release, with that version's contract |

## Commits and pull requests

- Commit subjects and pull request titles follow
  [Conventional Commits](https://www.conventionalcommits.org/), such as
  `feat:`, `fix:` and `docs:`. The release notes are built from them.
- Pull requests are squash-merged.
- The pull request template asks what changed, why, and how it was tested.

## Versions and releases

Stable releases are tagged `X.Y.Z` and betas `X.Y.Z-beta.N`. Inside the
package, a beta's version is `X.Y.Z~beta.N`, because apt sorts `~` before
anything, so a beta is older than its stable release. Release files are named
after the tag, for example `sc-guest_1.2.0-beta.3_all.deb`.

Every release carries a build attestation, which `gh attestation verify`
checks.

A stable release also carries its contract, `sc-guest-metadata-api.json`,
written by the contract test at the released commit. After each stable
release, copy that file into the metadata service's list of contracts. The
service is checked against every file on the list, and a released version's
file is never changed or removed: VMs keep running old versions.

## Why Python

Both commands are one Python 3 script that uses only the standard library.
`python3` is on every supported system, because cloud-init depends on it, and
it can make HTTP requests and read JSON. perl-base, the other interpreter
that's always installed, can do neither without modules from perl's full
package, and curl isn't installed with cloud-init. The script never imports
cloud-init, so changes to cloud-init's code can't break it. It does read two
files cloud-init writes, its status file and the instance ID, so a cloud-init
update that changes either one could.
