"""cloud-init datasource for Strettch Cloud.

On a new instance it reads the VM's metadata document, user data and vendor
data from the metadata service at 169.254.169.254 (Metadata API v1). The VM
has no address at that point and its network has no DHCP, so the first NIC
gets a temporary address for the requests.

This is a top-level module, not part of a package named in
datasource_pkg_list. When the package is removed but its settings stay,
cloud-init then finds no datasource, instead of failing to import the
package in every stage.

It uses only the parts of cloud-init that are the same from 22.4 to 26.2, so
it does its own HTTP and sets the temporary address with ip(8).
"""

import contextlib
import json
import logging
import os
import subprocess

from cloudinit import dmi, sources
from cloudinit.event import EventScope, EventType

from sc_guest import metadata

LOG = logging.getLogger(__name__)

# Every VM can use the same address: the metadata service answers on the
# VM's own link, before any traffic reaches the network.
TEMPORARY_ADDRESS = "169.254.10.10/16"

# DMI manufacturer of every Strettch Cloud VM.
MANUFACTURER = "Strettch Cloud"

SYS_CLASS_NET = "/sys/class/net"


class DataSourceStrettchCloud(sources.DataSource):
    dsname = "StrettchCloud"

    # The package sets network: {config: disabled} (SYSTEM_CFG), so that
    # cloud-init leaves the network alone when this datasource finds nothing.
    # Ranking the datasource's own config above it keeps the first boot
    # working.
    network_config_sources = (
        sources.NetworkConfigSource.CMD_LINE,
        sources.NetworkConfigSource.INITRAMFS,
        sources.NetworkConfigSource.DS,
        sources.NetworkConfigSource.SYSTEM_CFG,
    )

    # A VM's NICs never change after it's created, so the network is written
    # on the first boot only. Later boots never read the service, even if
    # user data asks for updates on every boot.
    supported_update_events = {
        EventScope.NETWORK: {EventType.BOOT_NEW_INSTANCE}
    }
    default_update_events = {EventScope.NETWORK: {EventType.BOOT_NEW_INSTANCE}}

    _network_config = None

    def __init__(self, sys_cfg, distro, paths, ud_proc=None):
        super().__init__(sys_cfg, distro, paths, ud_proc)
        # cloud-init 25.1 and later set this in DataSource.__init__, so it
        # can't be a class attribute.
        self.metadata_address = "http://169.254.169.254"

    def ds_detect(self):
        # cloud-init 25.1 and later call this only when datasource_list
        # holds more than this datasource. The package's list holds only it.
        return dmi.read_dmi_data("system-manufacturer") == MANUFACTURER

    def _get_data(self):
        try:
            with _temporary_address(_first_nic()):
                raw = metadata.get("metadata.json")
                if raw is None:
                    LOG.error(
                        "The metadata service has no document for this VM"
                    )
                    return False
                user_data = metadata.get("user-data")
                vendor_data = metadata.get("vendor-data")
        except metadata.Unavailable as error:
            # cloud-init then finds no datasource and caches nothing, so the
            # next boot tries again.
            LOG.error("%s", error)
            return False

        document = json.loads(raw)
        for key in ("instance-id", "hostname", "network-config"):
            if key not in document:
                raise ValueError(f"metadata document has no {key!r}")
        self.metadata = {
            key: value
            for key, value in document.items()
            if key != "network-config"
        }
        self.metadata["local-hostname"] = document["hostname"]
        self._network_config = document["network-config"]
        self.userdata_raw = user_data
        self.vendordata_raw = vendor_data
        LOG.info("Read instance %s", document["instance-id"])
        return True

    @property
    def network_config(self):
        return self._network_config

    def check_instance_id(self, sys_cfg):
        # Every boot after the first: is the cached copy this VM's? Each VM's
        # DMI serial number is its instance id, so no request is needed.
        return sources.instance_id_matches_system_uuid(
            self.get_instance_id(), "system-serial-number"
        )


@contextlib.contextmanager
def _temporary_address(nic):
    # Each change is undone on exit, last first, once it has succeeded. Every
    # undo runs even if a later change or an earlier undo fails; the first
    # error stays attached to the one raised.
    with contextlib.ExitStack() as undo:
        was_up = _is_up(nic)
        _ip("link", "set", "dev", nic, "up")
        if not was_up:
            undo.callback(_ip, "link", "set", "dev", nic, "down")
        _ip("address", "replace", TEMPORARY_ADDRESS, "dev", nic)
        undo.callback(_remove_temporary_address, nic)
        LOG.info("Added temporary address %s to %s", TEMPORARY_ADDRESS, nic)
        yield


def _remove_temporary_address(nic):
    _ip("address", "del", TEMPORARY_ADDRESS, "dev", nic)
    LOG.info("Removed temporary address from %s", nic)


def _first_nic():
    """The physical NIC with the lowest interface index."""
    nics = []
    for name in os.listdir(SYS_CLASS_NET):
        path = os.path.join(SYS_CLASS_NET, name)
        if not os.path.exists(os.path.join(path, "device")):
            continue
        with open(os.path.join(path, "ifindex")) as f:
            nics.append((int(f.read()), name))
    if not nics:
        raise RuntimeError(f"no network interface in {SYS_CLASS_NET}")
    return min(nics)[1]


def _is_up(nic):
    with open(os.path.join(SYS_CLASS_NET, nic, "flags")) as f:
        return bool(int(f.read(), 16) & 0x1)  # IFF_UP


def _ip(*args):
    command = ["ip", *args]
    LOG.debug("Running %s", command)
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(command)}: {result.stderr.strip()}")
    return result.stdout


datasources = [
    (DataSourceStrettchCloud, (sources.DEP_FILESYSTEM,)),
]


def get_datasource_list(depends):
    return sources.list_from_depends(depends, datasources)
