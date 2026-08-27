# SPDX-License-Identifier: AGPL-3.0-only
import std/json
import jester
import router_utils
import ".."/[auth, types]

proc createDebugRouter*(cfg: Config) =
  router debug:
    get "/.health":
      var health = getSessionPoolHealth()
      health["queue"] = getQueueHealth()
      respJson health

    get "/.sessions":
      cond cfg.enableDebug
      respJson getSessionPoolDebug()
