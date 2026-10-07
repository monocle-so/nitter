# SPDX-License-Identifier: AGPL-3.0-only
import httpclient, strutils, times
import types

const
  # Upstreams close idle keep-alive connections, and a pooled client whose
  # socket is already closed fails with "Connection was closed before full
  # request has been made" on reuse. This must stay strictly below the shortest
  # upstream idle timeout, or the two race and the pool hands out a connection
  # the far end is closing right then. The bundled api proxy reaps at 30s.
  maxIdleSeconds = 20.0

type
  PooledConn = object
    proxyKey: string
    client: AsyncHttpClient
    releasedAt: float # epochTime() when it was returned to the pool

  HttpPool* = ref object
    conns*: seq[PooledConn]

var
  maxConns: int
  proxyUrl: string
  proxyAuth: string
  proxySessionPerAccount: bool

proc setMaxHttpConns*(n: int) =
  maxConns = n

proc normalizeProxyUrl(url: string): string =
  let value = url.strip()
  if value.len == 0: ""
  elif "://" in value: value
  else: "http://" & value

proc setHttpProxy*(url: string; auth: string; perAccount=false) =
  proxyUrl = normalizeProxyUrl(url)
  proxyAuth = auth.strip()
  proxySessionPerAccount = perAccount

proc sanitizeSessionId(value: string): string =
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}:
      result.add(ch)

proc proxySessionId(session: Session): string =
  if session.isNil:
    return ""

  if session.id > 0:
    return "n" & $session.id

  result = sanitizeSessionId(session.username)
  if result.len > 0:
    result = "n" & result

proc foldProxyAuth(url, auth: string): string =
  if url.len == 0:
    return ""

  if auth.len == 0 or "@" in url:
    return url

  let schemeEnd = url.find("://") + 3
  url[0 ..< schemeEnd] & auth & "@" & url[schemeEnd .. ^1]

proc addProxySession(url, sessionId: string): string =
  result = url.replace("{session}", sessionId).replace("{account}", sessionId)
  if sessionId.len == 0 or not proxySessionPerAccount or "-sessid-" in result:
    return

  let
    schemeEnd = result.find("://") + 3
    at = result.find("@", schemeEnd)

  if schemeEnd < 3 or at < 0:
    return

  let colon = result.find(":", schemeEnd)
  let insertAt = if colon >= 0 and colon < at: colon else: at
  result = result[0 ..< insertAt] & "-sessid-" & sessionId & result[insertAt .. ^1]

proc proxyPortSpan(url: string): (int, int) =
  ## Bounds of the port digits in a proxy URL, or (-1, -1) if it has none.
  let schemeEnd = url.find("://") + 3
  if schemeEnd < 3:
    return (-1, -1)
  var hostEnd = url.find('/', schemeEnd)
  if hostEnd < 0:
    hostEnd = url.len
  let
    hostStart = max(schemeEnd, url.rfind('@', last = hostEnd - 1) + 1)
    colon = url.rfind(':', start = hostStart, last = hostEnd - 1)
  if colon < 0 or colon + 1 == hostEnd:
    return (-1, -1)
  for ch in url[colon + 1 ..< hostEnd]:
    if ch notin Digits:
      return (-1, -1)
  (colon + 1, hostEnd)

proc addProxyGroup(url: string; group: int): string =
  let (first, last) = proxyPortSpan(url)
  if group <= 0 or first < 0:
    return url
  url[0 ..< first] & $(parseInt(url[first ..< last]) + group) & url[last .. ^1]

proc proxyGroupPorts*(groups: int): string =
  ## Port range the proxy groups use, for the startup log.
  let (first, last) = proxyPortSpan(proxyUrl)
  if proxyUrl.len == 0:
    return "port offsets +0 to +" & $(groups - 1)
  if first < 0:
    raise newException(ValueError, "proxy URL has no port to offset")
  let base = parseInt(proxyUrl[first ..< last])
  "ports " & $base & "-" & $(base + groups - 1)

proc getHttpProxyKey*(session: Session): string =
  if proxyUrl.len == 0:
    return ""
  let
    url = addProxySession(foldProxyAuth(proxyUrl, proxyAuth), proxySessionId(session))
    group = if session.isNil: 0 else: session.proxyGroup
  addProxyGroup(url, group)

proc newClient(heads: HttpHeaders; proxyKey: string): AsyncHttpClient =
  if proxyKey.len > 0:
    newAsyncHttpClient(headers=heads, proxy=newProxy(proxyKey))
  else:
    newAsyncHttpClient(headers=heads)

proc release*(pool: HttpPool; client: AsyncHttpClient; proxyKey: string; badClient=false) =
  if pool.conns.len >= maxConns or badClient:
    try: client.close()
    except: discard
  elif client != nil:
    pool.conns.insert(PooledConn(
      client: client, proxyKey: proxyKey, releasedAt: epochTime()))

proc acquire*(pool: HttpPool; heads: HttpHeaders; proxyKey: string): AsyncHttpClient =
  let now = epochTime()
  var i = 0
  while i < pool.conns.len:
    if pool.conns[i].proxyKey != proxyKey:
      inc i
      continue

    let conn = pool.conns[i]
    pool.conns.delete(i)

    # Drop anything that has sat long enough for the far end to have closed it,
    # and keep scanning - a stale entry usually means its neighbours are stale
    # too, which is why retrying on the next pooled client used to fail as well.
    if now - conn.releasedAt > maxIdleSeconds:
      try: conn.client.close()
      except: discard
      continue

    result = conn.client
    result.headers = heads
    return

  result = newClient(heads, proxyKey)

template use*(pool: HttpPool; heads: HttpHeaders; proxyKey: string; body: untyped): untyped =
  var
    requestProxyKey {.inject.} = proxyKey
    c {.inject.} = pool.acquire(heads, requestProxyKey)
    badClient {.inject.} = false

  try:
    body
  except BadClientError, ProtocolError:
    # Twitter returned 503 or closed the connection, we need a new client
    pool.release(c, requestProxyKey, true)
    badClient = false
    c = pool.acquire(heads, requestProxyKey)
    body
  finally:
    pool.release(c, requestProxyKey, badClient)
