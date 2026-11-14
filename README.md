# sc-guest

Boot-time integration for Ubuntu and Debian virtual machines on Strettch
Cloud. It comes installed on Strettch Cloud images and has nothing to
configure.

It:

- gives cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- lets root log in over SSH with the VM's SSH keys
- on the first boot of a VM created with a root password, sets that password
  and allows password login over SSH. The metadata service holds only the
  password's hash, which goes into `/etc/shadow` as it is.
- tells the platform on every boot whether the VM's setup succeeded, and
  which version of sc-guest it runs. Setup means the root password and
  cloud-init's local and network stages, which set up the network, hostname
  and SSH keys. Commands run with `bootcmd`, and everything cloud-init does
  after those stages, such as `runcmd`, aren't checked.

It's only for Strettch Cloud VMs. On any other cloud, cloud-init finds no
datasource and sets up nothing, not even the network.

Supported systems: Ubuntu 22.04 and 24.04, Debian 12 and 13.

## Install

Strettch Cloud images come with it, and `apt` keeps it up to date. Each
release's `.deb` is also on
[Releases](https://github.com/strettch-cloud/sc-guest/releases).

## Contract with the metadata service

Each stable release also carries `sc-guest-metadata-api.json`, with its
checksum in `sc-guest-metadata-api.json.sha256`. It's a
[Pact](https://docs.pact.io) contract: every request that version sends to
the metadata service and what it needs back, recorded by a test that runs
the package's own code. The metadata service is checked against the contract
of every released version, so a change there can't break a version that VMs
still run. The file holds example values only.

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing and releasing
- [SECURITY.md](SECURITY.md): reporting a security problem
- [Issues](https://github.com/strettch-cloud/sc-guest/issues): reporting a bug

## License

Apache License 2.0. See [LICENSE](LICENSE).
