# SPDX-License-Identifier: AGPL-3.0-only
import std/json
import jester
import router_utils
import ".."/[auth, types]

# Built outside the `router`/`get` macro on purpose: mutating a JsonNode with
# `[]=` inside that macro's body fails to type-check (the same assignment
# compiles fine as a plain proc, e.g. `healthJson` in `json_api.nim`), so the
# merge happens here and the route just calls it.
proc debugHealth*(): JsonNode =
  result = getSessionPoolHealth()
  result["queue"] = getQueueHealth()

proc createDebugRouter*(cfg: Config) =
  router debug:
    get "/.health":
      respJson debugHealth()

    get "/.sessions":
      cond cfg.enableDebug
      respJson getSessionPoolDebug()
