"""Reads from the metadata service at 169.254.169.254 (Metadata API v1).

Uses only the Python standard library, so code that runs outside cloud-init
can use it without loading cloud-init.
"""

import http.client
import json
import logging
import threading
import time
import urllib.error
import urllib.request

from sc_guest import __version__

LOG = logging.getLogger(__name__)

BASE_URL = "http://169.254.169.254/v1/"

# Sent with every request, the units' included. The service refuses requests
# without Metadata-Flavor: an application inside the VM that is tricked into
# fetching a URL sends only the URL, not the header. User-Agent names the
# version in the service's logs.
HEADERS = {
    "Metadata-Flavor": "StrettchCloud",
    "User-Agent": f"sc-guest/{__version__}",
}

# Seconds per attempt. The service gives up on what is behind it after 5 s,
# so its error arrives before this timeout does.
TIMEOUT = 10

# Retries after the first attempt, waiting 1, 2, 4, 8, then 10 s between
# them: 275 s of waiting in all, plus up to TIMEOUT for each attempt.
RETRIES = 30
FIRST_DELAY = 1
MAX_DELAY = 10

# Never through a proxy: it adds X-Forwarded-For, which the service refuses.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_sleep = time.sleep
_monotonic = time.monotonic


class Deadline:
    """A limit on the total time get() may take, retries and waits included."""

    def __init__(self, seconds):
        self.seconds = seconds
        self.at = _monotonic() + seconds

    def remaining(self):
        return self.at - _monotonic()


class Unavailable(Exception):
    """The service gave neither an answer nor a 404 within RETRIES retries,
    or before the deadline."""


def get(path, deadline=None):
    """Returns the body of GET /v1/<path>, or None if the service answers 404.

    Any other answer, or none, is retried RETRIES times, then raises
    Unavailable. With a Deadline, it also raises Unavailable once the
    deadline passes, even partway through an answer that arrives a few bytes
    at a time.
    """
    request = urllib.request.Request(BASE_URL + path, headers=HEADERS)
    delay = FIRST_DELAY
    attempt = 1
    reason = "no attempt finished"
    while True:
        if deadline is not None and deadline.remaining() <= 0:
            raise Unavailable(
                f"gave up on GET {request.full_url} after {deadline.seconds} s, "
                f"last with {reason}"
            )
        found, result = _attempt(request, deadline)
        if found:
            return result
        reason = result
        if attempt > RETRIES:
            raise Unavailable(
                f"GET {request.full_url} failed {attempt} times, "
                f"last with {reason}"
            )
        LOG.warning(
            "GET %s attempt %d failed: %s; retrying in %d s",
            request.full_url,
            attempt,
            reason,
            delay,
        )
        _sleep(delay if deadline is None else max(0, min(delay, deadline.remaining())))
        delay = min(delay * 2, MAX_DELAY)
        attempt += 1


def _attempt(request, deadline):
    """One GET: (True, body or None for a 404), or (False, why it failed).

    The socket timeout bounds each read, not the whole answer, so with a
    deadline the attempt runs in a thread that is abandoned at the deadline:
    an answer whose headers or body trickle in can't hold the caller past it.
    The abandoned thread ends when its answer does, or with the process.
    """
    if deadline is None:
        return _send(request, TIMEOUT)
    outcome = [(False, "no complete answer before the deadline")]

    def run():
        outcome[0] = _send(request, max(0.001, min(TIMEOUT, deadline.remaining())))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    thread.join(max(0, deadline.remaining()))
    return outcome[0]


def _send(request, timeout):
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return True, response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return True, None
        return False, f"HTTP {error.code} {_error_code(error)}".strip()
    except (OSError, http.client.HTTPException) as error:
        return False, repr(error)


def _error_code(error):
    """The "code" of a Metadata API error body, or "" if there isn't one."""
    try:
        return str(json.loads(error.read()).get("code", ""))
    except (OSError, http.client.HTTPException, ValueError, AttributeError):
        return ""
