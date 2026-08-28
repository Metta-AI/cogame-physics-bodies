#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON summary of a physics-bodies `.replay` file.

Python 3 standard library only: NO Nim, NO Docker, NO browser. This is the
forensics path for a hosted replay — download the bytes and read them:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                    # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.endRule' /tmp/ep.json
    jq -r '[.intents[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

The config JSON is recovered by BRACE-MATCHING from the first `{` (the technique
the starter's AGENTS.md documents for prod forensics) as well as by the header
walk, so a header whose string framing ever changes still yields the config.
"""

from __future__ import annotations

import json
import struct
import sys
import zlib

MAGIC = b"COWLDPBD"
FORMAT_VERSION = 1
PROTOCOL = "physics-bodies/v1"

REC_HASH = 0x01
REC_INPUT = 0x02
REC_JOIN = 0x03
REC_LEAVE = 0x04
REC_CHAT = 0x05
REC_DEBUG_SPRITE = 0x06


class ReplayError(Exception):
    pass


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.at = 0

    def take(self, count: int) -> bytes:
        if count < 0 or self.at + count > len(self.data):
            raise ReplayError(f"truncated replay at byte {self.at}")
        out = self.data[self.at:self.at + count]
        self.at += count
        return out

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return struct.unpack("<H", self.take(2))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self.take(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def text(self) -> str:
        length = self.u16()
        raw = self.take(length)
        # Recorded strings are truncated on RUNE boundaries, never bytes, so a
        # strict decode is the correct check rather than a lenient one: if this
        # raises, the writer broke its own rune discipline.
        return raw.decode("utf-8")

    def blob(self) -> bytes:
        return self.take(self.u32())


def payload(raw: bytes) -> bytes:
    """Hosted artifacts may arrive gzip/zlib compressed."""
    if raw.startswith(MAGIC):
        return raw
    for wbits in (47, 15, -15):
        try:
            out = zlib.decompress(raw, wbits)
        except zlib.error:
            continue
        if out.startswith(MAGIC):
            return out
    return raw


def brace_matched_config(raw: bytes) -> str:
    """The config JSON, recovered by brace-matching from the first `{`."""
    start = raw.find(b"{")
    if start < 0:
        return ""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(raw)):
        ch = raw[i:i + 1]
        if in_string:
            if escaped:
                escaped = False
            elif ch == b"\\":
                escaped = True
            elif ch == b'"':
                in_string = False
            continue
        if ch == b'"':
            in_string = True
        elif ch == b"{":
            depth += 1
        elif ch == b"}":
            depth -= 1
            if depth == 0:
                return raw[start:i + 1].decode("utf-8", "replace")
    return ""


def summarize(raw: bytes) -> dict:
    data = payload(raw)
    reader = Reader(data)
    if reader.take(len(MAGIC)) != MAGIC:
        raise ReplayError("replay magic does not match COWLDPBD")
    format_version = reader.u16()
    if format_version != FORMAT_VERSION:
        raise ReplayError(f"unsupported replay format version {format_version}")
    game_name = reader.text()
    game_version = reader.text()
    reader.u64()                                   # recorded-at, milliseconds
    config_text = reader.text()

    try:
        config = json.loads(config_text)
    except ValueError:
        config = json.loads(brace_matched_config(data) or "{}")

    joins: list[dict] = []
    intents: list[dict] = []
    rounds: list[dict] = []
    registers: list[dict] = []
    fallbacks = 0
    fallback_causes: dict[str, int] = {}
    budget_guards: list[dict] = []
    stops: list[dict] = []
    results: dict = {}
    tick_count = 0
    input_records = 0
    hash_records = 0
    chat_records = 0

    while reader.at < len(data):
        kind = reader.u8()
        if kind == REC_HASH:
            tick = reader.u32()
            reader.u64()
            tick_count = max(tick_count, tick)
            hash_records += 1
        elif kind == REC_INPUT:
            reader.u32()
            reader.u8()
            reader.u8()
            input_records += 1
        elif kind == REC_JOIN:
            reader.u32()
            player = reader.u8()
            name = reader.text()
            slot = reader.i16()
            reader.text()                          # token: never reported
            joins.append({"player": player, "name": name, "slot": slot})
        elif kind == REC_LEAVE:
            reader.u32()
            reader.u8()
        elif kind == REC_CHAT:
            reader.u32()
            reader.u8()
            message = reader.text()
            chat_records += 1
            if not message.startswith("{"):
                continue
            try:
                record = json.loads(message)
            except ValueError:
                continue
            kind_key = record.get("k")
            if kind_key == "intent":
                intents.append({
                    "turn": record.get("turn"),
                    "seat": record.get("seat"),
                    "alias": record.get("alias"),
                    "body": record.get("body"),
                    "source": record.get("source"),
                    "latency_ms": record.get("latency_ms"),
                    "stance": record.get("stance"),
                    "aim": record.get("aim"),
                    "aggression": record.get("aggression"),
                    "posture_bias": record.get("posture_bias"),
                    "lead_ticks": record.get("lead_ticks"),
                    "circle_dir": record.get("circle_dir"),
                    "note": record.get("note"),
                    "say": record.get("say"),
                })
            elif kind_key == "fallback":
                fallbacks += 1
                cause = str(record.get("cause", "unknown"))
                fallback_causes[cause] = fallback_causes.get(cause, 0) + 1
            elif kind_key == "round":
                rounds.append(record)
            elif kind_key == "register":
                registers.append({
                    "seat": record.get("seat"),
                    "alias": record.get("alias"),
                    "body": record.get("body"),
                    "policy": record.get("policy"),
                    "kind": record.get("kind"),
                    "baseline": record.get("baseline"),
                })
            elif kind_key == "budget_guard":
                budget_guards.append(record)
            elif kind_key == "stop":
                stops.append(record)
            elif kind_key == "result":
                results = record.get("results", {}) or {}
        elif kind == REC_DEBUG_SPRITE:
            reader.u32()
            reader.u8()
            reader.blob()
        else:
            raise ReplayError(f"unknown replay record type {kind}")

    return {
        "protocol": PROTOCOL,
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "perm": config.get("perm"),
        "num_agents": config.get("num_agents"),
        "names": [join["name"] for join in joins],
        "aliases": results.get("aliases", [r.get("alias") for r in registers]),
        "bodies": results.get("bodies", [r.get("body") for r in registers]),
        "policyKinds": results.get("policyKinds",
                                   [r.get("kind") for r in registers]),
        "registers": registers,
        "tickCount": tick_count,
        "records": {
            "hashes": hash_records,
            "inputs": input_records,
            "chats": chat_records,
            "joins": len(joins),
        },
        "rounds": rounds,
        "intents": intents,
        "fallbacks": fallbacks,
        "fallbackCauses": fallback_causes,
        "budgetGuards": budget_guards,
        "stops": stops,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <replay path>", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as handle:
        raw = handle.read()
    try:
        summary = summarize(raw)
    except (ReplayError, UnicodeDecodeError, ValueError) as error:
        print(f"replay_summary: {error}", file=sys.stderr)
        return 1
    # ensure_ascii=False so the output is real UTF-8 (the point of the rune
    # discipline); a strict json.loads(out.decode("utf-8")) must accept it.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
