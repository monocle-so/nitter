#SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, times, json, random, strutils, tables, packedsets, deques, os, sets]
import types, consts
import experimental/parser/session

const hourInSeconds = 60 * 60
# how often the queue dispatcher re-checks for a freed-up session while
# waiting on time-based cooldowns/rate-limit resets (no event fires then)
const dispatchPollMs = 100

type
  QueuedRequest = object
    req: ApiReq
    fut: Future[Session]

var
  sessionPool: seq[Session]
  enableLogging = false
  # max requests at a time per upstream endpoint on each session
  maxConcurrentReqs = 1
  minRequestIntervalMs = 3000
  errorCooldownMs = 60 * 1000
  rateLimitRemainingBuffer = 10
  maxQueuedPerSession = 10

  requestQueue: Deque[QueuedRequest]
  dispatcherActive = false
  activeAccountWrites = initHashSet[int64]()

proc setMaxConcurrentReqs*(reqs: int) =
  if reqs > 0:
    maxConcurrentReqs = reqs

proc setSessionSafety*(minIntervalMs, cooldownMs, remainingBuffer: int) =
  if minIntervalMs >= 0:
    minRequestIntervalMs = minIntervalMs
  if cooldownMs >= 0:
    errorCooldownMs = cooldownMs
  if remainingBuffer >= 0:
    rateLimitRemainingBuffer = remainingBuffer

proc setMaxQueuedPerSession*(n: int) =
  if n >= 0:
    maxQueuedPerSession = n

proc nowMs(): int64 =
  int64(epochTime() * 1000)

template log(str: varargs[string, `$`]) =
  echo "[sessions] ", str.join("")

proc endpoint*(req: ApiReq; session: Session): string =
  case session.kind
  of oauth: req.oauth.endpoint
  of cookie: req.cookie.endpoint

proc pretty*(session: Session): string =
  if session.isNil:
    return "<null>"

  if session.id > 0 and session.username.len > 0:
    result = $session.id & " (" & session.username & ")"
  elif session.username.len > 0:
    result = session.username
  elif session.id > 0:
    result = $session.id
  else:
    result = "<unknown>"
  result = $session.kind & " " & result

proc snowflakeToEpoch(flake: int64): int64 =
  int64(((flake shr 22) + 1288834974657) div 1000)

proc getSessionPoolHealth*(): JsonNode =
  let now = epochTime().int

  var
    totalReqs = 0
    coolingDown = 0
    pacing = 0
    limited: PackedSet[int64]
    reqsPerApi: Table[string, int]
    oldest = now.int64
    newest = 0'i64
    average = 0'i64
    oauthTotal, cookieTotal = 0
    oauthLimited, cookieLimited = 0

  for session in sessionPool:
    let created = snowflakeToEpoch(session.id)
    if created > newest:
      newest = created
    if created < oldest:
      oldest = created
    average += created

    case session.kind
    of oauth: inc oauthTotal
    of cookie: inc cookieTotal

    if session.limited:
      limited.incl session.id
      case session.kind
      of oauth: inc oauthLimited
      of cookie: inc cookieLimited

    if session.nextAvailableAt > nowMs():
      inc coolingDown

    for deadline in session.nextRequestAt.values:
      if deadline > nowMs():
        inc pacing
        break

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        reqs = apiStatus.limit - apiStatus.remaining

      # no requests made with this session and endpoint since the limit reset
      if apiStatus.reset < now:
        continue

      reqsPerApi.mgetOrPut($api, 0).inc reqs
      totalReqs.inc reqs

  if sessionPool.len > 0:
    average = average div sessionPool.len
  else:
    oldest = 0
    average = 0

  return %*{
    "sessions": %*{
      "total": sessionPool.len,
      "limited": limited.card,
      "cooling_down": coolingDown,
      "pacing": pacing,
      "oauth": %*{"total": oauthTotal, "limited": oauthLimited},
      "cookie": %*{"total": cookieTotal, "limited": cookieLimited},
      "oldest": $fromUnix(oldest),
      "newest": $fromUnix(newest),
      "average": $fromUnix(average)
    },
    "requests": %*{
      "total": totalReqs,
      "apis": reqsPerApi
    }
  }

proc getSessionPoolDebug*(): JsonNode =
  let now = epochTime().int
  let currentMs = nowMs()
  var list = newJObject()

  for session in sessionPool:
    let sessionJson = %*{
      "kind": $session.kind,
      "apis": newJObject(),
      "pending": session.pending,
    }

    if session.limited:
      sessionJson["limited"] = %true
    if session.nextAvailableAt > currentMs:
      sessionJson["cooldown_ms"] = %(session.nextAvailableAt - currentMs)

    for api in session.apis.keys:
      let
        apiStatus = session.apis[api]
        obj = %*{}

      if apiStatus.reset > now.int:
        obj["remaining"] = %apiStatus.remaining
        obj["reset"] = %apiStatus.reset

      if "remaining" notin obj:
        continue

      sessionJson{"apis", $api} = obj

    for api, deadline in session.nextRequestAt:
      if deadline > currentMs:
        if api notin sessionJson["apis"]:
          sessionJson["apis"][api] = newJObject()
        sessionJson["apis"][api]["pacing_ms"] = %(deadline - currentMs)

    for api, pending in session.pendingByEndpoint:
      if pending > 0:
        if api notin sessionJson["apis"]:
          sessionJson["apis"][api] = newJObject()
        sessionJson["apis"][api]["pending"] = %pending

    list[$session.id] = sessionJson

  return %list

proc proxyGroupCount*(): int =
  for session in sessionPool:
    result = max(result, session.proxyGroup + 1)

proc rateLimitError*(): ref RateLimitError =
  newException(RateLimitError, "rate limited")

proc noSessionsError*(): ref NoSessionsError =
  newException(NoSessionsError, "no sessions available")

proc queueFullError*(): ref QueueFullError =
  newException(QueueFullError, "request queue is full")

proc isLimited(session: Session; req: ApiReq): bool =
  if session.isNil:
    return true

  let api = req.endpoint(session)
  if session.limited and api != graphUserTweetsV2:
    if (epochTime().int - session.limitedAt) > hourInSeconds:
      session.limited = false
      log "resetting limit: ", session.pretty
      return false
    else:
      return true

  if api in session.apis:
    let limit = session.apis[api]
    return limit.remaining <= rateLimitRemainingBuffer and limit.reset > epochTime().int
  else:
    return false

proc isCoolingDown(session: Session; req: ApiReq): bool =
  if session.isNil:
    return false
  let now = nowMs()
  session.nextAvailableAt > now or
    session.nextRequestAt.getOrDefault(req.endpoint(session)) > now

proc isReady(session: Session; req: ApiReq): bool =
  not (session.isNil or
       session.pendingByEndpoint.getOrDefault(req.endpoint(session)) >= maxConcurrentReqs or
       session.isCoolingDown(req) or session.isLimited(req))

proc reserve(session: Session; req: ApiReq) =
  let api = req.endpoint(session)
  inc session.pending
  session.pendingByEndpoint.mgetOrPut(api, 0).inc
  if minRequestIntervalMs > 0:
    let next = nowMs() + minRequestIntervalMs
    if session.nextRequestAt.getOrDefault(api) < next:
      session.nextRequestAt[api] = next

proc setCooldown*(session: Session; ms = errorCooldownMs) =
  if session.isNil or ms <= 0:
    return

  let next = nowMs() + ms
  if session.nextAvailableAt < next:
    session.nextAvailableAt = next

proc invalidate*(session: var Session) =
  if session.isNil: return
  log "invalidating: ", session.pretty

  # TODO: This isn't sufficient, but it works for now
  let idx = sessionPool.find(session)
  if idx > -1: sessionPool.delete(idx)
  session = nil

proc release*(session: Session; req: ApiReq) =
  if session.isNil: return
  let api = req.endpoint(session)
  if session.pendingByEndpoint.getOrDefault(api) > 0:
    dec session.pendingByEndpoint[api]
    dec session.pending

proc findReadySession(req: ApiReq): Session =
  if sessionPool.len == 0:
    return nil
  let start = rand(sessionPool.high)
  for i in 0 ..< sessionPool.len:
    let session = sessionPool[(start + i) mod sessionPool.len]
    if session.isReady(req):
      return session

proc queueCapacity(): int =
  # cap is per-account, so total queue depth scales with pool size
  max(1, sessionPool.len) * maxQueuedPerSession

proc getQueueHealth*(): JsonNode =
  # Requests waiting for a session across every endpoint. This is the pool
  # exhausting itself before any error shows up: a session limited or cooling
  # down does not fail a request, it queues it, so a pool that looks "fine" by
  # every other field here can still be adding latency nobody sees until the
  # queue is this full.
  %*{
    "depth": requestQueue.len,
    "capacity": queueCapacity()
  }

proc dispatchLoop() {.async.} =
  if dispatcherActive:
    return
  dispatcherActive = true
  try:
    while requestQueue.len > 0:
      var remaining: Deque[QueuedRequest]
      while requestQueue.len > 0:
        let item = requestQueue.popFirst()
        if item.fut.finished:
          # waiter already gave up (e.g. connection closed); drop it
          continue
        let session = findReadySession(item.req)
        if session.isNil:
          remaining.addLast(item)
        else:
          session.reserve(item.req)
          item.fut.complete(session)
      requestQueue = remaining
      if requestQueue.len > 0:
        await sleepAsync(dispatchPollMs)
  finally:
    dispatcherActive = false

proc getSession*(req: ApiReq): Future[Session] {.async.} =
  if sessionPool.len == 0:
    log "no sessions available for API: ", req.cookie.endpoint
    raise noSessionsError()

  let ready = findReadySession(req)
  if not ready.isNil:
    ready.reserve(req)
    return ready

  # no session is immediately available; queue this request rather than
  # dropping it, unless the per-account queue budget is already exhausted
  if requestQueue.len >= queueCapacity():
    log "queue full (", requestQueue.len, "/", queueCapacity(),
        "), rejecting request for API: ", req.cookie.endpoint
    raise queueFullError()

  let fut = newFuture[Session]("auth.getSession.queued")
  requestQueue.addLast(QueuedRequest(req: req, fut: fut))
  log "queuing request for API: ", req.cookie.endpoint,
      " (queue depth: ", requestQueue.len, "/", queueCapacity(), ")"

  asyncCheck dispatchLoop()
  result = await fut

proc acquireAccountWriteSession*(accountId: int64): Future[Session] {.async.} =
  ## Acquires the exact account requested by a state-changing API call. This
  ## intentionally never falls back to another pooled session.
  var session: Session
  for candidate in sessionPool:
    if candidate.id == accountId:
      session = candidate
      break

  if session.isNil:
    raise newException(KeyError, "Account not found")
  if session.kind != SessionKind.cookie:
    raise newException(ValueError, "Account is not a cookie session")
  if session.authToken.len == 0 or session.ct0.len == 0:
    raise newException(BadClientError, "Account cookie credentials are incomplete")

  while accountId in activeAccountWrites or session.nextAvailableAt > nowMs():
    await sleepAsync(dispatchPollMs)

  if session.limited and (epochTime().int - session.limitedAt) <= hourInSeconds:
    raise rateLimitError()
  if session.limited:
    session.limited = false

  activeAccountWrites.incl accountId
  inc session.pending
  result = session

proc releaseAccountWriteSession*(session: Session) =
  if session.isNil:
    return
  activeAccountWrites.excl session.id
  if session.pending > 0:
    dec session.pending

proc setLimited*(session: Session; req: ApiReq) =
  let api = req.endpoint(session)
  session.limited = true
  session.limitedAt = epochTime().int
  let remaining = if api in session.apis: session.apis[api].remaining else: 0
  log "rate limited by api: ", api, ", reqs left: ", remaining, ", ", session.pretty

proc setRateLimit*(session: Session; req: ApiReq; remaining, reset, limit: int) =
  # avoid undefined behavior in race conditions
  let api = req.endpoint(session)
  if api in session.apis:
    let rateLimit = session.apis[api]
    if rateLimit.reset >= reset and rateLimit.remaining < remaining:
      return
    if rateLimit.reset == reset and rateLimit.remaining >= remaining:
      session.apis[api].remaining = remaining
      return

  session.apis[api] = RateLimit(limit: limit, remaining: remaining, reset: reset)

proc initSessionPool*(cfg: Config; path: string) =
  enableLogging = cfg.enableDebug

  if path.endsWith(".json"):
    log "ERROR: .json is not supported, the file must be a valid JSONL file ending in .jsonl"
    quit 1

  if not fileExists(path):
    log "ERROR: ", path, " not found. This file is required to authenticate API requests."
    quit 1

  log "parsing JSONL account sessions file: ", path
  for line in path.lines:
    let session = parseSession(line)
    if cfg.proxyAccountsPerIp > 0:
      session.proxyGroup = sessionPool.len div cfg.proxyAccountsPerIp
    sessionPool.add session

  log "successfully added ", sessionPool.len, " valid account sessions"
