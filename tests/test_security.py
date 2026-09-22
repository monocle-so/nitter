import subprocess
from parameterized import parameterized

BASE_URL = 'http://localhost:8080'


def curl_status(url):
    """Get HTTP status code using curl to avoid URL normalization by Python libs."""
    result = subprocess.run(
        ['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', url],
        capture_output=True, text=True, timeout=10
    )
    return int(result.stdout)


class TestMalformedPaths:
    """Test that malformed paths don't crash the server.

    URLs like //foo are parsed as having 'foo' as the authority (host),
    resulting in an empty path. Empty paths previously crashed jester's
    static file handler. Now they return 400.

    URLs like //foo/bar are parsed as authority='foo', path='/bar',
    so they route normally (not empty path).
    """

    @parameterized.expand([
        # These parse to empty paths -> 400
        ('//lefty_rae', 400),
        ('//test', 400),
        ('//anyuser', 400),
    ])
    def test_empty_path_returns_400(self, path, expected_status):
        """URLs that parse to empty paths should return 400, not crash."""
        status = curl_status(f'{BASE_URL}{path}')
        assert status == expected_status, \
            f'Expected {expected_status} for {path}, got {status}'

    @parameterized.expand([
        ('/api/v1/', 200),
        ('/api/v1/health', 200),
        ('/.health', 200),
    ])
    def test_normal_paths_work(self, path, expected_status):
        """Normal paths should still work."""
        status = curl_status(f'{BASE_URL}{path}')
        assert status == expected_status, \
            f'Expected {expected_status} for {path}, got {status}'

    def test_server_survives_malformed_requests(self):
        """Server should handle malformed requests without crashing."""
        # These all parse to empty paths
        malformed_paths = ['//a', '//b', '//c', '//user', '//test']
        for path in malformed_paths:
            status = curl_status(f'{BASE_URL}{path}')
            assert status == 400, f'Expected 400 for {path}, got {status}'

        # Verify server is still responding after malformed requests
        status = curl_status(f'{BASE_URL}/api/v1/health')
        assert status == 200, 'Server should still be alive'


class TestRemovedDocumentRoutes:
    """HTML, redirect-to-HTML, preference, and RSS routes stay unavailable."""

    @parameterized.expand([
        ('/',),
        ('/about',),
        ('/explore',),
        ('/help',),
        ('/i/redirect?url=https%3A%2F%2Fx.com',),
        ('/jack',),
        ('/jack/about',),
        ('/jack/followers',),
        ('/jack/following',),
        ('/jack/status/20',),
        ('/jack/rss',),
        ('/search?q=nitter',),
        ('/search/rss?q=nitter',),
        ('/settings',),
        ('/i/article/20',),
        ('/i/communities/20',),
        ('/i/lists/20',),
        ('/i/spaces/20',),
        ('/i/broadcasts/20',),
    ])
    def test_document_route_returns_404(self, path):
        assert curl_status(f'{BASE_URL}{path}') == 404
