# SPDX-License-Identifier: AGPL-3.0-only
import os
import parsecfg except Config
import types, strutils

proc get*[T](config: parseCfg.Config; section, key: string; default: T): T =
  let val = config.getSectionValue(section, key)
  if val.len == 0: return default

  when T is int: parseInt(val)
  elif T is bool: parseBool(val)
  elif T is string: val

proc getEnvOrConfig(config: parseCfg.Config; envName, section, key, default: string): string =
  let envVal = getEnv(envName).strip()
  if envVal.len > 0: envVal
  else: config.get(section, key, default)

proc getEnvOrConfig(config: parseCfg.Config; envName, section, key: string; default: bool): bool =
  let envVal = getEnv(envName).strip()
  if envVal.len > 0: parseBool(envVal)
  else: config.get(section, key, default)

proc getEnvOrConfig(config: parseCfg.Config; envName, section, key: string; default: int): int =
  let envVal = getEnv(envName).strip()
  if envVal.len > 0: parseInt(envVal)
  else: config.get(section, key, default)

proc getConfig*(path: string): (Config, parseCfg.Config) =
  var cfg = loadConfig(path)

  let conf = Config(
    # Server
    address: cfg.get("Server", "address", "0.0.0.0"),
    port: cfg.get("Server", "port", 8080),
    useHttps: cfg.get("Server", "https", true),
    httpMaxConns: cfg.get("Server", "httpMaxConnections", 100),
    staticDir: cfg.get("Server", "staticDir", "./public"),
    title: cfg.get("Server", "title", "Nitter"),
    hostname: cfg.get("Server", "hostname", "nitter.net"),

    # Cache
    listCacheTime: cfg.get("Cache", "listMinutes", 120),
    rssCacheTime: cfg.get("Cache", "rssMinutes", 10),

    redisHost: cfg.getEnvOrConfig("NITTER_REDIS_HOST", "Cache", "redisHost", "localhost"),
    redisPort: cfg.getEnvOrConfig("NITTER_REDIS_PORT", "Cache", "redisPort", 6379),
    redisConns: cfg.get("Cache", "redisConnections", 20),
    redisMaxConns: cfg.get("Cache", "redisMaxConnections", 30),
    redisPassword: cfg.getEnvOrConfig("NITTER_REDIS_PASSWORD", "Cache", "redisPassword", ""),

    # Config
    hmacKey: cfg.getEnvOrConfig("NITTER_HMAC_KEY", "Config", "hmacKey", "secretkey"),
    base64Media: cfg.get("Config", "base64Media", false),
    minTokens: cfg.get("Config", "tokenCount", 10),
    enableDebug: cfg.getEnvOrConfig("NITTER_ENABLE_DEBUG", "Config", "enableDebug", false),
    proxy: cfg.getEnvOrConfig("NITTER_PROXY", "Config", "proxy", ""),
    proxyAuth: cfg.getEnvOrConfig("NITTER_PROXY_AUTH", "Config", "proxyAuth", ""),
    proxySessionPerAccount: cfg.getEnvOrConfig(
      "NITTER_PROXY_SESSION_PER_ACCOUNT", "Config", "proxySessionPerAccount", false),
    apiProxy: cfg.getEnvOrConfig("NITTER_API_PROXY", "Config", "apiProxy", ""),
    apiProxyRequired: cfg.getEnvOrConfig(
      "NITTER_API_PROXY_REQUIRED", "Config", "apiProxyRequired", false),
    disableTid: cfg.get("Config", "disableTid", false),
    maxConcurrentReqs: cfg.getEnvOrConfig("NITTER_MAX_CONCURRENT_REQS", "Config", "maxConcurrentReqs", 1),
    minRequestIntervalMs: cfg.getEnvOrConfig("NITTER_MIN_REQUEST_INTERVAL_MS", "Config", "minRequestIntervalMs", 3000),
    errorCooldownMs: cfg.getEnvOrConfig("NITTER_ERROR_COOLDOWN_MS", "Config", "errorCooldownMs", 60000),
    rateLimitRemainingBuffer: cfg.getEnvOrConfig("NITTER_RATE_LIMIT_REMAINING_BUFFER", "Config", "rateLimitRemainingBuffer", 10),
    maxRetries: cfg.get("Config", "maxRetries", 1),
    retryDelayMs: cfg.get("Config", "retryDelayMs", 150),
    maxQueuedPerSession: cfg.getEnvOrConfig(
      "NITTER_MAX_QUEUED_PER_SESSION", "Config", "maxQueuedPerSession", 10)
  )

  return (conf, cfg)
