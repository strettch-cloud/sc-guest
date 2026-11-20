"""sc_guest.metadata.get, with and without a Deadline.

A fake metadata service runs on 127.0.0.1 and get() is pointed at it. Most
tests use a fake clock that only moves when get() waits, so the real waits
(1, 2, 4, 8, then 10 s) and a 90 s deadline take no time. The tests about
answers that never finish use real time and a deadline of a second or so.
"""

import http.server
import threading
import time
import unittest

from sc_guest import metadata

UNAVAILABLE = (503, b'{"code": "unavailable"}')


class FakeService(http.server.ThreadingHTTPServer):
    """Answers each request with the next of self.answers, the last one
    repeated. An answer is (status, body) or a function given the handler."""

    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.answers = [(404, b"")]
        self.requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        requests = self.server.requests
        requests.append(self.path)
        answer = self.server.answers[min(len(requests), len(self.server.answers)) - 1]
        self.close_connection = True
        try:
            if callable(answer):
                answer(self)
            else:
                self.answer(*answer)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def answer(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FakeClock:
    def __init__(self):
        self.now = 0.0
        self.waits = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.waits.append(seconds)
        self.now += seconds


class MetadataGetTest(unittest.TestCase):
    def setUp(self):
        self.service = FakeService()
        threading.Thread(target=self.service.serve_forever, args=(0.05,), daemon=True).start()
        self.saved = (metadata.BASE_URL, metadata._sleep, metadata._monotonic)
        metadata.LOG.disabled = True
        metadata.BASE_URL = f"http://127.0.0.1:{self.service.server_address[1]}/v1/"
        self.clock = FakeClock()
        metadata._sleep = self.clock.sleep
        metadata._monotonic = self.clock.monotonic

    def tearDown(self):
        metadata.BASE_URL, metadata._sleep, metadata._monotonic = self.saved
        metadata.LOG.disabled = False
        self.service.shutdown()
        self.service.server_close()

    def use_real_time(self):
        metadata._sleep = time.sleep
        metadata._monotonic = time.monotonic

    def url(self, path):
        return metadata.BASE_URL + path


class WithoutDeadline(MetadataGetTest):
    def test_returns_the_body_the_service_answers_with(self):
        self.service.answers = [(200, b'{"hash": "$6$salt$digest"}')]

        body = metadata.get("password/hash")

        self.assertEqual(body, b'{"hash": "$6$salt$digest"}')

    def test_returns_none_when_the_service_answers_404(self):
        self.service.answers = [(404, b'{"code": "not_found"}')]

        body = metadata.get("password/hash")

        self.assertIsNone(body)

    def test_retries_until_the_service_answers_waiting_1_then_2_seconds(self):
        self.service.answers = [UNAVAILABLE, UNAVAILABLE, (200, b"hello")]

        body = metadata.get("user-data")

        self.assertEqual(body, b"hello")
        self.assertEqual(self.clock.waits, [1, 2])

    def test_gives_up_after_31_attempts_and_275_seconds_of_waiting(self):
        self.service.answers = [UNAVAILABLE]
        retries = 30

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("password/hash")

        self.assertEqual(
            str(raised.exception),
            f"GET {self.url('password/hash')} failed 31 times, last with HTTP 503 unavailable",
        )
        self.assertEqual(self.clock.waits, [1, 2, 4, 8] + [10] * (retries - 4))
        self.assertEqual(sum(self.clock.waits), 275)
        self.assertEqual(len(self.service.requests), retries + 1)


class WithDeadline(MetadataGetTest):
    def test_returns_the_body_the_service_answers_with(self):
        large_body = b"#cloud-config\n" + b"x" * 200_000
        self.service.answers = [(200, large_body)]

        body = metadata.get("user-data", metadata.Deadline(90))

        self.assertEqual(body, large_body)

    def test_returns_an_empty_body_as_empty(self):
        self.service.answers = [(200, b"")]

        body = metadata.get("user-data", metadata.Deadline(90))

        self.assertEqual(body, b"")

    def test_returns_none_when_the_service_answers_404(self):
        self.service.answers = [(404, b'{"code": "not_found"}')]

        body = metadata.get("user-data", metadata.Deadline(90))

        self.assertIsNone(body)

    def test_retries_until_the_service_answers_before_the_deadline(self):
        self.service.answers = [UNAVAILABLE] * 11 + [(200, b"hello")]

        body = metadata.get("password/hash", metadata.Deadline(90))

        self.assertEqual(body, b"hello")
        self.assertEqual(sum(self.clock.waits), 85)

    def test_gives_up_at_90_seconds_with_the_last_reason(self):
        self.service.answers = [UNAVAILABLE]

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("password/hash", metadata.Deadline(90))

        self.assertEqual(
            str(raised.exception),
            f"gave up on GET {self.url('password/hash')} after 90 s, last with HTTP 503 unavailable",
        )

    def test_waits_1_2_4_8_then_10_seconds_the_last_wait_ending_at_the_deadline(self):
        self.service.answers = [UNAVAILABLE]

        with self.assertRaises(metadata.Unavailable):
            metadata.get("password/hash", metadata.Deadline(90))

        self.assertEqual(self.clock.waits, [1, 2, 4, 8, 10, 10, 10, 10, 10, 10, 10, 5])
        self.assertEqual(len(self.service.requests), 12)

    def test_gives_up_without_asking_when_the_deadline_has_already_passed(self):
        deadline = metadata.Deadline(90)
        self.clock.now += 90

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("user-data", deadline)

        self.assertEqual(
            str(raised.exception),
            f"gave up on GET {self.url('user-data')} after 90 s, last with no attempt finished",
        )
        self.assertEqual(self.service.requests, [])

    def test_gives_up_without_waiting_when_an_attempt_ends_after_the_deadline(self):
        deadline_seconds = 90

        def slow_unavailable(handler):
            self.clock.now += deadline_seconds + 10
            handler.answer(*UNAVAILABLE)

        self.service.answers = [slow_unavailable]

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("password/hash", metadata.Deadline(deadline_seconds))

        self.assertEqual(
            str(raised.exception),
            f"gave up on GET {self.url('password/hash')} after 90 s, last with HTTP 503 unavailable",
        )
        self.assertEqual(self.clock.waits, [0])
        self.assertEqual(len(self.service.requests), 1)

    def test_a_service_that_never_answers_is_given_up_on_at_the_deadline(self):
        self.use_real_time()
        deadline_seconds = 1
        never_answer = 15
        self.service.answers = [lambda handler: time.sleep(never_answer)]
        start = time.monotonic()

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("password/hash", metadata.Deadline(deadline_seconds))

        elapsed = time.monotonic() - start
        self.assertTrue(
            str(raised.exception).startswith(
                f"gave up on GET {self.url('password/hash')} after 1 s, last with "
            ),
            raised.exception,
        )
        self.assertLess(elapsed, deadline_seconds + 1)

    def test_an_answer_arriving_a_few_bytes_at_a_time_is_cut_off_at_the_deadline(self):
        self.use_real_time()
        deadline_seconds = 1
        body = b'{"hash": "$6$salt$digest"}' + b" " * 200

        def trickle(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", str(len(body)))
            handler.end_headers()
            for i in range(0, len(body), 2):
                handler.wfile.write(body[i : i + 2])
                handler.wfile.flush()
                time.sleep(0.1)

        self.service.answers = [trickle]
        start = time.monotonic()

        with self.assertRaises(metadata.Unavailable) as raised:
            metadata.get("password/hash", metadata.Deadline(deadline_seconds))

        elapsed = time.monotonic() - start
        self.assertEqual(
            str(raised.exception),
            f"gave up on GET {self.url('password/hash')} after 1 s, "
            "last with no complete answer before the deadline",
        )
        self.assertLess(elapsed, deadline_seconds + 1)


if __name__ == "__main__":
    unittest.main()
