# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, strutils
import jester

import router_utils
import ".."/[types, formatters, redis_cache]
import media

proc createBroadcastRouter*(cfg: Config) =
  router broadcastRoute:
    get "/i/broadcasts/@id/stream":
      cond @"id".allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9'})
      var bc: Broadcast
      try:
        bc = await getCachedBroadcast(@"id")
      except:
        discard

      if bc.m3u8Url.len == 0:
        resp Http404

      let manifest = await safeFetch(bc.m3u8Url)
      if manifest.len == 0:
        resp Http502

      resp proxifyVideo(manifest, requestPrefs().proxyVideos, bc.m3u8Url), m3u8Mime
