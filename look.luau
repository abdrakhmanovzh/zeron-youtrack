--!strict
-- How the plugin draws an issue's parts, the same in the list (board.luau)
-- and in the issue's tab (viewer.luau): its state's hue, its priority's
-- bars, a tag's hue, someone as their initials, a date. Theme tokens and
-- palette hues alone, so every theme agrees.

local Icon = require("@ds/icon")

local M = {}

-- A state's hue, by words in its name.
function M.state_hue(state: string?): string
	local s = string.lower(state or "")
	if string.find(s, "progress", 1, true) then
		return "amber"
	elseif string.find(s, "review", 1, true) or string.find(s, "verif", 1, true) then
		return "violet"
	elseif string.find(s, "ready", 1, true) or string.find(s, "done", 1, true) or string.find(s, "fixed", 1, true) then
		return "emerald"
	elseif string.find(s, "block", 1, true) then
		return "red"
	elseif string.find(s, "open", 1, true) or string.find(s, "submit", 1, true) or string.find(s, "to do", 1, true) then
		return "sky"
	end
	return "gray"
end

-- A name's hue: the same name, the same hue, every time (tags, people).
local HUES = { "blue", "teal", "indigo", "orange", "rose", "lime", "sky", "violet" }
function M.hue_of(name: string): string
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 997
	end
	return HUES[(h % #HUES) + 1]
end

-- How many of the three bars a priority lights; 4 is urgent.
function M.priority_level(p: string?): number
	local s = string.lower(p or "")
	if string.find(s, "show", 1, true) or string.find(s, "critical", 1, true) or string.find(s, "urgent", 1, true) then
		return 4
	elseif string.find(s, "major", 1, true) or string.find(s, "high", 1, true) then
		return 3
	elseif string.find(s, "normal", 1, true) or string.find(s, "medium", 1, true) then
		return 2
	elseif string.find(s, "minor", 1, true) or string.find(s, "low", 1, true) then
		return 1
	end
	return 0
end

-- Linear's priority mark: three rising bars, as many lit as it's worth;
-- urgent, a warning in the danger's ink. `tip`: its name on hover.
function M.PriorityMark(p: string?, tip: boolean?): Node
	local level = M.priority_level(p)
	if level == 4 then
		return ui.row {
			w = 16,
			h = 16,
			shrink = 0,
			items = "center",
			justify = "center",
			tooltip = if tip then p else nil,
			Icon { name = "danger-triangle", size = 14, color = "$danger" },
		}
	end
	local bars: { Node } = {}
	for i = 1, 3 do
		table.insert(bars, ui.div {
			w = 3,
			h = 3 + i * 3,
			rounded = 1,
			bg = if i <= level then "$text.secondary" else "$border",
		})
	end
	return ui.row {
		w = 16,
		h = 16,
		shrink = 0,
		gap = 1.5,
		items = "end",
		justify = "center",
		pb = 2,
		tooltip = if tip then p else nil,
		table.unpack(bars),
	}
end

function M.dot(hue: string, size: number?): Node
	local s = size or 8
	return ui.div { w = s, h = s, shrink = 0, rounded = "$radius.full", bg = `$palette.{hue}.500` }
end

-- Up to two letters of a name ("Zhassulan A" → "ZA"), by character, not
-- byte, so a Cyrillic name gives letters and not halves of them.
function M.initials(name: string): string
	local out = {}
	for word in string.gmatch(name, "%S+") do
		local ok, cp = pcall(utf8.codepoint, word, 1)
		if ok and cp then
			table.insert(out, utf8.char(cp))
		end
		if #out == 2 then
			break
		end
	end
	return string.upper(table.concat(out))
end

-- Someone as a flat circle of their initials on their hue. Not ds/people's
-- face: YouTrack's pictures need the token, so every face fell back to its
-- shader-drawn waves and faded in as its row came into view, a dozen at a
-- time while scrolling. This is a box and two letters, drawn at once.
function M.Initials(p: any, size: number?): Node
	local s = size or 18
	local hue = M.hue_of(p.login or p.name or "")
	return ui.row {
		w = s,
		h = s,
		shrink = 0,
		rounded = "$radius.full",
		bg = `$palette.{hue}.600`,
		items = "center",
		justify = "center",
		ui.text {
			M.initials(p.name or p.login or "?"),
			text_size = math.floor(s * 0.45),
			weight = "$font.weight.semibold",
			color = `$palette.{hue}.100`,
		},
	}
end

-- A date as Linear writes it: "Nov 12", the year only when it isn't this one.
function M.short_date(ms: number?): string
	if not ms then
		return ""
	end
	local t = ms // 1000
	if os.date("%Y", t) == os.date("%Y") then
		return (os.date("%b %d", t) :: string)
	end
	return (os.date("%b %d, %Y", t) :: string)
end

return M
