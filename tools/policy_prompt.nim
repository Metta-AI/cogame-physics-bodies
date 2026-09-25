## Offline training exports use the same player prompt as the ordinary image.
import std/unicode

const SystemPrompt* = staticRead("../players/ordinary/system_prompt.txt")

proc userMessage*(strategy, viewJson: string): string =
  if strategy.len == 0:
    return viewJson
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    strategy.runeSubStr(0, 4000) & "\n\n" & viewJson
