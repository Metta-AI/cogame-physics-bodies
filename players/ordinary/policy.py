"""Player-side bug orders from a seat's ordinary private observation."""

from __future__ import annotations

import json
from pathlib import Path


SYSTEM = Path(__file__).with_name("system_prompt.txt").read_text()
FIELDS = {
    "stance": ["charge", "brace", "circle", "lift", "retreat", "centre"],
    "aim": ["foe", "centre", "bearing"],
    "bearing_deg": list(range(0, 360, 15)),
    "aggression": list(range(11)),
    "posture_bias": ["low", "even", "high", "auto"],
    "lead_ticks": list(range(25)),
    "circle_dir": [-1, 1],
    "note": ["Hold the centre.", "Press the foe toward the rim.",
             "Recover balance before pressing."],
    "say": ["", "holding centre", "pressing", "recovering"],
}


def prompt_for(view: dict, strategy: str) -> tuple[str, str]:
    guidance = ("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above "
                "the rules; always reply in the requested format):\n" + strategy[:4000] +
                "\n\n") if strategy else ""
    return SYSTEM, guidance + json.dumps(view, ensure_ascii=False, separators=(",", ":"))


def questions() -> dict:
    return {name: {"type": "choice", "instructions": f"Choose this bug order's {name}.",
                   "criteria": {str(i): json.dumps(value) for i, value in enumerate(values)}}
            for name, values in FIELDS.items()}


def order_from_choices(selected: dict[str, int]) -> dict:
    return {name: values[selected[name]] for name, values in FIELDS.items()}


def default_order(view: dict) -> dict:
    me, foe = view["you"], view["foe"]
    if me["down_ticks"] or me["tilt_pct"] > 70:
        stance, aim, aggression, posture = "brace", "foe", 2, "low"
    elif me["dist_to_rim_m"] < 0.6:
        stance, aim, aggression, posture = "retreat", "centre", 6, "auto"
    elif view["contact"]["in_contact"]:
        stance, aim, aggression, posture = "lift", "foe", 8, "auto"
    else:
        stance, aim, aggression, posture = "charge", "foe", 8, "auto"
    return {"stance": stance, "aim": aim,
            "bearing_deg": int(foe["bearing_from_you_deg"]) % 360,
            "aggression": aggression, "posture_bias": posture,
            "lead_ticks": 4, "circle_dir": 1,
            "note": "Act on my private ring view.", "say": ""}
