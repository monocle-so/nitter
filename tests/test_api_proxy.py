"""Unit tests for tools/api_proxy.py. curl is stubbed, so nothing leaves the host."""
import http.client
import os
import subprocess
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import api_proxy  # noqa: E402


class ApiProxyTest(unittest.TestCase):
    def setUp(self):
        os.environ["NITTER_PROXY"] = "http://user:pass@isp.example:8001"
        os.environ["NITTER_PROXY_SESSION_PER_ACCOUNT"] = "false"
        self.calls = []

        def fake_run(args, input, **kwargs):
            config = input.decode()
            body_path = next(
                (line.split('"@', 1)[1].rstrip('"') for line in config.splitlines() if line.startswith("data-binary")),
                None,
            )
            body = b""
            if body_path:
                with open(body_path, "rb") as f:
                    body = f.read()
            self.calls.append((config, body))
            return subprocess.CompletedProcess(args, 0, b"", b"")

        api_proxy.subprocess.run = fake_run
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), api_proxy.ProxyHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        api_proxy.subprocess.run = subprocess.run

    def request(self, path, method="GET", body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        conn.request(method, path, body=body, headers=headers or {})
        status = conn.getresponse().status
        conn.close()
        return status

    def proxy_line(self):
        return next(line for line in self.calls[-1][0].splitlines() if line.startswith("proxy"))

    def test_proxy_group_offsets_port_and_is_not_forwarded(self):
        self.request("/x.com/i/api/graphql/abc", headers={"x-nitter-proxy-group": "2"})
        self.assertEqual(self.proxy_line(), 'proxy = "http://user:pass@isp.example:8003"')
        self.assertNotIn("x-nitter-proxy-group", self.calls[-1][0].lower())

    def test_no_proxy_group_keeps_port(self):
        self.request("/x.com/i/api/graphql/abc")
        self.assertEqual(self.proxy_line(), 'proxy = "http://user:pass@isp.example:8001"')

    def test_invalid_proxy_group_is_rejected(self):
        for group in ("-1", "²"):
            self.assertEqual(self.request("/x.com/i/api/graphql/abc", headers={"x-nitter-proxy-group": group}), 400)
        self.assertEqual(self.calls, [])

    def test_unlisted_host_is_rejected(self):
        self.assertEqual(self.request("/example.com/"), 400)
        self.assertEqual(self.calls, [])

    def test_binary_body_is_forwarded_intact(self):
        body = bytes(range(256))
        self.request("/upload.x.com/i/media/upload.json", "POST", body, {"content-type": "application/octet-stream"})
        self.assertEqual(self.calls[-1][1], body)


if __name__ == "__main__":
    unittest.main()
