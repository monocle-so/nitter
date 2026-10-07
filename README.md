Clone the repo, place .env and sessions.jsonl in the repo root, then run:

cp nitter.example.conf nitter.conf
docker compose up -d --build

Test:
curl -fsS -H "Authorization: Bearer $NITTER_BEARER_TOKEN" http://127.0.0.1:8080/api/v1/health
curl -i -H "Authorization: Bearer $NITTER_BEARER_TOKEN" http://127.0.0.1:8080/api/v1/users/jack
curl -i -H "Authorization: Bearer $NITTER_BEARER_TOKEN" --get http://127.0.0.1:8080/api/v1/search/tweets --data-urlencode 'q="Owner.com" restaurant'
curl -i -H "Authorization: Bearer $NITTER_BEARER_TOKEN" --get http://127.0.0.1:8080/api/v1/search/tweets --data-urlencode 'q="Owner.com" restaurant' --data-urlencode 'sort=top'
```

Tweet search defaults to X's Latest (chronological) results; pass `sort=top` for
the relevance-ranked Top results instead.

## Account profile API

Both routes use a configured cookie session selected by its numeric account
ID. Set `NITTER_BEARER_TOKEN` in the caller's environment to the token
configured on the Nitter server, then send it as an HTTP bearer token. This is
Nitter's API token, not an X cookie or X bearer token. All `/api/v1` routes
require it. OAuth sessions cannot use these profile routes.

Read the current profile with `GET /api/v1/accounts/:account_id/profile`:

```sh
curl -i -H "Authorization: Bearer $NITTER_BEARER_TOKEN" \
  http://127.0.0.1:8080/api/v1/accounts/123456789/profile
```

The read is fresh and uses the selected account, not a cached or pooled user
profile. Its response has `account_id`, a `snapshot` with `name`, `bio`,
`website_url`, and `location`, and a `profile` in Nitter's standard user
format. For example:

```json
{
  "account_id": "123456789",
  "snapshot": {
    "name": "Sammy Jones",
    "bio": "Building things.",
    "website_url": "https://example.com",
    "location": "San Francisco"
  },
  "profile": {
    "id": "123456789",
    "username": "sammy",
    "fullname": "Sammy Jones"
  }
}
```

The example shows only three `profile` properties. The actual response also
includes bio, location, website, avatar, banner, counts, and other standard
Nitter user properties.

Update the profile with `POST /api/v1/accounts/:account_id/profile`. Send
`multipart/form-data`, even for a text-only update. Let your HTTP client set
the multipart boundary. Do not send JSON or base64-encoded images.

```sh
curl -i \
  -H "Authorization: Bearer $NITTER_BEARER_TOKEN" \
  -F 'name=Sammy Jones' \
  http://127.0.0.1:8080/api/v1/accounts/123456789/profile
```

You can send any nonempty combination of these fields:

| Field | Value | Limit and behavior |
| --- | --- | --- |
| `name` | Text | 1 to 50 Unicode code points; cannot be cleared. |
| `bio` | Text | Up to 160 Unicode code points; an empty value clears it. |
| `website_url` | Text | Empty to clear, or an absolute HTTP(S) URL up to 100 Unicode code points. |
| `profile_image` | File | JPEG, PNG, or WebP; up to 5 MiB. |
| `banner_image` | File | JPEG, PNG, or WebP; up to 5 MiB. |

For example, add files with `-F 'profile_image=@avatar.png;type=image/png'`
or `-F 'banner_image=@banner.jpg;type=image/jpeg'`. Image bytes must match the
declared MIME type. The whole request is limited to 12 MiB. Duplicate or
unknown fields are rejected. Omitted fields remain unchanged, including
`location`. An image cannot be removed through this endpoint.

Text updates read the latest profile through the selected account, merge the
supplied fields, and submit the full text profile to X. Image-only updates
skip that text snapshot and text write. When both text and images are present,
Nitter uploads all images first, then updates text, avatar, and banner in that
order. A failure stops later steps but does not roll back changes already made
on X. Do not blindly retry after a timeout or 502. Read the profile first to
check whether an earlier step succeeded.

A successful update returns `200 OK` with the normalized profile:

```json
{
  "ok": true,
  "account_id": "123456789",
  "updated_fields": ["name"],
  "media_ids": {},
  "profile": {
    "id": "123456789",
    "username": "sammy",
    "fullname": "Sammy Jones"
  }
}
```

`updated_fields` names only fields supplied in the request. `media_ids`
contains `profile_image` and/or `banner_image` IDs when those files were
uploaded; it is empty for text-only updates. As with the read example, the
actual `profile` includes the other standard Nitter user properties.

Errors use `{"error":"Human-readable error"}`. Relevant HTTP statuses are
`400` for malformed or invalid fields, `401` for a missing or invalid Nitter
token, `404` for an unconfigured account ID, `409` for a non-cookie account,
`413` for size limits, `415` for unsupported or mismatched content types,
`422` when X rejects a value or image, `429` for session or upstream rate
limits, `502` for other upstream or response failures, and `503` when
`NITTER_BEARER_TOKEN` is not configured on the server.

Request pacing (`minRequestIntervalMs`, or `NITTER_MIN_REQUEST_INTERVAL_MS`)
and concurrency (`maxConcurrentReqs`, or `NITTER_MAX_CONCURRENT_REQS`) are per
account and upstream endpoint. With concurrency set to 1, the same account can
run one search and one conversation fetch simultaneously. Another search must
wait for the active search to finish and its pacing interval to expire. Routes
using the same upstream endpoint share both limits, including tweet search and
user search. Error cooldowns (`errorCooldownMs`) still apply account-wide.

Set `NITTER_PROXY_ACCOUNTS_PER_IP` (`proxyAccountsPerIp`) to split accounts
across proxy IPs by port. Accounts are grouped in sessions file order, and each
group adds its index to the proxy URL's port: with `:8001` and 20, accounts
1-20 use port 8001, 21-40 use 8002, and so on. Keep the sessions file
append-only, since removing a line moves every later account to another IP.
The default of 0 sends every account through the configured port.

Health reports `sessions.cooling_down` for account-wide error cooldowns and
`sessions.pacing` for accounts with at least one endpoint in its pacing interval.
These counts can overlap; a paced account may still serve other endpoints.
The JSON API health route nests these fields under `sessions.sessions`.
With debug enabled, `/.sessions` exposes each endpoint's remaining `pacing_ms`
under `apis`, separately from the account's `cooldown_ms`. Each endpoint with
active work also reports `pending`; the session's top-level `pending` is the
total number of active requests across its endpoints, not a concurrency cap.
