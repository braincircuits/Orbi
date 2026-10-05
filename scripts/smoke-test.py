#!/usr/bin/env python3
"""Run the packaged client/server against a local HTTP origin; no internet access."""
import http.client
import http.server
import pathlib
import queue
import re
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = b"packaged-http3-ok"


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_):
        pass


def launch(jar, config, marker, processes):
    process = subprocess.Popen(
        ["java", "--enable-native-access=ALL-UNNAMED", "-jar", str(jar), str(config)],
        cwd=config.parent, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    processes.append(process)
    lines = queue.Queue()

    def collect():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=collect, daemon=True).start()
    output = []
    while True:
        line = lines.get(timeout=15)
        if line is None:
            raise RuntimeError("JAR exited before startup:\n" + "".join(output))
        output.append(line)
        if marker in line:
            return int(re.search(r":(\d+)\s*$", line).group(1))


def main():
    origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    processes = []
    try:
        with tempfile.TemporaryDirectory(prefix="http3-packaged-smoke-") as temp:
            base = pathlib.Path(temp)
            cert = ROOT / "ClientG/src/test/resources/tls/localhost.crt"
            key = ROOT / "ClientG/src/test/resources/tls/localhost.key"
            server_config = base / "server.properties"
            server_config.write_text(
                f"bind=127.0.0.1\nport=0\npassword=smoke-only\ntls.cert={cert}\ntls.key={key}\n"
            )
            udp_port = launch(ROOT / "Server/target/Server-1.0-SNAPSHOT.jar", server_config,
                              "HTTP/3 proxy listening", processes)
            client_config = base / "client.properties"
            client_config.write_text(
                f"port=0\npassword=smoke-only\nserver.host=127.0.0.1\nserver.port={udp_port}\n"
                f"tls.ca={cert}\ntls.serverName=localhost\n"
            )
            proxy_port = launch(ROOT / "ClientG/target/clientG-1.0-SNAPSHOT.jar", client_config,
                                "Local HTTP proxy listening", processes)
            origin_port = origin.server_port
            for tunnel in (False, True):
                connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=10)
                try:
                    if tunnel:
                        connection.set_tunnel("127.0.0.1", origin_port)
                    connection.request("GET", "/" if tunnel else f"http://127.0.0.1:{origin_port}/")
                    response = connection.getresponse()
                    assert response.status == 200, response.status
                    assert response.read() == PAYLOAD
                finally:
                    connection.close()
            print("Packaged JAR smoke test passed: HTTP forwarding and CONNECT over HTTP/3.")
    finally:
        for process in reversed(processes):
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        origin.shutdown()
        origin.server_close()


if __name__ == "__main__":
    main()
