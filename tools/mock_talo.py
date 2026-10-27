#!/usr/bin/env python3
"""A tiny in-memory imitation of the Talo endpoints crankboard uses.

Lets you try the library in the Playdate Simulator without a Talo account:

    python tools/mock_talo.py --seed 30

and in secrets.lua:  accessKey = "mock", host = "127.0.0.1", port = 8787, useSSL = false

Options:
    --port N           port to listen on (default 8787)
    --seed N           pre-fill the leaderboard with N fake players
    --fail             answer every request with 503 (to test the "couldn't connect" path)
    --leaderboard X    leaderboard internal name; repeat for several (default: highscores)
    --player NAME:SCORE  add a player with this name and score on every leaderboard
                       (e.g. one with the same name as yours); repeat for several
"""
import argparse
import json
import random
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

NAME_PROP = "name"  # mimics "Display name prop key" = name in the Talo dashboard

players = {}      # player id -> {"id", "props"}
aliases = {}      # alias id -> {"id", "service", "identifier", "player_id"}
boards = {}       # internal name -> list of entries
next_ids = {"alias": 1, "entry": 1}
args = None


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def continuity_date(header):
    # like Talo: a millisecond timestamp that is not in the future sets the entry's date
    if not header:
        return None
    try:
        when = datetime.fromtimestamp(int(header) / 1000, timezone.utc)
    except (ValueError, OverflowError, OSError):
        print("   bad continuity timestamp:", header)
        return None
    if when.timestamp() > datetime.now(timezone.utc).timestamp() + 1:
        print("   continuity timestamp in the future, ignored:", header)
        return None
    print("   continuity date:", when.isoformat())
    return when.isoformat()


def alias_json(alias):
    player = players[alias["player_id"]]
    display = next((p["value"] for p in player["props"] if p["key"] == NAME_PROP), alias["identifier"])
    return {
        "id": alias["id"],
        "service": alias["service"],
        "identifier": alias["identifier"],
        "displayName": display,
        "player": {"id": player["id"], "props": player["props"], "devBuild": False},
    }


def sorted_entries(name):
    return sorted(boards[name], key=lambda e: (-e["score"], e["id"]))


def entry_json(name, entry):
    position = sorted_entries(name).index(entry)
    return {
        "id": entry["id"],
        "position": position,
        "score": entry["score"],
        "leaderboardInternalName": name,
        "leaderboardSortMode": "desc",
        "playerAlias": alias_json(aliases[entry["alias_id"]]),
        "props": entry["props"],
        "hidden": False,
        "createdAt": entry["createdAt"],
    }


def create_alias(service, identifier):
    player_id = str(uuid.uuid4())
    players[player_id] = {"id": player_id, "props": []}
    alias = {"id": next_ids["alias"], "service": service, "identifier": identifier, "player_id": player_id}
    next_ids["alias"] += 1
    aliases[alias["id"]] = alias
    return alias


def seed(count):
    names = ["Ana", "Bo", "Cyd", "Dee", "Eli", "Fox", "Gus", "Hal", "Ivy", "Jo", "Kit", "Lou", "Max", "Nia",
             "Oz", "Pip", "Quin", "Rex", "Sky", "Tam", "Uma", "Vic", "Wes", "Xan", "Yui", "Zed"]
    for i in range(count):
        alias = create_alias("playdate", "pd-seed-%d" % i)
        name = names[i % len(names)] + ("" if i < len(names) else str(i))
        players[alias["player_id"]]["props"] = [{"key": NAME_PROP, "value": name}]
        for board in boards:
            props = [{"key": "level", "value": str(random.randint(1, 9))}, {"key": NAME_PROP, "value": name}]
            add_entry(board, alias, random.randint(5, 60), props)


def add_entry(name, alias, score, props, created=None):
    # unique leaderboard, higher is better (Talo's default "desc" + unique mode)
    for e in boards[name]:
        if e["alias_id"] == alias["id"]:
            if score > e["score"]:
                # like Talo: new props are merged into the existing ones
                merged = {p["key"]: p["value"] for p in e["props"]}
                merged.update({p["key"]: p["value"] for p in props})
                e["props"] = [{"key": k, "value": v} for k, v in merged.items() if v is not None]
                e["score"], e["createdAt"] = score, created or now_iso()
                return e, True
            return e, False
    entry = {"id": next_ids["entry"], "alias_id": alias["id"], "score": score, "props": props,
             "createdAt": created or now_iso()}
    next_ids["entry"] += 1
    boards[name].append(entry)
    return entry, False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        print("   body:", raw.decode(errors="replace"))
        return json.loads(raw or b"{}")

    def handle_any(self, method):
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.strip("/").split("/")]
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        print(">> %s %s  alias=%s" % (method, self.path, self.headers.get("x-talo-alias")))

        if args.fail:
            return self.reply(503, {"message": "Service unavailable (mock --fail)"})
        if not (self.headers.get("Authorization") or "").startswith("Bearer "):
            return self.reply(401, {"message": "Missing access key"})
        if parts[:1] != ["v1"]:
            return self.reply(404, {"message": "Not found"})
        parts = parts[1:]

        if method == "GET" and parts == ["players", "identify"]:
            service, identifier = query.get("service"), query.get("identifier")
            if not service or not identifier:
                return self.reply(400, {"message": "service and identifier are required"})
            alias = next((a for a in aliases.values()
                          if a["service"] == service and a["identifier"] == identifier), None)
            alias = alias or create_alias(service, identifier)
            return self.reply(200, {"alias": alias_json(alias), "socketToken": "mock"})

        if method == "PATCH" and len(parts) == 2 and parts[0] == "players":
            player = players.get(parts[1])
            if not player:
                return self.reply(404, {"message": "Player not found"})
            for prop in self.read_json().get("props", []):
                player["props"] = [p for p in player["props"] if p["key"] != prop["key"]]
                if prop.get("value") is not None:
                    player["props"].append(prop)
            return self.reply(200, {"player": player})

        if len(parts) >= 3 and parts[0] == "leaderboards" and parts[2] == "entries":
            name = parts[1]
            if name not in boards:
                return self.reply(404, {"message": "Leaderboard not found"})
            alias_header = self.headers.get("x-talo-alias")
            alias = aliases.get(int(alias_header)) if alias_header and alias_header.isdigit() else None

            if method == "POST" and len(parts) == 3:
                if not alias:
                    return self.reply(404, {"message": "Player not found"})
                body = self.read_json()
                if not isinstance(body.get("score"), (int, float)):
                    return self.reply(400, {"errors": {"score": ["score is required"]}})
                entry, updated = add_entry(name, alias, body["score"], body.get("props") or [],
                                           continuity_date(self.headers.get("x-talo-continuity-timestamp")))
                return self.reply(200, {"entry": entry_json(name, entry), "updated": updated})

            if method == "GET" and len(parts) == 3:
                page = int(query.get("page", 0))
                entries = sorted_entries(name)
                chunk = entries[page * 50:(page + 1) * 50]
                return self.reply(200, {"entries": [entry_json(name, e) for e in chunk],
                                        "count": len(entries),
                                        "isLastPage": (page + 1) * 50 >= len(entries)})

            if method == "GET" and parts[3:] == ["top"]:
                if not alias:
                    return self.reply(404, {"message": "Player not found"})
                limit = int(query.get("limit", 10))
                entries = sorted_entries(name)
                mine = [e for e in entries if e["alias_id"] == alias["id"]]
                return self.reply(200, {"topEntries": [entry_json(name, e) for e in entries[:limit]],
                                        "playerEntries": [entry_json(name, e) for e in mine]})

        return self.reply(404, {"message": "Not found"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def log_message(self, fmt, *a):
        print("<< " + fmt % a)


def main():
    global args
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--fail", action="store_true")
    parser.add_argument("--leaderboard", action="append")
    parser.add_argument("--player", action="append", default=[])
    args = parser.parse_args()
    for name in args.leaderboard or ["highscores"]:
        boards[name] = []
    if args.seed:
        seed(args.seed)
    for spec in args.player:
        name, _, score = spec.rpartition(":")
        alias = create_alias("playdate", "pd-extra-%d" % next_ids["alias"])
        players[alias["player_id"]]["props"] = [{"key": NAME_PROP, "value": name}]
        for board in boards:
            add_entry(board, alias, float(score) if "." in score else int(score),
                      [{"key": NAME_PROP, "value": name}])
    print("Mock Talo listening on http://localhost:%d (leaderboards: %s)" % (args.port, ", ".join(boards)))
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
