# SPDX-License-Identifier: AGPL-3.0-only
import std/[asyncdispatch, httpclient, options, sets, strutils, sysrand,
            tables, unicode, uri]
import packedjson

import apiutils, auth, parserutils, types
import experimental/parser as experimentalParser

const
  maxImageBytes* = 5 * 1024 * 1024
  uploadChunkBytes* = 1024 * 1024
  maxProfileRequestBytes* = 12 * 1024 * 1024
  upstreamErrorPreviewBytes = 4096
  uploadBase = "https://upload.x.com/i/media/upload.json"

type
  ProfileRequestError* = object of CatchableError
    status*: int

  ProfileImage* = object
    contentType*: string
    data*: string

  ProfileUpdateRequest* = object
    name*: Option[string]
    bio*: Option[string]
    websiteUrl*: Option[string]
    profileImage*: Option[ProfileImage]
    bannerImage*: Option[ProfileImage]

  ProfileUpdateResult* = object
    accountId*: string
    updatedFields*: seq[string]
    profileImageMediaId*: string
    bannerImageMediaId*: string
    profile*: User

  ProfileReadResult* = object
    snapshot*: ProfileSnapshot
    profile*: User

  ProfileSnapshot* = object
    name*: string
    bio*: string
    websiteUrl*: string
    location*: string

  AccountSettings* = object
    screenName*: string

  MultipartPart = object
    name: string
    filename: Option[string]
    contentType: string
    data: string

proc profileError*(status: int; message: string): ref ProfileRequestError =
  result = newException(ProfileRequestError, message)
  result.status = status

proc runeCount(value: string): int =
  if validateUtf8(value) != -1:
    raise profileError(400, "Text fields must contain valid UTF-8")
  value.runeLen

proc parseQuotedValue(value: string; start: var int): string =
  if start >= value.len or value[start] != '"':
    let finish = value.find(';', start)
    if finish < 0:
      result = value[start .. ^1].strip()
      start = value.len
    else:
      result = value[start ..< finish].strip()
      start = finish
    return

  inc start
  while start < value.len:
    case value[start]
    of '\\':
      inc start
      if start < value.len:
        result.add value[start]
        inc start
    of '"':
      inc start
      return
    else:
      result.add value[start]
      inc start
  raise profileError(400, "Malformed multipart disposition")

proc dispositionParams(value: string): Table[string, string] =
  result = initTable[string, string]()
  var cursor = 0
  let firstSeparator = value.find(';')
  let disposition =
    if firstSeparator < 0: value.strip().toLowerAscii()
    else: value[0 ..< firstSeparator].strip().toLowerAscii()
  if disposition != "form-data":
    raise profileError(400, "Multipart parts must use form-data disposition")
  cursor = if firstSeparator < 0: value.len else: firstSeparator + 1

  while cursor < value.len:
    while cursor < value.len and value[cursor] in {' ', '\t', ';'}:
      inc cursor
    if cursor >= value.len:
      break
    let
      equals = value.find('=', cursor)
      separator = value.find(';', cursor)
    if equals < 0 or (separator >= 0 and equals > separator):
      raise profileError(400, "Malformed multipart disposition parameter")
    let key = value[cursor ..< equals].strip().toLowerAscii()
    cursor = equals + 1
    if key.len == 0 or key in result:
      raise profileError(400, "Malformed multipart disposition parameter")
    result[key] = parseQuotedValue(value, cursor)
    while cursor < value.len and value[cursor] != ';':
      if value[cursor] notin {' ', '\t'}:
        raise profileError(400, "Malformed multipart disposition parameter")
      inc cursor

proc multipartBoundary(contentType: string): string =
  let sections = contentType.split(';')
  if sections.len == 0 or sections[0].strip().toLowerAscii() != "multipart/form-data":
    raise profileError(415, "Content-Type must be multipart/form-data")

  for index in 1 ..< sections.len:
    let section = sections[index].strip()
    let equals = section.find('=')
    if equals < 0 or section[0 ..< equals].strip().toLowerAscii() != "boundary":
      continue
    result = section[equals + 1 .. ^1].strip()
    if result.len >= 2 and result[0] == '"' and result[^1] == '"':
      result = result[1 .. ^2]
    break

  if result.len == 0 or result.len > 200 or '\c' in result or '\L' in result:
    raise profileError(400, "Invalid multipart boundary")

proc parseMultipart(contentType, body: string): seq[MultipartPart] =
  let
    boundary = multipartBoundary(contentType)
    marker = "--" & boundary

  if not body.startsWith(marker & "\c\L"):
    raise profileError(400, "Malformed multipart body")

  var cursor = marker.len + 2
  while cursor < body.len:
    let headerEnd = body.find("\c\L\c\L", cursor)
    if headerEnd < 0:
      raise profileError(400, "Malformed multipart headers")

    var headers = initTable[string, string]()
    for line in body[cursor ..< headerEnd].split("\c\L"):
      let colon = line.find(':')
      if colon <= 0:
        raise profileError(400, "Malformed multipart header")
      let key = line[0 ..< colon].strip().toLowerAscii()
      if key in headers:
        raise profileError(400, "Duplicate multipart header")
      headers[key] = line[colon + 1 .. ^1].strip()

    if "content-disposition" notin headers:
      raise profileError(400, "Missing multipart content disposition")
    let params = dispositionParams(headers["content-disposition"])
    if "name" notin params or params["name"].len == 0:
      raise profileError(400, "Missing multipart field name")

    let dataStart = headerEnd + 4
    let nextBoundary = body.find("\c\L" & marker, dataStart)
    if nextBoundary < 0:
      raise profileError(400, "Multipart body is missing its closing boundary")

    result.add MultipartPart(
      name: params["name"],
      filename: if "filename" in params: some(params["filename"]) else: none(string),
      contentType: headers.getOrDefault("content-type").toLowerAscii(),
      data: body[dataStart ..< nextBoundary]
    )

    cursor = nextBoundary + 2 + marker.len
    if cursor + 2 <= body.len and body[cursor ..< cursor + 2] == "--":
      cursor += 2
      if cursor + 2 <= body.len and body[cursor ..< cursor + 2] == "\c\L":
        cursor += 2
      if cursor != body.len:
        raise profileError(400, "Unexpected data after multipart body")
      return
    if cursor + 2 > body.len or body[cursor ..< cursor + 2] != "\c\L":
      raise profileError(400, "Malformed multipart boundary")
    cursor += 2

  raise profileError(400, "Multipart body is missing its closing boundary")

proc imageSignatureMatches(contentType, data: string): bool =
  case contentType
  of "image/jpeg":
    data.len >= 3 and data[0].ord == 0xff and data[1].ord == 0xd8 and
      data[2].ord == 0xff
  of "image/png":
    data.len >= 8 and data[0].ord == 0x89 and data[1 .. 3] == "PNG" and
      data[4].ord == 0x0d and data[5].ord == 0x0a and
      data[6].ord == 0x1a and data[7].ord == 0x0a
  of "image/webp":
    data.len >= 12 and data[0 .. 3] == "RIFF" and data[8 .. 11] == "WEBP"
  else:
    false

proc parseImage(part: MultipartPart; fieldName: string): ProfileImage =
  if part.filename.isNone or part.filename.get.len == 0:
    raise profileError(400, fieldName & " must be a file")
  if part.contentType notin ["image/jpeg", "image/png", "image/webp"]:
    raise profileError(415, "Unsupported " & fieldName & " content type")
  if part.data.len == 0:
    raise profileError(400, fieldName & " cannot be empty")
  if part.data.len > maxImageBytes:
    raise profileError(413, fieldName & " exceeds the 5 MiB limit")
  if not imageSignatureMatches(part.contentType, part.data):
    raise profileError(415, fieldName & " content does not match its content type")
  ProfileImage(contentType: part.contentType, data: part.data)

proc parseProfileUpdateRequest*(contentType, body: string): ProfileUpdateRequest =
  if body.len > maxProfileRequestBytes:
    raise profileError(413, "Request exceeds the 12 MiB limit")

  let parts = parseMultipart(contentType, body)
  var seen = initHashSet[string]()
  for part in parts:
    if part.name in seen:
      raise profileError(400, "Duplicate multipart field: " & part.name)
    seen.incl part.name

    case part.name
    of "name", "bio", "website_url":
      if part.filename.isSome:
        raise profileError(400, part.name & " must be a text field")
      if part.contentType.len > 0 and not part.contentType.startsWith("text/plain"):
        raise profileError(415, "Unsupported content type for " & part.name)
      discard runeCount(part.data)
      case part.name
      of "name": result.name = some(part.data)
      of "bio": result.bio = some(part.data)
      else: result.websiteUrl = some(part.data)
    of "profile_image":
      result.profileImage = some(parseImage(part, part.name))
    of "banner_image":
      result.bannerImage = some(parseImage(part, part.name))
    else:
      raise profileError(400, "Unknown multipart field: " & part.name)

  if seen.len == 0:
    raise profileError(400, "At least one profile field is required")
  if result.name.isSome and (result.name.get.runeCount < 1 or result.name.get.runeCount > 50):
    raise profileError(400, "name must contain between 1 and 50 characters")
  if result.bio.isSome and result.bio.get.runeCount > 160:
    raise profileError(400, "bio cannot exceed 160 characters")
  if result.websiteUrl.isSome:
    let website = result.websiteUrl.get
    if website.runeCount > 100:
      raise profileError(400, "website_url cannot exceed 100 characters")
    if website.len > 0:
      let parsed = parseUri(website)
      if parsed.scheme.toLowerAscii() notin ["http", "https"] or parsed.hostname.len == 0:
        raise profileError(400, "website_url must be an absolute HTTP(S) URL")

proc updatedFieldNames*(request: ProfileUpdateRequest): seq[string] =
  if request.name.isSome: result.add "name"
  if request.bio.isSome: result.add "bio"
  if request.websiteUrl.isSome: result.add "website_url"
  if request.profileImage.isSome: result.add "profile_image"
  if request.bannerImage.isSome: result.add "banner_image"

proc mergedProfileParams*(current: ProfileSnapshot;
                          request: ProfileUpdateRequest): seq[(string, string)] =
  result = @[
    ("name", if request.name.isSome: request.name.get else: current.name),
    ("description", if request.bio.isSome: request.bio.get else: current.bio),
    ("url", if request.websiteUrl.isSome: request.websiteUrl.get else: current.websiteUrl),
    ("location", current.location)
  ]

proc responseMessage(body, fallback: string): string =
  try:
    let parsed = parseJson(body)
    if parsed{"errors"}.kind == JArray and parsed{"errors"}.len > 0:
      let message = parsed{"errors"}[0]{"message"}.getStr
      if message.len > 0:
        return message
    let message = parsed{"error"}.getStr(parsed{"message"}.getStr)
    if message.len > 0:
      return message
  except CatchableError:
    discard
  fallback

proc upstreamErrorPreview(body: string): string =
  if body.len == 0:
    return "<empty>"

  let previewLength = min(body.len, upstreamErrorPreviewBytes)
  result = body[0 ..< previewLength]
    .replace("\c", "\\r")
    .replace("\L", "\\n")
  if body.len > previewLength:
    result.add "... [truncated, " & $body.len & " bytes total]"

proc requireSuccess(response: UpstreamResponse; operation: string) =
  if response.status >= 200 and response.status < 300:
    return
  echo "[profile-update] upstream failure: operation=", operation,
    ", status=", response.status,
    ", content-type=", response.headers.getOrDefault("content-type"),
    ", body=", upstreamErrorPreview(response.body)
  let message = responseMessage(response.body, operation & " failed")
  if response.status in [400, 404, 409, 415, 422]:
    raise profileError(422, message)
  raise profileError(502, message)

proc getProfileUrl(username: string): Uri =
  parseUri("https://x.com/i/api") /
    "graphql/KybxDj9RrADIITXlGG8kpw/UserByScreenName" ? @[
      ("variables", $(%*{
        "screen_name": username,
        "withGrokTranslatedBio": true
      })),
      ("fieldToggles", """{"withPayments":false,"withAuxiliaryUserLabels":true}""")
    ]

proc accountSettingsUrl(): Uri =
  parseUri("https://api.x.com/1.1/account/settings.json") ? @[
    ("include_ext_sharing_audiospaces_listening_data_with_followers", "true"),
    ("include_mention_filter", "true"),
    ("include_nsfw_user_flag", "true"),
    ("include_nsfw_admin_flag", "true"),
    ("include_ranked_timeline", "true"),
    ("include_alt_text_compose", "true"),
    ("include_ext_dm_av_call_settings", "true"),
    ("ext", "ssoConnections"),
    ("include_country_code", "true"),
    ("include_ext_dm_nsfw_media_filter", "true")
  ]

proc parseAccountSettings*(body: string): AccountSettings =
  let parsed = parseJson(body)
  let screenName = parsed{"screen_name"}
  if screenName.kind != JString or screenName.getStr.len == 0 or
      screenName.getStr.len > 20 or
      not screenName.getStr.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_'}):
    raise profileError(502, "Account settings returned no valid screen name")
  result.screenName = screenName.getStr

proc getAccountSettings(session: Session): Future[AccountSettings] {.async.} =
  let response = await requestWithSession(
    session, accountSettingsUrl(), HttpGet, forceWebBearer=true,
    includeTid=true)
  requireSuccess(response, "Account settings")
  try:
    result = parseAccountSettings(response.body)
  except ProfileRequestError:
    raise
  except CatchableError:
    raise profileError(502, "Account settings returned invalid JSON")

proc profileResult(body: string; accountId: int64): JsonNode =
  let parsed = parseJson(body)
  result = parsed{"data", "user", "result"}
  if result.kind == JNull or result{"rest_id"}.getStr != $accountId:
    raise profileError(502, "Profile response returned no matching user")

proc resolvedProfileWebsite(user: JsonNode): string =
  resolveTwitterLinks(user{"website", "url"}.getStr,
    user{"profile_bio", "entities", "url"})

proc parseProfileSnapshot*(body: string; accountId: int64): ProfileSnapshot =
  let user = profileResult(body, accountId)
  let
    name = user{"core", "name"}
    bio = user{"profile_bio", "description"}
    location = user{"location", "location"}
    website = user{"website", "url"}
  if name.kind != JString or name.getStr.len == 0 or bio.kind != JString or
      location.kind != JString or website.kind != JString:
    raise profileError(502, "Profile snapshot is missing a profile field")

  result.name = name.getStr
  result.bio = bio.getStr
  result.location = location.getStr
  result.websiteUrl = resolvedProfileWebsite(user)

proc parseProfileUser*(body: string; accountId: int64): User =
  let user = profileResult(body, accountId)
  result = experimentalParser.parseGraphUser(body)
  result.userPic = user{"avatar", "image_url"}.getImageStr.replace("_normal", "")
  result.website = resolvedProfileWebsite(user)
  result.banner = user{"banner", "image_url"}.getImageStr
  if result.banner.len > 0:
    result.banner.add "/1500x500"
  result.following = user{"relationship_counts", "following"}.getInt
  result.followers = user{"relationship_counts", "followers"}.getInt
  result.tweets = user{"tweet_counts", "tweets"}.getInt
  result.media = user{"tweet_counts", "media_tweets"}.getInt
  result.likes = user{"action_counts", "favorites_count"}.getInt

proc fetchProfileBody(session: Session; screenName, operation: string): Future[string] {.async.} =
  let response = await requestWithSession(
    session, getProfileUrl(screenName), HttpGet)
  requireSuccess(response, operation)
  result = response.body

proc fetchCurrentProfile(session: Session; screenName: string;
                         accountId: int64): Future[ProfileSnapshot] {.async.} =
  let body = await fetchProfileBody(session, screenName, "Profile snapshot")
  try:
    result = parseProfileSnapshot(body, accountId)
  except ProfileRequestError:
    raise
  except CatchableError as error:
    echo "[profile-update] invalid profile snapshot: account_id=", accountId,
      ", error=", error.name, ", body=", upstreamErrorPreview(body)
    raise profileError(502, "Profile snapshot returned invalid JSON")

proc fetchResultProfile(session: Session; screenName: string;
                        accountId: int64): Future[User] {.async.} =
  let body = await fetchProfileBody(session, screenName, "Resulting profile")
  try:
    result = parseProfileUser(body, accountId)
  except ProfileRequestError:
    raise
  except CatchableError as error:
    echo "[profile-update] invalid resulting profile: account_id=", accountId,
      ", error=", error.name, ", body=", upstreamErrorPreview(body)
    raise profileError(502, "Resulting profile returned invalid JSON")
  if result.id != $accountId:
    raise profileError(502, "Resulting profile returned no matching user")

proc readAccountProfile*(accountId: int64): Future[ProfileReadResult] {.async.} =
  var session: Session
  try:
    try:
      session = await acquireAccountWriteSession(accountId)
    except KeyError:
      raise profileError(404, "Account not found")
    except ValueError:
      raise profileError(409, "Account is not a cookie session")

    let settings = await getAccountSettings(session)
    let body = await fetchProfileBody(session, settings.screenName, "Profile read")
    result.snapshot = parseProfileSnapshot(body, accountId)
    result.profile = parseProfileUser(body, accountId)
  except ProfileRequestError:
    raise
  except RateLimitError:
    raise profileError(429, "Account session is rate limited")
  except BadClientError as error:
    raise profileError(502, error.msg)
  except CatchableError:
    raise profileError(502, "Profile read returned invalid JSON")
  finally:
    releaseAccountWriteSession(session)

proc multipartUploadBody(data: string): tuple[contentType, body: string] =
  var boundary = "----Nitter"
  for value in urandom(16):
    boundary.add toHex(value, 2)
  while boundary in data:
    boundary.add('x')
  result.contentType = "multipart/form-data; boundary=" & boundary
  result.body = "--" & boundary & "\c\L" &
    "Content-Disposition: form-data; name=\"media\"; filename=\"upload\"\c\L" &
    "Content-Type: application/octet-stream\c\L\c\L" & data & "\c\L--" &
    boundary & "--\c\L"

proc uploadUrl(params: seq[(string, string)]): Uri =
  parseUri(uploadBase) ? params

proc parseMediaId(response: UpstreamResponse): string =
  requireSuccess(response, "Media upload initialization")
  try:
    let parsed = parseJson(response.body)
    result = parsed{"media_id_string"}.getStr
  except CatchableError:
    discard
  if result.len == 0:
    raise profileError(502, "Media upload returned no media ID")

proc waitForMedia(session: Session; mediaId: string;
                  initial: UpstreamResponse): Future[void] {.async.} =
  var response = initial
  for attempt in 0 ..< 30:
    requireSuccess(response, "Media processing")
    var parsed: JsonNode
    try:
      parsed = parseJson(response.body)
    except CatchableError:
      raise profileError(502, "Media processing returned invalid JSON")

    let info = parsed{"processing_info"}
    if info.kind == JNull:
      return
    case info{"state"}.getStr
    of "succeeded":
      return
    of "failed":
      raise profileError(422, info{"error", "message"}.getStr("Media processing failed"))
    of "pending", "in_progress":
      let delay = max(1, min(5, info{"check_after_secs"}.getInt(1)))
      await sleepAsync(delay * 1000)
      response = await requestWithSession(session, uploadUrl(@[
        ("command", "STATUS"), ("media_id", mediaId)
      ]), HttpGet, skipTid=true, forceWebBearer=true)
    else:
      raise profileError(502, "Media processing returned an unknown state")
  raise profileError(502, "Media processing timed out")

proc uploadImage(session: Session; image: ProfileImage;
                 mediaCategory = ""): Future[string] {.async.} =
  var initParams = @[
    ("command", "INIT"),
    ("total_bytes", $image.data.len),
    ("media_type", image.contentType)
  ]
  if mediaCategory.len > 0:
    initParams.add ("media_category", mediaCategory)

  let initResponse = await requestWithSession(
    session, uploadUrl(initParams), HttpPost, contentType="application/x-www-form-urlencoded",
    skipTid=true, forceWebBearer=true)
  result = parseMediaId(initResponse)

  var offset = 0
  var segment = 0
  while offset < image.data.len:
    let finish = min(image.data.len, offset + uploadChunkBytes)
    let multipart = multipartUploadBody(image.data[offset ..< finish])
    let appendResponse = await requestWithSession(session, uploadUrl(@[
      ("command", "APPEND"), ("media_id", result), ("segment_index", $segment)
    ]), HttpPost, multipart.body, multipart.contentType, skipTid=true,
      forceWebBearer=true)
    requireSuccess(appendResponse, "Media upload segment")
    offset = finish
    inc segment

  let finalizeResponse = await requestWithSession(session, uploadUrl(@[
    ("command", "FINALIZE"), ("media_id", result)
  ]), HttpPost, contentType="application/x-www-form-urlencoded", skipTid=true,
    forceWebBearer=true)
  await waitForMedia(session, result, finalizeResponse)

proc profileMutationUrl*(endpoint: string): Uri =
  parseUri("https://api.x.com/1.1") / endpoint

proc postForm(session: Session; endpoint: string;
              params: seq[(string, string)]): Future[void] {.async.} =
  let url = profileMutationUrl(endpoint)
  let response = await requestWithSession(
    session, url, HttpPost, encodeQuery(params),
    "application/x-www-form-urlencoded", forceWebBearer=true, includeTid=true)
  requireSuccess(response, "Profile update: " & endpoint)

proc updateAccountProfile*(accountId: int64;
                           request: ProfileUpdateRequest): Future[ProfileUpdateResult] {.async.} =
  var session: Session
  try:
    try:
      session = await acquireAccountWriteSession(accountId)
    except KeyError:
      raise profileError(404, "Account not found")
    except ValueError:
      raise profileError(409, "Account is not a cookie session")

    var current: ProfileSnapshot
    var screenName = ""
    let hasText = request.name.isSome or request.bio.isSome or request.websiteUrl.isSome
    if hasText:
      screenName = (await getAccountSettings(session)).screenName
      current = await fetchCurrentProfile(session, screenName, accountId)

    if request.profileImage.isSome:
      result.profileImageMediaId = await uploadImage(session, request.profileImage.get)
    if request.bannerImage.isSome:
      result.bannerImageMediaId = await uploadImage(
        session, request.bannerImage.get, "banner_image")

    if hasText:
      await postForm(
        session, "account/update_profile.json", mergedProfileParams(current, request))
    if request.profileImage.isSome:
      await postForm(session, "account/update_profile_image.json", @[
        ("media_id", result.profileImageMediaId)
      ])
    if request.bannerImage.isSome:
      await postForm(session, "account/update_profile_banner.json", @[
        ("media_id", result.bannerImageMediaId)
      ])

    if screenName.len == 0:
      screenName = (await getAccountSettings(session)).screenName
    result.profile = await fetchResultProfile(session, screenName, accountId)
    result.accountId = $accountId
    result.updatedFields = request.updatedFieldNames
  except ProfileRequestError:
    raise
  except RateLimitError:
    raise profileError(429, "Account session is rate limited")
  except BadClientError as e:
    raise profileError(502, e.msg)
  except CatchableError as e:
    raise profileError(502, e.msg)
  finally:
    releaseAccountWriteSession(session)
