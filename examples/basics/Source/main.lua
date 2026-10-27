-- Example 0: THE BASICS. No game, just the calls.
--
-- CrankBoard needs four calls. This example shows each one and when to make it.
-- On the Playdate: Ⓐ pretends a game just ended with a random score, Ⓑ opens the leaderboard.
--
-- Before you run it:
--   1. Create a leaderboard called "highscores" and an access key in Talo (see docs/talo-setup.md).
--   2. Paste your access key below.
--   3. Copy crankboard.lua into this Source folder (next to this main.lua) and build.

import "CoreLibs/graphics"
import "crankboard"


-- 1. WHEN YOUR GAME STARTS: connect to Talo. Once.
crankboard.setup({
	accessKey = "PASTE_YOUR_TALO_ACCESS_KEY_HERE",
	leaderboard = "highscores", -- the "Internal name" of your leaderboard in Talo

	-- No Talo account yet? Run tools/mock_talo.py on your computer and remove the "--" below:
	-- host = "127.0.0.1", port = 8787, useSSL = false,
})


local lastScore = nil

function playdate.update()
	-- 2. EVERY FRAME, FIRST THING: give CrankBoard a turn.
	--    While it shows something, it returns true: then skip your game for this frame.
	if crankboard.update() then
		return
	end

	-- 3. WHEN A GAME ENDS: send the score if it's the player's new best.
	--    CrankBoard remembers the best score on this Playdate, so you don't have to.
	if playdate.buttonJustPressed(playdate.kButtonA) then
		lastScore = math.random(10, 999)
		if crankboard.isNewBest(lastScore) then
			crankboard.submitScore(lastScore)
		end
	end

	-- 4. WHEN THE PLAYER WANTS TO SEE THE SCORES: open the leaderboard.
	if playdate.buttonJustPressed(playdate.kButtonB) then
		crankboard.showLeaderboard()
	end

	-- That's all. Below, only the text on the screen.
	local gfx = playdate.graphics
	gfx.clear()
	gfx.drawTextAligned("*CrankBoard: the basics*", 200, 40, kTextAlignment.center)
	gfx.drawText("Ⓐ  A game ended: send a random score", 40, 100)
	gfx.drawText("Ⓑ  Open the online leaderboard", 40, 130)
	if lastScore then
		gfx.drawTextAligned("Last score: " .. lastScore .. "     Best: " .. (crankboard.getBest() or "-"),
			200, 190, kTextAlignment.center)
	end
end
