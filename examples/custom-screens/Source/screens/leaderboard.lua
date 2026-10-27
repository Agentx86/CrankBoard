-- The leaderboard screen: tabs at the top, the scores, the button hints at the bottom.
-- It looks exactly like CrankBoard's built-in one. Change anything you like.
--
-- What you get:
--   view.tabs         every tab: { name, title, loading, error, rows, scroll }
--   view.index        which tab is open (1, 2, 3...)
--   view.tab          the open tab
--   view.tab.rows     the scores, or nil while loading or after an error. Each row:
--                       row.rank (1 = best), row.name, row.score (text), row.props, row.own
--                     or { gap = true }: the ". . ." between the top list and the player's own row
--   view.tab.scroll   how many rows are scrolled away at the top
--   view.tab.note     when there's no connection: "No connection: scores from 2 days ago",
--                     and view.tab.rows are the scores saved the last time
--   view.visibleRows  how many rows fit on a page (set style.visibleRows to change it)
--   view.detail       the "detail" function from setup, or nil
--   view.hints        the button hints, e.g. { "⬅️➡️ Board", "Ⓑ Back" }
--   view.texts        texts from messages: loading, empty, retry
--   ctx.dots          an animated "..."
--   ctx.width, ctx.height   the screen size
--
-- CrankBoard handles the buttons and the scrolling: you only draw.
-- If you change ROW_HEIGHT or HEADER_HEIGHT, also set style.visibleRows in crankboard.setup()
-- to the number of rows that fit.

local gfx <const> = playdate.graphics

-- Easy things to change
local HEADER_HEIGHT <const> = 26
local ROW_HEIGHT <const> = 20
local rowFont = gfx.getSystemFont()
local ownRowFont = gfx.getSystemFont(gfx.font.kVariantBold)
local tabFont = gfx.getSystemFont(gfx.font.kVariantBold)
local hintFont = gfx.getSystemFont() -- must have the Ⓐ Ⓑ ⬅️ ➡️ symbols

local function fit(font, text, width)
	if font:getTextWidth(text) <= width then return text end
	while #text > 0 and font:getTextWidth(text .. "...") > width do
		text = text:sub(1, -2)
	end
	return text .. "..."
end

-- The black bar with the tabs; the open tab is a white "pill"
local function drawTabs(view, width)
	gfx.setColor(gfx.kColorBlack)
	gfx.fillRect(0, 0, width, HEADER_HEIGHT)
	local textY = (HEADER_HEIGHT - tabFont:getHeight()) // 2

	if #view.tabs == 1 then
		local title = view.tabs[1].title
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		tabFont:drawText(title, (width - tabFont:getTextWidth(title)) // 2, textY)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		return
	end

	local widths, total = {}, -4
	for i, tab in ipairs(view.tabs) do
		widths[i] = tabFont:getTextWidth(tab.title) + 16
		total = total + widths[i] + 4
	end
	if total > width - 8 then
		-- too many tabs to fit: show only the open one, "< This week >  1/3"
		local title = string.format("< %s >  %d/%d", view.tab.title, view.index, #view.tabs)
		gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		tabFont:drawText(title, (width - tabFont:getTextWidth(title)) // 2, textY)
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		return
	end

	local x = (width - total) // 2
	for i, tab in ipairs(view.tabs) do
		if i == view.index then
			gfx.setColor(gfx.kColorWhite)
			gfx.fillRoundRect(x, 3, widths[i], HEADER_HEIGHT - 6, 5)
			gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
		else
			gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
		end
		tabFont:drawText(tab.title, x + 8, textY)
		x = x + widths[i] + 4
	end
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	gfx.setColor(gfx.kColorBlack)
end

-- The line under the tabs when there's no connection
local function noteHeight(view)
	return view.tab.note and (rowFont:getHeight() + 4) or 0
end

-- "Loading...", "No scores yet" or an error, in the middle of the screen
local function drawMessage(text, view, ctx, footerHeight)
	local width = ctx.width - 40
	local _, h = gfx.getTextSizeForMaxWidth(text, width, nil, rowFont)
	h = h + 2
	local rowsTop = HEADER_HEIGHT + noteHeight(view)
	local top = rowsTop + (ctx.height - footerHeight - rowsTop - h) // 2
	gfx.drawTextInRect(text, 20, top, width, h, nil, nil, kTextAlignment.center, rowFont)
end

local function drawRows(view, ctx)
	local tab = view.tab
	local first = tab.scroll or 0

	-- column widths from the rows on screen, so scores and details line up
	local scoreW, detailW, details = 0, 0, {}
	for i = 1, view.visibleRows do
		local row = tab.rows[first + i]
		if row and not row.gap then
			local font = row.own and ownRowFont or rowFont
			scoreW = math.max(scoreW, font:getTextWidth(row.score))
			if view.detail then
				details[i] = tostring(view.detail(row) or "")
				detailW = math.max(detailW, font:getTextWidth(details[i]))
			end
		end
	end
	local scoreRight = ctx.width - 12
	local detailRight = scoreRight - scoreW - 14
	local nameRight = detailW > 0 and (detailRight - detailW - 12) or (scoreRight - scoreW - 12)

	for i = 1, view.visibleRows do
		local row = tab.rows[first + i]
		if not row then break end
		local y = HEADER_HEIGHT + noteHeight(view) + 3 + (i - 1) * ROW_HEIGHT
		local font = row.own and ownRowFont or rowFont
		local textY = y + (ROW_HEIGHT - font:getHeight()) // 2

		if row.gap then
			rowFont:drawText(". . .", (ctx.width - rowFont:getTextWidth(". . .")) // 2, textY)
		else
			if row.own then
				-- the player's own row: black, with white text
				gfx.fillRoundRect(4, y, ctx.width - 8, ROW_HEIGHT, 4)
				gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
			end
			local rank = tostring(row.rank)
			font:drawText(rank, 46 - font:getTextWidth(rank), textY)
			font:drawText(fit(font, row.name, nameRight - 56), 56, textY)
			if details[i] and details[i] ~= "" then
				font:drawText(details[i], detailRight - font:getTextWidth(details[i]), textY)
			end
			font:drawText(row.score, scoreRight - font:getTextWidth(row.score), textY)
			gfx.setImageDrawMode(gfx.kDrawModeCopy)
		end
	end
end

CrankBoardScreens = CrankBoardScreens or {}

function CrankBoardScreens.board(view, ctx)
	local footerHeight = hintFont:getHeight() + 6
	gfx.clear(gfx.kColorWhite)
	drawTabs(view, ctx.width)

	local tab = view.tab
	if tab.note then
		-- no connection: these are the scores saved the last time
		gfx.drawTextInRect(tab.note, 8, HEADER_HEIGHT + 2, ctx.width - 16, noteHeight(view), nil, nil,
			kTextAlignment.center, rowFont)
	end
	if tab.loading or not tab.rows and not tab.error then
		drawMessage(view.texts.loading .. ctx.dots, view, ctx, footerHeight)
	elseif tab.error then
		drawMessage(tab.error .. "\n\n" .. view.texts.retry, view, ctx, footerHeight)
	elseif #tab.rows == 0 then
		drawMessage(view.texts.empty, view, ctx, footerHeight)
	else
		drawRows(view, ctx)
	end

	-- the button hints at the bottom
	local footerY = ctx.height - footerHeight
	gfx.drawLine(0, footerY, ctx.width, footerY)
	local hint = table.concat(view.hints, "    ")
	hintFont:drawText(hint, (ctx.width - hintFont:getTextWidth(hint)) // 2,
		footerY + (footerHeight - hintFont:getHeight()) // 2 + 1)
end
