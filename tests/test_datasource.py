"""Tests the installed datasource against this system's own cloud-init.

Runs as root in a throwaway container of each supported system, after
setup-cloud-init.sh and with the package installed (see datasource.sh). The
metadata service is a local HTTP server, and /sys/class/net and, outside
TestIp, ip(8) are faked, so no network setup is needed.
"""

import http.server
import io
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
from unittest import mock

import DataSourceStrettchCloud as ds_module
from cloudinit import distros, helpers, sources, util
from cloudinit.event import EventScope, EventType
from sc_guest import metadata

CONFIG = "/etc/cloud/cloud.cfg.d/95_sc-guest.cfg"
INSTANCE_ID = "a7357398-9074-42d4-831e-08a4887ffa88"
NETWORK_CONFIG = {
    "version": 2,
    "ethernets": {
        "public0": {
            "match": {"macaddress": "1e:00:8c:00:49:cc"},
            "mtu": 1500,
            "addresses": ["102.202.208.150/24"],
            "nameservers": {"addresses": ["8.8.8.8"]},
            "routes": [{"to": "0.0.0.0/0", "via": "102.202.208.1"}],
        },
        "private0": {
            "match": {"macaddress": "02:01:01:0f:00:04"},
            "mtu": 1500,
            "addresses": ["10.7.1.50/24"],
        },
    },
}
# What cloud-init gets: each entry keyed by the fake NIC with its MAC.
KEYED_NETWORK_CONFIG = {
    "version": 2,
    "ethernets": {
        "ens3": NETWORK_CONFIG["ethernets"]["public0"],
        "ens4": NETWORK_CONFIG["ethernets"]["private0"],
    },
}
DOCUMENT = {
    "instance-id": INSTANCE_ID,
    "hostname": "web-01",
    "team-id": "5f1c2b0e-0000-0000-0000-000000000000",
    "region": "test-1",
    "public-keys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@example"],
    "network-config": NETWORK_CONFIG,
}
USER_DATA = b"#cloud-config\nruncmd: [[touch, /run/user-data-ran]]\n"
IDENTITY_HEADERS = {
    "x-instance-id",
    "x-instance-mac",
    "x-hypervisor-name",
    "x-forwarded-for",
    "traceparent",
}


def system_config():
    return util.read_conf_with_confd("/etc/cloud/cloud.cfg")


class FakeService:
    """A local stand-in for 169.254.169.254 that records every request."""

    def __init__(self, routes):
        self.routes = routes
        self.requests = []
        service = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                service.requests.append(
                    (self.path, {k.lower(): v for k, v in self.headers.items()})
                )
                status, body = service.routes.get(
                    self.path, (404, b'{"code": "PATH_NOT_FOUND"}')
                )
                if callable(status):
                    status, body = status()
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        class Server(http.server.ThreadingHTTPServer):
            def handle_error(self, request, client_address):
                pass  # a client that timed out and hung up

        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True

    def __enter__(self):
        self.thread.start()
        port = self.server.server_address[1]
        self.patch = mock.patch.object(
            metadata, "BASE_URL", f"http://127.0.0.1:{port}/v1/"
        )
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()
        self.server.shutdown()
        self.server.server_close()

    def paths(self):
        return [path for path, _ in self.requests]


def document_routes(document=DOCUMENT):
    return {
        "/v1/metadata.json": (200, json.dumps(document).encode()),
        "/v1/user-data": (200, USER_DATA),
        "/v1/vendor-data": (404, b'{"code": "VENDOR_DATA_NOT_SET"}'),
        "/v1/password": (200, b'{"password": "never-read"}'),
    }


class FakeHost(unittest.TestCase):
    """Fakes /sys/class/net and ip(8) for each test."""

    nics = {
        # name: (ifindex, flags, physical, MAC)
        "docker0": (1, 0x1003, False, "02:42:ac:11:00:02"),
        "ens4": (3, 0x1002, True, "02:01:01:0f:00:04"),
        "ens3": (2, 0x1002, True, "1e:00:8c:00:49:cc"),
    }

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        net = os.path.join(self.tmp.name, "net")
        for name, (ifindex, flags, physical, mac) in self.nics.items():
            os.makedirs(os.path.join(net, name))
            if physical:
                os.makedirs(os.path.join(net, name, "device"))
            with open(os.path.join(net, name, "ifindex"), "w") as f:
                f.write(f"{ifindex}\n")
            with open(os.path.join(net, name, "flags"), "w") as f:
                f.write(f"{flags:#x}\n")
            with open(os.path.join(net, name, "address"), "w") as f:
                f.write(f"{mac}\n")
        self.ip_calls = []
        for target, value in (
            ("SYS_CLASS_NET", net),
            ("_ip", self.fake_ip),
        ):
            patch = mock.patch.object(ds_module, target, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.sleeps = []
        patch = mock.patch.object(metadata, "_sleep", self.sleeps.append)
        patch.start()
        self.addCleanup(patch.stop)

    # ip commands that fail, by their first two arguments.
    ip_failures = ()

    def fake_ip(self, *args):
        self.ip_calls.append(list(args))
        if list(args[:2]) in self.ip_failures:
            raise RuntimeError(f"ip {' '.join(args)}: failed")
        return ""

    def datasource(self, sys_cfg=None):
        paths = helpers.Paths(
            {
                "cloud_dir": os.path.join(self.tmp.name, "cloud"),
                "run_dir": os.path.join(self.tmp.name, "run"),
            }
        )
        distro = distros.fetch("debian")("debian", {}, paths)
        if sys_cfg is None:
            sys_cfg = system_config()
        return ds_module.DataSourceStrettchCloud(sys_cfg, distro, paths)


class TestInstalledSettings(unittest.TestCase):
    def test_cloud_init_uses_only_this_datasource(self):
        self.assertEqual(system_config()["datasource_list"], ["StrettchCloud"])

    def test_datasource_list_is_on_one_line(self):
        # ds-identify only reads a single-line list.
        with open(CONFIG) as f:
            lines = f.read().splitlines()
        self.assertIn("datasource_list: [ StrettchCloud ]", lines)

    def test_network_config_is_disabled_by_default(self):
        self.assertEqual(system_config()["network"], {"config": "disabled"})

    def test_ds_identify_leaves_the_list_as_written(self):
        with tempfile.TemporaryDirectory() as run:
            result = subprocess.run(
                ["/usr/lib/cloud-init/ds-identify", "--force"],
                env={**os.environ, "PATH_RUN": run, "DI_LOG": "stderr"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("mode=enabled", result.stderr)
            self.assertFalse(
                os.path.exists(os.path.join(run, "cloud-init", "cloud.cfg"))
            )

    def test_cloud_init_finds_it_as_a_top_level_module(self):
        self.assertNotIn("datasource_pkg_list", system_config())
        pkg_list = ["", "cloudinit.sources"]
        found = sources.list_sources(
            ["StrettchCloud"], [sources.DEP_FILESYSTEM], pkg_list
        )
        self.assertEqual(found, [ds_module.DataSourceStrettchCloud])
        self.assertEqual(ds_module.__name__, "DataSourceStrettchCloud")
        # Only the local stage, before the network is up.
        network_stage = [sources.DEP_FILESYSTEM, sources.DEP_NETWORK]
        self.assertEqual(
            sources.list_sources(["StrettchCloud"], network_stage, pkg_list),
            [],
        )


class TestFirstBoot(FakeHost):
    def test_reads_its_configuration_through_a_temporary_address(self):
        ds = self.datasource()
        with FakeService(document_routes()) as service:
            self.assertTrue(ds.get_data())

        self.assertEqual(
            self.ip_calls,
            [
                ["link", "set", "dev", "ens3", "up"],
                ["address", "replace", "169.254.10.10/16", "dev", "ens3"],
                ["address", "del", "169.254.10.10/16", "dev", "ens3"],
                ["link", "set", "dev", "ens3", "down"],
            ],
        )
        self.assertEqual(
            service.paths(),
            ["/v1/metadata.json", "/v1/user-data", "/v1/vendor-data"],
        )
        self.assertEqual(ds.get_instance_id(), INSTANCE_ID)
        self.assertEqual(ds.metadata["local-hostname"], "web-01")
        self.assertEqual(ds.metadata["region"], "test-1")
        self.assertNotIn("network-config", ds.metadata)
        self.assertEqual(
            ds.get_public_ssh_keys(), DOCUMENT["public-keys"]
        )
        self.assertEqual(ds.network_config, KEYED_NETWORK_CONFIG)
        self.assertEqual(ds.userdata_raw, USER_DATA)
        self.assertIsNone(ds.vendordata_raw)

    def test_sends_the_flavor_header_and_no_identity_headers(self):
        with FakeService(document_routes()) as service:
            self.datasource().get_data()
        self.assertTrue(service.requests)
        for path, headers in service.requests:
            self.assertEqual(
                headers.get("metadata-flavor"), "StrettchCloud", path
            )
            self.assertFalse(IDENTITY_HEADERS & headers.keys(), path)

    def test_sends_the_package_version_as_the_user_agent(self):
        # The release tag the package was built from, set by datasource.sh.
        want = "sc-guest/" + os.environ["SC_GUEST_VERSION"]
        with FakeService(document_routes()) as service:
            self.datasource().get_data()
        self.assertTrue(service.requests)
        for path, headers in service.requests:
            self.assertEqual(headers.get("user-agent"), want, path)

    def test_never_requests_the_password(self):
        with FakeService(document_routes()) as service:
            self.datasource().get_data()
        self.assertNotIn("/v1/password", service.paths())

    def test_no_document_means_no_datasource(self):
        routes = document_routes()
        routes["/v1/metadata.json"] = (404, b'{"code": "INSTANCE_NOT_FOUND"}')
        with FakeService(routes) as service:
            self.assertFalse(self.datasource().get_data())
        self.assertEqual(service.paths(), ["/v1/metadata.json"])
        self.assertIn(
            ["address", "del", "169.254.10.10/16", "dev", "ens3"], self.ip_calls
        )

    def test_removes_the_temporary_address_when_the_document_is_bad(self):
        routes = document_routes({"hostname": "web-01"})
        with FakeService(routes):
            with self.assertRaises(ValueError):
                self.datasource().get_data()
        self.assertIn(
            ["address", "del", "169.254.10.10/16", "dev", "ens3"], self.ip_calls
        )

    def test_gives_up_when_the_service_stays_unavailable(self):
        routes = document_routes()
        routes["/v1/metadata.json"] = (
            502,
            b'{"code": "SERVICE_UNREACHABLE"}',
        )
        with mock.patch.object(metadata, "RETRIES", 2):
            with FakeService(routes) as service:
                with self.assertLogs(ds_module.LOG, "ERROR") as logs:
                    self.assertFalse(self.datasource().get_data())
        self.assertEqual(service.paths(), ["/v1/metadata.json"] * 3)
        self.assertIn("failed 3 times", logs.output[0])
        self.assertIn(
            ["address", "del", "169.254.10.10/16", "dev", "ens3"], self.ip_calls
        )

    def test_never_carries_on_without_the_user_data(self):
        routes = document_routes()
        routes["/v1/user-data"] = (503, b'{"code": "NOT_READY"}')
        with mock.patch.object(metadata, "RETRIES", 0):
            with FakeService(routes):
                self.assertFalse(self.datasource().get_data())

    def test_shipped_list_skips_the_platform_check(self):
        # From 25.1, a list of exactly [StrettchCloud] skips ds_detect.
        ds = self.datasource()
        with mock.patch("cloudinit.dmi.read_dmi_data", return_value="QEMU"):
            self.assertFalse(ds.ds_detect())
            with FakeService(document_routes()):
                self.assertTrue(ds.get_data())

    def test_detects_strettch_cloud_by_manufacturer(self):
        ds = self.datasource()
        with mock.patch(
            "cloudinit.dmi.read_dmi_data", return_value="Strettch Cloud"
        ):
            self.assertTrue(ds.ds_detect())


class TestNoNic(FakeHost):
    nics = {"lo": (1, 0x9, False, "00:00:00:00:00:00")}

    def test_fails_without_a_physical_nic(self):
        with self.assertRaisesRegex(RuntimeError, "no network interface"):
            self.datasource().get_data()


class TestNicAlreadyUp(FakeHost):
    nics = {"ens3": (2, 0x1003, True, "1e:00:8c:00:49:cc")}

    def test_leaves_it_up(self):
        with FakeService(document_routes()):
            self.assertTrue(self.datasource().get_data())
        self.assertEqual(
            self.ip_calls,
            [
                ["link", "set", "dev", "ens3", "up"],
                ["address", "replace", "169.254.10.10/16", "dev", "ens3"],
                ["address", "del", "169.254.10.10/16", "dev", "ens3"],
            ],
        )


class TestFailedIpCommand(FakeHost):
    UP = ["link", "set", "dev", "ens3", "up"]
    ADD = ["address", "replace", "169.254.10.10/16", "dev", "ens3"]
    REMOVE = ["address", "del", "169.254.10.10/16", "dev", "ens3"]
    DOWN = ["link", "set", "dev", "ens3", "down"]

    def test_takes_the_nic_down_when_the_address_cannot_be_added(self):
        self.ip_failures = [["address", "replace"]]
        with FakeService(document_routes()) as service:
            with self.assertRaisesRegex(RuntimeError, "^ip address replace"):
                self.datasource().get_data()
        self.assertEqual(service.paths(), [])
        self.assertEqual(self.ip_calls, [self.UP, self.ADD, self.DOWN])

    def test_takes_the_nic_down_when_the_address_cannot_be_removed(self):
        self.ip_failures = [["address", "del"]]
        with FakeService(document_routes()):
            with self.assertRaisesRegex(RuntimeError, "^ip address del"):
                self.datasource().get_data()
        self.assertEqual(
            self.ip_calls, [self.UP, self.ADD, self.REMOVE, self.DOWN]
        )

    def test_keeps_the_service_error_when_the_address_cannot_be_removed(self):
        self.ip_failures = [["address", "del"]]
        routes = document_routes()
        routes["/v1/metadata.json"] = (503, b'{"code": "NOT_READY"}')
        with mock.patch.object(metadata, "RETRIES", 0):
            with FakeService(routes):
                with self.assertRaisesRegex(
                    RuntimeError, "^ip address del"
                ) as raised:
                    self.datasource().get_data()
        self.assertIsInstance(
            raised.exception.__context__, metadata.Unavailable
        )
        self.assertEqual(
            self.ip_calls, [self.UP, self.ADD, self.REMOVE, self.DOWN]
        )


class TestRetries(FakeHost):
    def fail_then_answer(self, failures):
        attempts = []

        def open_(request, timeout):
            attempts.append(timeout)
            if len(attempts) <= len(failures):
                raise failures[len(attempts) - 1]
            return io.BytesIO(b"answer")

        patch = mock.patch.object(metadata._OPENER, "open", open_)
        patch.start()
        self.addCleanup(patch.stop)
        return attempts

    def http_error(self, status, code):
        body = json.dumps({"code": code, "message": ""}).encode()
        return urllib.error.HTTPError("url", status, code, {}, io.BytesIO(body))

    def test_retries_until_the_service_answers(self):
        attempts = self.fail_then_answer(
            [
                urllib.error.URLError(ConnectionRefusedError()),
                socket.timeout("timed out"),
                self.http_error(502, "SERVICE_UNREACHABLE"),
                self.http_error(429, "TOO_MANY_REQUESTS"),
                self.http_error(503, "NOT_READY"),
                self.http_error(403, "HOST_SCOPE_MISMATCH"),
                ConnectionResetError(),
            ]
        )
        self.assertEqual(metadata.get("metadata.json"), b"answer")
        self.assertEqual(attempts, [10] * 8)
        self.assertEqual(self.sleeps, [1, 2, 4, 8, 10, 10, 10])

    def test_gives_up_after_30_retries(self):
        attempts = self.fail_then_answer(
            [self.http_error(502, "SERVICE_UNREACHABLE")
             for _ in range(31)]
        )
        with self.assertRaisesRegex(
            metadata.Unavailable,
            "failed 31 times, last with HTTP 502 SERVICE_UNREACHABLE",
        ):
            metadata.get("metadata.json")
        self.assertEqual(len(attempts), 31)
        self.assertEqual(self.sleeps, [1, 2, 4, 8] + [10] * 26)

    def test_does_not_retry_not_found(self):
        self.fail_then_answer([self.http_error(404, "USER_DATA_NOT_SET")])
        self.assertIsNone(metadata.get("user-data"))
        self.assertEqual(self.sleeps, [])

    def test_logs_an_error_without_a_code(self):
        error = urllib.error.HTTPError(
            "url", 502, "Bad Gateway", {}, io.BytesIO(b"<html>")
        )
        self.fail_then_answer([error])
        with self.assertLogs(metadata.LOG, "WARNING") as logs:
            self.assertEqual(metadata.get("metadata.json"), b"answer")
        self.assertIn("attempt 1 failed: HTTP 502; retrying", logs.output[0])

    def test_retries_an_attempt_that_times_out(self):
        answered = []

        def hang_once():
            if not answered:
                answered.append(True)
                time.sleep(2)
            return 200, b"answer"

        with mock.patch.object(metadata, "TIMEOUT", 1):
            with FakeService({"/v1/slow": (hang_once, None)}) as service:
                start = time.monotonic()
                self.assertEqual(metadata.get("slow"), b"answer")
                elapsed = time.monotonic() - start
        self.assertEqual(service.paths(), ["/v1/slow", "/v1/slow"])
        self.assertGreaterEqual(elapsed, 1)
        self.assertLess(elapsed, 2)
        self.assertEqual(self.sleeps, [1])


class TestReboot(FakeHost):
    def first_boot(self):
        ds = self.datasource()
        with FakeService(document_routes()):
            self.assertTrue(ds.get_data())
        path = os.path.join(self.tmp.name, "obj.pkl")
        self.assertTrue(sources.pkl_store(ds, path))
        self.ip_calls.clear()
        return sources.pkl_load(path)

    def test_confirms_the_cached_copy_from_the_serial_number(self):
        cached = self.first_boot()
        serials = {"system-serial-number": INSTANCE_ID.upper()}
        with FakeService(document_routes()) as service:
            with mock.patch("cloudinit.dmi.read_dmi_data", serials.get):
                self.assertTrue(cached.check_instance_id({}))
            with mock.patch(
                "cloudinit.dmi.read_dmi_data", return_value="another-vm"
            ):
                self.assertFalse(cached.check_instance_id({}))
        self.assertEqual(service.requests, [])
        self.assertEqual(self.ip_calls, [])
        self.assertEqual(cached.network_config, KEYED_NETWORK_CONFIG)

    def test_never_reads_the_service_again(self):
        cached = self.first_boot()
        events = {EventScope.NETWORK: {EventType.BOOT_NEW_INSTANCE}}
        self.assertEqual(cached.supported_update_events, events)
        self.assertEqual(cached.default_update_events, events)
        with FakeService(document_routes()) as service:
            for event in (
                EventType.BOOT,
                EventType.BOOT_LEGACY,
                EventType.HOTPLUG,
            ):
                self.assertFalse(cached.update_metadata_if_supported([event]))
        self.assertEqual(service.requests, [])

    def test_ranks_its_network_config_above_the_system_config(self):
        order = list(ds_module.DataSourceStrettchCloud.network_config_sources)
        self.assertLess(
            order.index(sources.NetworkConfigSource.DS),
            order.index(sources.NetworkConfigSource.SYSTEM_CFG),
        )


PUBLIC = NETWORK_CONFIG["ethernets"]["public0"]
PRIVATE = NETWORK_CONFIG["ethernets"]["private0"]


class TestNicNames(FakeHost):
    def network_config(self, network_config):
        ds = self.datasource()
        document = {**DOCUMENT, "network-config": network_config}
        with FakeService(document_routes(document)):
            self.assertTrue(ds.get_data())
        return ds.network_config

    def test_keys_each_entry_by_the_nic_with_its_mac(self):
        # Each entry keeps its match and gets no set-name, so the key is only
        # netplan's name for it, which customers see in file names.
        self.assertEqual(
            self.network_config(NETWORK_CONFIG), KEYED_NETWORK_CONFIG
        )

    def test_matches_the_mac_in_any_case(self):
        public = {**PUBLIC, "match": {"macaddress": "1E:00:8C:00:49:CC"}}
        config = {"version": 2, "ethernets": {"public0": public}}
        self.assertEqual(
            self.network_config(config),
            {"version": 2, "ethernets": {"ens3": public}},
        )

    def test_leaves_a_key_that_is_already_the_nic_name(self):
        config = {"version": 2, "ethernets": {"ens3": PUBLIC}}
        self.assertEqual(self.network_config(config), config)

    def test_keeps_the_key_when_no_physical_nic_has_the_mac(self):
        # docker0 has this MAC, but isn't a physical NIC.
        docker = {"match": {"macaddress": "02:42:ac:11:00:02"}}
        config = {
            "version": 2,
            "ethernets": {"public0": docker, "private0": {"dhcp4": True}},
        }
        with self.assertLogs(ds_module.LOG, "WARNING") as logs:
            self.assertEqual(self.network_config(config), config)
        self.assertEqual(
            [record.getMessage() for record in logs.records],
            [
                "No physical NIC has MAC 02:42:ac:11:00:02; keeping the "
                "network config key public0",
                "No physical NIC has MAC None; keeping the network config "
                "key private0",
            ],
        )

    def test_keeps_the_key_when_the_name_is_taken(self):
        absent = {"match": {"macaddress": "02:00:00:00:00:99"}}
        config = {
            "version": 2,
            "ethernets": {
                "ens4": absent,
                "private0": PRIVATE,
                "public0": PUBLIC,
                "public1": PUBLIC,
            },
        }
        with self.assertLogs(ds_module.LOG, "WARNING") as logs:
            got = self.network_config(config)
        self.assertEqual(
            got,
            {
                "version": 2,
                "ethernets": {
                    "ens4": absent,
                    "private0": PRIVATE,
                    "ens3": PUBLIC,
                    "public1": PUBLIC,
                },
            },
        )
        self.assertEqual(
            [record.getMessage() for record in logs.records[1:]],
            [
                "ens4 is already a network config key; keeping private0",
                "ens3 is already a network config key; keeping public1",
            ],
        )

    def test_leaves_a_config_without_ethernets(self):
        config = {"version": 2}
        self.assertEqual(self.network_config(config), config)

    def test_leaves_the_names_to_the_system(self):
        # Each NIC keeps the names udev gives it.
        ds = self.datasource()
        with FakeService(document_routes()):
            self.assertTrue(ds.get_data())
        self.ip_calls.clear()
        ds.activate({}, is_new_instance=True)
        self.assertEqual(self.ip_calls, [])


class TestIp(unittest.TestCase):
    """Runs the real ip(8)."""

    def test_returns_its_output(self):
        self.assertIn("ip utility", ds_module._ip("-V"))

    def test_raises_with_the_command_and_its_error(self):
        with self.assertRaisesRegex(
            RuntimeError, "^ip link show dev sc-no-such-nic: .*does not exist"
        ):
            ds_module._ip("link", "show", "dev", "sc-no-such-nic")


if __name__ == "__main__":
    unittest.main()
