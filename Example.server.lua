-- Example: a /bug chat command. Place this Script in ServerScriptService next to DevbordReports.
-- Enable "Allow HTTP Requests" in Game Settings > Security, and store the key as a secret named "devbord_key".

local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- shows a system message in the player's chat; add a LocalScript that listens to this RemoteEvent
local notify = Instance.new("RemoteEvent")
notify.Name = "DevbordNotify"
notify.Parent = ReplicatedStorage

local Reports = require(script.Parent.DevbordReports).new({
	url = "https://devbord.com",
	key = HttpService:GetSecret("devbord_key"),
	onFixed = function(player, number)
		notify:FireClient(player, "Good news: your bug report #" .. tostring(number) .. " was fixed.")
	end,
})

local command = Instance.new("TextChatCommand")
command.Name = "DevbordBug"
command.PrimaryAlias = "/bug"
command.Parent = TextChatService

command.Triggered:Connect(function(source, message)
	local player = Players:GetPlayerByUserId(source.UserId)
	if not player then
		return
	end
	local description = string.gsub(message, "^/bug%s*", "")
	local result = Reports:report(player, description)
	if result.ok then
		notify:FireClient(player, result.duplicate and ("Thanks! This bug was already reported (#" .. result.number .. "); your report was added.") or ("Thanks! Your report is on the board as #" .. result.number .. "."))
	elseif result.code == "cooldown" then
		notify:FireClient(player, "Please wait a moment before reporting another bug.")
	elseif result.code == "too_short" then
		notify:FireClient(player, "Usage: /bug <what went wrong and what you expected>")
	else
		warn("[devbord] report failed: " .. tostring(result.error))
		notify:FireClient(player, "Sending the bug report failed. Please try again later.")
	end
end)
