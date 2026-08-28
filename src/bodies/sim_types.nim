## Constants, enums and records for THE RING — two four-legged bugs sumo in a
## shrinking clay ring.
##
## Forked from `Metta-AI/coworld-ctf` (paintbot). Everything that is not
## arena-rule-specific is kept verbatim from that starter: `TargetFps` /
## `ReplayFps` / `PlaybackSpeeds` (every speed-coupled layer is keyed to them),
## the lull-scan window, the rune caps, the closed `reason`/`endRule` string
## vocabulary and the websocket route names.
##
## INTEGER DISCIPLINE. Every stored sim field is explicitly `int32`, `int64`,
## `uint8`, `bool` or an enum: Nim's `int` is 64-bit natively and 32-bit under
## `--cpu:wasm32`, and the replay's per-tick `gameHash` chain is re-derived by
## the wasm build of this same module. There is NO floating point anywhere under
## `src/bodies/{sim,ring,body,trig,sim_types,sim_config,sim_state}.nim`
## (grep-enforced by tests/test_determinism.nim).

const
  GameName* = "physics-bodies"
  GameVersion* = "1"
    ## GV1 (ring rules): two four-legged bugs, ring-out, 3-knockdown knockout,
    ## shrinking ring, best of five, zero-sum +-3.750.
    ##
    ## PREPEND-ONLY changelog (ctf's discipline, kept): a new number goes ABOVE
    ## this line with a `GVnn (short rule name): HEADLINE` first line, and
    ## tools/ci/check_gameversion.sh diffs that headline so two branches cannot
    ## silently claim one number for two different rules.

  ## --- Time (kept verbatim from ctf: sim_types.nim:317,376) ----------------
  ReplayFps* = 24
  TargetFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  ## --- Rune caps (kept verbatim from ctf) ----------------------------------
  MaxNoteRunes* = 160           ## intent `note` cap, in RUNES (never bytes).
  MaxSayRunes* = 48             ## a bug's `say` cap, in RUNES.
  MaxPolicyLabelRunes* = 48     ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxIntentRunes* = 480         ## whole serialized `intent` record cap.
  MaxPromptRunes* = 4000        ## PLAYER_PROMPT transport cap (truncate,
                                ## never reject).

  ## --- Closed end vocabularies (kept verbatim from ctf) --------------------
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleMatchWon* = "match_won"
  EndRuleFullTime* = "full_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  ## --- Websocket + HTTP routes (kept verbatim from ctf) --------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"
  DefaultHost* = "0.0.0.0"
  DefaultPort* = 8080

  MaxPlayers* = 2               ## one seat = one bug; num_agents is 2.
  BodyCount* = 2                ## two bugs in the ring, always.
  LegCount* = 4

  ## --- Board render space --------------------------------------------------
  ## 1 board pixel = 5 000 um, so the 9.60 x 6.40 m arena is 1920 x 1280
  ## logical map pixels (BOARD_ASPECT 1.5). 2 457 600 map pixels sits under
  ## ctf's MaxSupersampledMapPixels (8 000 000), so boardRenderScaleFor still
  ## returns RenderScale 2 and predictedViewerRenderBytes(1920, 1280) is
  ## ~216 MB against WasmViewerBudgetBytes 1 600 000 000 — 7x headroom.
  MapWidth* = 1920
  MapHeight* = 1280
  UmPerPixel* = 5_000

  ## --- Geometry (fixed; identical every episode) --------------------------
  ArenaW* = 9_600_000'i32       ## um (9.60 m)
  ArenaH* = 6_400_000'i32       ## um (6.40 m)
  RingCentreX* = 4_800_000'i32
  RingCentreY* = 3_200_000'i32
  RingRadius0* = 3_000_000'i32  ## 3.00 m at round start (6.00 m across)
  RingRadiusMin* = 1_800_000'i32
  ShrinkStartTick* = 144'i32    ## 6.0 s into a round
  ShrinkPerTick* = 4_000'i32    ## um/tick (0.096 m/s)
  TorsoRadius* = 300_000'i32
  FootRadius* = 110_000'i32
  StartRadius* = 1_900_000'i32
  LegBaseIdx*: array[LegCount, int32] = [0'i32, 8, 16, 24]
  ReachByPosture*: array[4, int32] = [620_000'i32, 460_000, 300_000, 540_000]

  ## --- Actuation and dynamics (posture order: low, even, high, lift) ------
  ThrustUnit* = 3_600'i32
  TractionMulPct*: array[4, int32] = [130'i32, 100, 70, 90]
  FricNumPer1024*: array[4, int32] = [40'i32, 26, 16, 32]
  MaxSpeedByPosture*: array[4, int32] = [95_000'i32, 135_000, 165_000, 115_000]
  MaxBodySpeedHard* = 260_000'i32
  RestFloorUm* = 64'i32
    ## Integer friction has a floor: `v -= (v * FricNum) div 1024` stops
    ## changing `v` once `v * FricNum < 1024`, so a coasting bug would keep a
    ## few micrometres per tick of drift FOREVER. Anything under this (0.0015
    ## m/s) is snapped to rest after the friction step, which is what makes
    ## "a brace brakes to |v| = 0" true rather than nearly true.
  YawGainPct*: array[4, int32] = [70'i32, 100, 130, 90]
  YawAccelMilli* = 120'i32
  MaxYawMilli* = 900'i32
  YawDragNumPer1024* = 180'i32
  Restitution* = 1_200'i32      ## Q12; 0.293 rebound on a body-body normal.
  ShoveUnit* = 6_200'i32
  ShoveMulPct*: array[4, int32] = [110'i32, 100, 80, 150]
  TipImpulseThreshUm* = 26_000'i32
  TipPerUmDiv* = 40'i32
  LiftTipMilli* = 60'i32
  LiftSelfTipMilli* = 20'i32
  TipRecvMulPct*: array[4, int32] = [60'i32, 100, 140, 100]
  SpinTipMilli* = 600'i32
  TipRecoverMilli* = 26'i32
  TipDown* = 1_000'i32
  DownTicksDefault* = 36'i32
  KnockdownsToLoseDefault* = 3'i32
  CentreTieUm* = 20_000'i32

  ## --- Match shape --------------------------------------------------------
  TurnTicksDefault* = 36
  RoundTicksDefault* = 396
  ResetTicksDefault* = 36
  MaxRoundsDefault* = 5
  RoundsToClinchDefault* = 3
  MaxTicksDefault* = 2160
  MaxTicks* = MaxTicksDefault

  ## --- Scoring (micro-points; 1e-6 of a score point) ----------------------
  RoundWinMicro* = 1_000_000'i64
  RingOutBonusMicro* = 250_000'i64
  KnockoutBonusMicro* = 250_000'i64

  ## --- Decision layer defaults -------------------------------------------
  TurnBudgetMsDefault* = 16_000
  Attempt1MsDefault* = 9_000
  RetryMsDefault* = 5_000
  TurnSpacingMsDefault* = 6_000
  WallClockBudgetSecondsDefault* = 660
  LobbyJoinTimeoutTicksDefault* = 720
  StartWaitTicksDefault* = 5 * TargetFps
  GameOverTicksDefault* = 3 * TargetFps
  MaxOutputTokensDefault* = 900

  BugAliases*: array[BodyCount, string] = ["BUG-1", "BUG-2"]
  SideNames*: array[BodyCount, string] = ["bug1", "bug2"]

type
  BodiesError* = object of CatchableError
    ## Every refusal the sim raises (join errors, config errors, replay
    ## errors that are ours).

  SimGuardError* = object of BodiesError
    ## A step-12 invariant guard tripped: the episode ends `fault/sim_fault`
    ## with a partial replay, never a silent non-zero exit.

  Posture* = enum
    ## The command byte's 2-bit posture field. Array order everywhere.
    postureLow = "low"
    postureEven = "even"
    postureHigh = "high"
    postureLift = "lift"

  GamePhase* = enum
    Lobby
    Playing
    RoundReset
    GameOver

  RoundReason* = enum
    roundNone = "none"
    roundRingOut = "ring_out"
    roundKnockout = "knockout"
    roundDecision = "decision"
    roundDraw = "draw"

  SimEventKind* = enum
    ## The tier-2 analysis stream (COGAME_EVENTS_URI). Never enters gameHash.
    Contact
    Shove
    Stagger
    Knockdown
    RimSlip
    RingOut
    RoundEnd
    Intent
    PhaseChange

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting body index, -1 = n/a.
    target*: int               ## receiving body index, -1 = n/a.
    detail*: string            ## kind-specific label ("" = n/a).
    amount*: int               ## impulse um / tilt milli / turn index / 0.
    x*, y*: int                ## um, sim coordinates.
    content*: string           ## sanitized note/say text ("" = n/a).

  Body* = object
    ## One bug: a rigid torso disc on four posture-driven kinematic legs.
    ## Every field is hashed except `lastCmd`'s decode caches, which are
    ## derived from it.
    px*, py*: int32            ## torso centre, um.
    vx*, vy*: int32            ## velocity, um/tick.
    hMilli*: int32             ## heading, milli direction-index 0..31999.
    omegaMilli*: int32         ## yaw rate, milli-index/tick.
    tipMilli*: int32           ## tilt, 0..1000.
    downTicks*: int32
    groundedCount*: int32      ## 1..4 while up, 0 while Down.
    knockdowns*: int32         ## this ROUND.
    contacts*: int32           ## whole episode.
    shoveImpulseUm*: int64     ## whole episode.
    lastCmd*: uint8            ## the byte applied this tick (drive/posture/
                               ## effort); hashed via its decode.
    reach*: int32              ## derived: ReachByPosture[posture].
    footX*: array[LegCount, int32]
    footY*: array[LegCount, int32]
    footGrounded*: array[LegCount, bool]

  RoundLogEntry* = object
    round*: int32
    winner*: int32             ## body index, -1 = draw.
    reason*: RoundReason
    ticks*: int32
    knockdowns*: array[BodyCount, int32]

  ContactFx* = object
    ## Broadcast-only contact flash (never hashed): where the last contact
    ## landed, how hard, along which normal.
    tick*: int32
    x*, y*: int32
    impulseUm*: int32
    normalIdx*: int32
    lift*: bool

  SlotConfig* = object
    alias*: string
    token*: string

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    ## Every settable field. `config_schema` in the manifest template covers
    ## exactly these (tests/test_manifest.nim asserts the coverage).
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    slots*: seq[SlotConfig]
    closedRoster*: bool
    seed*: int
    numAgents*: int
    minPlayers*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    roundTicks*: int
    resetTicks*: int
    maxRounds*: int
    roundsToClinch*: int
    ringRadiusUm*: int
    ringRadiusMinUm*: int
    ringShrinkPerTickUm*: int
    shrinkStartTick*: int
    knockdownsToLose*: int
    downTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    speed*: int

  Player* = object
    ## One SEAT. `body` is the bug this seat drives (perm[joinOrder]).
    address*: string           ## the REAL policy name; spectator side only.
    token*: string
    joinOrder*: int            ## the stable seat slot.
    body*: int                 ## perm[joinOrder]; the bug it drives.
    reward*: int

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    bodies*: array[BodyCount, Body]
    perm*: array[BodyCount, int32]      ## seat -> body.
    invPerm*: array[BodyCount, int32]   ## body -> input index.
    startAxis*: array[MaxRoundsDefault, int32]
    axisDrawn*: int32          ## how many start axes have been drawn.
    ringRadiusNow*: int32
    roundIndex*: int32
    roundTick*: int32
    resetLeft*: int32          ## ticks left in the between-rounds hold.
    roundsWon*: array[BodyCount, int32]
    roundMicro*: array[BodyCount, int64]
    ringOuts*: array[BodyCount, int32]
    knockouts*: array[BodyCount, int32]
    knockdownsSuffered*: array[BodyCount, int32]
    effortSum*: array[BodyCount, int64]
    effortTicks*: array[BodyCount, int64]
    roundLog*: seq[RoundLogEntry]
    phase*: GamePhase
    tickCount*: int
    gameStartTick*: int
    lobbyTicks*: int
    lobbyNoShowSeat*: int32    ## seat the lobby budget expired on, -1 = none.
    gameOverTicks*: int
    rngState*: uint64
    rngDraws*: int32
    winner*: int32             ## body index, -1 = draw / undecided.
    isDraw*: bool
    timeLimitReached*: bool
    endReason*: string
    endRule*: string
    stopTick*: int32           ## the wall-clock stop tick, -1 = none.
    ## --- broadcast/analysis side, never hashed -----------------------------
    seatNames*: array[BodyCount, string]
    seatPolicyKind*: array[BodyCount, string]
    seatEffortPct*: array[BodyCount, int32]
    llmTurns*: array[BodyCount, int32]
    fallbackTurns*: array[BodyCount, int32]
    lastFx*: ContactFx
    feedIntents*: seq[string]
    events*: seq[SimEvent]
    collectEvents*: bool
    gameEventLoggingEnabled*: bool
    needsReregister*: bool

proc postureOf*(index: int32): Posture =
  ## The posture for a byte field value, saturating rather than raising: the
  ## command byte uses its whole 256-value range, so this cannot be reached
  ## out of range from the wire, only from a bug in a caller.
  Posture(clamp(int(index), 0, 3))

proc alias*(bodyIndex: int): string =
  ## The ANONYMOUS in-game name of one bug. This is the only name any seat
  ## ever sees; real policy names live spectator-side (roster/results/endcard).
  if bodyIndex >= 0 and bodyIndex < BodyCount: BugAliases[bodyIndex] else: "BUG-?"

proc sideText*(bodyIndex: int): string =
  ## The chrome's team key for one bug ("bug1" / "bug2").
  if bodyIndex >= 0 and bodyIndex < BodyCount: SideNames[bodyIndex] else: "bug?"
