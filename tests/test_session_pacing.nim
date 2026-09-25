# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, json, os, tables, times, unittest]
import ".."/src/[auth, types]

proc request(api: string): ApiReq =
  ApiReq(cookie: ApiUrl(endpoint: api), oauth: ApiUrl(endpoint: "oauth/" & api))

const
  searchApi = "SearchTimeline"
  postsApi = "ConversationTimeline"
  intervalMs = 60_000

let
  search = request(searchApi)
  posts = request(postsApi)
  fixturePath = getTempDir() / ("nitter-pacing-" & $getCurrentProcessId() & ".jsonl")

suite "per-endpoint session pacing and concurrency":
  setup:
    # Synthetic credentials only. The tests exercise scheduling without X or Redis.
    writeFile(fixturePath,
      """{"kind":"cookie","id":"1","auth_token":"test","ct0":"test"}""" & "\n")
    initSessionPool(Config(), fixturePath)
    removeFile(fixturePath)
    setMaxConcurrentReqs(1)
    setSessionSafety(0, 60_000, 10)
    setMaxQueuedPerSession(0)
    var session = waitFor getSession(search)
    release(session, search)
    setSessionSafety(intervalMs, 60_000, 10)

  teardown:
    invalidate(session)

  test "a completed search blocks another search but allows posts":
    let account = waitFor getSession(search)
    release(account, search)
    expect QueueFullError:
      discard waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    check otherEndpoint == account
    check account.nextRequestAt.hasKey(searchApi)
    check account.nextRequestAt.hasKey(postsApi)
    check not account.nextRequestAt.hasKey(search.oauth.endpoint)
    check account.nextAvailableAt == 0
    release(otherEndpoint, posts)

  test "different endpoints run concurrently but each allows one request":
    setSessionSafety(0, 60_000, 10)
    let account = waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    check otherEndpoint == account
    check account.pending == 2
    expect QueueFullError:
      discard waitFor getSession(search)
    expect QueueFullError:
      discard waitFor getSession(posts)
    release(account, search)
    let nextSearch = waitFor getSession(search)
    check nextSearch == account
    check account.pending == 2
    release(otherEndpoint, posts)
    # Completing posts must not release the active search's slot.
    expect QueueFullError:
      discard waitFor getSession(search)
    check account.pending == 1
    release(nextSearch, search)
    check account.pending == 0

  test "concurrency stays capped when the pacing interval has elapsed":
    let account = waitFor getSession(search)
    account.nextRequestAt[searchApi] = 0
    expect QueueFullError:
      discard waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    check otherEndpoint == account
    release(otherEndpoint, posts)
    release(account, search)

  test "configured concurrency applies independently to each endpoint":
    setSessionSafety(0, 60_000, 10)
    setMaxConcurrentReqs(2)
    let first = waitFor getSession(search)
    let second = waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    check first == second
    check first == otherEndpoint
    check first.pending == 3
    expect QueueFullError:
      discard waitFor getSession(search)
    release(first, search)
    let replacement = waitFor getSession(search)
    check replacement == first
    release(second, search)
    release(replacement, search)
    release(otherEndpoint, posts)
    check first.pending == 0

  test "different query parameters still share the same endpoint slot":
    setSessionSafety(0, 60_000, 10)
    let account = waitFor getSession(search)
    var peopleSearch = search
    peopleSearch.cookie.params = @[("product", "People")]
    expect QueueFullError:
      discard waitFor getSession(peopleSearch)
    release(account, search)

  test "releasing an idle endpoint does not decrement other active work":
    setSessionSafety(0, 60_000, 10)
    let account = waitFor getSession(search)
    release(account, posts)
    check account.pending == 1
    expect QueueFullError:
      discard waitFor getSession(search)
    release(account, search)
    release(account, search)
    check account.pending == 0

  test "expiration permits reuse of the same endpoint":
    let account = waitFor getSession(search)
    release(account, search)
    account.nextRequestAt[searchApi] = int64(epochTime() * 1000) - 1
    let reused = waitFor getSession(search)
    check reused == account
    check reused.nextRequestAt[searchApi] > int64(epochTime() * 1000)
    release(reused, search)

  test "error cooldown still blocks every endpoint and never shortens":
    session.setCooldown(60_000)
    let deadline = session.nextAvailableAt
    session.setCooldown(1)
    check session.nextAvailableAt == deadline
    expect QueueFullError:
      discard waitFor getSession(search)
    expect QueueFullError:
      discard waitFor getSession(posts)

  test "quota exhaustion remains endpoint specific":
    session.setRateLimit(search, 10, epochTime().int + 60, 50)
    expect QueueFullError:
      discard waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    check otherEndpoint == session
    release(otherEndpoint, posts)

  test "disabling pacing permits immediate reuse after release":
    setSessionSafety(0, 60_000, 10)
    let first = waitFor getSession(search)
    release(first, search)
    let second = waitFor getSession(search)
    check second == first
    check second.nextRequestAt.len == 0
    release(second, search)

  test "queued work skips a paced endpoint and reserves its own endpoint":
    setMaxQueuedPerSession(10)
    let account = waitFor getSession(search)
    let activePosts = waitFor getSession(posts)
    let waitingSearch = getSession(search)
    let waitingPosts = getSession(posts)
    check not waitingSearch.finished
    check not waitingPosts.finished
    release(activePosts, posts)
    account.nextRequestAt[postsApi] = 0

    check waitFor withTimeout(waitingPosts, 2000)
    if waitingPosts.finished:
      let selected = waitingPosts.read()
      check selected == account
      check selected.nextRequestAt.hasKey(postsApi)
      check selected.pendingByEndpoint[searchApi] == 1
      check selected.pendingByEndpoint[postsApi] == 1
      release(selected, posts)
    check not waitingSearch.finished

    # Advance only the blocked endpoint's deadline to let the queue drain.
    account.nextRequestAt[searchApi] = 0
    release(account, search)
    check waitFor withTimeout(waitingSearch, 2000)
    if waitingSearch.finished:
      let selected = waitingSearch.read()
      check selected == account
      check selected.nextRequestAt[searchApi] > int64(epochTime() * 1000)
      release(selected, search)

  test "debug reports active requests per endpoint and in total":
    setSessionSafety(0, 60_000, 10)
    let account = waitFor getSession(search)
    let otherEndpoint = waitFor getSession(posts)
    let debug = getSessionPoolDebug()["1"]
    check debug["pending"].getInt == 2
    check debug["apis"][searchApi]["pending"].getInt == 1
    check debug["apis"][postsApi]["pending"].getInt == 1
    release(account, search)
    release(otherEndpoint, posts)

  test "health and debug distinguish pacing from error cooldowns":
    let account = waitFor getSession(search)
    release(account, search)
    let health = getSessionPoolHealth()
    check health["sessions"]["cooling_down"].getInt == 0
    check health["sessions"]["pacing"].getInt == 1
    let debug = getSessionPoolDebug()["1"]
    check debug["apis"][searchApi]["pacing_ms"].getInt > 0
    check not debug.hasKey("cooldown_ms")

    account.setCooldown(60_000)
    let coolingHealth = getSessionPoolHealth()
    check coolingHealth["sessions"]["cooling_down"].getInt == 1
    check coolingHealth["sessions"]["pacing"].getInt == 1
    check getSessionPoolDebug()["1"]["cooldown_ms"].getInt > 0

  test "debug preserves quota information alongside endpoint pacing":
    let account = waitFor getSession(search)
    release(account, search)
    account.setRateLimit(search, 40, epochTime().int + 60, 50)
    let api = getSessionPoolDebug()["1"]["apis"][searchApi]
    check api["remaining"].getInt == 40
    check api["reset"].getInt > epochTime().int
    check api["pacing_ms"].getInt > 0
