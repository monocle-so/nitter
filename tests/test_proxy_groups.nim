# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, os, strutils, unittest]
import ".."/src/[auth, http_pool, types]

let fixturePath = getTempDir() / ("nitter-proxy-groups-" & $getCurrentProcessId() & ".jsonl")

proc account(id: int64): Session =
  result = waitFor acquireAccountWriteSession(id)
  releaseAccountWriteSession(result)

suite "proxy IP groups":
  setup:
    var lines: seq[string]
    for id in 1 .. 5:
      lines.add """{"kind":"cookie","id":"""" & $id & """","auth_token":"test","ct0":"test"}"""
    writeFile(fixturePath, lines.join("\n") & "\n")
    initSessionPool(Config(proxyAccountsPerIp: 2), fixturePath)
    removeFile(fixturePath)

  teardown:
    for id in 1 .. 5:
      var session = account(id)
      invalidate(session)

  test "accounts are grouped in sessions file order":
    for id, group in [1: 0, 2: 0, 3: 1, 4: 1, 5: 2]:
      check account(id).proxyGroup == group
    check proxyGroupCount() == 3

  test "each group adds its index to the proxy port":
    setHttpProxy("http://user:pass@isp.example:8001", "")
    check getHttpProxyKey(account(1)) == "http://user:pass@isp.example:8001"
    check getHttpProxyKey(account(4)) == "http://user:pass@isp.example:8002"
    check getHttpProxyKey(account(5)) == "http://user:pass@isp.example:8003"
    check proxyGroupPorts(3) == "ports 8001-8003"

  test "groups compose with per-account sticky sessions":
    setHttpProxy("http://user:pass@isp.example:8001", "", perAccount=true)
    check getHttpProxyKey(account(5)) == "http://user-sessid-n5:pass@isp.example:8003"

  test "a proxy without a port cannot be grouped":
    setHttpProxy("http://user:pass@isp.example", "")
    expect ValueError:
      discard proxyGroupPorts(3)
