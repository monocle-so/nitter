# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, json, strformat, logging, strutils
from net import Port
from os import getEnv, normalizedPath

import jester

import types, config, prefs, formatters, redis_cache, http_pool, auth, apiutils
import routes/[
  media, debug, broadcast, space, json_api, router_utils]

let
  configPath = getEnv("NITTER_CONF_FILE", "./nitter.conf")
  (cfg, fullCfg) = getConfig(configPath)

  sessionsPath = getEnv("NITTER_SESSIONS_FILE", "./sessions.jsonl")

if cfg.apiProxyRequired and cfg.apiProxy.strip().len == 0:
  quit "NITTER_API_PROXY_REQUIRED is enabled but NITTER_API_PROXY is empty", QuitFailure

initSessionPool(cfg, sessionsPath)

if not cfg.enableDebug:
  # Silence Jester's query warning
  addHandler(newConsoleLogger())
  setLogFilter(lvlError)

stdout.write &"Starting Nitter at {getUrlPrefix(cfg)}\n"
stdout.flushFile

updateDefaultPrefs(fullCfg)
setCacheTimes(cfg)
setHmacKey(cfg.hmacKey)
if cfg.hmacKey.len == 0 or cfg.hmacKey == "secretkey":
  stderr.write "WARNING: insecure default 'hmacKey' in nitter.conf; " &
    "set a unique random value to stop media URL signatures being forgeable.\n"
  stderr.flushFile
setProxyEncoding(cfg.base64Media)
setMaxHttpConns(cfg.httpMaxConns)
setHttpProxy(cfg.proxy, cfg.proxyAuth, cfg.proxySessionPerAccount)
setApiProxy(cfg.apiProxy)
if cfg.proxyAccountsPerIp > 0:
  let groups = proxyGroupCount()
  try:
    echo &"[sessions] proxy IP groups: {groups} x {cfg.proxyAccountsPerIp} accounts, ",
      proxyGroupPorts(groups)
  except ValueError as e:
    quit "NITTER_PROXY_ACCOUNTS_PER_IP is set but " & e.msg, QuitFailure
setDisableTid(cfg.disableTid)
setMaxConcurrentReqs(cfg.maxConcurrentReqs)
setSessionSafety(
  cfg.minRequestIntervalMs, cfg.errorCooldownMs, cfg.rateLimitRemainingBuffer)
setMaxRetries(cfg.maxRetries)
setRetryDelayMs(cfg.retryDelayMs)
setMaxQueuedPerSession(cfg.maxQueuedPerSession)

waitFor initRedisPool(cfg)
stdout.write &"Connected to Redis at {cfg.redisHost}:{cfg.redisPort}\n"
stdout.flushFile

createMediaRouter(cfg)
createBroadcastRouter(cfg)
createSpaceRouter(cfg)
createDebugRouter(cfg)
createJsonApiRouter(cfg)

settings:
  port = Port(cfg.port)
  staticDir = normalizedPath(cfg.staticDir)
  bindAddr = cfg.address
  reusePort = true
  maxBody = 12 * 1024 * 1024

let bearerToken = getEnv("NITTER_BEARER_TOKEN")

routes:
  before:
    if request.path.startsWith("/api/v1"):
      if bearerToken.len == 0:
        halt Http503, {"Content-Type": "application/json; charset=utf-8"},
             $jsonError("NITTER_BEARER_TOKEN is not configured")
      if request.headers.getOrDefault("Authorization") != &"Bearer {bearerToken}":
        halt Http401, {"Content-Type": "application/json; charset=utf-8"},
             $jsonError("Unauthorized")

    # Reject malformed paths
    if request.path.len == 0 or request.path[0] != '/':
      halt Http400

    # skip all file URLs
    cond "." notin request.path
    applyUrlPrefs()

  error Http404:
    resp Http404, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("Not found")

  error InternalError:
    echo error.exc.name, ": ", error.exc.msg
    resp Http500, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("Internal error")

  error BadClientError:
    echo error.exc.name, ": ", error.exc.msg
    resp Http500, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("Network error")

  error RateLimitError:
    resp Http429, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("Rate limited")

  error NoSessionsError:
    resp Http429, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("No sessions available")

  error QueueFullError:
    resp Http429, {"Content-Type": "application/json; charset=utf-8"},
         $jsonError("Request queue full")

  extend media, ""
  extend broadcastRoute, ""
  extend spaceRoute, ""
  extend debug, ""
  extend jsonApi, ""
