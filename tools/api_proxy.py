#!/usr/bin/env python3
import hashlib
import os
import re
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


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
# Set by Nitter to pick the account's proxy IP; never forwarded to X.
PROXY_GROUP_HEADER = "x-nitter-proxy-group"
MAX_REQUEST_BODY = 12 * 1024 * 1024
ALLOWED_TARGET_PREFIXES = ("x.com/", "api.x.com/", "upload.x.com/")


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


def grouped_proxy(proxy, group):
    """Adds the account's proxy group to the proxy port, one IP per group."""
    if not proxy or group == 0:
        return proxy
    parts = urlsplit(proxy)
    if parts.port is None:
        raise ValueError("NITTER_PROXY has no port to offset")
    host = parts.netloc.rsplit(":", 1)[0]
    return parts._replace(netloc=f"{host}:{parts.port + group}").geturl()


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
    if not value.startswith(ALLOWED_TARGET_PREFIXES):
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

    def send_text_error(self, status, message):
        body = message.encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def request_body(self):
        if self.headers.get("transfer-encoding"):
            self.send_text_error(400, "chunked request bodies are not supported")
            return None

        raw_length = self.headers.get("content-length", "0")
        try:
            length = int(raw_length)
        except ValueError:
            self.send_text_error(400, "invalid content-length")
            return None

        if length < 0 or length > MAX_REQUEST_BODY:
            self.send_text_error(413, "request body exceeds 12 MiB")
            return None

        body = self.rfile.read(length)
        if len(body) != length:
            self.send_text_error(400, "incomplete request body")
            return None
        return body

    def proxy_request(self, method, request_body=b""):
        url = target_url(self.path)
        if not url:
            self.send_text_error(400, "unsupported target")
            return

        cookie_header = self.headers.get("cookie", "")
        group = self.headers.get(PROXY_GROUP_HEADER, "0")
        if not group.isdigit():
            self.send_text_error(400, "invalid proxy group")
            return
        proxy = sticky_proxy(os.environ.get("NITTER_PROXY", ""), cookie_header)
        try:
            proxy = grouped_proxy(proxy, int(group))
        except ValueError as e:
            self.send_text_error(500, str(e))
            return

        with (
            tempfile.NamedTemporaryFile() as header_file,
            tempfile.NamedTemporaryFile() as body_file,
            tempfile.NamedTemporaryFile() as request_body_file,
        ):
            request_body_file.write(request_body)
            request_body_file.flush()
            config = [
                config_line("url", url),
                config_line("request", method),
                "http1.1",
                "silent",
                "show-error",
                "compressed",
                config_line("connect-timeout", "20"),
                config_line("max-time", "120" if method == "POST" else "35"),
                config_line("dump-header", header_file.name),
                config_line("output", body_file.name),
            ]

            if method == "POST":
                config.append(config_line("data-binary", "@" + request_body_file.name))

            if proxy:
                config.append(config_line("proxy", proxy))

            for name, value in self.headers.items():
                if name.lower() in HOP_BY_HOP or name.lower() == PROXY_GROUP_HEADER:
                    continue
                config.append(config_line("header", f"{name}: {value}"))

            proc = subprocess.run(
                ["curl", "--config", "-"],
                input=("\n".join(config) + "\n").encode(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=130 if method == "POST" else 45,
            )

            raw_headers = header_file.read()
            body = body_file.read()

        if proc.returncode != 0 and not raw_headers:
            self.send_text_error(502, "upstream fetch failed")
            return

        status, headers = parse_response_headers(raw_headers)
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/_health":
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        self.proxy_request("GET")

    def do_POST(self):
        body = self.request_body()
        if body is None:
            return
        self.proxy_request("POST", body)


def main():
    host = os.environ.get("API_PROXY_HOST", "0.0.0.0")
    port = int(os.environ.get("API_PROXY_PORT", "7000"))
    ThreadingHTTPServer((host, port), ProxyHandler).serve_forever()


if __name__ == "__main__":
    main()
