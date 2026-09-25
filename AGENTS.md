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

## Account profile operations

- Match each X browser operation's host, path, method, content type, headers,
  and form fields. Do not infer the host from the path alone. Current profile
  writes use `api.x.com/1.1/account/*`, not `x.com/i/api/1.1/account/*`.
  Current `UserByScreenName` reads use `x.com/i/api/graphql/*`.
- Do not assume the shared header defaults fit a new `/1.1/` operation.
  Account settings and profile writes currently need the web-session bearer
  and an `x-client-transaction-id`. The transaction ID must hash the actual
  HTTP method, including `POST` for writes. Add a focused regression test for
  the chosen host and method when adding another operation.
- Resolve a profile by the numeric account ID using that account's settings
  response to obtain its screen name. Fetch a fresh profile with the same
  session before merging text changes. Check that the returned user ID matches
  the requested account. Never merge from Redis, another session, or
  caller-supplied profile state.
- Preserve omitted profile fields, including location. Image-only updates
  must not submit a text profile update. Upload images before visible changes,
  then apply text, avatar, and banner updates in order.
- A profile update is not atomic. A later failure can follow an earlier X
  mutation. Do not automatically retry an ambiguous failed write. Read the
  account profile first to determine its current state.
- Do not label a pacing, rate-limit, or transport error as invalid JSON.
  Preserve rate limits as HTTP 429 and log genuine parse failures with a
  bounded response preview, never credentials or full request bodies.

## Verification

- Run the focused tests for the code being changed.
- For changes to API transport or profile updates, compile the Nitter server in
  release mode before considering the work complete.
- For changes to `tools/api_proxy.py`, test its hostname allowlist and binary
  request-body forwarding.
- When verifying the local Docker service, rebuild and restart it after code
  changes. Use read-only account reads for smoke checks. Send a live profile
  write only when the user explicitly authorizes that change, then read back
  the profile to confirm it.
