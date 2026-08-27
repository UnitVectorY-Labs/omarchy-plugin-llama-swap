#!/usr/bin/env python3
import http.server
import pathlib
import subprocess
import threading
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib" / "llama-swap-request"
TOKEN = "test-token-not-for-argv"
REQUEST_STARTED = threading.Event()
RELEASE_REQUEST = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def do_GET(self):
        self.server.authorization = self.headers.get("Authorization")
        if self.path == "/snapshot":
            body = b'{"data":[]}'
        elif self.path == "/oversized":
            body = b"x" * (1024 * 1024 + 1)
        elif self.path == "/blocked":
            REQUEST_STARTED.set()
            RELEASE_REQUEST.wait(timeout=5)
            body = b'{"data":[]}'
        elif self.path == "/events":
            oversized = b"data: " + b"x" * 65536 + b"\n"
            records = [b'data: {"type":"ignored"}\n' for _ in range(600)]
            body = oversized + b"".join(records)
        else:
            self.send_error(404)
            return

        self.send_response(200)
        # The oversized response is delimited only by connection close. This
        # exercises the cap for streaming/unknown-length transfers.
        if self.path != "/oversized":
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def log_message(self, _format, *_args):
        pass


class RequestHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.authorization = None
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def run_helper(self, mode, path):
        return subprocess.run(
            [str(HELPER), mode, "GET", self.base_url + path, "5" if mode == "request" else "0"],
            input=TOKEN + "\n",
            text=True,
            capture_output=True,
            check=False,
        )

    def test_token_arrives_via_header(self):
        result = self.run_helper("request", "/snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{"data":[]}')
        self.assertEqual(self.server.authorization, "Bearer " + TOKEN)

    def test_snapshot_has_hard_byte_cap(self):
        result = self.run_helper("request", "/oversized")
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout.encode()), 1024 * 1024)

    def test_token_is_absent_from_process_arguments(self):
        REQUEST_STARTED.clear()
        RELEASE_REQUEST.clear()
        process = subprocess.Popen(
            [str(HELPER), "request", "GET", self.base_url + "/blocked", "5"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            process.stdin.write(TOKEN + "\n")
            process.stdin.flush()
            self.assertTrue(REQUEST_STARTED.wait(timeout=3), "request did not start")

            pending = [process.pid]
            command_lines = []
            while pending:
                pid = pending.pop()
                try:
                    command_lines.append(pathlib.Path(f"/proc/{pid}/cmdline").read_bytes())
                    children = pathlib.Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
                    pending.extend(int(child) for child in children)
                except (FileNotFoundError, ProcessLookupError):
                    pass
            self.assertNotIn(TOKEN.encode(), b"\n".join(command_lines))
        finally:
            RELEASE_REQUEST.set()
            process.communicate(timeout=5)

    def test_events_have_line_and_record_caps(self):
        result = self.run_helper("events", "/events")
        self.assertEqual(len(result.stdout.splitlines()), 512)
        self.assertNotIn("x" * 65536, result.stdout)


if __name__ == "__main__":
    unittest.main()
