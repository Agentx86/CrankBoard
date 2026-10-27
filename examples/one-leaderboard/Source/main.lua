-- Example 1: ONE online leaderboard for all time.
--
-- The game: press Ⓐ as many times as you can in 5 seconds.
-- When you beat your best score, it goes to the online leaderboard.
--
-- Before you run it:
--   1. Create a leaderboard and an access key in Talo (see docs/talo-setup.md).
--   2. Paste your access key below (STEP 1).
--   3. Copy crankboard.lua into this Source folder (next to this main.lua) and build.

import "CoreLibs/graphics"
import "crankboard"

local gfx <const> = playdate.graphics


-- STEP 1: connect CrankBoard to your Talo game. Do this once, at the start.
crankboard.setup({
	accessKey = "PASTE_YOUR_TALO_ACCESS_KEY_HERE",
	leaderboard = "highscores", -- the "Internal name" of your leaderboard in Talo

	-- No Talo account yet? Run tools/mock_talo.py on your computer and remove the "--" below:
	-- host = "127.0.0.1", port = 8787, useSSL = false,
})


-- STEP 2: let players open the leaderboard from the Playdate menu (the ⊙ button).
playdate.getSystemMenu():addMenuItem("leaderboard", function()
	crankboard.showLeaderboard()
end)


-- The game itself. Nothing here is special to CrankBoard, except STEP 3 and STEP 4.

local score = 0
local screen = "menu" -- "menu", "playing" or "gameover"
local roundEndsAt = 0
local gameOverAt = 0
local scoreSent = false

local function centered(text, y)
	gfx.drawTextAligned(text, 200, y, kTextAlignment.center)
end

function playdate.update()
	-- STEP 3: give CrankBoard a turn first, every frame.
	-- While it shows a question or the leaderboard, it returns true:
	-- then we stop here, and the game waits.
	if crankboard.update() then
		return
	end

	local now = playdate.getCurrentTimeMilliseconds()
	gfx.clear()

	if screen == "menu" then
		centered("*TAP TAP TAP*", 60)
		centered("Best: " .. (crankboard.getBest() or 0), 100) -- CrankBoard remembers the best score
		centered("Ⓐ Play       Ⓑ Online leaderboard", 180)
		if playdate.buttonJustPressed(playdate.kButtonA) then
			screen, score, roundEndsAt = "playing", 0, now + 5000
		elseif playdate.buttonJustPressed(playdate.kButtonB) then
			crankboard.showLeaderboard()
		end

	elseif screen == "playing" then
		if playdate.buttonJustPressed(playdate.kButtonA) then
			score = score + 1
		end
		centered("*" .. score .. "*", 100)
		centered(string.format("%.1f seconds left", math.max(0, roundEndsAt - now) / 1000), 140)
		if now >= roundEndsAt then
			screen, gameOverAt, scoreSent = "gameover", now, false
		end

	elseif screen == "gameover" then
		centered("*Time's up!*", 60)
		centered("Score: " .. score .. "     Best: " .. (crankboard.getBest() or 0), 100)

		-- STEP 4: send the score if it's a new best.
		-- We wait one second first, so the player isn't still pressing Ⓐ
		-- when the question "Join the online leaderboard?" appears.
		if not scoreSent and now - gameOverAt > 1000 then
			scoreSent = true
			if crankboard.isNewBest(score) then
				crankboard.submitScore(score) -- this also saves it as the new best
			end
		end

		if scoreSent then
			centered("Ⓐ Back to menu", 180)
			if playdate.buttonJustPressed(playdate.kButtonA) then
				screen = "menu"
			end
		end
	end
end
