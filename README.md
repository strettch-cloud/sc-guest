# sc-guest

Boot-time integration for Ubuntu and Debian virtual machines on Strettch
Cloud. It comes installed on Strettch Cloud images and has nothing to
configure.

It:

- gives cloud-init a datasource that reads the VM's configuration from the
  metadata service at `169.254.169.254`
- lets root log in over SSH with the VM's SSH keys
- on the first boot of a VM created with a root password, sets that password
  and allows password login over SSH
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

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): building, testing and releasing
- [SECURITY.md](SECURITY.md): reporting a security problem
- [Issues](https://github.com/strettch-cloud/sc-guest/issues): reporting a bug

## License

Apache License 2.0. See [LICENSE](LICENSE).
