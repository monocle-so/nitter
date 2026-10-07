# SPDX-License-Identifier: AGPL-3.0-only
import std/[options, strutils, unittest, uri]
import packedjson

import ".."/src/parserutils
import ".."/src/profile_update
import ".."/src/tid

const boundary = "nitter-profile-test-boundary"

proc textPart(name, value: string): string =
  "--" & boundary & "\c\L" &
    "Content-Disposition: form-data; name=\"" & name & "\"\c\L\c\L" &
    value & "\c\L"

proc filePart(name, contentType, value: string): string =
  "--" & boundary & "\c\L" &
    "Content-Disposition: form-data; name=\"" & name &
    "\"; filename=\"upload\"\c\L" &
    "Content-Type: " & contentType & "\c\L\c\L" & value & "\c\L"

proc multipart(parts: varargs[string]): tuple[contentType, body: string] =
  result.contentType = "multipart/form-data; boundary=" & boundary
  result.body = parts.join("") & "--" & boundary & "--\c\L"

suite "profile update request parsing":
  test "profile mutations use the X API host":
    check $profileMutationUrl("account/update_profile.json") ==
      "https://api.x.com/1.1/account/update_profile.json"

  test "profile POST transaction IDs hash the POST method":
    check transactionIdHashInput("POST", "/1.1/account/update_profile.json",
      42, "key") ==
      "POST!/1.1/account/update_profile.json!42obfiowerehiringkey"

  test "account settings supplies the screen name for a selected session":
    let settings = parseAccountSettings("""{
      "screen_name": "david_simi3",
      "protected": false,
      "ext": {"ssoConnections": {"r": {"ok": []}}}
    }""")
    check settings.screenName == "david_simi3"

  test "account settings rejects a missing screen name":
    expect ProfileRequestError:
      discard parseAccountSettings("""{"protected": false}""")

  test "parses text and binary fields without base64 encoding":
    let input = multipart(
      textPart("name", "Sammy Jones"),
      textPart("bio", "Building things."),
      filePart("profile_image", "image/png", "\x89PNG\x0d\x0a\x1a\x0a"))
    let request = parseProfileUpdateRequest(input.contentType, input.body)
    check request.name == some("Sammy Jones")
    check request.bio == some("Building things.")
    check request.websiteUrl.isNone
    check request.profileImage.get.data == "\x89PNG\x0d\x0a\x1a\x0a"
    check request.updatedFieldNames == @["name", "bio", "profile_image"]

  test "empty bio and website values are explicit clears":
    let input = multipart(textPart("bio", ""), textPart("website_url", ""))
    let request = parseProfileUpdateRequest(input.contentType, input.body)
    check request.bio == some("")
    check request.websiteUrl == some("")

  test "a one-field update preserves the full current profile":
    let
      input = multipart(textPart("name", "Sammy Jones"))
      request = parseProfileUpdateRequest(input.contentType, input.body)
      current = ProfileSnapshot(
        name: "Old Name",
        bio: "Existing bio",
        websiteUrl: "https://old.example",
        location: "Los Angeles")
      params = mergedProfileParams(current, request)
    check params == @[
      ("name", "Sammy Jones"),
      ("description", "Existing bio"),
      ("url", "https://old.example"),
      ("location", "Los Angeles")
    ]

  test "resolves Twitter URL entities in plain text":
    let entities = parseJson("""{"urls": [
      {"url": "https://t.co/first", "expanded_url": "https://first.example"},
      {"url": "https://t.co/second", "expanded_url": "https://second.example"},
      {"url": "https://t.co/unknown", "expanded_url": ""}
    ]}""")
    check resolveTwitterLinks("See https://t.co/first and https://t.co/second", entities) ==
      "See https://first.example and https://second.example"
    check resolveTwitterLinks("https://t.co/other", entities) == "https://t.co/other"
    check resolveTwitterLinks("https://t.co/unknown", entities) == "https://t.co/unknown"
    check resolveTwitterLinks("https://t.co/first", parseJson("{}")) ==
      "https://t.co/first"

  test "new profile response preserves text and normalizes images":
    let body = """{
      "data": {"user": {"result": {
        "__typename": "User",
        "rest_id": "123",
        "core": {"name": "Old Name", "screen_name": "sample", "created_at": "Sun May 11 15:24:21 +0000 2025"},
        "profile_bio": {
          "description": "Visit https://example.com",
          "entities": {"url": {"urls": [{
            "display_url": "example.com",
            "expanded_url": "https://example.com",
            "url": "https://t.co/website"
          }]}}
        },
        "location": {"location": "Los Angeles"},
        "website": {"url": "https://t.co/website"},
        "avatar": {"image_url": "https://pbs.twimg.com/profile_images/123/avatar_normal.jpg"},
        "banner": {"image_url": "https://pbs.twimg.com/profile_banners/123/456"},
        "action_counts": {"favorites_count": 12},
        "relationship_counts": {"following": 4, "followers": 5},
        "tweet_counts": {"tweets": 6, "media_tweets": 7},
        "is_blue_verified": true
      }}}
    }"""
    let snapshot = parseProfileSnapshot(body, 123)
    check snapshot.name == "Old Name"
    check snapshot.bio == "Visit https://example.com"
    check snapshot.location == "Los Angeles"
    check snapshot.websiteUrl == "https://example.com"
    let nameOnly = ProfileUpdateRequest(name: some("New Name"))
    check ("url", "https://example.com") in mergedProfileParams(snapshot, nameOnly)

    let user = parseProfileUser(body, 123)
    check user.id == "123"
    check user.username == "sample"
    check user.fullname == "Old Name"
    check user.website == "https://example.com"
    check user.userPic == "profile_images/123/avatar.jpg"
    check user.banner == "profile_banners/123/456/1500x500"
    check user.likes == 12
    check user.following == 4
    check user.followers == 5
    check user.tweets == 6
    check user.media == 7

  test "snapshot rejects a different account before mutation":
    expect ProfileRequestError:
      discard parseProfileSnapshot("""{
        "data": {"user": {"result": {
          "rest_id": "999",
          "core": {"name": "Someone else"},
          "profile_bio": {"description": ""},
          "location": {"location": ""},
          "website": {"url": ""}
        }}}
      }""", 123)

  test "snapshot rejects missing preserved fields":
    expect ProfileRequestError:
      discard parseProfileSnapshot("""{
        "data": {"user": {"result": {
          "rest_id": "123",
          "core": {"name": "Old Name"},
          "profile_bio": {"description": ""},
          "location": {"location": ""}
        }}}
      }""", 123)

  test "rejects duplicate fields":
    let input = multipart(textPart("bio", "first"), textPart("bio", "second"))
    expect ProfileRequestError:
      discard parseProfileUpdateRequest(input.contentType, input.body)

  test "rejects unknown fields":
    let input = multipart(textPart("location", "Somewhere"))
    expect ProfileRequestError:
      discard parseProfileUpdateRequest(input.contentType, input.body)

  test "rejects a MIME type that does not match the image signature":
    let input = multipart(filePart("banner_image", "image/png", "not a png"))
    try:
      discard parseProfileUpdateRequest(input.contentType, input.body)
      check false
    except ProfileRequestError as error:
      check error.status == 415

  test "rejects invalid websites":
    let input = multipart(textPart("website_url", "example.com"))
    try:
      discard parseProfileUpdateRequest(input.contentType, input.body)
      check false
    except ProfileRequestError as error:
      check error.status == 400

  test "rejects an empty request":
    let input = multipart()
    expect ProfileRequestError:
      discard parseProfileUpdateRequest(input.contentType, input.body)

  test "rejects bodies over the request limit before parsing":
    expect ProfileRequestError:
      discard parseProfileUpdateRequest(
        "multipart/form-data; boundary=x", repeat("x", maxProfileRequestBytes + 1))
