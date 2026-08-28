## Join / auth / results.
##
## One SEAT is one bug. `perm` maps seat -> body and is drawn once at t = 0
## from the seeded stream; it is written into the replay config JSON and into
## `results.bodies`, and is NEVER visible to any seat.

import std/[json, strutils]
import sim_types, sim_state, labels

proc nextPlayerSlot*(sim: SimServer): int =
  ## Joins are strictly slot-sequential, so the seat the lobby is waiting on
  ## is always exactly this.
  sim.players.len

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.seatCount()

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  for player in sim.players:
    if player.address == address:
      return true
  false

proc resolvePlayerSlot*(sim: SimServer, address, token: string,
                        requestedSlot: int): int =
  ## The seat one websocket resolves to. A requested slot is honoured when it
  ## is legal; otherwise the next open one. A slot with a configured token
  ## demands exactly that token.
  if requestedSlot >= 0:
    if requestedSlot >= sim.seatCount():
      raise newException(BodiesError,
        "Player slot must be between 0 and " & $(sim.seatCount() - 1) & ".")
    if requestedSlot < sim.config.slots.len and
        sim.config.slots[requestedSlot].token.len > 0 and
        sim.config.slots[requestedSlot].token != token:
      raise newException(BodiesError,
        "Player token does not match configured slot " & $requestedSlot & ".")
    return requestedSlot
  if token.len > 0:
    for i in 0 ..< sim.config.slots.len:
      if sim.config.slots[i].token.len > 0 and
          sim.config.slots[i].token == token:
        return i
  sim.nextPlayerSlot()

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live seat. The BODIES are fixed for the whole episode — a
  ## dropped seat's bug keeps playing on the `pusher` baseline, so nothing
  ## here touches `bodies` or `perm`.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.players.delete(playerIndex)

proc addPlayer*(sim: var SimServer, address: string, requestedSlot = -1,
                token = "", trusted = false): int =
  ## Seats one player. Returns its live index, which for this game is also its
  ## seat slot (seats never leave a hole: a drop keeps playing scripted).
  if not sim.canAddPlayer():
    raise newException(BodiesError,
      "Match is full (" & $sim.seatCount() & " seats).")
  if sim.playerAddressOccupied(address):
    raise newException(BodiesError, "Player name is already connected.")
  let order =
    if trusted: (if requestedSlot >= 0: requestedSlot else: sim.players.len)
    else: sim.resolvePlayerSlot(address, token, requestedSlot)
  if not trusted and order != sim.nextPlayerSlot():
    raise newException(BodiesError,
      "Player slot " & $order & " cannot join before slot " &
        $sim.nextPlayerSlot() & ".")
  sim.players.add Player(
    address: address,
    token: token,
    joinOrder: order,
    body: int(sim.perm[clamp(order, 0, BodyCount - 1)]),
    reward: 0
  )
  if order >= 0 and order < BodyCount:
    sim.seatNames[order] = address
  sim.players.high

proc seatOfBody*(sim: SimServer, bodyIndex: int): int =
  ## Which SEAT drives one bug, or -1 when no seat does (a no-show's bug plays
  ## the `pusher` baseline for the whole run).
  for s in 0 ..< sim.seatCount():
    if int(sim.perm[s]) == bodyIndex:
      return s
  -1

proc bodyOfSeat*(sim: SimServer, seat: int): int =
  if seat < 0 or seat >= BodyCount: -1 else: int(sim.perm[seat])

proc inputIndexOfBody*(sim: SimServer, bodyIndex: int): int =
  ## The replay input row one bug's command byte is recorded on. This is the
  ## seat index whenever a seat drives the bug, and stays a stable 0/1 row when
  ## none does — `perm` is a permutation of `0 .. 1` either way, so its inverse
  ## is always defined and the action log is always complete.
  if bodyIndex >= 0 and bodyIndex < BodyCount:
    int(sim.invPerm[bodyIndex])
  else:
    0

proc rawScoreMicro*(sim: SimServer, seat: int): int64 =
  let body = sim.bodyOfSeat(seat)
  if body < 0: 0'i64 else: sim.roundMicro[body]

proc seatScoreMicro*(sim: SimServer, seat: int): int64 =
  ## The zero-sum score: my banked points minus the other seat's, in
  ## micro-points. `seatScoreMicro(0) + seatScoreMicro(1) == 0` exactly, by
  ## construction — it is one subtraction and its negation.
  let other = 1 - seat
  sim.rawScoreMicro(seat) - sim.rawScoreMicro(other)

proc meanEffortPct*(sim: SimServer, bodyIndex: int): int =
  if bodyIndex < 0 or bodyIndex >= BodyCount:
    return 0
  let ticks = sim.effortTicks[bodyIndex]
  if ticks <= 0:
    return 0
  int((sim.effortSum[bodyIndex] * 100) div (ticks * 3))

proc playerResultsJson*(sim: SimServer): string =
  ## The results document, written to COGAME_RESULTS_URI. It must equal the
  ## manifest's `results_schema` KEY FOR KEY — that schema is
  ## `additionalProperties: false` and the certifier rejects any unknown
  ## field, so adding or removing a key here means editing
  ## `coworld_manifest_template.json` in the same commit. 21 keys.
  var
    names = newJArray()
    aliases = newJArray()
    bodies = newJArray()
    policyKinds = newJArray()
    scores = newJArray()
    win = newJArray()
    roundsWon = newJArray()
    roundResults = newJArray()
    ringOuts = newJArray()
    knockouts = newJArray()
    knockdownsSuffered = newJArray()
    contacts = newJArray()
    shoveImpulse = newJArray()
    meanEffort = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in 0 ..< BodyCount:
    let body = int(sim.perm[seat])
    names.add %(
      if sim.seatNames[seat].len > 0: sim.seatNames[seat]
      else: "player-" & $seat)
    aliases.add %alias(body)
    bodies.add %body
    policyKinds.add %(
      if sim.seatPolicyKind[seat].len > 0: sim.seatPolicyKind[seat]
      else: "scripted")
    scores.add %round3(float(sim.seatScoreMicro(seat)) / 1_000_000.0)
    ## `win` is [false, false] exactly when the round tally ties, which Elo
    ## reads as a draw, which it is.
    win.add %(sim.roundsWon[body] > sim.roundsWon[1 - body])
    roundsWon.add %int(sim.roundsWon[body])
    ringOuts.add %int(sim.ringOuts[body])
    knockouts.add %int(sim.knockouts[body])
    knockdownsSuffered.add %int(sim.knockdownsSuffered[body])
    contacts.add %int(sim.bodies[body].contacts)
    shoveImpulse.add %round2(
      float(sim.bodies[body].shoveImpulseUm) / 1_000_000.0)
    meanEffort.add %sim.meanEffortPct(body)
    llmTurns.add %int(sim.llmTurns[seat])
    fallbackTurns.add %int(sim.fallbackTurns[seat])
  for entry in sim.roundLog:
    roundResults.add %*{
      "round": int(entry.round),
      "winner": int(entry.winner),
      "reason": $entry.reason,
      "ticks": int(entry.ticks),
      "knockdowns": [int(entry.knockdowns[0]), int(entry.knockdowns[1])]
    }
  var results = newJObject()
  results["names"] = names
  results["aliases"] = aliases
  results["bodies"] = bodies
  results["policyKinds"] = policyKinds
  results["scores"] = scores
  results["win"] = win
  results["roundsWon"] = roundsWon
  results["roundResults"] = roundResults
  results["ringOuts"] = ringOuts
  results["knockouts"] = knockouts
  results["knockdownsSuffered"] = knockdownsSuffered
  results["contacts"] = contacts
  results["shoveImpulse"] = shoveImpulse
  results["meanEffortPct"] = meanEffort
  results["llmTurns"] = llmTurns
  results["fallbackTurns"] = fallbackTurns
  results["rounds"] = %sim.roundLog.len
  results["finalTick"] = %sim.tickCount
  results["reason"] = %(
    if sim.endReason.len > 0: sim.endReason else: ReasonComplete)
  results["endRule"] = %(
    if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime)
  results["seed"] = %sim.config.seed
  $results

proc policyName*(name: string): string =
  ## Strips the per-seat " (N)" suffix the hosted runtime appends to one
  ## policy's multiple connections, so every seat of a policy collapses to one
  ## spectator-side identity.
  var text = name.strip()
  if text.endsWith(")"):
    let open = text.rfind('(')
    if open > 0:
      var allDigits = open + 1 < text.len - 1
      for i in open + 1 ..< text.len - 1:
        if text[i] notin {'0' .. '9'}:
          allDigits = false
      if allDigits:
        text = text[0 ..< open].strip(chars = {' ', '_'}, leading = false)
  text
