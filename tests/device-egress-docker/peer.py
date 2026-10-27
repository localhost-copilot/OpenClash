#!/usr/bin/env python3
"""Isolated WAN services and real TCP/UDP client probes (no proxy environment)."""
import concurrent.futures
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "203.0.113.10"


def source(address):
    return str(ipaddress.ip_address(address).ipv4_mapped or address) if ":" in address else address


def probe(protocol, host=HOST, timeout=0.35):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    try:
        with socket.socket(family, socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.connect((host, 8080 if protocol == "tcp" else 9000))
            if protocol == "tcp":
                sock.sendall(b"GET / HTTP/1.0\r\nHost: harness\r\n\r\n")
                data = b""
                while chunk := sock.recv(4096):
                    data += chunk
                return data.split(b"\r\n\r\n", 1)[1].decode().strip()
            sock.send(b"source?")
            return sock.recv(4096).decode().strip()
    except (OSError, IndexError):
        return "BLOCKED"


def probes(host=HOST, timeout=0.35):
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        jobs = {p: pool.submit(probe, p, host, timeout) for p in ("tcp", "udp")}
        return {p: job.result() for p, job in jobs.items()}


def server():
    # IPv6 deliberately uses routing rather than NAT, so the unbound control
    # proves WAN reachability before we assert that the bound MAC is blocked.
    subprocess.run(["ip", "-6", "route", "replace", "fd42:231::/64", "via", "fd42:232::2"], check=True)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = (source(self.client_address[0]) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    class HTTP(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    def udp():
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
            sock.bind(("::", 9000))
            while True:
                _, addr = sock.recvfrom(4096)
                try:
                    sock.sendto(source(addr[0]).encode(), addr)
                except OSError:
                    # Docker briefly removes the return route while restarting
                    # the router. A failed reply must not kill the echo service.
                    continue

    # The proxy dials this container's HTTP/UDP sockets from .10, whereas direct
    # forwarded traffic is masqueraded by the router to .2.
    Path("/tmp/node.yaml").write_text(json.dumps({
        "listeners": [{"name": "node", "type": "shadowsocks", "listen": "0.0.0.0",
                       "port": 8388, "cipher": "aes-128-gcm", "password": "docker-only", "udp": True}],
        "rules": ["MATCH,DIRECT"], "log-level": "warning"}))
    subprocess.Popen(["clash", "-d", "/tmp", "-f", "/tmp/node.yaml"])
    threading.Thread(target=udp, daemon=True).start()
    HTTP(("::", 8080), Handler).serve_forever()


def client():
    subprocess.run(["ip", "route", "replace", "default", "via", "10.231.0.2"], check=True)
    subprocess.run(["ip", "-6", "route", "replace", "default", "via", "fd42:231::2", "metric", "1"], check=True)
    while True:
        time.sleep(3600)


def socks_probe(protocol):
    """Probe a shared ordinary group through the router's stock SOCKS inbound."""
    try:
        with socket.create_connection(("10.231.0.2", 7891), timeout=1) as control:
            control.settimeout(1)
            control.sendall(b"\x05\x01\x00")
            assert control.recv(2) == b"\x05\x00"
            command = 1 if protocol == "tcp" else 3
            destination = socket.inet_aton(HOST) if command == 1 else bytes(4)
            port = 8080 if command == 1 else 0
            control.sendall(bytes([5, command, 0, 1]) + destination + port.to_bytes(2, "big"))
            response = control.recv(10)
            assert len(response) >= 10 and response[1] == 0 and response[3] == 1, response
            if protocol == "tcp":
                control.sendall(b"GET / HTTP/1.0\r\nHost: harness\r\n\r\n")
                data = b""
                while chunk := control.recv(4096):
                    data += chunk
                return data.split(b"\r\n\r\n", 1)[1].decode().strip()
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.settimeout(1)
                endpoint = socket.inet_ntoa(response[4:8])
                if endpoint == "0.0.0.0":
                    endpoint = "10.231.0.2"
                udp.sendto(b"\x00\x00\x00\x01" + socket.inet_aton(HOST) + (9000).to_bytes(2, "big") + b"source?", (endpoint, int.from_bytes(response[8:10], "big")))
                return udp.recv(4096)[10:].decode().strip()
    except (OSError, AssertionError, IndexError):
        return "BLOCKED"


def poll(path, stop_path):
    # Both protocols are sampled independently throughout a lifecycle action.
    # Each request uses a fresh socket so established connections cannot hide leaks.
    counts = {p: {} for p in ("tcp", "udp")}
    def worker(protocol):
        with open(path + "." + protocol, "w", buffering=1) as stream:
            while not os.path.exists(stop_path):
                result = probe(protocol)
                counts[protocol][result] = counts[protocol].get(result, 0) + 1
                stream.write(json.dumps({"at": time.time(), "source": result}) + "\n")
                # Up to 200 fresh connections per second per protocol; avoid
                # turning a lifecycle test into a CPU saturation benchmark.
                time.sleep(0.005)
    threads = [threading.Thread(target=worker, args=(p,)) for p in counts]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    print(json.dumps(counts), flush=True)


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "wan":
        server()
    elif command == "client":
        client()
    elif command == "probe":
        print(json.dumps(probes(sys.argv[2] if len(sys.argv) > 2 else HOST)))
    elif command == "poll":
        poll(sys.argv[2], sys.argv[3])
    elif command == "socks-probe":
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            jobs = {p: pool.submit(socks_probe, p) for p in ("tcp", "udp")}
            print(json.dumps({p: job.result() for p, job in jobs.items()}))
