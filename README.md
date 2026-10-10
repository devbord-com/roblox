# devbord reports for Roblox

A ModuleScript that turns bug reports from players into cards on devbord. Every card carries the player, the place
version, the server and the position of the character. When the card is completed on devbord, the player can be told
that the bug was fixed.

## Install

1. In devbord, create an **API key with the "Report only" scope** on the board for bugs and pick the list the reports go
   to (board menu › Integrations › API keys). Such a key cannot read or change anything. This needs the Standard plan or higher: Standard includes 50 reports a month, Premium has no monthly limit.
2. In Roblox Studio: Game Settings › Security › enable **Allow HTTP Requests**, and add a secret named `devbord_key`
   with the key as its value.
3. Add `DevbordReports.lua` as a ModuleScript named `DevbordReports` in ServerScriptService.
4. Add `Example.server.lua` as a Script next to it for a ready-made `/bug` command, or call the module from your own code.

## Use

```lua
local Reports = require(game.ServerScriptService.DevbordReports).new({
	url = "https://devbord.com",
	key = game:GetService("HttpService"):GetSecret("devbord_key"),
	onFixed = function(player, number) end, -- the card was completed while the player is in this server
})

local result = Reports:report(player, "The shop door does not open", {
	fingerprint = "shop:door",        -- reports with the same fingerprint are collected on one card
	fields = { Level = "Docks" },     -- extra facts on the card
	logs = debug.traceback(),         -- shown as a code block
	priority = "high",
})
-- result.ok, result.number, result.duplicate, result.receipt, result.code, result.error
```

`report` yields while the request is in flight and never throws. It applies a cooldown per player (120 seconds by
default) on top of the limit of the key on devbord (120 reports per hour by default, adjustable on the key).

## Notes

- The module runs on the server only. Never put the key in a LocalScript or in ReplicatedStorage.
- To tell players about fixed bugs, the module stores the receipt and the user ID of each report in the data store
  `DevbordReports` and asks devbord for the status every 5 minutes. Pass `notifyFixed = false` to turn this off.
- This module has been syntax-checked but not yet run inside Roblox; test it in Studio before you publish.
