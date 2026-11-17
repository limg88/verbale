#!/usr/bin/env python3
"""Run the Swift report checks through llm-gateway with synthetic upstreams."""
import argparse
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--project", type=Path, default=ROOT.parent / "llm-gateway")
args = parser.parse_args()
token = "integration-test-token-no-secrets"
budgets = []
leaks = []
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/leak")
            self.end_headers()
            if self.path == "/leak":
                leaks.append(True)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert isinstance(body.get("max_tokens"), int), body
        model = body["model"]
        if model == "quota":
            self.send_response(429)
            self.end_headers()
            self.wfile.write(b'{"error":{"code":"insufficient_quota","message":"synthetic quota"}}')
            return
        if model == "slow":
            time.sleep(2)
        if model == "grow":
            budgets.append(body["max_tokens"])
        content = "Decisione [[S1]]. Nota personale [[N]]."
        if model == "operational":
            content = json.dumps({"facts":[{"kind":"action","text":"Verificare il capitolato","refs":["S1"],"owner":"Marco","commitment":"agreed"}],"overview":[{"kind":"summary","text":"Verifica pianificata","refs":["S1"]}]})
        finish = "length" if model == "length" or model == "grow" and body["max_tokens"] < 8000 else "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        events = [{"choices":[{"delta":{"content":content}}]}, {"choices":[{"delta":{},"finish_reason":finish}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}]
        try:
            for event in events:
                self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

with tempfile.TemporaryDirectory(prefix="verbale-go-") as directory:
    work = Path(directory)
    environment = dict(os.environ, GOCACHE=str(work / "cache"), GOMODCACHE=str(work / "modules"))
    subprocess.run(["go", "build", "-o", str(work / "gateway"), "."], cwd=args.project, env=environment, check=True)
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{upstream.server_port}/v1"
    config = {"listen_addr":f"127.0.0.1:{port}","api_key":token,"backends":[],"upstreams":[{"name":"local","base_url":base,"models":["test","grow","operational","quota","length","slow"]},{"name":"groq","base_url":base,"models":["test"]}]}
    (work / "config.json").write_text(json.dumps(config))
    with (work / "gateway.log").open("w") as log:
        process = subprocess.Popen([str(work / "gateway"), "-config", str(work / "config.json")], stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1).close()
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError("Gateway startup failed")
                    time.sleep(.05)
            else:
                raise RuntimeError("Gateway startup timed out")
            metadata = work / "metadata.json"
            metadata.write_text(json.dumps({"endpoint":f"http://127.0.0.1:{port}/v1","redirect":base}))
            subprocess.run(["sh","scripts/test.sh","--gateway-metadata",str(metadata)], cwd=ROOT, check=True)
            assert budgets == [6000, 16000], budgets
            assert not leaks, "Redirect was followed"
            print("PASS Go gateway: Swift report integration and output budget recovery")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            upstream.shutdown()
