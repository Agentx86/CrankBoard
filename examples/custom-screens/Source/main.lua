-- Example 3: YOUR OWN SCREENS.
--
-- Every screen CrankBoard draws is in its own small file in the "screens" folder,
-- and they look exactly like the built-in ones. To change the look of your game's
-- leaderboard, copy the "screens" folder into your game and edit the screen you want:
--
--   screens/dialog.lua       "Join the online leaderboard?", "Score submitted!", errors
--   screens/busy.lua         "Sending score...", "Loading..."
--   screens/keyboard.lua     the panel next to the keyboard when the player types a name
--   screens/leaderboard.lua  the leaderboard screen
--
-- You only draw: CrankBoard still asks the questions, reads the buttons and sends the scores.
-- Don't need to change a screen? Leave its file out and CrankBoard uses the built-in one.
--
-- On the Playdate: Ⓐ pretends a game just ended with a random score, Ⓑ opens the leaderboard.
--
-- Before you run it:
--   1. Create a leaderboard called "highscores" and an access key in Talo (see docs/talo-setup.md).
--   2. Paste your access key below.
--   3. Copy crankboard.lua into this Source folder (next to this main.lua) and build.

import "CoreLibs/graphics"
import "crankboard"

-- Each file adds its screen to the CrankBoardScreens table
import "screens/dialog"
import "screens/busy"
import "screens/keyboard"
import "screens/leaderboard"


crankboard.setup({
	accessKey = "PASTE_YOUR_TALO_ACCESS_KEY_HERE",
	leaderboard = "highscores",

	draw = CrankBoardScreens, -- use the screens from the "screens" folder

	-- No Talo account yet? Run tools/mock_talo.py on your computer and remove the "--" below:
	-- host = "127.0.0.1", port = 8787, useSSL = false,
})


local lastScore = nil

function playdate.update()
	if crankboard.update() then
		return
	end

	if playdate.buttonJustPressed(playdate.kButtonA) then
		lastScore = math.random(10, 999)
		crankboard.submitScore(lastScore)
	end
	if playdate.buttonJustPressed(playdate.kButtonB) then
		crankboard.showLeaderboard()
	end

	local gfx = playdate.graphics
	gfx.clear()
	gfx.drawTextAligned("*CrankBoard: your own screens*", 200, 40, kTextAlignment.center)
	gfx.drawText("Ⓐ  A game ended: send a random score", 40, 100)
	gfx.drawText("Ⓑ  Open the online leaderboard", 40, 130)
	gfx.drawTextAligned("Edit the files in the screens folder", 200, 170, kTextAlignment.center)
	if lastScore then
		gfx.drawTextAligned("Last score sent: " .. lastScore, 200, 200, kTextAlignment.center)
	end
end
