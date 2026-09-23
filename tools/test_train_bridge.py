"""Play both certified ring variants through the numeric training protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"physics-{variant}-{teacher}", "players": 2})
        widths = set()
        first_view = None
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [6, 3, 360, 11, 4, 25, 2]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_intent" in view
            if observation["seat"] == 0:
                first_view = (view["clock"], view["ring"])
            else:
                assert (view["clock"], view["ring"]) == first_view
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 400
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1"}
        assert abs(sum(observation["scores"].values())) < 1e-6
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for variant in ("default", "blitz"):
        for teacher in (True, False):
            play(binary, variant, teacher)
