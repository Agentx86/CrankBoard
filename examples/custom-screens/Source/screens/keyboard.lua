-- The panel next to the Playdate keyboard, when the player types their name.
-- The keyboard itself is drawn by the Playdate; this is the space on its left.
-- It looks exactly like CrankBoard's built-in one. Change anything you like.
--
-- What you get:
--   k.prompt     the question, e.g. "Enter your name for the online leaderboard"
--   k.text       what the player has typed so far
--   k.left       where the keyboard starts (it slides in from the right)
--   k.maxLength  the longest name allowed
--
-- Your game's last frame is already drawn behind it (darkened, see style.dim).

local gfx <const> = playdate.graphics

-- Easy things to change
local PADDING <const> = 10
local TOP <const> = 40       -- where the question starts
local promptFont = gfx.getSystemFont(gfx.font.kVariantBold)
local textFont = gfx.getSystemFont()

CrankBoardScreens = CrankBoardScreens or {}

function CrankBoardScreens.keyboard(k, ctx)
	if k.left < 40 then return end -- the keyboard covers almost everything
	local width = k.left - PADDING * 2

	-- the white panel
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRect(0, 0, k.left, ctx.height)
	gfx.setColor(gfx.kColorBlack)

	-- the question
	local _, promptH = gfx.getTextSizeForMaxWidth(k.prompt, width, nil, promptFont)
	promptH = promptH + 2
	gfx.drawTextInRect(k.prompt, PADDING, TOP, width, promptH, nil, nil, kTextAlignment.left, promptFont)

	-- the name being typed, in a box, with a blinking cursor
	local boxY = TOP + promptH + 16
	gfx.drawRect(PADDING, boxY, width, textFont:getHeight() + 10)
	local cursor = (playdate.getCurrentTimeMilliseconds() // 500) % 2 == 0 and "|" or ""
	local shown = k.text .. cursor
	while #shown > 0 and textFont:getTextWidth(shown) > width - 10 do
		shown = shown:sub(2) -- a long name scrolls to the left
	end
	textFont:drawText(shown, PADDING + 5, boxY + 5)
end
