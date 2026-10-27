-- The "please wait" box: "Sending score...", "Loading..." and "Please wait...".
-- It looks exactly like CrankBoard's built-in one. Change anything you like.
--
-- What you get:
--   m.kind   "sending", "loading" or "wait"
--   m.text   the text, e.g. "Sending score"
--   m.age    milliseconds since it appeared, for animations
--   ctx.dots an animated "..." to put after the text
--   ctx.width, ctx.height   the screen size
--
-- Your game's last frame is already drawn behind it (darkened, see style.dim).

local gfx <const> = playdate.graphics

-- Easy things to change
local WIDTH <const> = 320
local PADDING <const> = 14
local CORNER <const> = 8
local BORDER <const> = 2
local font = gfx.getSystemFont()

CrankBoardScreens = CrankBoardScreens or {}

function CrankBoardScreens.busy(m, ctx)
	local text = m.text .. ctx.dots
	local width = WIDTH - PADDING * 2
	local _, textH = gfx.getTextSizeForMaxWidth(text, width, nil, font)
	textH = textH + 2
	local height = PADDING * 2 + textH
	local x = (ctx.width - WIDTH) // 2
	local y = (ctx.height - height) // 2

	gfx.setColor(gfx.kColorWhite)
	gfx.fillRoundRect(x, y, WIDTH, height, CORNER)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(BORDER)
	gfx.drawRoundRect(x, y, WIDTH, height, CORNER)
	gfx.setLineWidth(1)

	gfx.drawTextInRect(text, x + PADDING, y + PADDING, width, textH, nil, nil, kTextAlignment.center, font)
end
