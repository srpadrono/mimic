#!/usr/bin/env python3
"""The "real" Acme backends: Auth, Catalog and Payments, each on its own port.

This stands in for production so the example has something to record. Mimic sits in front of it
with pass-through on, forwards the app's calls here, and keeps each reply as a mock. After that the
backend can be stopped: Mimic answers everything.

It only ever succeeds. Every failure in `openapi.yaml` (a declined card, a busy Payments service,
an expired session, an item that sold out) is something this server never does on its own, which
is the point of the example: those are the cases the agent has to script in Mimic.

    python3 backend/acme_backend.py            # Auth 9080, Catalog 9081, Payments 9082
    python3 backend/acme_backend.py --base 9180

Standard library only.
"""

import argparse
import itertools
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PRODUCTS = [
    {"id": "p_lamp", "name": "Desk lamp", "price": 39.5, "currency": "USD", "stock": 12, "emoji": "💡"},
    {"id": "p_plant", "name": "Monstera", "price": 24.0, "currency": "USD", "stock": 5, "emoji": "🪴"},
    {"id": "p_headphones", "name": "Headphones", "price": 89.0, "currency": "USD", "stock": 7, "emoji": "🎧"},
    {"id": "p_mug", "name": "Camp mug", "price": 12.0, "currency": "USD", "stock": 30, "emoji": "☕️"},
    {"id": "p_notebook", "name": "Notebook", "price": 8.5, "currency": "USD", "stock": 40, "emoji": "📓"},
    {"id": "p_backpack", "name": "Backpack", "price": 64.0, "currency": "USD", "stock": 3, "emoji": "🎒"},
]
PRICES = {product["id"]: product["price"] for product in PRODUCTS}
TOKEN = "tok_live_7Hq2"
REFRESH_TOKEN = "rt_live_9Vx4"
CARDS = {"card_visa_4242", "card_mastercard_5555"}
ORDER_NUMBERS = itertools.count(1042)
ORDER_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    service = "?"
    server_version = "AcmeBackend/1.0"

    def log_message(self, fmt, *args):
        print(f"[{self.service}] {self.command} {self.path} {fmt % args}", flush=True)

    def reply(self, status, body, headers=None):
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except ValueError:
            return None

    def authorized(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def not_found(self):
        self.reply(404, {"error": "not_found", "message": f"No route for {self.command} {self.path}."})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        handler = ROUTES.get((self.service, method, self.path.split("?", 1)[0]))
        if handler is None and self.service == "Catalog" and method == "GET" and self.path.startswith("/products/"):
            handler = product_detail
        if handler is None:
            self.not_found()
        else:
            handler(self)


def login(request):
    body = request.body()
    if not body or not body.get("email") or not body.get("password"):
        request.reply(400, {"error": "invalid_request", "message": "Email and password are required."})
        return
    request.reply(200, {"token": TOKEN, "refreshToken": REFRESH_TOKEN,
                        "user": {"id": "u_1001", "name": "Sam Rivera"}})


def refresh(request):
    body = request.body() or {}
    if body.get("refreshToken") != REFRESH_TOKEN:
        request.reply(401, {"error": "refresh_expired", "message": "Sign in again."})
        return
    request.reply(200, {"token": TOKEN})


def products(request):
    request.reply(200, {"products": PRODUCTS})


def product_detail(request):
    product_id = request.path.rsplit("/", 1)[-1]
    product = next((product for product in PRODUCTS if product["id"] == product_id), None)
    if product is None:
        request.reply(404, {"error": "not_found", "message": "No such product."})
    else:
        request.reply(200, product)


def place_order(request):
    if not request.authorized():
        request.reply(401, {"error": "token_expired", "message": "Your session has expired."})
        return
    body = request.body()
    items = (body or {}).get("items") or []
    if not items or any(item.get("productId") not in PRICES for item in items):
        request.reply(400, {"error": "invalid_request", "message": "The order has no valid items."})
        return
    if body.get("paymentMethod") not in CARDS:
        request.reply(402, {"error": "card_declined", "message": "Your card was declined. Try another card."})
        return
    total = round(sum(PRICES[item["productId"]] * int(item.get("quantity", 1)) for item in items), 2)
    with ORDER_LOCK:
        number = next(ORDER_NUMBERS)
    request.reply(201, {"orderId": f"ORD-{number}", "status": "paid", "total": total, "currency": "USD"})


ROUTES = {
    ("Auth", "POST", "/auth/login"): login,
    ("Auth", "POST", "/auth/refresh"): refresh,
    ("Catalog", "GET", "/products"): products,
    ("Payments", "POST", "/orders"): place_order,
}


def serve(service, port):
    handler = type(f"{service}Handler", (Handler,), {"service": service})
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"{service:<9} http://127.0.0.1:{port}", flush=True)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", type=int, default=9080, help="Auth port; Catalog and Payments follow it.")
    args = parser.parse_args()
    servers = [serve(name, args.base + offset) for offset, name in enumerate(["Auth", "Catalog", "Payments"])]
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        for server in servers:
            server.shutdown()


if __name__ == "__main__":
    main()
