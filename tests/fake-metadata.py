#!/usr/bin/python3 -I
"""A fake metadata service for the tests, serving Metadata API v1's
password hash, password ack and boot report endpoints on 169.254.169.254:80.
The address has to be on the container's loopback first.

Usage: fake-metadata.py <dir>

<dir>/config.json is read on every request:
  password_hash  the hash of the pending password, or null when none is
                 pending
  ack_status     the answer to an ack while a password is pending (204)
  report_status  the answer to a boot report (204)
An ack answered with 204 consumes the password, as the real service does.
GET /v1/password, which only 0.1.0 read, answers 404 as the real service
does.

<dir>/requests.jsonl gets one line per request: method, path, whether the
Metadata-Flavor header was right, the User-Agent header, and the body.
"""

import http.server
import json
import os
import socketserver
import sys
import threading

DIR = sys.argv[1]
CONFIG = os.path.join(DIR, "config.json")
LOG = os.path.join(DIR, "requests.jsonl")
lock = threading.Lock()


def load_config():
    with open(CONFIG) as f:
        return json.load(f)


class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self, status, document=None):
        body = json.dumps(document).encode() if document is not None else b""
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        flavor = self.headers.get("Metadata-Flavor") == "StrettchCloud"
        with lock:
            with open(LOG, "a") as f:
                f.write(json.dumps({
                    "method": self.command,
                    "path": self.path,
                    "flavor": flavor,
                    "user_agent": self.headers.get("User-Agent"),
                    "body": body,
                }) + "\n")
            if not flavor:
                return self.answer(403, {"code": "METADATA_FLAVOR_REQUIRED", "message": "missing header"})
            config = load_config()
            route = (self.command, self.path)
            if route == ("GET", "/v1/password"):
                return self.answer(404, {"code": "PASSWORD_NOT_PENDING", "message": "none"})
            if route == ("GET", "/v1/password/hash"):
                if config.get("password_hash") is None:
                    return self.answer(404, {"code": "PASSWORD_NOT_PENDING", "message": "none"})
                return self.answer(200, {"hash": config["password_hash"]})
            if route == ("POST", "/v1/password/ack"):
                if config.get("password_hash") is None:
                    return self.answer(404, {"code": "PASSWORD_NOT_PENDING", "message": "none"})
                status = config.get("ack_status", 204)
                if status == 204:
                    config["password_hash"] = None
                    with open(CONFIG, "w") as f:
                        json.dump(config, f)
                return self.answer(status, None if status == 204 else {"code": "TEST", "message": "test"})
            if route == ("POST", "/v1/report/boot"):
                status = config.get("report_status", 204)
                return self.answer(status, None if status == 204 else {"code": "TEST", "message": "test"})
            return self.answer(404, {"code": "PATH_NOT_FOUND", "message": self.path})

    do_GET = handle_request
    do_POST = handle_request

    def log_message(self, *args):
        pass


# Not http.server's HTTPServer: it looks up its own address in DNS before
# listening, which can stall in a container.
class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


Server(("169.254.169.254", 80), Handler).serve_forever()
