# SPDX-License-Identifier: AGPL-3.0-only
import std/[options, strutils, unittest]

import ".."/src/profile_update

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

  test "snapshot merging preserves raw bio text instead of rendered HTML":
    let snapshot = parseProfileSnapshot("""{
      "data": {"user_result": {"result": {
        "rest_id": "123",
        "legacy": {
          "name": "Old Name",
          "description": "Visit https://example.com",
          "location": "Los Angeles",
          "url": "https://t.co/example",
          "entities": {"url": {"urls": [{
            "expanded_url": "https://example.com"
          }]}}
        }
      }}}
    }""", 123)
    check snapshot.bio == "Visit https://example.com"
    check snapshot.websiteUrl == "https://example.com"

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
