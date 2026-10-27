-- The dialog: "Join the online leaderboard?", "Score submitted!" and the error messages.
-- It looks exactly like CrankBoard's built-in dialog. Change anything you like.
--
-- What you get:
--   d.kind     what it's about: "join", "submitted", "accessDenied", "connectFailed",
--              "uploadFailed" or "rejected"
--   d.title    the title, or nil
--   d.text     the message
--   d.icon     an image from style.icons, or nil
--   d.buttons  the buttons, e.g. { { button = "a", label = "Ⓐ Yes" }, { button = "b", label = "Ⓑ No" } }
--   d.age      milliseconds since the dialog opened, for animations
--   ctx.width, ctx.height   the screen size
--
-- Your game's last frame is already drawn behind the dialog (darkened, see style.dim).
-- CrankBoard handles the buttons: you only draw.

local gfx <const> = playdate.graphics

-- Easy things to change
local WIDTH <const> = 320
local PADDING <const> = 14   -- space between the border and the text
local CORNER <const> = 8     -- rounded corners; 0 for square ones
local BORDER <const> = 2     -- border thickness
local GAP <const> = 8        -- space between the title, the text and the buttons
local titleFont = gfx.getSystemFont(gfx.font.kVariantBold)
local textFont = gfx.getSystemFont()
local buttonFont = gfx.getSystemFont() -- must have the Ⓐ Ⓑ symbols

local function textHeight(text, width, font)
	local _, h = gfx.getTextSizeForMaxWidth(text, width, nil, font)
	return h + 2
end

CrankBoardScreens = CrankBoardScreens or {}

function CrankBoardScreens.dialog(d, ctx)
	-- 1. Work out the size of the box
	local iconWidth = d.icon and (d.icon.width + 12) or 0
	local width = WIDTH - PADDING * 2 - iconWidth
	local align = d.icon and kTextAlignment.left or kTextAlignment.center

	local titleH = d.title and textHeight(d.title, width, titleFont) or 0
	local textH = textHeight(d.text or "", width, textFont)
	local blockH = titleH + textH + (titleH > 0 and GAP or 0)
	local contentH = math.max(blockH, d.icon and d.icon.height or 0)
	local buttonsH = #d.buttons > 0 and (GAP + buttonFont:getHeight() + 6) or 0
	local height = PADDING * 2 + contentH + buttonsH
	local x = (ctx.width - WIDTH) // 2
	local y = (ctx.height - height) // 2

	-- 2. The box
	gfx.setColor(gfx.kColorWhite)
	gfx.fillRoundRect(x, y, WIDTH, height, CORNER)
	gfx.setColor(gfx.kColorBlack)
	gfx.setLineWidth(BORDER)
	gfx.drawRoundRect(x, y, WIDTH, height, CORNER)
	gfx.setLineWidth(1)

	-- 3. The icon, the title and the text
	if d.icon then
		d.icon:draw(x + PADDING, y + PADDING + (contentH - d.icon.height) // 2)
	end
	local textX = x + PADDING + iconWidth
	local textY = y + PADDING + (contentH - blockH) // 2
	if d.title then
		gfx.drawTextInRect(d.title, textX, textY, width, titleH, nil, nil, align, titleFont)
		textY = textY + titleH + GAP
	end
	gfx.drawTextInRect(d.text or "", textX, textY, width, textH, nil, nil, align, textFont)

	-- 4. The buttons, "Ⓐ Yes      Ⓑ No" under a line
	if #d.buttons > 0 then
		local lineY = y + height - PADDING - (buttonFont:getHeight() + 6)
		gfx.drawLine(x + PADDING, lineY, x + WIDTH - PADDING, lineY)
		local labels = {}
		for i, button in ipairs(d.buttons) do labels[i] = button.label end
		local hint = table.concat(labels, "      ")
		buttonFont:drawText(hint, x + (WIDTH - buttonFont:getTextWidth(hint)) // 2, lineY + 5)
	end
end
