# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, json, options, strutils, times

import jester

import router_utils
import ".."/[api, auth, profile_update, query, redis_cache, types]

export api, profile_update, query, redis_cache, types

proc dateJson*(dt: DateTime): JsonNode =
  try:
    let ts = dt.toTime().toUnix()
    if ts <= 0:
      return newJNull()
    return %ts
  except CatchableError:
    return newJNull()

proc validUsername*(name: string): bool =
  name.len > 0 and name.len <= 20 and
    name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_'})

proc validId*(id: string): bool =
  id.len > 0 and id.len <= 19 and id.allCharsInSet({'0'..'9'})

proc jsonError*(message: string): JsonNode =
  result = newJObject()
  result["error"] = %message

template respApi*(node: JsonNode) =
  resp Http200, {"Content-Type": "application/json; charset=utf-8"}, $node

template respApiError*(code: HttpCode; message: string) =
  resp code, {"Content-Type": "application/json; charset=utf-8"}, $jsonError(message)

proc userJson*(user: User): JsonNode =
  result = newJObject()
  result["id"] = %user.id
  result["username"] = %user.username
  result["fullname"] = %user.fullname
  result["location"] = %user.location
  result["website"] = %user.website
  result["bio"] = %user.bio
  result["avatar"] = %user.userPic
  result["banner"] = %user.banner
  result["pinned_tweet_id"] = %user.pinnedTweet
  result["following"] = %user.following
  result["followers"] = %user.followers
  result["tweets"] = %user.tweets
  result["likes"] = %user.likes
  result["media"] = %user.media
  result["verified_type"] = %($user.verifiedType)
  result["protected"] = %user.protected
  result["suspended"] = %user.suspended
  result["join_date"] = dateJson(user.joinDate)

proc statsJson*(stats: TweetStats): JsonNode =
  result = newJObject()
  result["replies"] = %stats.replies
  result["retweets"] = %stats.retweets
  result["likes"] = %stats.likes
  result["views"] = %stats.views

proc videoVariantJson*(variant: VideoVariant): JsonNode =
  result = newJObject()
  result["content_type"] = %($variant.contentType)
  result["url"] = %variant.url
  result["bitrate"] = %variant.bitrate
  result["resolution"] = %variant.resolution

proc videoJson*(video: Video): JsonNode =
  result = newJObject()
  result["duration_ms"] = %video.durationMs
  result["url"] = %video.url
  result["thumbnail"] = %video.thumb
  result["available"] = %video.available
  result["reason"] = %video.reason
  result["title"] = %video.title
  result["description"] = %video.description
  result["playback_type"] = %($video.playbackType)

  var variants = newJArray()
  for variant in video.variants:
    variants.add videoVariantJson(variant)
  result["variants"] = variants

proc mediaJson*(media: Media): JsonNode =
  result = newJObject()
  case media.kind
  of photoMedia:
    result["type"] = %"photo"
    result["url"] = %media.photo.url
    result["alt_text"] = %media.photo.altText
  of videoMedia:
    result["type"] = %"video"
    result["video"] = videoJson(media.video)
  of gifMedia:
    result["type"] = %"gif"
    result["url"] = %media.gif.url
    result["thumbnail"] = %media.gif.thumb
    result["alt_text"] = %media.gif.altText

proc mediaListJson*(media: MediaEntities): JsonNode =
  result = newJArray()
  for item in media:
    result.add mediaJson(item)

proc pollJson*(poll: Poll): JsonNode =
  result = newJObject()
  result["options"] = %poll.options
  result["values"] = %poll.values
  result["votes"] = %poll.votes
  result["leader"] = %poll.leader
  result["status"] = %poll.status

proc cardJson*(card: Card): JsonNode =
  result = newJObject()
  result["kind"] = %($card.kind)
  result["url"] = %card.url
  result["title"] = %card.title
  result["destination"] = %card.dest
  result["text"] = %card.text
  result["image"] = %card.image
  result["video"] =
    if card.video.isSome: videoJson(card.video.get())
    else: newJNull()

proc articlePreviewJson*(article: ArticlePreview): JsonNode =
  result = newJObject()
  result["title"] = %article.title
  result["preview_text"] = %article.previewText
  result["cover_image"] = %article.coverImage
  result["tweet_id"] = %article.tweetId

proc userListJson*(users: seq[User]): JsonNode =
  result = newJArray()
  for user in users:
    result.add userJson(user)

proc tweetJson*(tweet: Tweet; depth = 0): JsonNode =
  if tweet.isNil:
    return newJNull()

  result = newJObject()
  result["id"] = %tweet.id
  result["thread_id"] = %tweet.threadId
  result["reply_id"] = %tweet.replyId
  result["user"] = userJson(tweet.user)
  result["text"] = %tweet.text
  result["created_at"] = dateJson(tweet.time)
  result["reply_to"] = %tweet.reply
  result["pinned"] = %tweet.pinned
  result["has_thread"] = %tweet.hasThread
  result["available"] = %tweet.available
  result["tombstone"] = %tweet.tombstone
  result["location"] = %tweet.location
  result["stats"] = statsJson(tweet.stats)
  result["media"] = mediaListJson(tweet.media)
  result["media_tags"] = userListJson(tweet.mediaTags)
  result["history"] = %tweet.history
  result["note"] = %tweet.note
  result["is_ad"] = %tweet.isAd
  result["is_ai"] = %tweet.isAI
  result["attribution"] =
    if tweet.attribution.isSome: userJson(tweet.attribution.get())
    else: newJNull()
  result["attribution_link"] = %tweet.attributionLink
  result["card"] =
    if tweet.card.isSome: cardJson(tweet.card.get())
    else: newJNull()
  result["poll"] =
    if tweet.poll.isSome: pollJson(tweet.poll.get())
    else: newJNull()
  result["article_preview"] =
    if tweet.articlePreview.isSome: articlePreviewJson(tweet.articlePreview.get())
    else: newJNull()

  if depth < 2:
    result["retweet"] =
      if tweet.retweet.isSome: tweetJson(tweet.retweet.get(), depth + 1)
      else: newJNull()
    result["quote"] =
      if tweet.quote.isSome: tweetJson(tweet.quote.get(), depth + 1)
      else: newJNull()
  else:
    result["retweet"] = newJNull()
    result["quote"] = newJNull()

proc tweetsJson*(tweets: Tweets): JsonNode =
  result = newJArray()
  for tweet in tweets:
    result.add tweetJson(tweet)

proc tweetGroupsJson*(groups: seq[Tweets]): JsonNode =
  result = newJArray()
  for group in groups:
    result.add tweetsJson(group)

proc timelineJson*(timeline: Timeline): JsonNode =
  result = newJObject()
  result["items"] = tweetGroupsJson(timeline.content)
  result["cursor_top"] = %timeline.top
  result["cursor_bottom"] = %timeline.bottom
  result["beginning"] = %timeline.beginning

proc userResultJson*(users: Result[User]): JsonNode =
  result = newJObject()
  result["items"] = userListJson(users.content)
  result["cursor_top"] = %users.top
  result["cursor_bottom"] = %users.bottom
  result["beginning"] = %users.beginning

proc chainJson*(chain: Chain): JsonNode =
  result = newJObject()
  result["items"] = tweetsJson(chain.content)
  result["has_more"] = %chain.hasMore
  result["cursor"] = %chain.cursor

proc chainsJson*(chains: Result[Chain]): JsonNode =
  result = newJObject()
  var items = newJArray()
  for chain in chains.content:
    items.add chainJson(chain)
  result["items"] = items
  result["cursor_top"] = %chains.top
  result["cursor_bottom"] = %chains.bottom
  result["beginning"] = %chains.beginning

proc conversationJson*(conv: Conversation): JsonNode =
  result = newJObject()
  result["tweet"] = tweetJson(conv.tweet)
  result["before"] = chainJson(conv.before)
  result["after"] = chainJson(conv.after)
  result["replies"] = chainsJson(conv.replies)

proc profileJson*(profile: Profile): JsonNode =
  result = newJObject()
  result["user"] = userJson(profile.user)
  result["timeline"] = timelineJson(profile.tweets)

proc profileUpdateJson*(update: ProfileUpdateResult): JsonNode =
  result = newJObject()
  result["ok"] = %true
  result["account_id"] = %update.accountId
  result["updated_fields"] = %update.updatedFields

  let mediaIds = newJObject()
  if update.profileImageMediaId.len > 0:
    mediaIds["profile_image"] = %update.profileImageMediaId
  if update.bannerImageMediaId.len > 0:
    mediaIds["banner_image"] = %update.bannerImageMediaId
  result["media_ids"] = mediaIds
  result["profile"] = userJson(update.profile)

proc profileReadJson*(accountId: string; read: ProfileReadResult): JsonNode =
  result = newJObject()
  result["account_id"] = %accountId
  result["snapshot"] = %*{
    "name": read.snapshot.name,
    "bio": read.snapshot.bio,
    "website_url": read.snapshot.websiteUrl,
    "location": read.snapshot.location
  }
  result["profile"] = userJson(read.profile)

proc apiIndexJson*(): JsonNode =
  result = newJObject()
  result["name"] = %"Nitter local REST API"
  result["version"] = %"v1"

  var endpoints = newJArray()
  for endpoint in [
    "/api/v1/health",
    "/api/v1/users/:username",
    "/api/v1/users/:username/tweets",
    "/api/v1/users/:username/replies",
    "/api/v1/users/:username/media",
    "/api/v1/users/:username/followers",
    "/api/v1/users/:username/following",
    "/api/v1/tweets/:id",
    "/api/v1/tweets/:id/replies",
    "/api/v1/search/tweets?q=...&sort=latest|top",
    "/api/v1/search/users?q=...",
    "GET /api/v1/accounts/:account_id/profile",
    "POST /api/v1/accounts/:account_id/profile"
  ]:
    endpoints.add %endpoint
  result["endpoints"] = endpoints

proc healthJson*(): JsonNode =
  result = newJObject()
  result["ok"] = %true
  result["sessions"] = getSessionPoolHealth()
  result["queue"] = getQueueHealth()

proc getTimelineKind*(kind: string): TimelineKind =
  case kind
  of "replies": TimelineKind.replies
  of "media": TimelineKind.media
  else: TimelineKind.tweets

proc loadProfileTimeline*(name, kind, cursor: string): Future[Profile] {.async.} =
  let userId = await getUserId(name)

  if userId.len == 0:
    return Profile(user: User(username: name))
  if userId == "suspended":
    return Profile(user: User(username: name, suspended: true))

  result = await getGraphUserTweets(userId, getTimelineKind(kind), cursor)
  result.user = await getCachedUser(name)

proc createJsonApiRouter*(cfg: Config) =
  router jsonApi:
    get "/api/v1/?":
      respApi(apiIndexJson())

    get "/api/v1/health/?":
      respApi(healthJson())

    get "/api/v1/accounts/@account_id/profile/?":
      let accountId = @"account_id"
      if not validId(accountId):
        respApiError(Http400, "Invalid account ID")

      var numericAccountId: int64
      try:
        numericAccountId = parseBiggestInt(accountId)
      except ValueError:
        respApiError(Http400, "Invalid account ID")
      if numericAccountId <= 0:
        respApiError(Http400, "Invalid account ID")

      try:
        respApi(profileReadJson(accountId, await readAccountProfile(numericAccountId)))
      except ProfileRequestError as error:
        respApiError(HttpCode(error.status), error.msg)

    post "/api/v1/accounts/@account_id/profile/?":
      let accountId = @"account_id"
      if not validId(accountId):
        respApiError(Http400, "Invalid account ID")

      var numericAccountId: int64
      try:
        numericAccountId = parseBiggestInt(accountId)
      except ValueError:
        respApiError(Http400, "Invalid account ID")
      if numericAccountId <= 0:
        respApiError(Http400, "Invalid account ID")

      try:
        let updateRequest = parseProfileUpdateRequest(
          request.headers.getOrDefault("Content-Type"), request.body)
        let update = await updateAccountProfile(numericAccountId, updateRequest)
        respApi(profileUpdateJson(update))
      except ProfileRequestError as error:
        respApiError(HttpCode(error.status), error.msg)

    get "/api/v1/users/@name/?":
      let name = @"name"
      if not validUsername(name):
        respApiError(Http400, "Invalid username")

      let user = await getCachedUser(name)
      if user.username.len == 0:
        respApiError(Http404, "User not found")
      if user.suspended:
        respApiError(Http404, "User is suspended")

      respApi(userJson(user))

    get "/api/v1/users/@name/@kind/?":
      let
        name = @"name"
        kind = @"kind"

      if not validUsername(name):
        respApiError(Http400, "Invalid username")

      case kind
      of "tweets", "replies", "media":
        let profile = await loadProfileTimeline(name, kind, getCursor())
        if profile.user.suspended:
          respApiError(Http404, "User is suspended")
        if profile.user.id.len == 0:
          respApiError(Http404, "User not found")

        respApi(profileJson(profile))

      of "followers", "following":
        let userId = await getUserId(name)
        if userId.len == 0:
          respApiError(Http404, "User not found")
        if userId == "suspended":
          respApiError(Http404, "User is suspended")

        let users =
          if kind == "followers": await getGraphFollowers(userId, getCursor())
          else: await getGraphFollowing(userId, getCursor())

        respApi(userResultJson(users))

      else:
        respApiError(Http404, "Unknown user endpoint")

    get "/api/v1/tweets/@id/?":
      let id = @"id"
      if not validId(id):
        respApiError(Http400, "Invalid tweet ID")

      let conv = await getTweet(id, getCursor())
      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        respApiError(Http404, "Tweet not found")

      respApi(conversationJson(conv))

    get "/api/v1/tweets/@id/replies/?":
      let id = @"id"
      if not validId(id):
        respApiError(Http400, "Invalid tweet ID")

      let replies = await getReplies(id, getCursor())
      respApi(chainsJson(replies))

    get "/api/v1/search/tweets/?":
      if @"q".len == 0:
        respApiError(Http400, "Missing q parameter")
      if @"q".len > 500:
        respApiError(Http400, "Search input too long")

      var q = initQuery(params(request))
      q.kind = tweets
      respApi(timelineJson(await getGraphTweetSearch(q, getCursor())))

    get "/api/v1/search/users/?":
      if @"q".len == 0:
        respApiError(Http400, "Missing q parameter")
      if @"q".len > 500:
        respApiError(Http400, "Search input too long")

      var q = initQuery(params(request))
      q.kind = users
      respApi(userResultJson(await getGraphUserSearch(q, getCursor())))
