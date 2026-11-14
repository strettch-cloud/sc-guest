"""Reads from the metadata service at 169.254.169.254 (Metadata API v1).

Uses only the Python standard library, so code that runs outside cloud-init
can use it without loading cloud-init.
"""

import http.client
import json
import logging
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


class Unavailable(Exception):
    """The service gave neither an answer nor a 404 within RETRIES retries."""


def get(path):
    """Returns the body of GET /v1/<path>, or None if the service answers 404.

    Any other answer, or none, is retried RETRIES times, then raises
    Unavailable.
    """
    request = urllib.request.Request(BASE_URL + path, headers=HEADERS)
    delay = FIRST_DELAY
    attempt = 1
    while True:
        try:
            with _OPENER.open(request, timeout=TIMEOUT) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            reason = f"HTTP {error.code} {_error_code(error)}".strip()
        except (OSError, http.client.HTTPException) as error:
            reason = repr(error)
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
        _sleep(delay)
        delay = min(delay * 2, MAX_DELAY)
        attempt += 1


def _error_code(error):
    """The "code" of a Metadata API error body, or "" if there isn't one."""
    try:
        return str(json.loads(error.read()).get("code", ""))
    except (OSError, http.client.HTTPException, ValueError, AttributeError):
        return ""
