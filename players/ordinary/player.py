"""Physics Bodies orders over the ordinary player WebSocket."""

from __future__ import annotations

import json
import math
import os
import urllib.request
from urllib.parse import parse_qs, urlsplit

import websocket

from policy import FIELDS, default_order, order_from_choices, prompt_for, questions


def choose(view: dict, strategy: str, seat: int) -> tuple[dict, str]:
    system, user = prompt_for(view, strategy)
    if os.environ.get("PHYSICS_BODIES_JEV") == "1":
        sidecar = os.environ.get("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "")
        if sidecar:
            endpoint, model, key = sidecar, "typesafe/jev-1.13", ""
        else:
            endpoint = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
            model = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")
            key = os.environ["TYPESAFE_API_KEY"]
        catalog = questions()
        body = json.dumps({"model": model,
                           "state": {"policy": system, "summary": user},
                           "questions": catalog}).encode()
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = "Bearer " + key
        else:
            headers["X-Coworld-Player-Slot"] = str(seat)
        request = urllib.request.Request(endpoint.rstrip("/") + "/v1/systemone",
                                         body, headers, method="POST")
        with urllib.request.urlopen(request, timeout=8) as response:
            answers = json.load(response)["answers"]
        selected = {}
        for name, values in FIELDS.items():
            answer = answers[name]
            probabilities = [answer["probabilities"][str(i)] for i in range(len(values))]
            if (answer["type"] != "choice" or len(answer["probabilities"]) != len(values)
                    or any(not isinstance(p, (int, float)) or not math.isfinite(p)
                           or p < 0 or p > 1 for p in probabilities)
                    or abs(sum(probabilities) - 1) > len(values) * 0.005 + 1e-6):
                raise ValueError(f"invalid Jev {name} probabilities")
            selected[name] = max(range(len(values)), key=probabilities.__getitem__)
        return order_from_choices(selected), "jev"
    if strategy:
        body = json.dumps({"model": os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5"),
                           "max_tokens": 500, "system": system,
                           "messages": [{"role": "user", "content": user}]}).encode()
        request = urllib.request.Request(
            "https://api.anthropic.com/v1/messages", body,
            {"Content-Type": "application/json", "anthropic-version": "2023-06-01",
             "x-api-key": os.environ["ANTHROPIC_API_KEY"]}, method="POST")
        with urllib.request.urlopen(request, timeout=8) as response:
            return json.loads(json.load(response)["content"][0]["text"]), "llm"
    return default_order(view), "heuristic"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    seat = int(parse_qs(urlsplit(url).query)["slot"][0])
    strategy = os.environ.get("PLAYER_PROMPT", "")
    backend = ("jev" if os.environ.get("PHYSICS_BODIES_JEV") == "1"
               else "llm" if strategy else "heuristic")
    registration = json.dumps({"type": "register", "scripted": None,
                               "policy": os.environ.get("PLAYER_POLICY_LABEL", backend)[:48]}).encode()
    packet = bytes([0x81]) + len(registration).to_bytes(2, "little") + registration
    sent_again = False

    def on_open(socket: websocket.WebSocketApp) -> None:
        socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)

    def on_data(socket: websocket.WebSocketApp, data, opcode: int, _continued: bool) -> None:
        nonlocal sent_again
        if opcode == websocket.ABNF.OPCODE_BINARY:
            if not sent_again:
                socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)
                sent_again = True
            socket.send(bytes([0x85]), opcode=websocket.ABNF.OPCODE_BINARY)

    def on_message(socket: websocket.WebSocketApp, message: str) -> None:
        frame = json.loads(message)
        if frame["type"] == "turn":
            action, source = choose(frame["view"], strategy, seat)
            socket.send(json.dumps({"type": "decision", "turn": frame["turn"],
                                    "action": action, "source": source}))

    app = websocket.WebSocketApp(url,
                                 on_open=on_open, on_data=on_data,
                                 on_message=on_message)
    app.run_forever(reconnect=1)


if __name__ == "__main__":
    main()
