#!/usr/bin/env python3
"""Initialize Laptop Link and temporarily share its enrollment key over HTTP."""
import argparse
import errno
import ipaddress
import json
import os
import re
import stat
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Expected a directory owned by you: {path}")
    path.chmod(0o700)


def read_key(config_path):
    config = json.loads(config_path.read_text())
    path = Path(config['keyFile'])
    if not path.is_absolute():
        raise ValueError('Configured keyFile must be absolute')
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Enrollment key must be a regular file owned by you, with mode 600')
    key = path.read_bytes()
    if len(key) != 32:
        raise ValueError('Enrollment key must contain exactly 32 bytes')
    return key


def local_addresses():
    output = subprocess.check_output(['/sbin/ifconfig'], text=True)
    addresses = []
    for candidate in re.findall(r'\binet (\d+\.\d+\.\d+\.\d+)', output):
        address = ipaddress.IPv4Address(candidate)
        if not address.is_loopback and not address.is_unspecified and candidate not in addresses:
            addresses.append(candidate)
    return addresses


def choose_address(explicit=None):
    if explicit:
        address = ipaddress.IPv4Address(explicit)
        if address.is_unspecified or address.is_multicast:
            raise ValueError('Choose a specific local IPv4 address')
        return str(address)
    addresses = local_addresses()
    if not addresses:
        raise ValueError('No local IPv4 address found. Connect to a LAN and retry.')
    print('Local IP addresses: ' + ', '.join(addresses))
    while True:
        selected = input(f'IP to share on [{addresses[0]}]: ').strip() or addresses[0]
        if selected in addresses:
            return selected
        print('Choose one of the listed local IP addresses.')


def key_handler(key):
    class KeyHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_key(False)

        def do_HEAD(self):
            self.send_key(True)

        def send_key(self, head_only):
            if self.path != '/client.key':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(key)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            if not head_only:
                self.wfile.write(key)

        def log_message(self, format, *args):
            # Never log key bytes or arbitrary request paths.
            print(f'HTTP request from {self.client_address[0]}', flush=True)
    return KeyHandler


class KeyHTTPServer(HTTPServer):
    allow_reuse_address = False

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address


def reserve_ports(address, handler):
    """Hold five bindable ports so they cannot be taken during the prompt."""
    servers = []
    try:
        for port in range(8000, 9000):
            try:
                servers.append(KeyHTTPServer((address, port), handler))
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    raise
                continue
            if len(servers) == 5:
                return servers
        raise ValueError('Could not find five available ports between 8000 and 8999')
    except BaseException:
        for server in servers:
            server.server_close()
        raise


def share_key(key, address, repo=REPO):
    directory = repo / '.key-share'
    private_directory(directory)
    copy = directory / 'client.key'
    descriptor, staging = tempfile.mkstemp(dir=directory, prefix='.client-')
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(key)
        try:
            os.link(staging, copy)
        except FileExistsError as error:
            raise ValueError(f'Key copy already exists: {copy}. Stop the previous sharing session or remove its stale copy.') from error
    finally:
        Path(staging).unlink(missing_ok=True)
    servers = []
    try:
        servers = reserve_ports(address, key_handler(key))
        ports = [server.server_port for server in servers]
        print('Available HTTP ports: ' + ', '.join(map(str, ports)), flush=True)
        while True:
            choice = input(f'Port to use [{ports[0]}]: ').strip() or str(ports[0])
            if choice.isascii() and choice.isdecimal() and int(choice) in ports:
                selected = next(server for server in servers if server.server_port == int(choice))
                break
            print('Enter one of the five listed port numbers.')
        for server in servers:
            if server is not selected:
                server.server_close()
        print(f'Repository key copy: {copy}')
        print(f'Download URL: http://{address}:{selected.server_port}/client.key', flush=True)
        print('HTTP shares this key without encryption. Use a trusted LAN; press Ctrl+C after downloading.')
        print('Only /client.key is served. Stopping removes the repository copy; the original key stays in place.', flush=True)
        selected.serve_forever(poll_interval=0.25)
    finally:
        for server in servers:
            server.server_close()
        copy.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path,
                        default=Path.home() / 'Library/Application Support/LaptopLink/server.json')
    parser.add_argument('--root', type=Path, help='Workspace for a new configuration')
    parser.add_argument('--bind', help='Local IPv4 address (otherwise prompted)')
    parser.add_argument('--no-launch', action='store_true', help='Share the key without launching the app')
    args = parser.parse_args()
    config = args.config.expanduser().absolute()
    app = REPO / 'dist/LaptopLinkServer.app'
    binary = app / 'Contents/MacOS/link-server'
    if not binary.is_file():
        subprocess.run([str(REPO / 'scripts/package-apps.sh')], cwd=REPO, check=True)
    if not config.exists():
        root = args.root or Path(input(f'Workspace folder [{Path.cwd()}]: ').strip() or str(Path.cwd()))
        root = root.expanduser().resolve()
        if not root.is_dir():
            raise ValueError('Workspace must be an existing directory')
        subprocess.run([str(binary), '--init', '--root', str(root), '--config', str(config)], check=True)
    elif args.root:
        raise ValueError('--root only applies to a new configuration; existing configuration was preserved')
    key = read_key(config)
    if not args.no_launch:
        subprocess.run(['/usr/bin/open', str(app), '--args', '--config', str(config)], check=True)
    share_key(key, choose_address(args.bind))


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nHTTP sharing stopped; repository key copy removed.')
    except (OSError, ValueError, KeyError, EOFError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Setup failed: {error}')
