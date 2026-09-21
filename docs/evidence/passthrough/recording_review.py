#!/usr/bin/env python3
"""Synthetic loopback integration check; launches only the explicitly supplied Mimic build.

Uses a unique app-container database, defaults suite and discovery file. Never opens
or resets the developer's store. Removes its own project after verification. Retains
an isolated database and a temporary process log as evidence. No third-party packages.
"""

import argparse
import concurrent.futures
import gzip
import http.server
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error
import uuid

parser = argparse.ArgumentParser(
    description="Exercise two backend captures against an explicit local Mimic build."
)
parser.add_argument(
    "--app", required=True, help="Path to Mimic.app/Contents/MacOS/Mimic"
)
parser.add_argument("--live-google", action="store_true", help="Also make public DNS JSON requests to Google over HTTPS")
parser.add_argument("--live-jsonplaceholder", action="store_true", help="Also check public JSONPlaceholder objects and arrays")
parser.add_argument("--live-mixed", action="store_true", help="Call Google and JSONPlaceholder concurrently through separate listeners")
args = parser.parse_args()
APP = str(pathlib.Path(args.app).resolve(strict=True))
root = pathlib.Path("/tmp")
root.mkdir(parents=True, exist_ok=True)
work = pathlib.Path(tempfile.mkdtemp(prefix="passthrough-review-", dir=root))


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        self.request_body = self.rfile.read(
            int(self.headers.get("Content-Length", "0"))
        )
        self.do_GET()

    def do_GET(self):
        with self.server.lock:
            self.server.calls[self.path] = self.server.calls.get(self.path, 0) + 1
            n = self.server.calls[self.path]
        payload = {"backend": self.server.tag, "path": self.path, "visit": n}
        if self.command == "POST":
            payload["request"] = json.loads(self.request_body)
        body = json.dumps(payload).encode()
        status, kind = 200, "application/json"
        if self.path == "/large":
            body = b"a" * 70000
        if self.path == "/binary":
            body, kind = b"\xff\x00\x80", "application/octet-stream"
        if self.path == "/gzip":
            body = gzip.compress(body)
        if self.path == "/failure":
            status = 503
        if self.path == "/empty":
            status, body = 204, b""
        if self.path == "/conditional" and n == 1:
            status, body = 304, b""
        if self.path == "/range" and n == 1:
            status, body = 206, b"1"
        if self.path == "/empty-json" and n == 1:
            body = b""
        if self.path.startswith("/json/"):
            body = [b'{"ok":true,"n":1,"items":[null,false]}',
                    b'[1,true,null,"hello"]', b'true', b'false', b'null',
                    b'1', b'"hello"', '{"name":"日本語 🧪"}'.encode()][int(self.path.rsplit("/", 1)[1])]
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        if self.path == "/gzip":
            self.send_header("Content-Encoding", "gzip")
        if status == 206:
            self.send_header("Content-Range", "bytes 5-5/20")
        self.end_headers()
        self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    request_queue_size = 128


servers = []
for tag in ["Catalog", "Accounts"]:
    s = Server(("127.0.0.1", 0), Upstream)
    s.tag = tag
    s.calls = {}
    s.lock = threading.Lock()
    threading.Thread(target=s.serve_forever, daemon=True).start()
    servers.append(s)
local = [port(), port()]
control = port()
token = uuid.uuid4().hex
backend = str(uuid.uuid4())
env = {k: v for k, v in os.environ.items() if not k.startswith("MIMIC_")}
store_path = (
    "~/Library/Application Support/devxa.Mimic/passthrough-review-"
    + uuid.uuid4().hex
    + ".sqlite"
)
env.update(
    MIMIC_HEADLESS="1",
    MIMIC_DATABASE_PATH=store_path,
    MIMIC_DEFAULTS_SUITE="Mimic.PassthroughReview." + uuid.uuid4().hex,
    MIMIC_CONTROL_PORT=str(control),
    MIMIC_CONTROL_TOKEN=token,
    MIMIC_CONTROL_FILE="~/Library/Application Support/devxa.Mimic/review-control-"
    + uuid.uuid4().hex
    + ".json",
)
log = open(work / "app.log", "w")
process = subprocess.Popen([APP], env=env, stdout=log, stderr=log)


def command(operation, **args):
    req = urllib.request.Request(
        f"http://127.0.0.1:{control}/v1/command",
        data=json.dumps({operation: args}).encode(),
        headers={"X-Mimic-Token": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        error = json.load(e)
        if error.get("error", {}).get("code") == "project.noneOpen":
            raise ConnectionError("Project is still opening")
        raise AssertionError(error)
    assert data["ok"], data
    return data.get("result", {})


def wait(predicate, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.05)
    raise AssertionError("Condition timed out")


def call(which, path, data=None, encoding="identity"):
    req = urllib.request.Request(
        f"http://127.0.0.1:{local[which]}{path}",
        data=data,
        headers={"Accept-Encoding": encoding, **({"Content-Type": "application/json"} if data else {})},
    )
    try:
        r = urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as e:
        r = e
    with r:
        return r.status, r.read()


def endpoints():
    return command("endpointList")["endpoints"]


def find(which, path):
    return next(
        (
            e
            for e in endpoints()
            if e["path"] == path
            and e.get("backendID") == (backend.upper() if which else None)
        ),
        None,
    )


try:
    wait(lambda: command("ping"))
    command("projectCreate", name="Passthrough recording review", port=local[0])
    config = {
        "port": local[0],
        "globalDelayMs": 0,
        "primaryName": "Catalog",
        "upstreamURL": f"http://127.0.0.1:{servers[0].server_port}",
        "passthroughEnabled": True,
        "captureResponses": True,
        "backends": [
            {
                "id": backend,
                "name": "Accounts",
                "port": local[1],
                "upstreamURL": f"http://127.0.0.1:{servers[1].server_port}",
                "passthroughEnabled": True,
                "captureResponses": True,
            }
        ],
    }
    command("serverConfigure", configuration=config)
    project = command("projectExport")["project"]
    command("serverStart")
    wait(lambda: call(0, "/ready")[0] == 200)
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        futures = [
            pool.submit(call, b, f"/parallel/{i}") for b in range(2) for i in range(100)
        ]
        replies = [f.result() for f in futures]
    assert all(s == 200 for s, _ in replies)
    wait(lambda: len(endpoints()) == 201)
    for which in range(2):
        for i in range(100):
            e = find(which, f"/parallel/{i}")
            assert e is not None
            assert (
                json.loads(e["scenarios"][0]["body"])["backend"] == servers[which].tag
            )
    print(
        "PASS: 200 parallel captures across two backend ports, including identical paths",
        flush=True,
    )
    for which in range(2):
        for attempt in range(3):
            e = find(which, "/parallel/0")
            command("endpointDelete", endpoint={"id": e["id"]})
            # No arbitrary wait for engine updates: an immediately issued request must see the deletion.
            status, body = call(which, "/parallel/0")
            assert status == 200
            wait(lambda: find(which, "/parallel/0"))
            assert json.loads(body)["visit"] == attempt + 2, (which, attempt, body)
            command("state")  # Await the pending engine update before checking replay.
            status, replay = call(which, "/parallel/0")
            assert json.loads(replay) == json.loads(body), (
                which,
                attempt,
                body,
                replay,
            )
    print(
        "PASS: delete, immediately recapture, and replay, three cycles on each backend",
        flush=True,
    )
    for path, first_status, first_body in [("/conditional", 304, b""),
                                            ("/range", 206, b"1"),
                                            ("/empty-json", 200, b"")]:
        assert call(0, path) == (first_status, first_body)
        # This sentinel is captured after the problematic response has been logged.
        sentinel = path + "-barrier"
        call(0, sentinel)
        wait(lambda: find(0, sentinel))
        assert find(0, path) is None, (path, find(0, path))
        status, complete = call(0, path)
        assert status == 200 and json.loads(complete)["visit"] == 2
        wait(lambda: find(0, path))
        assert find(0, path)["scenarios"][0]["body"] == complete.decode()
        command("state")
        assert call(0, path) == (200, complete)
    print("PASS: cached 304, partial 206 containing 1, and empty JSON cannot poison later complete captures", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        replies = list(pool.map(lambda pair: (pair, call(*pair)),
                                [(which, f"/json/{i}") for which in range(2) for i in range(8)]))
    for (which, path), (status, body) in replies:
        assert status == 200
        wait(lambda: find(which, path))
        assert find(which, path)["scenarios"][0]["body"] == body.decode()
        command("state")
        assert call(which, path) == (200, body)
    print("PASS: 16 parallel JSON objects, arrays, booleans, null, numbers, strings and Unicode preserve exact bodies", flush=True)
    for path in ["/large", "/binary", "/gzip"]:
        status, body = call(0, path)
        assert status == 200
        assert find(0, path) is None
    print(
        "PASS: oversized, binary and compressed responses forward without creating invalid text mocks",
        flush=True,
    )
    assert call(0, "/failure")[0] == 503
    wait(lambda: find(0, "/failure"))
    assert find(0, "/failure")["scenarios"][0]["statusCode"] == 503
    assert call(0, "/empty")[0] == 204
    wait(lambda: find(0, "/empty"))
    print("PASS: real 503 and empty 204 responses are captured", flush=True)
    for which in range(2):
        for operation in ["Account", "Catalog"]:
            payload = json.dumps(
                {"operationName": operation, "query": f"query {operation} {{ id }}"}
            ).encode()
            assert call(which, "/graphql", payload)[0] == 200
    command("state")
    graphql = [e for e in endpoints() if e["path"] == "/graphql"]
    assert len(graphql) == 4
    assert {e.get("graphqlOperation") for e in graphql} == {"Account", "Catalog"}
    assert call(0, "/search?q=one")[0] == 200
    wait(lambda: find(0, "/search"))
    command("state")
    assert json.loads(call(0, "/search?q=two")[1])["path"] == "/search?q=one"
    print(
        "PASS: GraphQL operation and backend identity remain separate; query strings retain documented route semantics",
        flush=True,
    )
    config["upstreamURL"] = f"http://127.0.0.1:{servers[1].server_port}"
    command("serverConfigure", configuration=config)
    assert json.loads(call(0, "/changed-upstream")[1])["backend"] == "Accounts"
    config["passthroughEnabled"] = False
    command("serverConfigure", configuration=config)
    assert call(0, "/disabled")[0] == 404
    assert find(0, "/disabled") is None
    config["passthroughEnabled"] = True
    config["captureResponses"] = False
    command("serverConfigure", configuration=config)
    assert call(0, "/not-captured")[0] == 200
    assert find(0, "/not-captured") is None
    config["captureResponses"] = True
    command("serverConfigure", configuration=config)
    assert call(0, "/not-captured")[0] == 200
    wait(lambda: find(0, "/not-captured"))
    print(
        "PASS: upstream changes, disabling forwarding, and disabling/re-enabling capture apply live",
        flush=True,
    )
    command("serverStop")
    wait(lambda: command("serverStatus")["server"]["state"] == "stopped")
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        config["backends"][0]["port"] = occupied.getsockname()[1]
        command("serverConfigure", configuration=config)
        command("serverStart")
        wait(lambda: command("serverStatus")["server"]["state"] == "error")
        with socket.socket() as probe:
            assert probe.connect_ex(("127.0.0.1", local[0])) != 0
    config["backends"][0]["port"] = local[1]
    command("serverConfigure", configuration=config)
    command("serverStart")
    wait(lambda: command("serverStatus")["server"]["state"] == "running")
    assert call(0, "/parallel/0")[0] == 200 and call(1, "/parallel/0")[0] == 200
    command("serverStop")
    wait(lambda: command("serverStatus")["server"]["state"] == "stopped")
    print(
        "PASS: secondary-port bind failure releases primary listener; corrected configuration restarts both ports",
        flush=True,
    )
    if args.live_google:
        config["upstreamURL"] = "https://dns.google.com"
        config["captureResponses"] = True
        config["backends"][0]["upstreamURL"] = "https://dns.google.com"
        config["backends"][0]["captureResponses"] = True
        command("serverConfigure", configuration=config)
        command("serverStart")
        wait(lambda: command("serverStatus")["server"]["state"] == "running")
        for which in range(2):
            for attempt in range(3):
                status, body = call(which, "/resolve?name=example.com&type=A")
                assert status == 200, (status, body)
                parsed = json.loads(body)
                assert parsed["Status"] == 0 and parsed["Question"][0]["name"] == "example.com."
                wait(lambda: find(which, "/resolve"))
                assert find(which, "/resolve")["scenarios"][0]["body"] == body.decode()
                command("state")
                assert call(which, "/resolve?name=example.com&type=A") == (status, body)
                print(f"PASS: live Google DNS HTTPS backend {which} capture/replay cycle {attempt + 1}, {len(body)} bytes preserved", flush=True)
                command("endpointDelete", endpoint={"id": find(which, "/resolve")["id"]})
                command("state")
            compressed_path = "/resolve?name=example.com&type=A&cd=1"
            status, wire_body = call(which, compressed_path, encoding="gzip")
            assert status == 200 and json.loads(gzip.decompress(wire_body))["Status"] == 0
            def compressed_log():
                return next((entry for entry in command("logList", limit=100)["logs"]
                             if entry["path"] == compressed_path
                             and entry.get("backendID") == (backend.upper() if which else None)), None)
            entry = wait(compressed_log)
            assert entry["responseBodyIsBinary"] is True
            assert find(which, "/resolve") is None
            try:
                command("logSaveAsMock", id=entry["id"])
            except AssertionError as error:
                assert "Accept-Encoding: identity" in str(error), error
            else:
                raise AssertionError("Compressed wire body unexpectedly captured")
            print(f"PASS: live Google gzip backend {which}, {len(wire_body)} wire bytes decode to valid JSON; capture gives compression guidance", flush=True)
        command("serverStop")
        wait(lambda: command("serverStatus")["server"]["state"] == "stopped")
    if args.live_jsonplaceholder:
        config["upstreamURL"] = "https://jsonplaceholder.typicode.com"
        config["captureResponses"] = True
        config["backends"][0]["upstreamURL"] = "https://jsonplaceholder.typicode.com"
        config["backends"][0]["captureResponses"] = True
        command("serverConfigure", configuration=config)
        command("serverStart")
        wait(lambda: command("serverStatus")["server"]["state"] == "running")
        paths = ["/posts/1", "/todos/1", "/users/1", "/posts?userId=1"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            replies = list(pool.map(lambda pair: (pair, call(*pair)),
                                    [(which, path) for which in range(2) for path in paths]))
        for (which, path), (status, body) in replies:
            assert status == 200, (which, path, status, body[:200])
            parsed = json.loads(body)
            assert isinstance(parsed, (dict, list)) and parsed
            route = path.split("?")[0]
            wait(lambda: find(which, route))
            assert find(which, route)["scenarios"][0]["body"] == body.decode()
            command("state")
            assert call(which, path) == (status, body)
            print(f"PASS: JSONPlaceholder backend {which} {path}, {len(body)} bytes captured/replayed exactly", flush=True)
        for which in range(2):
            command("endpointDelete", endpoint={"id": find(which, "/posts/1")["id"]})
            command("state")
            status, body = call(which, "/posts/1")
            assert status == 200 and json.loads(body)["id"] == 1
            wait(lambda: find(which, "/posts/1"))
            assert find(which, "/posts/1")["scenarios"][0]["body"] == body.decode()
            command("state")
            assert call(which, "/posts/1") == (status, body)
        print("PASS: JSONPlaceholder deleted routes recapture on both listeners", flush=True)
        command("serverStop")
        wait(lambda: command("serverStatus")["server"]["state"] == "stopped")
    mixed_saved = []
    if args.live_mixed:
        config["upstreamURL"] = "https://dns.google.com"
        config["captureResponses"] = True
        config["backends"][0]["upstreamURL"] = "https://jsonplaceholder.typicode.com"
        config["backends"][0]["captureResponses"] = True
        command("serverConfigure", configuration=config)
        command("serverStart")
        wait(lambda: command("serverStatus")["server"]["state"] == "running")
        routes = [(0, "/resolve?name=example.com&type=A"),
                  (1, "/posts/1"), (1, "/todos/1"), (1, "/users/1")]
        for cycle in range(3):
            for which, path in routes:
                endpoint = find(which, path.split("?")[0])
                if endpoint:
                    command("endpointDelete", endpoint={"id": endpoint["id"]})
            command("state")
            barrier = threading.Barrier(4)
            def simultaneous(pair):
                barrier.wait(timeout=10)
                started = time.monotonic()
                response = call(*pair)
                return pair, response, started, time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                replies = list(pool.map(simultaneous, routes))
            # All four calls started before any completed: measured overlap, not just a pool.
            overlap = min(r[3] for r in replies) - max(r[2] for r in replies)
            assert overlap > 0, replies
            mixed_saved = []
            for (which, path), (status, body), started, finished in replies:
                assert status == 200, (which, path, status, body[:200])
                parsed = json.loads(body)
                if which == 0:
                    assert parsed["Status"] == 0 and parsed["Question"][0]["name"] == "example.com."
                else:
                    assert parsed["id"] == 1 and "Status" not in parsed
                route = path.split("?")[0]
                wait(lambda: find(which, route))
                assert find(which, route)["scenarios"][0]["body"] == body.decode()
                mixed_saved.append((which, route, body.decode()))
                records = command("logList", limit=100)["logs"]
                assert any(e["path"] == path and e["outcome"] == "passthrough"
                           and e.get("backendID") == (backend.upper() if which else None)
                           and e["responseBody"] == body.decode() for e in records)
            command("state")
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                replay = list(pool.map(lambda pair: call(*pair), routes))
            assert replay == [r[1] for r in replies]
            print(f"PASS: mixed Google + JSONPlaceholder cycle {cycle + 1}: four concurrent calls overlap {overlap:.3f}s; exact backend-specific capture and parallel replay", flush=True)
        command("serverStop")
        wait(lambda: command("serverStatus")["server"]["state"] == "stopped")
    expected = len(endpoints())
    command("projectClose")
    command("projectOpen", project={"id": project["id"]})
    wait(lambda: len(endpoints()) == expected)
    process.terminate()
    process.wait(timeout=15)
    process = subprocess.Popen([APP], env=env, stdout=log, stderr=log)
    wait(lambda: command("ping"))
    command("projectOpen", project={"id": project["id"]})
    wait(lambda: len(endpoints()) == expected)
    print(
        f"PASS: {expected} captures persisted across close, quit, relaunch and reopen",
        flush=True,
    )
    for which, route, body in mixed_saved:
        assert find(which, route)["scenarios"][0]["body"] == body
    if mixed_saved:
        print("PASS: all four mixed-backend response bodies persist exactly across app relaunch", flush=True)
    command("projectDelete", project={"id": project["id"]})
    print("EVIDENCE:", work, flush=True)
finally:
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()
    for s in servers:
        s.shutdown()
        s.server_close()
