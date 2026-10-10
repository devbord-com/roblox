-- DevbordReports: turns in-game bug reports into cards on devbord.
-- Place this ModuleScript in ServerScriptService. It only runs on the server: the API key never reaches players.
--
--   local Reports = require(game.ServerScriptService.DevbordReports).new({
--     url = "https://devbord.com",
--     key = HttpService:GetSecret("devbord_key"), -- a "Report only" key; a plain string works too
--   })
--   local result = Reports:report(player, "The shop door does not open", { fingerprint = "shop:door" })

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local DevbordReports = {}
DevbordReports.__index = DevbordReports

---@class DevbordOptions
---@field url string base address of devbord, e.g. "https://devbord.com"
---@field key any a "Report only" API key: a string or a Secret from HttpService:GetSecret
---@field cooldown? number seconds a player has to wait between two reports (default 120)
---@field minLength? number shortest description that is accepted (default 8)
---@field labels? string[] labels for new cards (default { "Bug" })
---@field notifyFixed? boolean follow reports and call onFixed when the card is completed (default true)
---@field checkInterval? number seconds between two status checks (default 300)
---@field onFixed? fun(player: Player, number: number) called when a report of an online player was fixed

---@class DevbordReportOptions
---@field title? string card title; defaults to the first line of the description
---@field fingerprint? string reports with the same fingerprint are collected on one open card
---@field fields? table<string, any> extra facts shown on the card, e.g. { Level = "Docks" }
---@field logs? string output or a stack trace, shown as a code block
---@field priority? string "low", "normal", "high" or "urgent"
---@field labels? string[] overrides the default labels

---@class DevbordResult
---@field ok boolean
---@field number? number card number on the board
---@field duplicate? boolean true when the report was added to an existing card
---@field receipt? string keep this to ask for the status later
---@field error? string what went wrong, for the server log
---@field code? string stable error code from the API, or "cooldown", "too_short", "http"

---@param options DevbordOptions
---@return table reports
function DevbordReports.new(options)
	assert(type(options) == "table" and type(options.url) == "string" and options.key ~= nil, "DevbordReports.new needs url and key")
	local self = setmetatable({}, DevbordReports)
	self.url = string.gsub(options.url, "/+$", "")
	self.key = options.key
	self.cooldown = options.cooldown or 120
	self.minLength = options.minLength or 8
	self.labels = options.labels or { "Bug" }
	self.onFixed = options.onFixed
	self.lastReport = {}
	self.store = nil
	if options.notifyFixed ~= false then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore("DevbordReports")
		end)
		if ok then
			self.store = store
			self:_follow(options.checkInterval or 300)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		self.lastReport[player.UserId] = nil
	end)
	return self
end

function DevbordReports:_authorization()
	if type(self.key) == "string" then
		return "Bearer " .. self.key
	end
	return self.key:AddPrefix("Bearer ")
end

function DevbordReports:_request(method, path, body, idempotencyKey)
	local headers = { ["Content-Type"] = "application/json", ["Authorization"] = self:_authorization() }
	if idempotencyKey then
		headers["Idempotency-Key"] = idempotencyKey
	end
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = self.url .. "/api/v1" .. path, Method = method, Headers = headers, Body = body and HttpService:JSONEncode(body) or nil })
	end)
	if not ok then
		return nil, { error = tostring(response), code = "http" }
	end
	local decoded
	local parsed = pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	if not parsed or type(decoded) ~= "table" then
		decoded = {}
	end
	if not response.Success then
		return nil, { error = decoded.error or ("HTTP " .. tostring(response.StatusCode)), code = decoded.code or "http" }
	end
	return decoded, nil
end

---Sends a report for a player. Yields while the request is in flight.
---@param player Player
---@param description string
---@param options? DevbordReportOptions
---@return DevbordResult
function DevbordReports:report(player, description, options)
	options = options or {}
	description = string.sub(string.gsub(tostring(description or ""), "^%s*(.-)%s*$", "%1"), 1, 4000)
	if #description < self.minLength then
		return { ok = false, code = "too_short", error = "description is too short" }
	end
	local now = os.time()
	local last = self.lastReport[player.UserId]
	if last and now - last < self.cooldown then
		return { ok = false, code = "cooldown", error = "wait " .. tostring(self.cooldown - (now - last)) .. " seconds" }
	end
	self.lastReport[player.UserId] = now

	local fields = { Place = tostring(game.PlaceId), ["Place version"] = tostring(game.PlaceVersion), Server = game.JobId }
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local p = root.Position
		fields.Position = string.format("%.1f, %.1f, %.1f", p.X, p.Y, p.Z)
	end
	for name, value in pairs(options.fields or {}) do
		fields[name] = value
	end

	local result, err = self:_request("POST", "/reports", {
		title = options.title,
		description = description,
		reporter = { ref = tostring(player.UserId), name = player.Name },
		fingerprint = options.fingerprint,
		fields = fields,
		logs = options.logs,
		priority = options.priority,
		labels = options.labels or self.labels,
	}, HttpService:GenerateGUID(false))
	if not result then
		self.lastReport[player.UserId] = nil
		return { ok = false, code = err.code, error = err.error }
	end
	if self.store and result.receipt then
		pcall(function()
			self.store:SetAsync("r_" .. result.receipt, { user = player.UserId, number = result.number, at = now })
			self.store:UpdateAsync("open", function(open)
				open = open or {}
				table.insert(open, result.receipt)
				-- keep the list bounded: the oldest reports stop being followed
				while #open > 200 do
					table.remove(open, 1)
				end
				return open
			end)
		end)
	end
	return { ok = true, number = result.number, duplicate = result.duplicate, receipt = result.receipt }
end

---Asks devbord for the state of reports: "open", "completed", "archived" or "unknown".
---@param receipts string[] at most 100
---@return table[]? states one { receipt, state, number, list } per receipt, or nil when the request failed
function DevbordReports:status(receipts)
	local result = self:_request("POST", "/reports/status", { receipts = receipts })
	return result
end

function DevbordReports:_checkFixed()
	local ok, open = pcall(function()
		return self.store:GetAsync("open")
	end)
	if not ok or type(open) ~= "table" or #open == 0 then
		return
	end
	local batch = {}
	for i = 1, math.min(#open, 100) do
		batch[i] = open[i]
	end
	local states = self:status(batch)
	if not states then
		return
	end
	local done = {}
	for _, item in ipairs(states) do
		if item.state ~= "open" then
			local found, entry = pcall(function()
				return self.store:GetAsync("r_" .. item.receipt)
			end)
			local player = found and entry and Players:GetPlayerByUserId(entry.user)
			-- a fixed report stays followed until its reporter is in this server, for at most 30 days
			local waiting = item.state == "completed" and found and entry and not player and os.time() - (entry.at or 0) < 30 * 86400
			if not waiting then
				done[item.receipt] = true
				if item.state == "completed" and player and self.onFixed then
					task.spawn(self.onFixed, player, entry.number)
				end
				pcall(function()
					self.store:RemoveAsync("r_" .. item.receipt)
				end)
			end
		end
	end
	pcall(function()
		self.store:UpdateAsync("open", function(current)
			local kept = {}
			for _, receipt in ipairs(current or {}) do
				if not done[receipt] then
					table.insert(kept, receipt)
				end
			end
			return kept
		end)
	end)
end

function DevbordReports:_follow(interval)
	task.spawn(function()
		while true do
			task.wait(math.max(60, interval))
			self:_checkFixed()
		end
	end)
end

return DevbordReports
