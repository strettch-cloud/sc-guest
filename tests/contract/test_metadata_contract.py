"""Writes the contract between sc-guest and the metadata service.

Each test runs the package's own client code against a Pact mock server and
describes one request and the answer the code relies on. A test fails unless
the code sends exactly that request and takes the answer. Together the tests
write sc-guest-metadata-api.json, which the metadata service is checked
against, so a change there that would break this version is caught.

Only what the code relies on is described. Answers are matched by type, not
by value, and the service may add fields. Error bodies aren't described,
except the one error code the code branches on.

Needs pact-python (see requirements.txt next to this file), which needs
Python 3.11 or later, so it runs on its own and not with the tests in the
supported systems' containers. The requests are the same on all of them: the
code under test uses only the standard library.

  SC_GUEST_VERSION  the version the requests carry; the release tag when
                    the contract is written for a release
  PACT_DIR          where the contract is written, by default build/pacts
"""

import contextlib
import http.client
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

from pact import Pact, match

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
# Keeps __pycache__ out of src/, which the package is built from.
sys.dont_write_bytecode = True

import sc_guest

# The build writes the release tag into the installed copy (see debian/rules).
# The source tree says 0.0.0, so a release's contract gets its tag from here.
# It has to be set before anything reads it at import.
sc_guest.__version__ = os.environ.get("SC_GUEST_VERSION") or sc_guest.__version__

from sc_guest import metadata

PACT_DIR = pathlib.Path(os.environ.get("PACT_DIR") or ROOT / "build" / "pacts")
PACT_FILE = PACT_DIR / "sc-guest-metadata-api.json"

# Provider states: what the metadata service has to be given before it is
# asked. Its own check sets each one up by this exact text.
VM_WITH_TWO_NETWORK_CARDS = "a VM with a public and a private network card"
UNKNOWN_VM = "no VM is known for this request"
USER_DATA = "the VM has user data"
NO_USER_DATA = "the VM has no user data"
VENDOR_DATA = "vendor data is configured"
NO_VENDOR_DATA = "no vendor data is configured"
PASSWORD_PENDING = "a password is pending"
NO_PASSWORD_PENDING = "no password is pending"

# Examples only. The addresses are from the ranges reserved for
# documentation (RFC 5737 and RFC 7042).
INSTANCE_ID = "3f2b8c1e-5d47-4a69-9b0c-7e1f2a3b4c5d"
BOOT_ID = "0b6f4a52-9c1d-4e3f-8a7b-6c5d4e3f2a1b"
# The SHA-512 crypt hash of "example-Password-1".
PASSWORD_HASH = (
    "$6$rounds=100000$ExampleSalt.0123$"
    "EZdUWg71ykmdOGOLrThdVH1lhs2JcaCjuOvZSroM4BH4BfB/Pxnk8yH1nfCoxsh1iFrvjxGOtWIBf0xbdiwlh0"
)

# The largest report this version sends. The numbers are written out, not
# read from the code: if the code's limits change, the test fails until the
# contract is changed on purpose.
MOST_ERRORS = 20
LONGEST_ERROR_BYTES = 2048


def network_card(mac, address):
    return {
        "match": {"macaddress": match.str(mac)},
        "addresses": match.each_like(match.str(address)),
    }


# What the datasource and cloud-init need from the document. A network card
# may also have an MTU, nameservers and routes; none of them is required.
DOCUMENT = {
    "instance-id": match.str(INSTANCE_ID),
    "hostname": match.str("web-01"),
    "public-keys": match.each_like(
        match.str("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnly user@example")
    ),
    "network-config": {
        # Exactly 2: the entries below are in version 2's format.
        "version": 2,
        # Every entry is matched, whatever its key. The service keys them by
        # the card's role, and the datasource finds each card by its MAC.
        "ethernets": match.each_value_matches(
            {
                "public0": network_card("00:00:5e:00:53:01", "203.0.113.10/24"),
                "private0": network_card("00:00:5e:00:53:02", "198.51.100.10/24"),
            },
            rules=match.type({}),
        ),
    },
}

# Pact's regular expressions have to match the whole value, and are read by
# two engines: the mock server's here and the verifier's on the service's side.
ANY_VERSION = r"^sc-guest/.+$"
JSON_CONTENT_TYPE = r"^application/json(;.*)?$"
# Any crypt(3) hash, as the command checks it: the service may change the
# method, but never send anything else.
CRYPT_HASH = r"^\$[0-9a-z]+\$[./0-9A-Za-z$=,]+$"


def load_command():
    """Loads src/sc-guest, which has no .py suffix, as a module."""
    loader = importlib.machinery.SourceFileLoader(
        "sc_guest_command", str(ROOT / "src" / "sc-guest")
    )
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader(loader.name, loader)
    )
    # The command sets its own PATH when it loads.
    with mock.patch.dict(os.environ):
        loader.exec_module(module)
    return module


command = load_command()


def setUpModule():
    # Every test adds its interaction to the file, so a file left by an
    # earlier run would keep interactions that no longer exist.
    PACT_FILE.unlink(missing_ok=True)


def not_answered(*args):
    raise AssertionError(
        "the code would retry: the request or its answer isn't what the "
        "contract describes"
    )


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.pact = Pact("sc-guest", "metadata-api").with_specification("V4")
        self.files = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))

    def interaction(self, description, state, method, path, body=None):
        """Describes the request. Every request carries the header the
        service requires and the package's version."""
        interaction = (
            self.pact.upon_receiving(description)
            .given(state)
            .with_request(method, path)
            .with_header("Metadata-Flavor", "StrettchCloud")
            .with_header(
                "User-Agent",
                match.regex(f"sc-guest/{sc_guest.__version__}", regex=ANY_VERSION),
            )
        )
        if body is not None:
            interaction.with_header("Content-Type", "application/json")
            interaction.with_body(body, content_type="application/json")
        return interaction

    @contextlib.contextmanager
    def service(self):
        """Puts the mock server where the code expects the metadata service.

        Leaving the block fails the test unless the code sent the request as
        described. Only then is the interaction added to the contract.
        """
        connect = http.client.HTTPConnection

        def connect_to_mock(host, port=None, **kwargs):
            if (host, port) == ("169.254.169.254", 80):
                host, port = "127.0.0.1", server.port
            return connect(host, port, **kwargs)

        with self.pact.serve(addr="127.0.0.1") as server, contextlib.ExitStack() as patches:
            for patch in (
                mock.patch.object(
                    metadata, "BASE_URL", f"http://127.0.0.1:{server.port}/v1/"
                ),
                mock.patch.object(http.client, "HTTPConnection", connect_to_mock),
                # Both clients sleep only before a retry, and the mock server
                # answers a request it doesn't expect with a 500.
                mock.patch.object(metadata, "_sleep", not_answered),
                mock.patch.object(command, "time", mock.Mock(sleep=not_answered)),
            ):
                patches.enter_context(patch)
            yield
        self.pact.write_file(PACT_DIR)

    def command_file(self, name, text):
        """Points one of the command's file paths at a temporary file."""
        path = self.files / name.lower()
        if text is not None:
            path.write_text(text, encoding="utf-8")
        self.enterContext(mock.patch.object(command, name, str(path)))
        return path


def json_answer(interaction, body):
    return (
        interaction.will_respond_with(200)
        .with_header(
            "Content-Type", match.regex("application/json", regex=JSON_CONTENT_TYPE)
        )
        .with_body(body, content_type="application/json")
    )


def data_answer(interaction, example):
    """Any bytes, as long as there are some: cloud-init works out the format,
    and the code never looks at the content type."""
    return (
        interaction.will_respond_with(200)
        .with_header("Content-Type", match.regex("application/octet-stream", regex=r"^.+$"))
        .with_body(example, content_type="application/octet-stream")
        .with_matching_rules(
            {"body": {"$": {"combine": "AND", "matchers": [{"match": "notEmpty"}]}}},
            "Response",
        )
    )


def any_success(interaction):
    """Any 2xx. The service answers 204 today, and the code takes them all."""
    return interaction.will_respond_with(204).with_matching_rules(
        {
            "status": {
                "combine": "AND",
                "matchers": [{"match": "statusCode", "status": "success"}],
            }
        },
        "Response",
    )


class TestDatasourceRequests(ContractTest):
    """The three requests the datasource makes, through the client it uses."""

    def test_document(self):
        json_answer(
            self.interaction(
                "a request for the VM's metadata document",
                VM_WITH_TWO_NETWORK_CARDS,
                "GET",
                "/v1/metadata.json",
            ),
            DOCUMENT,
        )
        with self.service():
            document = json.loads(metadata.get("metadata.json"))

        # The keys the datasource refuses to go on without.
        for key in ("instance-id", "hostname", "network-config"):
            self.assertIn(key, document)
        self.assertEqual(
            {
                key: entry["match"]["macaddress"]
                for key, entry in document["network-config"]["ethernets"].items()
            },
            {"public0": "00:00:5e:00:53:01", "private0": "00:00:5e:00:53:02"},
        )

    def test_no_document_for_an_unknown_vm(self):
        self.interaction(
            "a request for the metadata document of a VM the service doesn't know",
            UNKNOWN_VM,
            "GET",
            "/v1/metadata.json",
        ).will_respond_with(404)
        with self.service():
            self.assertIsNone(metadata.get("metadata.json"))

    def test_user_data(self):
        example = "#cloud-config\npackages: [htop]\n"
        data_answer(
            self.interaction(
                "a request for the VM's user data", USER_DATA, "GET", "/v1/user-data"
            ),
            example,
        )
        with self.service():
            self.assertEqual(metadata.get("user-data"), example.encode())

    def test_no_user_data(self):
        self.interaction(
            "a request for the user data of a VM that has none",
            NO_USER_DATA,
            "GET",
            "/v1/user-data",
        ).will_respond_with(404)
        with self.service():
            self.assertIsNone(metadata.get("user-data"))

    def test_vendor_data(self):
        example = "#cloud-config\ntimezone: Etc/UTC\n"
        data_answer(
            self.interaction(
                "a request for the vendor data", VENDOR_DATA, "GET", "/v1/vendor-data"
            ),
            example,
        )
        with self.service():
            self.assertEqual(metadata.get("vendor-data"), example.encode())

    def test_no_vendor_data(self):
        self.interaction(
            "a request for the vendor data when there is none",
            NO_VENDOR_DATA,
            "GET",
            "/v1/vendor-data",
        ).will_respond_with(404)
        with self.service():
            self.assertIsNone(metadata.get("vendor-data"))


class TestPasswordRequests(ContractTest):
    """sc-guest password reads the password's hash, and sc-guest report
    confirms it was set."""

    def password_was_set(self):
        self.command_file("CLOUD_INIT_INSTANCE_ID", INSTANCE_ID + "\n")
        state = {"instance-id": INSTANCE_ID, "state": "set"}
        return self.command_file("PASSWORD_STATE", json.dumps(state))

    def test_password_hash(self):
        json_answer(
            self.interaction(
                "a request for the hash of the VM's root password",
                PASSWORD_PENDING,
                "GET",
                "/v1/password/hash",
            ),
            {"hash": match.regex(PASSWORD_HASH, regex=CRYPT_HASH)},
        )
        with self.service():
            self.assertEqual(command.fetch_password_hash(), PASSWORD_HASH)

    def test_no_password_hash(self):
        # The code is matched exactly: only this 404 means there is none, and
        # any other is retried.
        self.interaction(
            "a request for the root password hash of a VM created without one",
            NO_PASSWORD_PENDING,
            "GET",
            "/v1/password/hash",
        ).will_respond_with(404).with_body(
            {"code": "PASSWORD_NOT_PENDING"}, content_type="application/json"
        )
        with self.service(), mock.patch.object(command, "log"):
            self.assertIsNone(command.fetch_password_hash())

    def test_ack(self):
        state = self.password_was_set()
        any_success(
            self.interaction(
                "a confirmation that the root password was set",
                PASSWORD_PENDING,
                "POST",
                "/v1/password/ack",
            )
        )
        with self.service(), mock.patch.object(command, "log"):
            command.send_ack()
        self.assertEqual(json.loads(state.read_text())["state"], "acked")

    def test_ack_already_taken(self):
        state = self.password_was_set()
        self.interaction(
            "a confirmation of a password the service no longer holds",
            NO_PASSWORD_PENDING,
            "POST",
            "/v1/password/ack",
        ).will_respond_with(404)
        with self.service(), mock.patch.object(command, "log"):
            command.send_ack()
        self.assertEqual(json.loads(state.read_text())["state"], "acked")


class TestBootReport(ContractTest):
    """sc-guest report builds each report from cloud-init's status file."""

    def send_report(self, description, errors, stage_errors=()):
        """Sends the report sc-guest builds from a boot whose network stage
        logged stage_errors, and describes it as carrying errors."""
        status = {
            "v1": {
                "datasource": "DataSourceStrettchCloud",
                "init-local": {"errors": [], "finished": 1.0},
                "init": {"errors": list(stage_errors), "finished": 2.0},
            }
        }
        self.command_file("CLOUD_INIT_STATUS", json.dumps(status))
        self.command_file("PASSWORD_ERROR", None)
        self.command_file("BOOT_ID", BOOT_ID + "\n")
        any_success(
            self.interaction(
                description,
                VM_WITH_TWO_NETWORK_CARDS,
                "POST",
                "/v1/report/boot",
                body={
                    "status": "error" if errors else "done",
                    "boot-id": BOOT_ID,
                    "errors": errors,
                    "version": sc_guest.__version__,
                },
            )
        )
        with self.service(), mock.patch.object(command, "log"):
            command.send_report()

    def test_done(self):
        self.send_report("a boot report without errors", [])

    def test_error(self):
        error = "Failed to set the hostname to web-01"
        self.send_report("a boot report with one error", [error], [error])

    def test_largest_report(self):
        # As many errors as a report carries, each longer than it may be and
        # different from its first byte, so none is dropped as a repeat.
        logged = [f"{number:02d} " + "x" * 3000 for number in range(MOST_ERRORS)]
        sent = [error[: LONGEST_ERROR_BYTES - 3] + "..." for error in logged]
        self.send_report("the largest boot report sc-guest sends", sent, logged)


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if not program.result.wasSuccessful():
        # Tests that passed have written their part; a partial contract must
        # not be mistaken for a whole one.
        PACT_FILE.unlink(missing_ok=True)
        sys.exit(1)
