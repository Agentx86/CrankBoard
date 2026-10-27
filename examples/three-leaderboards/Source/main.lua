-- Example 2: THREE online leaderboards: this week, this month and all time.
--
-- The game: press Ⓐ as many times as you can in 5 seconds.
-- Every game is sent online, together with the tap speed (extra data).
-- The leaderboard screen has a tab for each leaderboard.
--
-- Before you run it:
--   1. Create three leaderboards and an access key in Talo (see docs/talo-setup.md):
--        weekly  (Refresh entries: Weekly)
--        monthly (Refresh entries: Monthly)
--        alltime (Refresh entries: Never)
--   2. Paste your access key below (STEP 1).
--   3. Copy crankboard.lua into this Source folder (next to this main.lua) and build.

import "CoreLibs/graphics"
import "crankboard"

local gfx <const> = playdate.graphics

local ROUND_SECONDS <const> = 5


-- STEP 1: connect CrankBoard to your Talo game, with three leaderboards.
-- The order here is the order of the tabs on the leaderboard screen.
crankboard.setup({
	accessKey = "PASTE_YOUR_TALO_ACCESS_KEY_HERE",
	leaderboards = {
		-- name = the "Internal name" in Talo, title = what players see on the tab,
		-- shortTitle = the name next to the place in "Score submitted!"
		{ name = "weekly", title = "This week", shortTitle = "Week" },
		{ name = "monthly", title = "This month", shortTitle = "Month" },
		{ name = "alltime", title = "All time", shortTitle = "All time" },
	},

	-- Every game is sent (not only records), so the question shouldn't say "New high score!"
	messages = { joinTitle = "Online leaderboard" },

	-- Show the scores as "42 taps", and an extra column with the speed sent in STEP 4
	formatScore = function(score) return score .. " taps" end,
	detail = function(row) return row.props.speed and (row.props.speed .. "/s") or "" end,

	-- No Talo account yet? Run tools/mock_talo.py on your computer and remove the "--" below:
	-- host = "127.0.0.1", port = 8787, useSSL = false,
})


-- STEP 2: the Playdate menu (the ⊙ button): open the leaderboard, change the name,
-- and switch online scores on or off.
local menu = playdate.getSystemMenu()
menu:addMenuItem("leaderboard", function() crankboard.showLeaderboard({ limit = 10 }) end)
menu:addMenuItem("change name", function() crankboard.editName() end)
local onlineItem = menu:addCheckmarkMenuItem("online", crankboard.isOptedIn(), function(on)
	crankboard.setOptedIn(on) -- turning it on also sends the games played while it was off
end)

-- Scores that couldn't be sent last time (no Wi-Fi) are sent now
crankboard.flush()


-- The game itself. Nothing here is special to CrankBoard, except STEP 3 and STEP 4.

local score = 0
local newBest = false
local screen = "menu" -- "menu", "playing" or "gameover"
local roundEndsAt = 0
local gameOverAt = 0
local scoreSent = false
local onlineResult = nil -- what happened to the score, shown on the game over screen

local RESULT_TEXT <const> = {
	[crankboard.SUBMITTED] = "Sent to the online leaderboard",
	[crankboard.QUEUED] = "No connection: it will be sent later",
	[crankboard.DENIED] = "Network access is turned off",
	[crankboard.DECLINED] = "Kept on this Playdate only",
	[crankboard.LOCAL] = "Kept on this Playdate only",
	[crankboard.FAILED] = "Couldn't send the score",
}

local function centered(text, y)
	gfx.drawTextAligned(text, 200, y, kTextAlignment.center)
end

function playdate.update()
	-- STEP 3: give CrankBoard a turn first, every frame.
	if crankboard.update() then
		return
	end

	local now = playdate.getCurrentTimeMilliseconds()
	if onlineItem:getValue() ~= crankboard.isOptedIn() then
		onlineItem:setValue(crankboard.isOptedIn()) -- keep the menu checkmark up to date
	end
	gfx.clear()

	if screen == "menu" then
		centered("*TAP TAP TAP*", 60)
		centered("Best: " .. (crankboard.getBest("alltime") or 0), 100) -- CrankBoard remembers it
		centered("Ⓐ Play       Ⓑ Online leaderboard", 180)
		if playdate.buttonJustPressed(playdate.kButtonA) then
			screen, score, roundEndsAt = "playing", 0, now + ROUND_SECONDS * 1000
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			crankboard.showLeaderboard({ limit = 10 }) -- top 10, and your own place below it
		end

	elseif screen == "playing" then
		if playdate.buttonJustPressed(playdate.kButtonA) then
			score = score + 1
		end
		centered("*" .. score .. "*", 100)
		centered(string.format("%.1f seconds left", math.max(0, roundEndsAt - now) / 1000), 140)
		if now >= roundEndsAt then
			screen, gameOverAt, scoreSent, onlineResult, newBest = "gameover", now, false, nil, false
		end

	elseif screen == "gameover" then
		centered(newBest and "*New best score!*" or "*Time's up!*", 50)
		centered("Score: " .. score .. "     Best: " .. (crankboard.getBest("alltime") or score), 90)

		-- STEP 4: send EVERY game, not only records: a new week starts empty,
		-- and Talo keeps only each player's best score per leaderboard anyway.
		-- "props" is extra data saved with the score; here, the taps per second.
		if not scoreSent and now - gameOverAt > 1000 and score > 0 then
			scoreSent = true
			-- submitScore also keeps the best score on this Playdate, and says right away if it's new
			newBest = crankboard.submitScore(score, {
				props = { speed = string.format("%.1f", score / ROUND_SECONDS) },
				onComplete = function(result, info)
					onlineResult = RESULT_TEXT[result]
					if info.ranks and info.ranks.weekly then
						onlineResult = onlineResult .. " (#" .. info.ranks.weekly .. " this week)"
					end
				end,
			})
		end

		if onlineResult then
			centered(onlineResult, 130)
		end
		if scoreSent or score == 0 then
			centered("Ⓐ Back to menu", 190)
			if playdate.buttonJustPressed(playdate.kButtonA) then
				screen = "menu"
			end
		end
	end
end
