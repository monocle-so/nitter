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
  maxBody = 64 * 1024

let bearerToken = getEnv("NITTER_BEARER_TOKEN")

routes:
  before:
    # Media-proxy routes are exempt: they need to be fetchable by third
    # parties (e.g. an LLM provider downloading an image URL) that can't be
    # handed our bearer token.
    let isMediaRoute = request.path.startsWith("/pic") or request.path.startsWith("/video")
    # Debug/health routes are exempt so uptime checks and operators can read
    # them without the bearer token. /.sessions is still gated separately
    # behind cfg.enableDebug.
    let isDebugRoute = request.path == "/.health" or request.path == "/.sessions"
    if bearerToken.len > 0 and not isMediaRoute and not isDebugRoute and
        request.headers.getOrDefault("Authorization") != &"Bearer {bearerToken}":
      halt Http401

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
