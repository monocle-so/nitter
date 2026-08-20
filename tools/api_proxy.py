#!/usr/bin/env python3
import hashlib
import os
import re
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote


HOP_BY_HOP = {
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

STRIP_RESPONSE_HEADERS = HOP_BY_HOP | {"content-encoding"}


def clean_config_value(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "")


def config_line(name, value=None):
    if value is None:
        return name
    return f'{name} = "{clean_config_value(value)}"'


def parse_cookie_header(cookie_header):
    cookies = {}
    for part in cookie_header.split(";"):
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        cookies[name.strip()] = value.strip()
    return cookies


def session_id_from_cookie(cookie_header):
    cookies = parse_cookie_header(cookie_header)
    twid = unquote(cookies.get("twid", "").strip('"'))
    if "u=" in twid:
        value = twid.split("u=", 1)[1].split("&", 1)[0].strip('"')
        if value:
            return "n" + re.sub(r"[^A-Za-z0-9]", "", value)

    auth_token = cookies.get("auth_token", "")
    if auth_token:
        return "n" + hashlib.sha256(auth_token.encode()).hexdigest()[:16]

    return ""


def sticky_proxy(proxy, cookie_header):
    proxy = (proxy or "").strip()
    if not proxy:
        return ""

    if "://" not in proxy:
        proxy = "http://" + proxy

    per_account = os.environ.get("NITTER_PROXY_SESSION_PER_ACCOUNT", "true").lower()
    if per_account not in {"1", "true", "yes", "on"} or "-sessid-" in proxy:
        return proxy

    sid = session_id_from_cookie(cookie_header)
    if not sid:
        return proxy

    scheme_end = proxy.find("://") + 3
    at = proxy.find("@", scheme_end)
    if scheme_end < 3 or at < 0:
        return proxy

    colon = proxy.find(":", scheme_end)
    insert_at = colon if 0 <= colon < at else at
    return proxy[:insert_at] + "-sessid-" + sid + proxy[insert_at:]


def split_header_blocks(raw_headers):
    blocks = []
    for block in re.split(rb"\r?\n\r?\n", raw_headers.strip()):
        if block.startswith(b"HTTP/"):
            blocks.append(block)
    return blocks


def parse_response_headers(raw_headers):
    blocks = split_header_blocks(raw_headers)
    if not blocks:
        return 502, []

    lines = blocks[-1].splitlines()
    status_parts = lines[0].decode("iso-8859-1", "replace").split()
    status = int(status_parts[1]) if len(status_parts) > 1 and status_parts[1].isdigit() else 502

    headers = []
    for line in lines[1:]:
        if b":" not in line:
            continue
        name, value = line.split(b":", 1)
        header_name = name.decode("iso-8859-1", "replace").strip()
        if header_name.lower() in STRIP_RESPONSE_HEADERS:
            continue
        headers.append((header_name, value.decode("iso-8859-1", "replace").strip()))

    return status, headers


def target_url(path):
    value = path.lstrip("/")
    if not value.startswith(("x.com/", "api.x.com/")):
        return ""
    return "https://" + value


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "NitterApiProxy/1.0"
    # HTTP/1.0 (the BaseHTTPRequestHandler default) closes the connection after
    # every response. Nitter pools and reuses its clients, so it would keep
    # writing onto sockets this server had already closed and fail with
    # "Connection was closed before full request has been made". Every response
    # path below sends content-length, which is what 1.1 keep-alive requires.
    protocol_version = "HTTP/1.1"
    # Keep-alive holds a thread per idle connection, so reap quiet ones.
    timeout = 30  # seconds

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/_health":
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        url = target_url(self.path)
        if not url:
            self.send_error(400, "unsupported target")
            return

        cookie_header = self.headers.get("cookie", "")
        proxy = sticky_proxy(os.environ.get("NITTER_PROXY", ""), cookie_header)

        with tempfile.NamedTemporaryFile() as header_file, tempfile.NamedTemporaryFile() as body_file:
            config = [
                config_line("url", url),
                "http1.1",
                "silent",
                "show-error",
                "compressed",
                config_line("connect-timeout", "20"),
                config_line("max-time", "35"),
                config_line("dump-header", header_file.name),
                config_line("output", body_file.name),
            ]

            if proxy:
                config.append(config_line("proxy", proxy))

            for name, value in self.headers.items():
                if name.lower() in HOP_BY_HOP:
                    continue
                config.append(config_line("header", f"{name}: {value}"))

            proc = subprocess.run(
                ["curl", "--config", "-"],
                input=("\n".join(config) + "\n").encode(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=45,
            )

            raw_headers = header_file.read()
            body = body_file.read()

        if proc.returncode != 0 and not raw_headers:
            message = b"upstream fetch failed"
            self.send_response(502)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
            return

        status, headers = parse_response_headers(raw_headers)
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    host = os.environ.get("API_PROXY_HOST", "0.0.0.0")
    port = int(os.environ.get("API_PROXY_PORT", "7000"))
    ThreadingHTTPServer((host, port), ProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
