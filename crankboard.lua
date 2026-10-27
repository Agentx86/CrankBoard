-- CrankBoard 0.4.0 by BitCaliberGames (https://bitcalibergames.itch.io/)
-- Online leaderboards for Playdate games, powered by Talo. MIT License. Documentation: README.md

import "CoreLibs/graphics"
import "CoreLibs/keyboard"
import "CoreLibs/nineslice"

local pd <const> = playdate
local gfx <const> = playdate.graphics
local net <const> = playdate.network

crankboard = {}
local M <const> = crankboard

M.version = "0.4.0"

M.SUBMITTED = "submitted"
M.QUEUED = "queued"
M.DENIED = "denied"
M.DECLINED = "declined"
M.LOCAL = "local"
M.FAILED = "failed"

local DEFAULT_MESSAGES <const> = {
	joinTitle = "New high score!",
	joinText = "Join the online leaderboard?\nYour name and score will be sent online.",
	yes = "Ⓐ Yes",
	no = "Ⓑ No",
	ok = "Ⓐ OK",
	accessReason = "Sends your high scores to the online leaderboard and shows the best players.",
	accessDenied = "Network access is disabled.\nEnable it in Settings > Permissions.",
	connectFailed = "Couldn't connect.\nCheck Wi-Fi and try again.",
	uploadFailed = "Couldn't connect.\nYour score is saved and will be sent next time.",
	rejected = "The score could not be submitted.",
	sending = "Sending score",
	submitted = "Score submitted!",
	submittedRank = "Score submitted!\nYou are #%d",
	rankLine = "%s: #%d",
	rankSeparator = "\n",
	loading = "Loading",
	wait = "Please wait",
	enterName = "Enter your name for the online leaderboard",
	leaderboardTitle = "Online Leaderboard",
	empty = "No scores yet.\nBe the first!",
	offlineNote = "No connection: scores from %s",
	justNow = "a moment ago",
	minutesAgo = "%d min ago",
	hoursAgo = "%d h ago",
	yesterday = "yesterday",
	daysAgo = "%d days ago",
	retry = "Ⓐ Retry",
	tabHint = "⬅️➡️ Board",
	scrollHint = "⬆️⬇️ Scroll",
	backHint = "Ⓑ Back",
	defaultName = "Player",
}

local DEFAULTS <const> = {
	host = "api.trytalo.com",
	port = 443,
	useSSL = true,
	basePath = "/v1",
	service = "playdate",
	askName = true,
	maxNameLength = 16,
	namePropKey = "name",
	devBuild = pd.isSimulator == 1,
	timeout = 20,
	connectTimeout = 10,
	maxPending = 60,
	topLimit = 50,
	saveFile = "crankboard",
	debug = false,
}

local MAX_PROP_KEY <const> = 128
local MAX_PROP_VALUE <const> = 512
local MAX_TOP <const> = 200

local cfg = nil
local msg = nil
local state = nil
local boards = {}

local flows = {}
local modalCount = 0
local backdrop = nil
local needBackdrop = false
local restoreBackdrop = false
local setupAt = 0
local updateCalled = false
local warnedNoUpdate = false

local BUTTONS <const> = {
	a = pd.kButtonA, b = pd.kButtonB, up = pd.kButtonUp, down = pd.kButtonDown,
	left = pd.kButtonLeft, right = pd.kButtonRight,
}
local INPUT_GUARD_MS <const> = 400

local function now()
	return pd.getCurrentTimeMilliseconds()
end

local function log(...)
	if cfg and cfg.debug then print("[crankboard]", ...) end
end

local function warn(...)
	print("[crankboard] WARNING:", ...)
end

local function unixTime()
	local s, ms = pd.getSecondsSinceEpoch()
	return s + 946684800, ms
end

local entropy = {}

local function addEntropy(tag)
	local s, ms = pd.getSecondsSinceEpoch()
	local sample = string.format("%s:%d.%d:%d:%d:%d:%d", tag, s, ms, now(),
		math.floor((pd.getElapsedTime() % 1) * 1000000),
		math.floor(pd.getCrankPosition() * 1000),
		math.floor((pd.getBatteryVoltage() or 0) * 1000))
	if pd.accelerometerIsRunning() then
		local x, y, z = pd.readAccelerometer()
		sample = sample .. string.format(":%.6f:%.6f:%.6f", x or 0, y or 0, z or 0)
	end
	entropy[#entropy + 1] = sample
	if #entropy > 64 then table.remove(entropy, 2) end
end

local function mix32(h)
	h = h & 0xffffffff
	h = ((h ~ (h >> 16)) * 0x85ebca6b) & 0xffffffff
	h = ((h ~ (h >> 13)) * 0xc2b2ae35) & 0xffffffff
	return (h ~ (h >> 16)) & 0xffffffff
end

local function hash32(text)
	local h = 0x811c9dc5
	for i = 1, #text do
		h = ((h ~ text:byte(i)) * 16777619) & 0xffffffff
	end
	return mix32(h)
end

local function newPlayerKey()
	addEntropy("key")
	local pool = table.concat(entropy, "|") .. tostring({})
	return string.format("pd-%08x%08x", hash32(pool .. "#1"), hash32(pool .. "#2"))
end

local function urlencode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function idstr(v)
	if type(v) == "number" then return string.format("%d", math.floor(v)) end
	return tostring(v)
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function defaultFormatScore(score)
	if type(score) == "number" and score == math.floor(score) then
		return string.format("%d", score)
	end
	return tostring(score)
end

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

local function normalizeProps(props)
	local out = {}
	for k, v in pairs(props or {}) do
		k = tostring(k)
		if #k > MAX_PROP_KEY then
			warn("prop key too long, skipped: " .. k:sub(1, 32) .. "...")
		else
			v = type(v) == "number" and defaultFormatScore(v) or tostring(v)
			if #v > MAX_PROP_VALUE then
				warn("prop '" .. k .. "' is longer than " .. MAX_PROP_VALUE .. " characters, truncated")
				v = v:sub(1, MAX_PROP_VALUE)
			end
			out[k] = v
		end
	end
	return out
end

local function propsMap(list)
	local out = {}
	for _, p in ipairs(list or {}) do
		if type(p) == "table" and p.key then out[p.key] = p.value end
	end
	return out
end

local function findBoard(name)
	for _, b in ipairs(boards) do
		if b.name == name then return b end
	end
	return nil
end

local function boardTitle(name)
	local b = findBoard(name)
	return b and b.title
end

local function boardShortTitle(name)
	local b = findBoard(name)
	return b and (b.shortTitle or b.title) or name
end

local function boardNames(list)
	local names = {}
	for i, b in ipairs(list) do
		names[i] = type(b) == "table" and b.name or b
	end
	return names
end

local function saveState()
	pd.datastore.write(state, cfg.saveFile)
end

local function loadState()
	state = { prompted = false, optedIn = false, pending = {} }
	local saved = pd.datastore.read(cfg.saveFile)
	if type(saved) == "table" then
		for k, v in pairs(saved) do state[k] = v end
	end
	if type(state.pending) ~= "table" then state.pending = {} end
end

local function playerKey()
	if not state.playerKey then
		state.playerKey = newPlayerKey()
		saveState()
	end
	return state.playerKey
end

local function addPending(lb, score, props)
	local ts, ms = unixTime()
	local item = { lb = lb, score = score, ts = ts, ms = ms, props = props }
	table.insert(state.pending, item)
	while #state.pending > cfg.maxPending do table.remove(state.pending, 1) end
	saveState()
	return item
end

local function defaultPlayerName()
	return msg.defaultName .. " " .. playerKey():sub(4, 7):upper()
end

local function isAscending(lb)
	for _, b in ipairs(boards) do
		if b.name == lb and b.ascending ~= nil then return b.ascending end
	end
	return cfg.ascending == true
end

local function beats(score, best, lb)
	if best == nil then return true end
	if isAscending(lb) then return score < best end
	return score > best
end

local function recordBest(lb, score, props)
	state.best = state.best or {}
	if not beats(score, state.best[lb], lb) then return false end
	state.best[lb] = score
	local ts, ms = unixTime()
	state.bestInfo = state.bestInfo or {}
	state.bestInfo[lb] = { ts = ts, ms = ms, props = props }
	saveState()
	return true
end

local function holdRun(lb, score, props)
	local ts, ms = unixTime()
	local day = ts // 86400
	state.held = state.held or {}
	for i, item in ipairs(state.held) do
		if item.lb == lb and item.ts // 86400 == day then
			if not beats(score, item.score, lb) then return end
			table.remove(state.held, i)
			break
		end
	end
	table.insert(state.held, { lb = lb, score = score, ts = ts, ms = ms, props = props })
	while #state.held > cfg.maxPending do table.remove(state.held, 1) end
	saveState()
end

local function releaseHeld()
	local queue = {}
	for _, item in ipairs(state.held or {}) do
		if findBoard(item.lb) then queue[#queue + 1] = item end
	end
	local covered = {}
	for _, list in ipairs({ queue, state.pending }) do
		for _, item in ipairs(list) do
			if state.best and item.score == state.best[item.lb] then covered[item.lb] = true end
		end
	end
	for _, b in ipairs(boards) do
		local best = state.best and state.best[b.name]
		if best ~= nil and not covered[b.name] then
			local info = state.bestInfo and state.bestInfo[b.name] or {}
			queue[#queue + 1] = { lb = b.name, score = best, ts = info.ts, ms = info.ms, props = info.props }
		end
	end
	for _, item in ipairs(state.pending) do queue[#queue + 1] = item end
	while #queue > cfg.maxPending do table.remove(queue, 1) end
	state.pending = queue
	state.held = nil
	saveState()
end

local SCREEN_W <const> = 400
local SCREEN_H <const> = 240

local DEFAULT_STYLE <const> = {
	dialogWidth = 320,
	padding = 14,
	cornerRadius = 8,
	borderWidth = 2,
	doubleBorder = false,
	inverted = false,
	dim = 0.5,
	buttons = "text",
	tabs = "bar",
	ownRow = "fill",
	rowHeight = 20,
	headerHeight = 26,
	visibleRows = nil,
	frame = nil,
	boardFrame = nil,
	frameInset = nil,
	icons = {},
	font = nil,
	titleFont = nil,
	ownFont = nil,
	buttonFont = nil,
	titleScale = 1,
	textMode = "fill",
}

local DEFAULT_SOUNDS <const> = {
	confirm = "CoreLibs/assets/sfx/selection",
	cancel = "CoreLibs/assets/sfx/selection-reverse",
	move = "CoreLibs/assets/sfx/click",
	error = "CoreLibs/assets/sfx/denial",
	success = "CoreLibs/assets/sfx/selection",
}

local S = nil
local imageCache, frameCache, soundCache = {}, {}, {}

local function loadFont(src, fallback)
	if type(src) == "string" then
		local font = gfx.font.new(src)
		if not font then warn("font not found: " .. src) end
		return font or fallback
	end
	return src or fallback
end

local function loadImage(src)
	if type(src) ~= "string" then return src end
	if imageCache[src] == nil then
		imageCache[src] = gfx.image.new(src) or false
		if not imageCache[src] then warn("image not found: " .. src) end
	end
	return imageCache[src] or nil
end

local function loadFrame(src)
	if src == nil then return nil, 0 end
	if type(src) ~= "string" then return src, S.frameInset or 16 end
	if frameCache[src] == nil then
		local img = gfx.image.new(src)
		if img then
			local w, h = img:getSize()
			local cw, ch = w // 3, h // 3
			frameCache[src] = {
				slice = gfx.nineSlice.new(src, cw, ch, w - 2 * cw, h - 2 * ch),
				inset = math.max(cw, ch),
			}
		else
			warn("frame image not found: " .. src)
			frameCache[src] = false
		end
	end
	local f = frameCache[src]
	if not f then return nil, 0 end
	return f.slice, S.frameInset or f.inset
end

local function playSound(name)
	if not cfg.sounds then return end
	local src = cfg.sounds[name]
	if not src then return end
	if type(src) == "function" then
		src(name)
		return
	end
	local player = soundCache[name]
	if player == nil then
		if type(src) == "string" then
			player = pd.sound.sampleplayer.new(src) or false
			if not player then warn("sound not found: " .. src) end
		else
			player = src
		end
		soundCache[name] = player
	end
	if player then player:play() end
end

local function boardLayout(view)
	local slice, inset = loadFrame(S.boardFrame)
	local x, y = inset, inset
	local w, h = SCREEN_W - 2 * inset, SCREEN_H - 2 * inset
	local headerH = math.max(S.headerHeight, S.titleFont:getHeight() * S.titleScale + 6)
	local tab = view and view.tabs[view.index]
	local noteH = (tab and tab.note) and (S.font:getHeight() + 4) or 0
	local footerH = S.buttonFont:getHeight() + 6
	local rows = S.visibleRows or math.max(1, (h - headerH - noteH - footerH - 6) // S.rowHeight)
	return {
		slice = slice, x = x, y = y, w = w, h = h,
		headerH = headerH, noteH = noteH, footerH = footerH, rowH = S.rowHeight, rows = rows,
		top = y + headerH + noteH,
	}
end

local function visibleRows(view)
	return S.visibleRows or boardLayout(view).rows
end

local function await(op)
	return coroutine.yield(op)
end

local function currentFlow()
	return flows[1]
end

local function setBusy(text, kind)
	flows[1].busy = text
	flows[1].busyKind = kind
	flows[1].busySince = now()
end

local function beginModal()
	modalCount = modalCount + 1
	if modalCount == 1 then
		needBackdrop = true
		restoreBackdrop = false
		pd.inputHandlers.push({}, true)
	end
end

local function endModal()
	modalCount = modalCount - 1
	if modalCount == 0 then
		pd.inputHandlers.pop()
		restoreBackdrop = true
	end
end

local function becomeModal()
	local f = currentFlow()
	if not f.modal then
		f.modal = true
		beginModal()
	end
end

local function requestAccess()
	return await({ type = "access" })
end

local function dialog(d)
	return await({ type = "dialog", dialog = d })
end

local function buildHeaders(extra)
	local h = {
		["Authorization"] = "Bearer " .. cfg.accessKey,
		["Content-Type"] = "application/json",
		["Accept"] = "application/json",
	}
	if cfg.devBuild then
		h["x-talo-dev-build"] = "1"
		h["x-talo-include-dev-data"] = "1"
	end
	for k, v in pairs(extra or {}) do h[k] = v end
	return h
end

local function http(method, path, body, headers)
	return await({
		type = "http",
		method = method,
		path = cfg.basePath .. path,
		body = body and json.encode(body) or nil,
		headers = buildHeaders(headers),
	})
end

local function hint(res, lb)
	local s = res.status or 0
	if res.denied then
		return "the player turned off network access for this game (Settings > Permissions)"
	elseif s == 0 then
		return "no connection: Wi-Fi is off, there is no internet, or the server can't be reached"
	elseif s == 401 then
		return "Talo didn't accept the access key: copy it again from Talo (API keys) into crankboard.setup()"
	elseif s == 403 then
		return "the access key is missing a scope: it needs read:players, write:players, "
			.. "read:leaderboards and write:leaderboards"
	elseif s == 404 and lb and (res.body or ""):find("Leaderboard", 1, true) then
		return "Talo has no leaderboard with the internal name '" .. tostring(lb)
			.. "' (names are case-sensitive)"
	end
	return nil
end

local function describe(res, lb)
	local m = res.data and type(res.data) == "table" and res.data.message
	local text = string.format("HTTP %s %s", tostring(res.status), m or res.error or res.body or "")
	local h = hint(res, lb)
	return h and (text .. " -> " .. h) or text
end

local function ensurePlayer()
	if state.aliasId then return { ok = true } end
	local res = http("GET", "/players/identify?service=" .. urlencode(cfg.service)
		.. "&identifier=" .. urlencode(playerKey()))
	local alias = res.ok and type(res.data) == "table" and res.data.alias
	if alias and alias.id then
		state.aliasId = alias.id
		state.playerId = alias.player and alias.player.id
		state.nameSynced = nil
		saveState()
		return { ok = true }
	end
	if res.ok then res.ok = false end
	warn("identify failed: " .. describe(res))
	return res
end

local function syncName()
	if not cfg.namePropKey or not state.name or not state.playerId then return end
	if state.nameSynced == state.name then return end
	local res = http("PATCH", "/players/" .. urlencode(state.playerId), {
		props = { { key = cfg.namePropKey, value = state.name } },
	})
	if res.ok then
		state.nameSynced = state.name
		saveState()
	else
		log("name sync failed: " .. describe(res))
	end
end

local function entryProps(item, withName)
	local list = {}
	for k, v in pairs(item.props or {}) do
		list[#list + 1] = { key = k, value = v }
	end
	table.sort(list, function(a, b) return a.key < b.key end)
	if withName and cfg.namePropKey and state.name and not (item.props and item.props[cfg.namePropKey]) then
		list[#list + 1] = { key = cfg.namePropKey, value = state.name }
	end
	return list
end

local function postScore(item)
	local headers = { ["x-talo-alias"] = idstr(state.aliasId) }
	if item.ts and unixTime() - item.ts > 30 then
		headers["x-talo-continuity-timestamp"] = string.format("%d%03d", item.ts, item.ms or 0)
	end
	local path = "/leaderboards/" .. urlencode(item.lb) .. "/entries"
	local props = entryProps(item, true)
	local body = { score = item.score, props = #props > 0 and props or nil }
	local res = http("POST", path, body, headers)
	if res.status == 400 and body.props then
		local withoutName = entryProps(item, false)
		if #withoutName < #props then
			log("entry props rejected, retrying without the name")
			body.props = #withoutName > 0 and withoutName or nil
			res = http("POST", path, body, headers)
		end
	end
	return res
end

local function isPlayerNotFound(res)
	return res.status == 404 and (res.body or ""):find("Player not found", 1, true) ~= nil
end

local function uploadItem(item)
	local res = ensurePlayer()
	if not res.ok then return res end
	syncName()
	res = postScore(item)
	if isPlayerNotFound(res) then
		state.aliasId, state.playerId = nil, nil
		saveState()
		res = ensurePlayer()
		if not res.ok then return res end
		syncName()
		res = postScore(item)
	end
	if res.ok and not (type(res.data) == "table" and res.data.entry) then
		res.ok, res.status, res.error = false, 0, "unexpected answer: " .. tostring(res.body)
	end
	return res
end

local function isTransient(res)
	local s = res.status or 0
	return res.denied or s == 0 or s == 401 or s == 403 or s == 408 or s == 429 or s >= 500
end

local function flushPending()
	if #state.pending == 0 then return "ok", 0 end
	if not requestAccess() then return "denied", 0 end
	local sent = 0
	while #state.pending > 0 do
		local item = state.pending[1]
		local res = uploadItem(item)
		if res.ok then
			log("submitted", item.lb, item.score)
			sent = sent + 1
		elseif isTransient(res) then
			if res.status == 401 or res.status == 403 then
				warn("upload failed, keeping score: " .. describe(res, item.lb))
			else
				log("upload failed, keeping score: " .. describe(res, item.lb))
			end
			return res.denied and "denied" or "failed", sent
		else
			warn("score rejected and dropped (" .. tostring(item.lb) .. "): " .. describe(res, item.lb))
		end
		table.remove(state.pending, 1)
		item.result = res
		saveState()
	end
	return "ok", sent
end

local function askName()
	local text = await({ type = "keyboard", text = state.name or "" })
	text = trim(text or "")
	if text == "" then text = state.name or defaultPlayerName() end
	state.name = text
	saveState()
end

local function finish(callback, status, info)
	if callback then callback(status, info or {}) end
end

local function summarize(items)
	local info = { ranks = {}, entries = {} }
	local pending, rejected, rejectedLb = false, nil, nil
	for _, item in ipairs(items) do
		local res = item.result
		if not res then
			pending = true
		elseif res.ok then
			local entry = type(res.data) == "table" and res.data.entry or nil
			if entry then
				local rank = entry.position and math.floor(entry.position) + 1 or nil
				info.entries[item.lb] = entry
				info.ranks[item.lb] = rank
				info.entry = info.entry or entry
				info.rank = info.rank or rank
			end
		else
			rejected, rejectedLb = res, item.lb
		end
	end
	if rejected then info.error = describe(rejected, rejectedLb) end
	local status = pending and M.QUEUED or (rejected and M.FAILED or M.SUBMITTED)
	return status, info
end

local function rankList(items, info)
	local list = {}
	for _, item in ipairs(items) do
		local rank = info.ranks[item.lb]
		if rank then
			list[#list + 1] = { leaderboard = item.lb, title = boardShortTitle(item.lb), rank = rank }
		end
	end
	return list
end

local function submittedText(items, info)
	if #items == 1 then
		return info.rank and string.format(msg.submittedRank, info.rank) or msg.submitted
	end
	local lines = {}
	for _, r in ipairs(rankList(items, info)) do
		lines[#lines + 1] = string.format(msg.rankLine, r.title, r.rank)
	end
	if #lines == 0 then return msg.submitted end
	return msg.submitted .. "\n" .. table.concat(lines, msg.rankSeparator)
end

local function addItems(names, score, props)
	local items = {}
	for i, lb in ipairs(names) do items[i] = addPending(lb, score, props) end
	return items
end

local function holdItems(names, score, props)
	for _, lb in ipairs(names) do holdRun(lb, score, props) end
end

local function joinFlow(names, score, props, onComplete)
	state.prompted = true
	saveState()

	local answer = dialog({ kind = "join", title = msg.joinTitle, text = msg.joinText, a = msg.yes, b = msg.no })
	if answer ~= "a" then
		holdItems(names, score, props)
		return finish(onComplete, M.DECLINED)
	end
	state.optedIn = true
	local items = addItems(names, score, props)
	releaseHeld()

	if not requestAccess() then
		dialog({ kind = "accessDenied", text = msg.accessDenied, a = msg.ok })
		return finish(onComplete, M.DENIED, { joined = true })
	end
	net.setEnabled(true)

	if cfg.askName and not state.name then askName() end

	setBusy(msg.sending, "sending")
	flushPending()
	setBusy(nil)

	local status, info = summarize(items)
	info.joined = true
	if status == M.SUBMITTED then
		dialog({ kind = "submitted", text = submittedText(items, info), a = msg.ok, autoClose = 3000,
			ranks = rankList(items, info) })
	elseif status == M.FAILED then
		dialog({ kind = "rejected", text = msg.rejected, a = msg.ok })
	else
		dialog({ kind = "uploadFailed", text = msg.uploadFailed, a = msg.ok })
	end
	return finish(onComplete, status, info)
end

local function autoSubmitFlow(names, score, props, onComplete)
	local items = addItems(names, score, props)
	local flushed = flushPending()
	local status, info = summarize(items)
	if status == M.QUEUED and flushed == "denied" then status = M.DENIED end
	return finish(onComplete, status, info)
end

local function submitFlow(names, score, props, onComplete)
	if cfg.disabled and state.optedIn then
		addItems(names, score, props)
		return finish(onComplete, M.LOCAL)
	elseif cfg.disabled or (state.prompted and not state.optedIn) then
		holdItems(names, score, props)
		return finish(onComplete, M.LOCAL)
	elseif state.optedIn then
		return autoSubmitFlow(names, score, props, onComplete)
	end
	becomeModal()
	return joinFlow(names, score, props, onComplete)
end

local function entryName(e)
	local alias = e.playerAlias or {}
	if alias.displayName and alias.displayName ~= "" and alias.displayName ~= alias.identifier then
		return alias.displayName
	end
	for _, p in ipairs(e.props or {}) do
		if p.key == cfg.namePropKey and p.value and p.value ~= "" then return p.value end
	end
	if alias.service and alias.service ~= cfg.service and alias.identifier then
		return alias.identifier
	end
	return msg.defaultName
end

local function isOwnEntry(e)
	return state.aliasId ~= nil and e.playerAlias ~= nil and e.playerAlias.id ~= nil
		and idstr(e.playerAlias.id) == idstr(state.aliasId)
end

local function makeRow(e, index, format)
	local own = isOwnEntry(e)
	return {
		rank = math.floor(e.position or (index - 1)) + 1,
		name = own and state.name or entryName(e),
		score = format(e.score),
		props = propsMap(e.props),
		own = own,
		entry = e,
	}
end

local function fetchEntries(lb, limit)
	limit = clamp(limit or cfg.topLimit, 1, MAX_TOP)
	local base = "/leaderboards/" .. urlencode(lb) .. "/entries"
	if state.aliasId then
		local res = http("GET", base .. "/top?limit=" .. limit, nil,
			{ ["x-talo-alias"] = idstr(state.aliasId) })
		if res.ok and type(res.data) == "table" then
			return res, res.data.topEntries or {}, res.data.playerEntries or {}
		end
		if isTransient(res) then return res end
	end
	local res = http("GET", base .. "?page=0")
	if res.ok and type(res.data) == "table" then
		local top = {}
		for i, e in ipairs(res.data.entries or {}) do
			if i > limit then break end
			top[i] = e
		end
		return res, top, {}
	end
	if res.ok then res.ok = false end
	return res
end

local function buildRows(top, mine, format)
	local rows, ownShown = {}, false
	for i, e in ipairs(top) do
		local row = makeRow(e, i, format)
		ownShown = ownShown or row.own
		rows[#rows + 1] = row
	end
	if not ownShown and #mine > 0 then
		local best = mine[1]
		for _, e in ipairs(mine) do
			if (e.position or math.huge) < (best.position or math.huge) then best = e end
		end
		rows[#rows + 1] = { gap = true }
		local row = makeRow(best, #top + 1, format)
		row.own = true
		rows[#rows + 1] = row
	end
	return rows
end

local function initialScroll(rows, view)
	local page = visibleRows(view)
	for i, row in ipairs(rows) do
		if row.own then
			return clamp(i - page // 2 - 1, 0, math.max(0, #rows - page))
		end
	end
	return 0
end

local function resolveTabs(options)
	local list = options.leaderboards
		or (options.leaderboard and { options.leaderboard })
		or boards
	local tabs = {}
	for i, b in ipairs(list) do
		local name = type(b) == "table" and b.name or b
		local title = type(b) == "table" and b.title or boardTitle(name)
		tabs[i] = { name = name, title = title or name }
	end
	if #tabs == 1 then
		local b = list[1]
		tabs[1].title = options.title or (type(b) == "table" and b.title) or boardTitle(tabs[1].name)
			or msg.leaderboardTitle
	end
	return tabs
end

local function saveCache(lb, rows)
	local saved = {}
	for i, row in ipairs(rows) do
		if row.gap then
			saved[i] = { gap = true }
		else
			saved[i] = {
				rank = row.rank, name = row.name, score = row.entry and row.entry.score,
				props = row.props, own = row.own,
			}
		end
	end
	state.cache = state.cache or {}
	state.cache[lb] = { savedAt = unixTime(), rows = saved }
	saveState()
end

local function ago(ts)
	local seconds = math.max(0, unixTime() - ts)
	if seconds < 60 then return msg.justNow end
	if seconds < 3600 then return string.format(msg.minutesAgo, seconds // 60) end
	if seconds < 86400 then return string.format(msg.hoursAgo, seconds // 3600) end
	if seconds < 2 * 86400 then return msg.yesterday end
	return string.format(msg.daysAgo, seconds // 86400)
end

local function cachedRows(lb, format, limit)
	local cached = state.cache and state.cache[lb]
	if not cached then return nil end
	limit = clamp(limit or cfg.topLimit, 1, MAX_TOP)
	local rows, own, ownShown, pastTop = {}, nil, false, false
	for _, saved in ipairs(cached.rows) do
		if saved.gap then
			pastTop = true
		else
			local row = {
				rank = saved.rank, name = saved.own and state.name or saved.name, score = format(saved.score),
				props = saved.props or {}, own = saved.own,
			}
			if not pastTop and #rows < limit then
				rows[#rows + 1] = row
				ownShown = ownShown or row.own
			elseif row.own and not own then
				own = row
			end
		end
	end
	if own and not ownShown then
		rows[#rows + 1] = { gap = true }
		rows[#rows + 1] = own
	end
	return rows, { cached = true, savedAt = cached.savedAt, ago = ago(cached.savedAt) }
end

local function useCache(view, tab)
	local rows, info = cachedRows(tab.name, view.format, view.limit)
	if not rows then return false end
	tab.rows = rows
	tab.note = string.format(msg.offlineNote, info.ago)
	tab.error = nil
	tab.loaded = true
	tab.scroll = initialScroll(tab.rows, view)
	return true
end

local function loadTab(view, tab)
	tab.loading = true
	local res, top, mine = fetchEntries(tab.name, view.limit)
	tab.loading = false
	tab.loaded = true
	if res.ok then
		tab.rows = buildRows(top, mine, view.format)
		tab.note = nil
		tab.scroll = initialScroll(tab.rows, view)
		tab.error = nil
		saveCache(tab.name, tab.rows)
		return true
	end
	warn("loading leaderboard '" .. tostring(tab.name) .. "' failed: " .. describe(res, tab.name))
	if isTransient(res) and useCache(view, tab) then return true end
	tab.rows = nil
	tab.error = msg.connectFailed
	return false
end

local function leaderboardFlow(options)
	local tabs = resolveTabs(options)
	local view = {
		tabs = tabs,
		index = clamp(options.tab or 1, 1, #tabs),
		limit = options.limit,
		format = options.formatScore or cfg.formatScore or defaultFormatScore,
		detail = options.detail or cfg.detail,
		crank = 0,
	}
	setBusy(msg.loading, "loading")
	if not requestAccess() then
		if not useCache(view, tabs[view.index]) then
			dialog({ kind = "accessDenied", text = msg.accessDenied, a = msg.ok })
			return false
		end
		for _, tab in ipairs(tabs) do
			if not tab.loaded and not useCache(view, tab) then tab.loaded, tab.error = true, msg.accessDenied end
		end
	elseif state.optedIn then
		flushPending()
	end
	if not tabs[view.index].loaded and not loadTab(view, tabs[view.index]) then
		dialog({ kind = "connectFailed", text = msg.connectFailed, a = msg.ok })
		return false
	end
	setBusy(nil)

	view.openedAt = now()
	currentFlow().view = view
	while true do
		local tab = tabs[view.index]
		if not tab.loaded then loadTab(view, tab) end
		if await({ type = "board", view = view }) == "close" then break end
	end
	currentFlow().view = nil
	return true
end

local function entriesFlow(options)
	local lb = options.leaderboard or boards[1].name
	local format = options.formatScore or cfg.formatScore or defaultFormatScore
	local function offline(err)
		local rows, info = nil, nil
		if options.cache ~= false then rows, info = cachedRows(lb, format, options.limit) end
		if not rows then return options.onComplete(false, nil, err) end
		info.error = err
		options.onComplete(true, rows, info)
	end
	if not requestAccess() then return offline("denied") end
	local res, top, mine = fetchEntries(lb, options.limit)
	if not res.ok then
		local err = describe(res, lb)
		if isTransient(res) then return offline(err) end
		return options.onComplete(false, nil, err)
	end
	local rows = buildRows(top, mine, format)
	saveCache(lb, rows)
	options.onComplete(true, rows, res.data)
end

local function startFlow(fn, modal, ...)
	local args = table.pack(...)
	flows[#flows + 1] = {
		co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end),
		modal = modal,
	}
	if modal then beginModal() end
end

local function completeOp(op, result)
	if op.done then return end
	op.done = true
	op.result = result
end

local function finishHttp(op, reason)
	if op.done then return end
	local conn = op.conn
	op.readAvailable()
	local status = conn:getResponseStatus() or 0
	local body = table.concat(op.chunks)
	local data = nil
	if #body > 0 then
		local ok, decoded = pcall(json.decode, body)
		if ok then data = decoded end
	end
	local res = {
		ok = status >= 200 and status < 300,
		status = status,
		data = data,
		body = body,
		error = conn:getError() or reason,
	}
	log(op.method, op.path, "->", status, #body .. " bytes", res.error or "")
	completeOp(op, res)
end

local function startHttp(op)
	local conn = net.http.new(cfg.host, cfg.port, cfg.useSSL, msg.accessReason)
	if not conn then
		return completeOp(op, { ok = false, status = 0, denied = true, error = "network access denied" })
	end
	op.conn = conn
	op.chunks = {}
	op.started = now()
	op.readAvailable = function()
		local n = conn:getBytesAvailable()
		while n and n > 0 do
			local data = conn:read(n)
			if not data or #data == 0 then break end
			op.chunks[#op.chunks + 1] = data
			op.lastData = now()
			n = conn:getBytesAvailable()
		end
	end
	conn:setConnectTimeout(cfg.connectTimeout)
	conn:setRequestCallback(function() op.readAvailable() end)
	conn:setRequestCompleteCallback(function() finishHttp(op) end)
	conn:setConnectionClosedCallback(function() finishHttp(op, "connection closed") end)

	log(op.method, op.path, op.body or "")
	local called, ok, err = pcall(function()
		if op.method == "GET" then
			return conn:get(op.path, op.headers)
		elseif op.method == "POST" then
			return conn:post(op.path, op.headers, op.body or "")
		else
			return conn:query(op.method, op.path, op.headers, op.body or "")
		end
	end)
	if not called then ok, err = false, tostring(ok) end
	if not ok then
		completeOp(op, { ok = false, status = 0, error = err or "request failed" })
	end
end

local function pollHttp(op)
	if op.done or not op.conn then return end
	local t = now()
	if t - op.started > cfg.timeout * 1000 then
		finishHttp(op, "timeout")
	elseif op.lastData and t - op.lastData > 400 then
		local ok, decoded = pcall(json.decode, table.concat(op.chunks))
		if ok and type(decoded) == "table" then finishHttp(op) end
	end
end

local function startKeyboard(op)
	local kb = pd.keyboard
	op.saved = {
		kb.keyboardWillHideCallback, kb.keyboardDidHideCallback, kb.textChangedCallback,
	}
	kb.keyboardWillHideCallback = function(okPressed)
		op.text = okPressed and kb.text or nil
	end
	kb.keyboardDidHideCallback = function()
		kb.keyboardWillHideCallback, kb.keyboardDidHideCallback, kb.textChangedCallback =
			table.unpack(op.saved, 1, 3)
		completeOp(op, op.text)
	end
	kb.textChangedCallback = function()
		if #kb.text > cfg.maxNameLength then kb.text = kb.text:sub(1, cfg.maxNameLength) end
	end
	kb.setCapitalizationBehavior(kb.kCapitalizationWords)
	kb.show(op.text or "")
end

local function startOp(op)
	op.openedAt = now()
	if op.type == "access" then
		local conn = net.http.new(cfg.host, cfg.port, cfg.useSSL, msg.accessReason)
		completeOp(op, conn and true or false)
	elseif op.type == "http" then
		startHttp(op)
	elseif op.type == "keyboard" then
		startKeyboard(op)
	elseif op.type == "dialog" then
		local kind = op.dialog.kind
		if kind == "submitted" then
			playSound("success")
		elseif kind == "accessDenied" or kind == "connectFailed" or kind == "uploadFailed" or kind == "rejected" then
			playSound("error")
		end
	end
end

local function pollBoard(op, input)
	local view = op.view
	local tabs = view.tabs
	local ready = now() - view.openedAt > INPUT_GUARD_MS

	if input.left or input.right then
		local index = clamp(view.index + (input.right and 1 or -1), 1, #tabs)
		if index ~= view.index then
			view.index = index
			playSound("move")
			if not tabs[index].loaded then completeOp(op, "load") end
		end
		return
	end

	local tab = tabs[view.index]
	if tab.rows then
		local maxScroll = math.max(0, #tab.rows - visibleRows(view))
		view.crank = view.crank + (input.crank or 0)
		local step = 0
		if input.up then step = step - 1 end
		if input.down then step = step + 1 end
		while view.crank >= 30 do view.crank = view.crank - 30; step = step + 1 end
		while view.crank <= -30 do view.crank = view.crank + 30; step = step - 1 end
		local scroll = clamp((tab.scroll or 0) + step, 0, maxScroll)
		if scroll ~= (tab.scroll or 0) then playSound("move") end
		tab.scroll = scroll
	end

	if ready and input.b then
		playSound("cancel")
		completeOp(op, "close")
	elseif ready and input.a then
		if tab.error then
			playSound("confirm")
			tab.loaded = false
			completeOp(op, "load")
		else
			playSound("cancel")
			completeOp(op, "close")
		end
	end
end

local function pollOp(op, input)
	if op.type == "http" then
		pollHttp(op)
	elseif op.type == "dialog" then
		local d = op.dialog
		local ready = now() - op.openedAt > INPUT_GUARD_MS
		if ready and input.a then
			playSound("confirm")
			completeOp(op, "a")
		elseif ready and input.b then
			playSound(d.b and "cancel" or "confirm")
			completeOp(op, d.b and "b" or "a")
		elseif d.autoClose and now() - op.openedAt > d.autoClose then
			completeOp(op, "a")
		end
	elseif op.type == "board" then
		pollBoard(op, input)
	end
end

local function fg() return S.inverted and gfx.kColorWhite or gfx.kColorBlack end
local function bg() return S.inverted and gfx.kColorBlack or gfx.kColorWhite end

local function textMode(onFg)
	if S.textMode == "copy" then
		return onFg and gfx.kDrawModeInverted or gfx.kDrawModeCopy
	end
	return (S.inverted ~= (onFg == true)) and gfx.kDrawModeFillWhite or gfx.kDrawModeFillBlack
end

local function hintMode(onFg)
	return (S.inverted ~= (onFg == true)) and gfx.kDrawModeInverted or gfx.kDrawModeCopy
end

local function measure(text, width, font, scale)
	if not text or text == "" then return 0, 0 end
	scale = scale or 1
	local w, h = gfx.getTextSizeForMaxWidth(text, width // scale, nil, font)
	return w * scale, (h + 2) * scale
end

local function drawText(text, x, y, w, h, font, align, scale)
	if not text or text == "" then return end
	scale = scale or 1
	if scale == 1 then
		gfx.drawTextInRect(text, x, y, w, h, nil, nil, align, font)
		return
	end
	local img = gfx.imageWithText(text, w // scale, h // scale, nil, nil, nil, align, font)
	if not img then return end
	local iw = img.width * scale
	if align == kTextAlignment.center then
		x = x + (w - iw) // 2
	elseif align == kTextAlignment.right then
		x = x + w - iw
	end
	img:drawScaled(x, y, scale)
end

local function fitText(font, text, width)
	if width <= 0 then return "" end
	if font:getTextWidth(text) <= width then return text end
	while #text > 0 and font:getTextWidth(text .. "...") > width do
		text = text:sub(1, -2)
	end
	return text .. "..."
end

local function dots()
	local n = (now() // 400) % 4
	return string.rep(".", n) .. string.rep(" ", 3 - n)
end

local function drawBackdrop(amount)
	if backdrop then
		backdrop:draw(0, 0)
	else
		gfx.clear(gfx.kColorWhite)
	end
	if amount and amount > 0 then
		gfx.setColor(gfx.kColorBlack)
		gfx.setDitherPattern(amount, gfx.image.kDitherTypeBayer2x2)
		gfx.fillRect(0, 0, SCREEN_W, SCREEN_H)
		gfx.setColor(gfx.kColorBlack)
	end
end

local function drawPanel(x, y, w, h)
	local slice = loadFrame(S.frame)
	if slice then
		slice:drawInRect(x, y, w, h)
		return
	end
	gfx.setColor(bg())
	gfx.fillRoundRect(x, y, w, h, S.cornerRadius)
	if S.borderWidth > 0 then
		gfx.setColor(gfx.kColorBlack)
		gfx.setLineWidth(S.borderWidth)
		gfx.drawRoundRect(x, y, w, h, S.cornerRadius)
		gfx.setLineWidth(1)
	end
	if S.doubleBorder then
		local i = S.borderWidth + 2
		gfx.setColor(fg())
		gfx.drawRoundRect(x + i, y + i, w - 2 * i, h - 2 * i, math.max(0, S.cornerRadius - i))
	end
	gfx.setColor(gfx.kColorBlack)
end

local function buttonsHeight()
	local fh = S.buttonFont:getHeight()
	return S.buttons == "pills" and fh + 8 or fh + 6
end

local function drawButtons(buttons, x, y, w)
	local font = S.buttonFont
	local fh = font:getHeight()
	if S.buttons == "pills" then
		local gap = 16
		local bw = math.min(130, (w - gap * (#buttons - 1)) // #buttons)
		local bh = fh + 8
		local bx = x + (w - (#buttons * bw + (#buttons - 1) * gap)) // 2
		for i, b in ipairs(buttons) do
			local primary = i == 1
			gfx.setColor(fg())
			if primary then
				gfx.fillRoundRect(bx, y, bw, bh, bh // 2)
			else
				gfx.drawRoundRect(bx, y, bw, bh, bh // 2)
			end
			gfx.setImageDrawMode(hintMode(primary))
			font:drawText(b.label, bx + (bw - font:getTextWidth(b.label)) // 2, y + 4)
			gfx.setImageDrawMode(gfx.kDrawModeCopy)
			bx = bx + bw + gap
		end
	else
		local labels = {}
		for i, b in ipairs(buttons) do labels[i] = b.label end
		local hint = table.concat(labels, "      ")
		gfx.setColor(fg())
		gfx.drawLine(x, y, x + w, y)
		gfx.setImageDrawMode(hintMode(false))
		font:drawText(hint, x + (w - font:getTextWidth(hint)) // 2, y + 5)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end
	gfx.setColor(gfx.kColorBlack)
end

local function drawDialogBox(d)
	local slice, inset = loadFrame(S.frame)
	local pad = slice and inset or S.padding
	local w = S.dialogWidth
	local icon = d.icon
	local iconW = icon and (icon.width + 12) or 0
	local inner = w - pad * 2 - iconW
	local align = icon and kTextAlignment.left or kTextAlignment.center
	local gap = 8

	local _, th = measure(d.title, inner, S.titleFont, S.titleScale)
	local _, bh = measure(d.text, inner, S.font)
	local textH = th + bh + ((th > 0 and bh > 0) and gap or 0)
	local contentH = math.max(textH, icon and icon.height or 0)
	local hasButtons = d.buttons and #d.buttons > 0
	local h = pad * 2 + contentH + (hasButtons and (gap + buttonsHeight()) or 0)
	local x, y = (SCREEN_W - w) // 2, (SCREEN_H - h) // 2

	drawPanel(x, y, w, h)
	if icon then
		icon:draw(x + pad, y + pad + (contentH - icon.height) // 2)
	end
	local cx = x + pad + iconW
	local cy = y + pad + (contentH - textH) // 2
	gfx.setImageDrawMode(textMode(false))
	if th > 0 then
		drawText(d.title, cx, cy, inner, th, S.titleFont, align, S.titleScale)
		cy = cy + th + gap
	end
	drawText(d.text, cx, cy, inner, bh, S.font, align)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	if hasButtons then
		drawButtons(d.buttons, x + pad, y + h - pad - buttonsHeight(), w - pad * 2)
	end
end

local function drawKeyboardPanel(k)
	local left = k.left
	if left < 40 then return end
	local pad = 10
	gfx.setColor(bg())
	gfx.fillRect(0, 0, left, SCREEN_H)
	gfx.setColor(fg())
	local inner = left - pad * 2
	local _, ph = measure(k.prompt, inner, S.titleFont)
	gfx.setImageDrawMode(textMode(false))
	drawText(k.prompt, pad, 40, inner, ph, S.titleFont, kTextAlignment.left)
	local boxY = 40 + ph + 16
	local fh = S.font:getHeight()
	gfx.drawRect(pad, boxY, inner, fh + 10)
	local shown = k.text .. ((now() // 500) % 2 == 0 and "|" or "")
	while #shown > 0 and S.font:getTextWidth(shown) > inner - 10 do shown = shown:sub(2) end
	S.font:drawText(shown, pad + 5, boxY + 5)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	gfx.setColor(gfx.kColorBlack)
end

local function drawTabs(view, L)
	local tabs = view.tabs
	local font = S.titleFont
	local bar = S.tabs ~= "underline"
	local x0, y0, w, hh = L.x, L.y, L.w, L.headerH
	if bar then
		gfx.setColor(fg())
		gfx.fillRect(x0, y0, w, hh)
	end
	local ty = y0 + (hh - font:getHeight()) // 2

	if #tabs == 1 then
		gfx.setImageDrawMode(textMode(bar))
		local th = font:getHeight() * S.titleScale
		drawText(tabs[1].title, x0 + 8, y0 + (hh - th) // 2, w - 16, th + 4, font, kTextAlignment.center, S.titleScale)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		gfx.setColor(gfx.kColorBlack)
		return
	end

	local widths, total = {}, -4
	for i, tab in ipairs(tabs) do
		widths[i] = font:getTextWidth(tab.title) + 16
		total = total + widths[i] + 4
	end
	if total <= w - 8 then
		local x = x0 + (w - total) // 2
		for i, tab in ipairs(tabs) do
			local current = i == view.index
			if bar and current then
				gfx.setColor(bg())
				gfx.fillRoundRect(x, y0 + 3, widths[i], hh - 6, 5)
				gfx.setImageDrawMode(textMode(false))
			else
				gfx.setImageDrawMode(textMode(bar))
			end
			font:drawText(tab.title, x + 8, ty)
			if not bar and current then
				gfx.setColor(fg())
				gfx.fillRect(x + 8, ty + font:getHeight() + 1, widths[i] - 16, 2)
			end
			x = x + widths[i] + 4
		end
	else
		local title = string.format("< %s >  %d/%d", tabs[view.index].title, view.index, #tabs)
		title = fitText(font, title, w - 20)
		gfx.setImageDrawMode(textMode(bar))
		font:drawText(title, x0 + (w - font:getTextWidth(title)) // 2, ty)
	end
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	gfx.setColor(gfx.kColorBlack)
end

local function drawCentered(text, L)
	local w = L.w - 40
	local _, h = measure(text, w, S.font)
	local top = L.top + (L.y + L.h - L.footerH - L.top - h) // 2
	gfx.setImageDrawMode(textMode(false))
	drawText(text, L.x + 20, top, w, h, S.font, kTextAlignment.center)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function drawRows(view, tab, L)
	local normal, own = S.font, S.ownFont
	local scroll = tab.scroll or 0
	local left, rightEdge = L.x, L.x + L.w

	local scoreW, detailW, details = 0, 0, {}
	for i = 1, L.rows do
		local row = tab.rows[scroll + i]
		if row and not row.gap then
			local font = row.own and own or normal
			scoreW = math.max(scoreW, font:getTextWidth(row.score))
			if view.detail then
				local ok, d = pcall(view.detail, row)
				d = ok and d and tostring(d) or ""
				details[i] = d
				detailW = math.max(detailW, font:getTextWidth(d))
			end
		end
	end
	local scoreRight = rightEdge - 12
	local detailRight = scoreRight - scoreW - 14
	local nameRight = detailW > 0 and (detailRight - detailW - 12) or (scoreRight - scoreW - 12)
	local nameX, rankRight = left + 56, left + 46

	for i = 1, L.rows do
		local row = tab.rows[scroll + i]
		if not row then break end
		local y = L.top + 3 + (i - 1) * L.rowH
		local font = row.own and own or normal
		local ty = y + (L.rowH - font:getHeight()) // 2
		if row.gap then
			local gapText = ". . ."
			gfx.setImageDrawMode(textMode(false))
			normal:drawText(gapText, left + (L.w - normal:getTextWidth(gapText)) // 2, ty)
		else
			local onFg = false
			if row.own then
				gfx.setColor(fg())
				if S.ownRow == "outline" then
					gfx.setLineWidth(2)
					gfx.drawRect(left + 4, y - 1, L.w - 8, L.rowH + 1)
					gfx.setLineWidth(1)
				elseif S.ownRow == "arrow" then
					local ay = y + L.rowH // 2
					gfx.fillTriangle(left + 8, ay - 5, left + 8, ay + 5, left + 15, ay)
					gfx.drawLine(nameX, y + L.rowH - 3, scoreRight, y + L.rowH - 3)
				else
					gfx.fillRoundRect(left + 4, y, L.w - 8, L.rowH, 4)
					onFg = true
				end
			end
			gfx.setImageDrawMode(textMode(onFg))
			local rank = tostring(row.rank)
			font:drawText(rank, rankRight - font:getTextWidth(rank), ty)
			font:drawText(row.score, scoreRight - font:getTextWidth(row.score), ty)
			if details[i] and details[i] ~= "" then
				font:drawText(details[i], detailRight - font:getTextWidth(details[i]), ty)
			end
			font:drawText(fitText(font, row.name, nameRight - nameX), nameX, ty)
		end
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		gfx.setColor(gfx.kColorBlack)
	end
end

local function boardHints(view)
	local tab = view.tabs[view.index]
	local hints = {}
	if #view.tabs > 1 then hints[#hints + 1] = msg.tabHint end
	if tab.rows and #tab.rows > visibleRows(view) then hints[#hints + 1] = msg.scrollHint end
	hints[#hints + 1] = msg.backHint
	return hints
end

local function drawBoard(view)
	local L = boardLayout(view)
	gfx.clear(bg())
	if L.slice then L.slice:drawInRect(0, 0, SCREEN_W, SCREEN_H) end
	drawTabs(view, L)

	local tab = view.tabs[view.index]
	if tab.note then
		gfx.setImageDrawMode(textMode(false))
		drawText(tab.note, L.x + 8, L.y + L.headerH + 2, L.w - 16, L.noteH, S.font, kTextAlignment.center)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
	end
	if tab.loading or not tab.loaded then
		drawCentered(msg.loading .. dots(), L)
	elseif tab.error then
		drawCentered(tab.error .. "\n\n" .. msg.retry, L)
	elseif #tab.rows == 0 then
		drawCentered(msg.empty, L)
	else
		drawRows(view, tab, L)
	end

	local fy = L.y + L.h - L.footerH
	gfx.setColor(fg())
	gfx.drawLine(L.x, fy, L.x + L.w, fy)
	local hint = table.concat(boardHints(view), "    ")
	local font = S.buttonFont
	gfx.setImageDrawMode(hintMode(false))
	font:drawText(hint, L.x + (L.w - font:getTextWidth(hint)) // 2, fy + (L.footerH - font:getHeight()) // 2 + 1)
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	gfx.setColor(gfx.kColorBlack)
end

local hookWarned = {}

local function drawWith(name, model, builtin)
	local hook = cfg.draw and cfg.draw[name]
	if hook then
		local ctx = {
			width = SCREEN_W,
			height = SCREEN_H,
			style = S,
			drawBackdrop = drawBackdrop,
			drawDefault = function() builtin(model) end,
			dots = dots(),
		}
		local ok, err = pcall(hook, model, ctx)
		if ok then return end
		if not hookWarned[name] then
			warn("draw." .. name .. " failed, using the built-in look: " .. tostring(err))
			hookWarned[name] = true
		end
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		gfx.setColor(gfx.kColorBlack)
	end
	builtin(model)
end

local function dialogModel(op)
	local d = op.dialog
	local buttons = {}
	if d.a then buttons[#buttons + 1] = { button = "a", label = d.a } end
	if d.b then buttons[#buttons + 1] = { button = "b", label = d.b } end
	local icons = S.icons or {}
	local icon = icons[d.kind]
	if not icon and (d.kind == "accessDenied" or d.kind == "connectFailed"
		or d.kind == "uploadFailed" or d.kind == "rejected") then
		icon = icons.error
	end
	return {
		kind = d.kind,
		title = d.title,
		text = d.text,
		icon = loadImage(icon),
		buttons = buttons,
		ranks = d.ranks,
		age = now() - op.openedAt,
	}
end

local function boardModel(view)
	return {
		tabs = view.tabs,
		index = view.index,
		tab = view.tabs[view.index],
		visibleRows = visibleRows(view),
		hints = boardHints(view),
		detail = view.detail,
		age = now() - view.openedAt,
		texts = { loading = msg.loading, empty = msg.empty, retry = msg.retry },
	}
end

local function render()
	local f = flows[1]
	local op = f and f.op
	if f and f.view then
		local model = boardModel(f.view)
		drawWith("board", model, function() drawBoard(f.view) end)
		return
	end
	drawBackdrop(S.dim)
	if f and not f.modal then
		drawWith("busy", { kind = "wait", text = msg.wait, age = 0 }, function(m)
			drawDialogBox({ text = m.text .. dots(), buttons = {} })
		end)
	elseif op and op.type == "dialog" and not op.done then
		drawWith("dialog", dialogModel(op), drawDialogBox)
	elseif op and op.type == "keyboard" then
		local model = {
			prompt = msg.enterName,
			text = pd.keyboard.text or "",
			left = pd.keyboard.left(),
			maxLength = cfg.maxNameLength,
		}
		drawWith("keyboard", model, drawKeyboardPanel)
	elseif f and f.busy then
		local model = { kind = f.busyKind, text = f.busy, age = now() - (f.busySince or now()) }
		drawWith("busy", model, function(m)
			drawDialogBox({ text = m.text .. dots(), buttons = {} })
		end)
	end
end

local function readInput(modal)
	local input = {}
	local pressed = false
	for name, button in pairs(BUTTONS) do
		input[name] = pd.buttonJustPressed(button)
		pressed = pressed or input[name]
	end
	if pressed and not state.playerKey then addEntropy("input") end
	if modal then input.crank = pd.getCrankChange() end
	return input
end

local function runFlows(input)
	for _ = 1, 8 do
		local f = flows[1]
		if not f then return end
		local op = f.op
		if op then
			if not op.done then pollOp(op, input) end
			if not op.done then return end
			if op.conn then op.conn:close() end
			input = {}
		end
		f.op = nil
		local ok, nextOp = coroutine.resume(f.co, op and op.result)
		if not ok then
			print("[crankboard] ERROR: " .. debug.traceback(f.co, tostring(nextOp)))
		end
		if not ok or coroutine.status(f.co) == "dead" then
			table.remove(flows, 1)
			if f.modal then endModal() end
		else
			f.op = nextOp
			startOp(nextOp)
		end
	end
end

local KEY_FILE_FIELDS <const> = { "accessKey", "host", "port", "useSSL", "basePath" }

local function readKeyFile(path)
	if not pd.file.exists(path) then return nil, "not found" end
	local ok, data = pcall(json.decodeFile, path)
	if not ok or type(data) ~= "table" then return nil, "not valid JSON" end
	local out = {}
	for _, k in ipairs(KEY_FILE_FIELDS) do out[k] = data[k] end
	return out
end

local function isUsableKey(key)
	return type(key) == "string" and key ~= "" and not key:find("PASTE", 1, true)
end

function M.setup(options)
	options = options or {}
	assert(options.accessKeyFile or (type(options.accessKey) == "string" and options.accessKey ~= ""),
		"crankboard.setup: accessKey or accessKeyFile is required")
	local list = options.leaderboards or (options.leaderboard and { options.leaderboard })
	assert(type(list) == "table" and #list > 0,
		"crankboard.setup: leaderboard (internal name) or leaderboards is required")
	boards = {}
	for i, b in ipairs(list) do
		local name = type(b) == "table" and b.name or b
		assert(type(name) == "string" and name ~= "", "crankboard.setup: invalid leaderboard #" .. i)
		boards[i] = { name = name }
		if type(b) == "table" then
			boards[i].title = b.title
			boards[i].shortTitle = b.shortTitle
			boards[i].ascending = b.ascending
		end
	end

	cfg = {}
	for k, v in pairs(DEFAULTS) do cfg[k] = v end
	for k, v in pairs(options) do
		if k ~= "messages" and k ~= "leaderboards" and k ~= "leaderboard"
			and k ~= "style" and k ~= "sounds" then
			cfg[k] = v
		end
	end
	if options.accessKeyFile then
		local file, why = readKeyFile(options.accessKeyFile)
		if file and isUsableKey(file.accessKey) then
			for k, v in pairs(file) do cfg[k] = v end
		elseif not isUsableKey(options.accessKey) then
			warn(options.accessKeyFile .. (file and " holds no access key" or (" " .. why))
				.. ": online leaderboards are off. Put { \"accessKey\": \"...\" } from Talo (API keys) in it")
		end
	elseif not isUsableKey(options.accessKey) then
		warn("accessKey is still the placeholder: online leaderboards are off. "
			.. "Paste your key from Talo (API keys) into crankboard.setup()")
	end
	cfg.disabled = not isUsableKey(cfg.accessKey)
	msg = {}
	for k, v in pairs(DEFAULT_MESSAGES) do msg[k] = v end
	for k, v in pairs(options.messages or {}) do msg[k] = v end

	S = {}
	for k, v in pairs(DEFAULT_STYLE) do S[k] = v end
	for k, v in pairs(options.style or {}) do S[k] = v end
	S.icons = S.icons or {}
	local systemFont = gfx.getSystemFont(gfx.font.kVariantNormal)
	S.font = loadFont(S.font or options.font, systemFont)
	S.titleFont = loadFont(S.titleFont or options.boldFont, gfx.getSystemFont(gfx.font.kVariantBold))
	S.ownFont = loadFont(S.ownFont, S.titleFont)
	S.buttonFont = loadFont(S.buttonFont, systemFont)
	imageCache, frameCache = {}, {}

	if options.sounds == false then
		cfg.sounds = false
	else
		cfg.sounds = {}
		for k, v in pairs(DEFAULT_SOUNDS) do cfg.sounds[k] = v end
		for k, v in pairs(options.sounds or {}) do cfg.sounds[k] = v end
	end
	soundCache = {}

	addEntropy("setup")
	loadState()
	setupAt = now()
end

local function checkUpdateCalled()
	if not updateCalled and not warnedNoUpdate and now() - setupAt > 2000 then
		warnedNoUpdate = true
		warn("crankboard.update() is never called: add 'if crankboard.update() then return end' "
			.. "at the start of playdate.update(), otherwise nothing will happen")
	end
end

function M.update()
	if not cfg then return false end
	updateCalled = true
	local input = readInput(modalCount > 0)
	runFlows(input)

	if needBackdrop then
		backdrop = gfx.getDisplayImage()
		needBackdrop = false
	end

	local ox, oy = gfx.getDrawOffset()
	gfx.pushContext()
	gfx.setDrawOffset(0, 0)
	gfx.clearClipRect()
	if modalCount > 0 then
		render()
	elseif restoreBackdrop then
		drawBackdrop(false)
	end
	gfx.popContext()
	gfx.setDrawOffset(ox, oy)

	if modalCount == 0 and restoreBackdrop then
		restoreBackdrop = false
		backdrop = nil
		return true
	end
	return modalCount > 0
end

function M.submitScore(score, options)
	assert(cfg, "crankboard.setup() must be called first")
	checkUpdateCalled()
	assert(type(score) == "number", "crankboard.submitScore: score must be a number")
	options = options or {}
	local names = options.leaderboards and boardNames(options.leaderboards)
		or (options.leaderboard and { options.leaderboard })
		or boardNames(boards)
	addEntropy("submit")
	local props = normalizeProps(options.props)
	local newBest = false
	for i, lb in ipairs(names) do
		local isNew = recordBest(lb, score, props)
		if i == 1 then newBest = isNew end
	end
	local onComplete = options.onComplete
	startFlow(submitFlow, false, names, score, props, onComplete and function(status, info)
		info.newBest = newBest
		onComplete(status, info)
	end)
	return newBest
end

function M.showLeaderboard(options)
	assert(cfg, "crankboard.setup() must be called first")
	checkUpdateCalled()
	options = options or {}
	if cfg.disabled then
		warn("showLeaderboard: online leaderboards are off (no access key); hide it when isEnabled() is false")
		if options.onClose then options.onClose(false) end
		return
	end
	startFlow(function()
		local shown = leaderboardFlow(options)
		if options.onClose then options.onClose(shown) end
	end, true)
end

function M.getEntries(options)
	assert(cfg, "crankboard.setup() must be called first")
	assert(options and options.onComplete, "crankboard.getEntries: onComplete is required")
	if cfg.disabled then
		return options.onComplete(false, nil, "online leaderboards are off (no access key)")
	end
	startFlow(entriesFlow, false, options)
end

function M.getCachedEntries(options)
	assert(cfg, "crankboard.setup() must be called first")
	options = options or {}
	return cachedRows(options.leaderboard or boards[1].name,
		options.formatScore or cfg.formatScore or defaultFormatScore, options.limit)
end

function M.flush(onComplete)
	assert(cfg, "crankboard.setup() must be called first")
	if cfg.disabled or not state.optedIn or #state.pending == 0 then
		if onComplete then onComplete(true, 0) end
		return
	end
	startFlow(function()
		local result, sent = flushPending()
		if onComplete then onComplete(result == "ok", sent) end
	end, false)
end

function M.editName(onDone)
	assert(cfg, "crankboard.setup() must be called first")
	checkUpdateCalled()
	startFlow(function()
		askName()
		if onDone then onDone(state.name) end
	end, true)
end

function M.getName() return state and state.name end

function M.setName(name)
	assert(cfg, "crankboard.setup() must be called first")
	name = trim(tostring(name or ""))
	if name == "" then return end
	state.name = name:sub(1, cfg.maxNameLength)
	saveState()
end

function M.isOptedIn() return state ~= nil and state.optedIn end

function M.setOptedIn(flag)
	assert(cfg, "crankboard.setup() must be called first")
	local joining = flag and not state.optedIn
	state.optedIn = flag and true or false
	state.prompted = true
	saveState()
	if joining then
		releaseHeld()
		M.flush()
	end
end

function M.isEnabled() return cfg ~= nil and not cfg.disabled end

function M.wasPrompted() return state ~= nil and state.prompted end

function M.resetPrompt()
	assert(cfg, "crankboard.setup() must be called first")
	state.prompted = false
	state.optedIn = false
	saveState()
end

function M.getBest(leaderboard)
	assert(cfg, "crankboard.setup() must be called first")
	return state.best and state.best[leaderboard or boards[1].name] or nil
end

function M.isNewBest(score, leaderboard)
	assert(cfg, "crankboard.setup() must be called first")
	local lb = leaderboard or boards[1].name
	return beats(score, state.best and state.best[lb] or nil, lb)
end

function M.pendingCount() return state and #state.pending or 0 end

function M.isActive() return modalCount > 0 end

function M.isBusy() return #flows > 0 end

function M.reset()
	assert(cfg, "crankboard.setup() must be called first")
	pd.datastore.delete(cfg.saveFile)
	loadState()
end
