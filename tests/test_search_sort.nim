# SPDX-License-Identifier: AGPL-3.0-only
import std/[strutils, tables, unittest]
import ".."/src/[api, query, types]

suite "tweet search sort":
  test "defaults to Latest and ignores unknown values":
    check initQuery({"q": "x"}.toTable).sort == latest
    check initQuery({"q": "x", "sort": "bogus"}.toTable).sort == latest

  test "sort=top selects X's Top product":
    let q = initQuery({"q": "x", "sort": "top"}.toTable)
    check q.sort == top
    check searchProduct(q.sort) == "Top"
    check searchProduct(latest) == "Latest"

  test "genQueryUrl keeps a non-default sort and omits the default":
    check "sort=top" in genQueryUrl(initQuery({"q": "x", "sort": "top"}.toTable))
    check "sort=" notin genQueryUrl(initQuery({"q": "x"}.toTable))
