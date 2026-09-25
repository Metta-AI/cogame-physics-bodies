"""The Jev player chooses independent fields of the ordinary bug order."""

import io
import json
import os
import unittest
from unittest.mock import patch

from player import choose
from policy import FIELDS, default_order, order_from_choices, questions


class PolicyTest(unittest.TestCase):
    def test_complete_order_from_independent_choices(self) -> None:
        selected = {name: len(values) - 1 for name, values in FIELDS.items()}
        order = order_from_choices(selected)
        self.assertEqual(set(order), set(FIELDS))
        self.assertEqual(order["stance"], "centre")
        self.assertEqual(order["bearing_deg"], 345)
        self.assertEqual(order["lead_ticks"], 24)
        self.assertEqual(set(questions()), set(order))

    def test_default_uses_private_view(self) -> None:
        view = {"you": {"down_ticks": 0, "tilt_pct": 10, "dist_to_rim_m": 0.4},
                "foe": {"bearing_from_you_deg": 91},
                "contact": {"in_contact": False}}
        order = default_order(view)
        self.assertEqual(order["stance"], "retreat")
        self.assertEqual(order["aim"], "centre")
        self.assertEqual(order["bearing_deg"], 91)

    def test_jev_ranks_every_order_field(self) -> None:
        answers = {name: {"type": "choice", "probabilities": {
            str(i): 1.0 if i == len(values) - 1 else 0.0
            for i in range(len(values))}}
            for name, values in FIELDS.items()}
        response = io.BytesIO(json.dumps({"answers": answers}).encode())
        with patch.dict(os.environ, {"PHYSICS_BODIES_JEV": "1", "TYPESAFE_API_KEY": "test"}), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            order, source = choose({"you": {"alias": "BUG-1"}}, "", 0)
        self.assertEqual(source, "jev")
        self.assertEqual(order["stance"], "centre")
        self.assertEqual(order["bearing_deg"], 345)
        request = urlopen.call_args.args[0]
        self.assertEqual(set(json.loads(request.data)["questions"]), set(FIELDS))
        self.assertIn('"alias":"BUG-1"', json.loads(request.data)["state"]["summary"])

    def test_prompt_call_is_player_side(self) -> None:
        action = {name: values[0] for name, values in FIELDS.items()}
        response = io.BytesIO(json.dumps({"content": [{"text": json.dumps(action)}]}).encode())
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test"}, clear=True), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            result, source = choose({"you": {"alias": "BUG-1"}}, "hold the centre", 0)
        self.assertEqual(source, "llm")
        self.assertEqual(result, action)
        self.assertEqual(urlopen.call_args.args[0].full_url,
                         "https://api.anthropic.com/v1/messages")

    def test_sidecar_call_has_seat_attribution(self) -> None:
        answers = {name: {"type": "choice", "probabilities": {
            str(i): 1.0 if i == 0 else 0.0 for i in range(len(values))}}
            for name, values in FIELDS.items()}
        response = io.BytesIO(json.dumps({"answers": answers}).encode())
        with patch.dict(os.environ, {"PHYSICS_BODIES_JEV": "1",
                                  "AWS_ENDPOINT_URL_BEDROCK_RUNTIME": "http://sidecar"}, clear=True), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            choose({"you": {"alias": "BUG-2"}}, "", 1)
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("X-coworld-player-slot"), "1")
        self.assertIsNone(request.get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
