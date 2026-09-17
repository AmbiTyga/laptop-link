"""Run with: python3 -m unittest discover -s Tests/Setup -v"""
import importlib.util
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

SPEC = importlib.util.spec_from_file_location('link_setup', Path(__file__).resolve().parents[2] / 'scripts/setup.py')
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def test_http_serves_only_key(self):
        key = bytes(range(32))
        server = setup.KeyHTTPServer(('127.0.0.1', 0), setup.key_handler(key))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            with urlopen(base + '/client.key') as response:
                self.assertEqual(response.read(), key)
                self.assertEqual(response.headers['Cache-Control'], 'no-store')
            for path in ['/', '/server.json', '/../client.key', '/%2e%2e/client.key', '/client.key?download=1']:
                with self.assertRaises(HTTPError) as error:
                    urlopen(base + path)
                self.assertEqual(error.exception.code, 404)
                error.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_five_ports_skip_occupied_and_stay_reserved(self):
        occupied = socket.socket()
        for candidate in range(8000, 9000):
            try:
                occupied.bind(('127.0.0.1', candidate))
                break
            except OSError:
                continue
        else:
            occupied.close()
            self.fail('No test port available')
        occupied.listen()
        servers = []
        try:
            servers = setup.reserve_ports('127.0.0.1', setup.key_handler(bytes(32)))
            self.assertEqual(len({server.server_port for server in servers}), 5)
            self.assertNotIn(occupied.getsockname()[1], [server.server_port for server in servers])
            for server in servers:
                with socket.socket() as other, self.assertRaises(OSError):
                    other.bind(('127.0.0.1', server.server_port))
        finally:
            occupied.close()
            for server in servers:
                server.server_close()

    def test_copy_is_private_and_removed_on_cancel(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy = root / '.key-share/client.key'
            def cancel(*args):
                self.assertEqual(copy.read_bytes(), bytes(range(32)))
                self.assertEqual(copy.stat().st_mode & 0o777, 0o600)
                raise KeyboardInterrupt
            with patch.object(setup, 'reserve_ports', side_effect=cancel), self.assertRaises(KeyboardInterrupt):
                setup.share_key(bytes(range(32)), '127.0.0.1', root)
            self.assertFalse(copy.exists())

    def test_existing_repository_copy_is_not_replaced_or_deleted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy = root / '.key-share/client.key'
            copy.parent.mkdir()
            copy.write_bytes(b'existing session')
            with self.assertRaises(ValueError):
                setup.share_key(bytes(32), '127.0.0.1', root)
            self.assertEqual(copy.read_bytes(), b'existing session')

    def test_reuses_private_configured_key_and_rejects_invalid_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = root / 'existing.key'
            key.write_bytes(bytes(range(32)))
            key.chmod(0o600)
            config = root / 'server.json'
            config.write_text(json.dumps({'keyFile': str(key)}))
            self.assertEqual(setup.read_key(config), key.read_bytes())
            key.chmod(0o644)
            with self.assertRaises(ValueError):
                setup.read_key(config)
            key.chmod(0o600)
            key.write_bytes(b'invalid')
            with self.assertRaises(ValueError):
                setup.read_key(config)


if __name__ == '__main__':
    unittest.main()
