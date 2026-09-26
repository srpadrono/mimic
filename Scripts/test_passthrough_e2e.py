#!/usr/bin/env python3
"""Exercise a built Mimic app and CLI against synthetic local HTTP backends.

Usage: python3 Scripts/test_passthrough_e2e.py --app /path/Mimic.app --cli /path/mimic
Owns only its child process, temporary database/defaults, and loopback sockets.
"""
import argparse
from contextlib import ExitStack
import gzip
import http.client
import http.server
import json
import os
from pathlib import Path
import plistlib
import socket
import shutil
import subprocess
import tempfile
import threading
import time


def free_ports(count):
    with ExitStack() as stack:
        sockets = [stack.enter_context(socket.socket()) for _ in range(count)]
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        return [sock.getsockname()[1] for sock in sockets]


class Backend(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", "12")
            self.end_headers()
            self.wfile.write(b"first\n")
            self.wfile.flush()
            # The client releases the second chunk only after receiving the first. A buffering
            # proxy therefore times out instead of passing a machine-speed-dependent deadline.
            self.server.release_stream.wait(5)
            self.wfile.write(b"last!\n")
            return
        body = b'{"ok":true}'
        media = "application/json"
        if self.path == "/binary":
            body, media = b"\x89PNG\r\n\x1a\n\xff\x00", "image/png"
        elif self.path == "/large":
            body, media = b"a" * 100_000, "text/plain"
        elif self.path == "/oversized":
            body, media = b"a" * 5_242_881, "text/plain"
        elif self.path == "/gzip":
            body = gzip.compress(body, mtime=0)
        self.send_response(200)
        self.send_header("Content-Type", media)
        if self.path == "/gzip":
            self.send_header("Content-Encoding", "gzip")
        if self.path == "/cookies":
            self.send_header("Set-Cookie", "a=one; Path=/; HttpOnly")
            self.send_header("Set-Cookie", "b=two; Path=/; HttpOnly")
            self.send_header("Connection", "X-Hop")
            self.send_header("X-Hop", "must-not-forward")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        body = json.dumps({"operation": request["operationName"]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(app, cli):
    with tempfile.TemporaryDirectory(prefix="mimic-passthrough-") as folder:
        work = Path(folder)
        # Test-only copy: normal app signing confines file access to its container, whereas this
        # headless harness deliberately shares a temporary store/discovery file with a CLI process.
        # Leave the supplied app untouched; UI tests exercise the normally sandboxed build.
        test_app = work / "Mimic.app"
        shutil.copytree(app, test_app, symlinks=True)
        # Framework window preferences use the bundle's standard domain, even when app-owned
        # preferences use MIMIC_DEFAULTS_SUITE. Keep both identities disposable.
        bundle_id = "devxa.Mimic.Passthrough." + work.name.replace("_", "-") + ".App"
        info_path = test_app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = bundle_id
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(test_app)],
                       check=True, capture_output=True)
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        upstream.release_stream = threading.Event()
        control, primary, secondary = free_ports(3)
        env = {**os.environ, "MIMIC_HEADLESS": "1", "MIMIC_DATABASE_PATH": str(work / "mimic.sqlite"),
               "MIMIC_CONTROL_FILE": str(work / "control.json"), "MIMIC_CONTROL_PORT": str(control),
               "MIMIC_DEFAULTS_SUITE": "devxa.Mimic.Passthrough." + work.name}
        for key in ("MIMIC_CONTROL_URL", "MIMIC_CONTROL_TOKEN"):
            env.pop(key, None)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        app_log = open(work / "app.log", "w")
        child = subprocess.Popen([str(test_app / "Contents/MacOS/Mimic")], env=env,
                                 stdout=app_log, stderr=app_log)
        def command(*args, fail=False):
            result = subprocess.run([cli, *args], env=env, capture_output=True, text=True, timeout=15)
            if fail:
                assert result.returncode == 4 and result.stderr.startswith("request.invalid:"), (
                    "Expected the app's capture refusal, not a launch/transport error", result.returncode, result.stderr)
                return
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        def request(port, path, body=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            connection.request("POST" if body else "GET", path, body=body,
                               headers={"Content-Type": "application/json"} if body else {})
            response = connection.getresponse()
            data = response.read()
            result = response.status, response.headers, data
            connection.close()
            return result
        def logged(path, excluding=()):
            for _ in range(100):
                matches = [x for x in command("log", "list")["logs"]
                           if x["path"] == path and x["id"] not in excluding]
                if matches:
                    return matches[-1]
                time.sleep(.02)
            raise AssertionError("Missing request log: " + path)
        try:
            for _ in range(200):
                if (work / "control.json").exists():
                    break
                assert child.poll() is None, "App exited before discovery"
                time.sleep(.05)
            else:
                raise AssertionError("App did not publish its discovery file")
            discovery = json.loads((work / "control.json").read_text())
            assert discovery["pid"] == child.pid and discovery["port"] == control, "Not this test's app"
            assert (work / "control.json").stat().st_mode & 0o777 == 0o600
            initial = command("state")["state"]
            assert initial["pid"] == child.pid and not initial.get("storeFailure"), "Fixture is not isolated on disk"
            with (work / "mimic.sqlite").open("rb") as database:
                assert database.read(16) == b"SQLite format 3\0", "Requested temporary database was not created"
            command("project", "create", "Passthrough evidence", "--port", str(primary))
            for _ in range(100):
                if (command("state")["state"].get("project") or {}).get("name") == "Passthrough evidence":
                    break
                time.sleep(.05)
            else:
                raise AssertionError("Created project did not become active")
            url = f"http://127.0.0.1:{upstream.server_port}"
            command("server", "configure", "--name", "Catalog", "--upstream", url)
            command("server", "backend", "add", "--name", "Accounts", "--port", str(secondary), "--upstream", url)
            command("server", "start")
            for _ in range(100):
                status = command("server", "status")["server"]
                if status["state"] == "running":
                    break
                assert status["state"] != "error", status
                time.sleep(.05)
            else:
                raise AssertionError("Listeners did not start")
            assert request(primary, "/binary")[2] == b"\x89PNG\r\n\x1a\n\xff\x00"
            command("log", "save-as-mock", logged("/binary")["id"], fail=True)
            print("PASS binary bytes preserved; unsafe capture refused")
            _, headers, _ = request(secondary, "/cookies")
            assert headers.get_all("Set-Cookie") == ["a=one; Path=/; HttpOnly", "b=two; Path=/; HttpOnly"]
            assert headers.get("X-Hop") is None
            entry = logged("/cookies")
            assert entry["listenerPort"] == secondary and entry["backendName"] == "Accounts"
            print("PASS repeated cookies, hop headers, secondary listener metadata")
            compressed = request(primary, "/gzip")[2]
            assert compressed == gzip.compress(b'{"ok":true}', mtime=0)
            command("log", "save-as-mock", logged("/gzip")["id"], fail=True)
            assert len(request(primary, "/large")[2]) == 100_000
            large_log = logged("/large")
            assert len(large_log["responseBody"].encode()) == 65_536
            assert large_log["responseBodyTruncated"]
            command("log", "save-as-mock", large_log["id"])
            command("state")
            assert request(primary, "/large")[2] == b"a" * 100_000
            assert logged("/large", excluding={large_log["id"]})["outcome"] == "endpoint", "Replay still used the upstream"
            assert len(request(primary, "/oversized")[2]) == 5_242_881
            command("log", "save-as-mock", logged("/oversized")["id"], fail=True)
            print("PASS large replies capture completely with bounded previews; compressed and over-5MiB capture refused")
            connection = http.client.HTTPConnection("127.0.0.1", primary, timeout=3)
            start = time.monotonic()
            connection.request("GET", "/stream")
            response = connection.getresponse()
            assert response.read(6) == b"first\n"
            first = time.monotonic() - start
            upstream.release_stream.set()
            assert response.read() == b"last!\n"
            connection.close()
            print(f"PASS streaming first bytes in {first:.3f}s before the delayed second chunk")
            def graphql(name):
                body = json.dumps({"query": f"query {name} {{ value }}", "operationName": name})
                return json.loads(request(primary, "/graphql", body)[2])
            assert graphql("Account")["operation"] == "Account"
            command("log", "save-as-mock", logged("/graphql")["id"])
            assert graphql("Orders")["operation"] == "Orders"
            print("PASS captured GraphQL operation does not intercept other operations")
            command("server", "configure", "--pass-through", "false")
            assert request(primary, "/disabled")[0] == 404
            assert command("project", "export")["serverConfiguration"]["upstreamURL"] == url
            command("server", "configure", "--pass-through", "true", "--capture-responses", "true")
            request(primary, "/automatic")
            for _ in range(100):
                if any(x["path"] == "/automatic" for x in command("endpoint", "list")["endpoints"]):
                    break
                time.sleep(.02)
            else:
                raise AssertionError("Automatic capture did not create a mock")
            command("server", "configure", "--pass-through", "false")
            assert request(primary, "/automatic")[0] == 200
            print("PASS live pause/resume retains URL; automatic mock works with forwarding off")
            backend = command("project", "export")["serverConfiguration"]["backends"][0]["id"]
            command("journey", "create", "Mixed")
            command("journey", "step", "add", "Mixed", "GET", "/primary")
            command("journey", "step", "add", "Mixed", "GET", "/secondary", "--backend", backend)
            journey = command("journey", "export", "Mixed")
            assert [step["backend"] for step in journey["steps"]] == ["primary", backend]
            print("PASS mixed-backend journey export preserves routing")
            # Bound but not listening: another process cannot steal the deliberately offline port.
            with socket.socket() as offline:
                offline.bind(("127.0.0.1", 0))
                command("server", "configure", "--upstream", f"http://127.0.0.1:{offline.getsockname()[1]}")
                assert request(primary, "/offline")[0] == 502
            assert logged("/offline")["outcome"] == "proxyFailure"
            command("log", "save-as-mock", logged("/offline")["id"], fail=True)
            assert not any(x["path"] == "/offline" for x in command("endpoint", "list")["endpoints"])
            print("PASS connection failure is distinct and is never captured")
            command("server", "stop")
            app_log.flush()
            assert "is implemented in both" not in (work / "app.log").read_text(), "Duplicate runtime classes in app packaging"
            print("PASS shared HTTP client packaging has no duplicate runtime classes")
        finally:
            upstream.release_stream.set()
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            upstream.shutdown()
            upstream.server_close()
            app_log.close()
            subprocess.run(["defaults", "delete", env["MIMIC_DEFAULTS_SUITE"]], capture_output=True)
            subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--cli", required=True)
    args = parser.parse_args()
    run(args.app, args.cli)
