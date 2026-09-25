# Repository instructions

## Authenticated X API transport

- Send every authenticated request to `x.com`, `api.x.com`, or
  `upload.x.com` through the shared transport in `src/apiutils.nim`.
- Use `fetch` or `fetchRaw` for ordinary pooled reads. Use
  `requestWithSession` when a request must stay pinned to one selected account
  or requires a POST body.
- Do not create a separate `AsyncHttpClient`, `HttpClient`, curl invocation, or
  other direct network path for authenticated X API traffic.
- Do not bypass `NITTER_API_PROXY` or add a silent direct-to-X fallback. When
  `NITTER_API_PROXY_REQUIRED` is enabled, failure to use the proxy is a bug.
- If a new X operation needs another HTTP method, request-body format, or X
  hostname, extend `tools/api_proxy.py` deliberately. Keep its target hostname
  allowlist explicit and keep request-body limits bounded.
- Preserve the selected session's cookie, CSRF token, authorization choice,
  proxy identity, pacing, and per-account write lock when adding account-bound
  operations. Never fall back to a different pooled account.
- Do not log cookies, authorization headers, CSRF tokens, proxy credentials,
  or complete request bodies. Upstream error logs may include status, content
  type, and a bounded response-body preview.

Media CDN fetching, external-link resolution, and transaction-ID metadata are
not authenticated X API traffic. Keep those paths separate and preserve their
existing SSRF protections and hostname validation.

## Verification

- Run the focused tests for the code being changed.
- For changes to API transport or profile updates, compile the Nitter server in
  release mode before considering the work complete.
- For changes to `tools/api_proxy.py`, test its hostname allowlist and binary
  request-body forwarding.
