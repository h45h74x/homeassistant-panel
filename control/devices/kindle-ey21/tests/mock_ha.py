#!/usr/bin/env python3
"""Mock HA for agent tests: mock_ha.py <scenario.json> <port-file> <log-file>.
Scenario: {"hello":[{"status":200,"body":{...}|"raw","delay":0}], "state":[...], "commands":[...], "config":[...]}
Last entry of each list repeats. Empty command polls wait min(wait,2)s unless delay is given."""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import jsonschema

scen_file, port_file, log_file = sys.argv[1:4]
scen = json.load(open(scen_file))
schema_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../contract/schema")
schemas = {n: json.load(open(os.path.join(schema_dir, n + ".schema.json"))) for n in ("hello", "state")}
lock = threading.Lock()
counts = {}

def log(line):
    with lock, open(log_file, "a") as f:
        f.write(line.replace("\n", " ") + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_any(self):
        u = urlparse(self.path)
        ep = u.path.rstrip("/").rsplit("/", 1)[-1]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        log("%s %s auth=%s body=%s" % (self.command, self.path, self.headers.get("Authorization", ""), body))
        if not self.headers.get("Authorization", "").startswith("Bearer ") or " " in self.headers.get("Authorization", "")[7:]:
            log("AUTH-ERROR %s" % ep)
        if ep in schemas:
            try:
                jsonschema.validate(json.loads(body), schemas[ep])
            except Exception as e:
                log("SCHEMA-ERROR %s %s" % (ep, str(e).splitlines()[0]))
        lst = scen.get(ep)
        if not lst:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        with lock:
            i = counts.get(ep, 0); counts[ep] = i + 1
        e = lst[min(i, len(lst) - 1)]
        b = e.get("body", "")
        b = b if isinstance(b, str) else json.dumps(b, separators=(",", ":"))
        d = e.get("delay")
        if d is None and ep == "commands" and '"commands":[]' in b:
            d = min(float(parse_qs(u.query).get("wait", ["0"])[0]), 2)
        if d: time.sleep(d)
        data = b.encode()
        self.send_response(e.get("status", 200))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except OSError: pass
    do_GET = do_POST = handle_any

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(port_file + ".tmp", "w").write(str(srv.server_address[1]))
os.rename(port_file + ".tmp", port_file)
srv.serve_forever()
