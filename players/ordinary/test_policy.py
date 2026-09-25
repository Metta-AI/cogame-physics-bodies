"""Ordinary Physics Bodies player decisions."""

import io
import json
import os
import unittest
from unittest.mock import patch

from player import choose
from policy import default_order


class PolicyTest(unittest.TestCase):
    def test_default_uses_private_view(self) -> None:
        view = {"you": {"down_ticks": 0, "tilt_pct": 10, "dist_to_rim_m": 0.4},
                "foe": {"bearing_from_you_deg": 91},
                "contact": {"in_contact": False}}
        order = default_order(view)
        self.assertEqual(order["stance"], "retreat")
        self.assertEqual(order["aim"], "centre")
        self.assertEqual(order["bearing_deg"], 91)

    def test_prompt_call_is_player_side(self) -> None:
        action = default_order({"you": {"down_ticks": 0, "tilt_pct": 10, "dist_to_rim_m": 0.4},
                                "foe": {"bearing_from_you_deg": 91},
                                "contact": {"in_contact": False}})
        response = io.BytesIO(json.dumps({"content": [{"text": json.dumps(action)}]}).encode())
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test"}, clear=True), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            result, source = choose({"you": {"alias": "BUG-1"}}, "hold the centre")
        self.assertEqual(source, "llm")
        self.assertEqual(result, action)
        self.assertEqual(urlopen.call_args.args[0].full_url,
                         "https://api.anthropic.com/v1/messages")


if __name__ == "__main__":
    unittest.main()
