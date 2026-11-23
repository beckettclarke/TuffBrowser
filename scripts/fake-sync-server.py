#!/usr/bin/env python3
"""A local stand-in for Mozilla's token and Sync 1.5 storage servers, for testing Tuff's sync
end to end without a Mozilla account (debug builds only).

    scripts/fake-sync-server.py 8765 &
    TUFF_SYNC_SERVER=http://127.0.0.1:8765 TUFF_DEBUG_SCRIPT="sync fake; wait 1; sync now; ..." Tuff

Debug builds with TUFF_SYNC_SERVER skip the OAuth server and ask this one for tokens; `sync fake`
signs in with FAKE_SYNC_KEY below. Hawk signatures are checked. GET /debug/dump prints every
record, decrypted with openssl, to check what Tuff uploads; POST /debug/init sets the account up as
another browser would have, and POST /debug/put/<collection> with a JSON array of cleartext records
stores them as another device would.
"""
import base64, hashlib, hmac, json, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

# kSync for `sync fake`: 64 bytes, base64url. Tuff's DebugHooks has the same value.
FAKE_SYNC_KEY = "dHVmZi1mYWtlLXN5bmMta2V5LWZvci10ZXN0aW5nLW9ubHktMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYg"
TOKEN_ID, TOKEN_KEY, UID = "fake-token-id", "fake-token-key", "1"

lock = threading.Lock()
collections = {}  # name -> {id: {"id", "payload", "modified", "sortindex"}}
modified = {}  # name -> timestamp
batches = {}  # id -> (collection, [records])


def now():
    return round(time.time(), 2)


def b64url(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def encrypt(cleartext, keys):
    enc, mac = keys
    iv = __import__("os").urandom(16)
    out = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", enc.hex(), "-iv", iv.hex()],
                         input=json.dumps(cleartext).encode(), capture_output=True, check=True)
    ciphertext = base64.b64encode(out.stdout).decode()
    return json.dumps({"ciphertext": ciphertext, "IV": base64.b64encode(iv).decode(),
                       "hmac": hmac.new(mac, ciphertext.encode(), hashlib.sha256).hexdigest()})


def bulk_keys():
    key = b64url(FAKE_SYNC_KEY)
    keys = decrypt(collections["crypto"]["keys"]["payload"], (key[:32], key[32:]))
    return base64.b64decode(keys["default"][0]), base64.b64decode(keys["default"][1])


def decrypt(payload, keys):
    data = json.loads(payload)
    if "ciphertext" not in data:
        return data
    enc, mac = keys
    expect = hmac.new(mac, data["ciphertext"].encode(), hashlib.sha256).hexdigest()
    if expect != data["hmac"]:
        return {"error": "bad hmac"}
    out = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc", "-K", enc.hex(), "-iv", base64.b64decode(data["IV"]).hex()],
        input=base64.b64decode(data["ciphertext"]), capture_output=True,
    )
    return json.loads(out.stdout) if out.returncode == 0 else {"error": out.stderr.decode()}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Weave-Timestamp", "%.2f" % now())
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def hawk_ok(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Hawk "):
            return False
        fields = dict(part.strip().split("=", 1) for part in header[5:].split(","))
        fields = {k: v.strip('"') for k, v in fields.items()}
        host, _, port = self.headers["Host"].partition(":")
        normalized = "hawk.1.header\n%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n" % (
            fields["ts"], fields["nonce"], self.command, self.path, host.lower(), port or "80", fields.get("ext", ""))
        mac = base64.b64encode(hmac.new(TOKEN_KEY.encode(), normalized.encode(), hashlib.sha256).digest()).decode()
        if mac != fields.get("mac") or fields.get("id") != TOKEN_ID:
            print("hawk mismatch for", self.command, self.path, file=sys.stderr)
            return False
        return True

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length)) if length else None

    def precondition(self, name):
        since = self.headers.get("X-If-Unmodified-Since")
        return since is None or modified.get(name, 0) <= float(since)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/token/1.0/sync/1.5":
            if not self.headers.get("X-KeyID") or not self.headers.get("Authorization", "").startswith("Bearer "):
                return self.reply(401, {"status": "invalid-credentials"})
            host = self.headers["Host"]
            return self.reply(200, {"id": TOKEN_ID, "key": TOKEN_KEY, "uid": UID, "duration": 3600,
                                    "api_endpoint": "http://%s/1.5/%s" % (host, UID)})
        if url.path == "/debug/dump":
            return self.dump()
        if not self.hawk_ok():
            return self.reply(401, {"status": "invalid-hawk"})
        parts = url.path.split("/")[3:]
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        with lock:
            if parts == ["info", "collections"]:
                return self.reply(200, modified)
            if parts == ["info", "configuration"]:
                return self.reply(200, {"max_post_records": 7, "max_total_records": 100000})
            if len(parts) == 3 and parts[0] == "storage":
                record = collections.get(parts[1], {}).get(parts[2])
                return self.reply(200, record) if record else self.reply(404, {})
            if len(parts) == 2 and parts[0] == "storage":
                items = list(collections.get(parts[1], {}).values())
                newer = float(query.get("newer", 0))
                items = [r for r in items if r["modified"] > newer]
                items.sort(key=lambda r: -r["modified"])
                offset = int(query.get("offset", 0))
                limit = int(query.get("limit", 100000))
                page = items[offset:offset + limit]
                headers = {"X-Last-Modified": "%.2f" % modified.get(parts[1], 0)}
                if offset + limit < len(items):
                    headers["X-Weave-Next-Offset"] = str(offset + limit)
                return self.reply(200, page, headers)
        self.reply(404, {})

    def store(self, name, records, ts):
        coll = collections.setdefault(name, {})
        for r in records:
            item = {"id": r["id"], "payload": r["payload"], "modified": ts}
            if "sortindex" in r:
                item["sortindex"] = r["sortindex"]
            coll[r["id"]] = item
        modified[name] = ts

    def do_PUT(self):
        if not self.hawk_ok():
            return self.reply(401, {})
        parts = urlsplit(self.path).path.split("/")[3:]
        body = self.body()
        with lock:
            if not self.precondition(parts[1]):
                return self.reply(412, {})
            ts = now() + 0.01
            self.store(parts[1], [dict(body, id=parts[2])], ts)
            return self.reply(200, ts, {"X-Last-Modified": "%.2f" % ts})

    def do_POST(self):
        if self.path == "/debug/init":
            # An account another browser set up: meta/global and crypto/keys, before Tuff signs in.
            import os
            key = b64url(FAKE_SYNC_KEY)
            bulk = [base64.b64encode(os.urandom(32)).decode(), base64.b64encode(os.urandom(32)).decode()]
            engines = {name: {"version": version, "syncID": name[:12].ljust(12, "x")} for name, version in
                       [("bookmarks", 2), ("history", 1), ("passwords", 1), ("tabs", 1), ("clients", 1), ("spaces", 3)]}
            with lock:
                self.store("crypto", [{"id": "keys", "payload": encrypt({"id": "keys", "default": bulk, "collections": {}}, (key[:32], key[32:]))}], now())
                self.store("meta", [{"id": "global", "payload": json.dumps({"syncID": "fakeglobal01", "storageVersion": 5, "engines": engines, "declined": []})}], now())
            return self.reply(200, {})
        if self.path.startswith("/debug/put/"):
            # Another device's cleartext records, encrypted here (to test reading Firefox's).
            name = self.path.split("/")[3]
            with lock:
                keys = bulk_keys()
                self.store(name, [{"id": r["id"], "payload": encrypt(r, keys)} for r in self.body()], now() + 0.01)
            return self.reply(200, {})
        if not self.hawk_ok():
            return self.reply(401, {})
        url = urlsplit(self.path)
        name = url.path.split("/")[4]
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        records = self.body()
        assert len(records) <= 7, "more records in one POST than info/configuration allows"
        with lock:
            if not self.precondition(name):
                return self.reply(412, {})
            batch = query.get("batch")
            if batch == "true" and query.get("commit") != "true":
                bid = str(len(batches) + 1)
                batches[bid] = (name, list(records))
                return self.reply(202, {"batch": bid, "success": [r["id"] for r in records], "failed": {}})
            pending = []
            if batch and batch != "true":
                pending = batches[batch][1]
                pending += records
                if query.get("commit") != "true":
                    return self.reply(202, {"batch": batch, "success": [r["id"] for r in records], "failed": {}})
                del batches[batch]
            else:
                pending = records
            ts = now() + 0.01
            self.store(name, pending, ts)
            return self.reply(200, {"modified": ts, "success": [r["id"] for r in pending], "failed": {}},
                              {"X-Last-Modified": "%.2f" % ts})

    def do_DELETE(self):
        if not self.hawk_ok():
            return self.reply(401, {})
        with lock:
            collections.clear()
            modified.clear()
        self.reply(200, {})

    def dump(self):
        key = b64url(FAKE_SYNC_KEY)
        root = (key[:32], key[32:])
        out = {}
        with lock:
            keys_record = collections.get("crypto", {}).get("keys")
            bulk = None
            if keys_record:
                keys = decrypt(keys_record["payload"], root)
                bulk = (base64.b64decode(keys["default"][0]), base64.b64decode(keys["default"][1]))
            for name, coll in collections.items():
                out[name] = {}
                for rid, r in coll.items():
                    use = root if name == "crypto" else bulk
                    out[name][rid] = decrypt(r["payload"], use) if use or name == "meta" else r["payload"]
        self.reply(200, out)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
