## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
##
## Both paths must produce byte-identical rows: a consumer cannot be asked to
## tell them apart, and a second serializer would drift the moment a field is
## added. `SimEvent` never enters `gameHash`, so nothing here can affect
## determinism.

import std/json
import sim

proc key*(kind: SimEventKind): string =
  ## The JSON event key for one tier-2 event kind.
  case kind
  of Contact: "contact"
  of Shove: "shove"
  of Stagger: "stagger"
  of Knockdown: "knockdown"
  of RimSlip: "rim_slip"
  of RingOut: "ring_out"
  of RoundEnd: "round_end"
  of Intent: "intent"
  of PhaseChange: "phase"

proc jsonRow*(event: SimEvent): JsonNode =
  ## One JSON-lines row for a tier-2 sim event.
  %*{
    "tick": event.tick,
    "kind": event.kind.key(),
    "source": event.source,
    "target": event.target,
    "detail": event.detail,
    "amount": event.amount,
    "x": event.x,
    "y": event.y,
    "content": event.content
  }

proc eventsJsonl*(events: openArray[SimEvent], ticks: int,
                  summaryExtra: JsonNode = nil): string =
  ## The full JSON-lines stream: one row per event, then a SUMMARY row.
  ##
  ## The trailing summary is part of the contract, not decoration — it is how a
  ## reader distinguishes "this episode had no events" from "the file was
  ## truncated", and it carries the GameVersion the events were produced under
  ## so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
