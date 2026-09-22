# SPDX-License-Identifier: AGPL-3.0-only
"""Integration test for the retained Twitter Space stream proxy."""

import requests


SPACE_ID = "1mxPaaRAwYjKN"
SPACE_URL = f"http://localhost:8080/i/spaces/{SPACE_ID}"


def test_space_stream_endpoint():
    """The stream endpoint returns an HLS manifest without an HTML page."""
    response = requests.get(f"{SPACE_URL}/stream", timeout=30)
    assert response.status_code == 200
    assert response.headers["content-type"].startswith(
        "application/vnd.apple.mpegurl"
    )
    assert "#EXTM3U" in response.text
    assert "#EXT-X-TARGETDURATION" in response.text
