Clone the repo, place .env and sessions.jsonl in the repo root, then run:

cp nitter.example.conf nitter.conf
docker compose up -d --build

Test:
curl -fsS http://127.0.0.1:8080/api/v1/health
curl -i http://127.0.0.1:8080/api/v1/users/jack
curl -i --get http://127.0.0.1:8080/api/v1/search/tweets --data-urlencode 'q="Owner.com" restaurant'

Request pacing (`minRequestIntervalMs`, or `NITTER_MIN_REQUEST_INTERVAL_MS`)
and concurrency (`maxConcurrentReqs`, or `NITTER_MAX_CONCURRENT_REQS`) are per
account and upstream endpoint. With concurrency set to 1, the same account can
run one search and one conversation fetch simultaneously. Another search must
wait for the active search to finish and its pacing interval to expire. Routes
using the same upstream endpoint share both limits, including tweet search and
user search. Error cooldowns (`errorCooldownMs`) still apply account-wide.

Health reports `sessions.cooling_down` for account-wide error cooldowns and
`sessions.pacing` for accounts with at least one endpoint in its pacing interval.
These counts can overlap; a paced account may still serve other endpoints.
The JSON API health route nests these fields under `sessions.sessions`.
With debug enabled, `/.sessions` exposes each endpoint's remaining `pacing_ms`
under `apis`, separately from the account's `cooldown_ms`. Each endpoint with
active work also reports `pending`; the session's top-level `pending` is the
total number of active requests across its endpoints, not a concurrency cap.
