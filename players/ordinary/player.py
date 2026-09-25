"""Physics Bodies orders over the ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.request

import websocket

from policy import default_order, prompt_for


def choose(view: dict, strategy: str) -> tuple[dict, str]:
    system, user = prompt_for(view, strategy)
    if strategy:
        body = json.dumps({"model": os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001"),
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
    strategy = os.environ.get("PLAYER_PROMPT", "")
    backend = "llm" if strategy else "heuristic"
    registration = json.dumps({"type": "register", "kind": "external", "scripted": None,
                               "policy": os.environ.get("PLAYER_POLICY_LABEL", backend)[:48]}).encode()
    packet = bytes([0x81]) + len(registration).to_bytes(2, "little") + registration
    connected_once = False
    failed_dials = 0
    while failed_dials < (6 if connected_once else 240):
        opened = False
        sent_again = False

        def on_open(socket: websocket.WebSocketApp) -> None:
            nonlocal opened
            opened = True
            socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)

        def on_data(socket: websocket.WebSocketApp, data, opcode: int, _continued: bool) -> None:
            nonlocal sent_again
            if opcode == websocket.ABNF.OPCODE_BINARY:
                if not sent_again:
                    socket.send(packet, opcode=websocket.ABNF.OPCODE_BINARY)
                    sent_again = True
                socket.send(bytes([0x85]), opcode=websocket.ABNF.OPCODE_BINARY)

        def on_message(socket: websocket.WebSocketApp, message: str | bytes) -> None:
            if isinstance(message, bytes):
                return
            frame = json.loads(message)
            if frame["type"] == "turn":
                if backend == "llm" and not os.environ.get("ANTHROPIC_API_KEY"):
                    socket.send(json.dumps({"type": "decision", "id": frame["id"],
                                            "cause": "no_credentials",
                                            "error": "prompt credential unavailable"}))
                    return
                action, source = choose(frame["view"], strategy)
                socket.send(json.dumps({"type": "decision", "id": frame["id"],
                                        "turn": frame["turn"],
                                        "action": action, "source": source}))

        app = websocket.WebSocketApp(url,
                                     on_open=on_open, on_data=on_data,
                                     on_message=on_message)
        app.run_forever()
        if opened:
            connected_once = True
            failed_dials = 0
        failed_dials += 1
        time.sleep(0.5)


if __name__ == "__main__":
    main()
