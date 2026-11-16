--!strict
-- Issues: the YouTrack plugin's page, laid out as a Linear-style list.
--
-- A head (title, count, refresh) and three filters as tabs (Assigned to me,
-- Reported by me, All) stand still; under them one card fills the rest of
-- the page: a quiet search field heading it, then the issues grouped by
-- state, each group a header (its chevron, dot, name, count) on a light
-- wash that folds (not sticky: a header that sticks over glass has to be
-- opaque or blur what's under it each frame, and both cost), each issue one
-- dense row: priority bars, the id in mono, the title, its tags, who it's
-- assigned to, when it last changed. A row opens the issue in the browser.
-- Read-only: GET requests alone.
--
-- Drawn as Zeron draws its long lists (ds/git_changes): the groups and
-- issues flattened into rows of known heights, in one `ui.list` that builds
-- only the slice in view, keyed by issue (and its `updated`, so a changed
-- issue is drawn again and the rest stay as they stood), with Zeron's own
-- rail (ds/rail) as its scrollbar. A fold drops its rows from the list,
-- re-laid out from the heights it knows, building nothing offscreen.
--
-- What it was looking at (the filter, the folded groups) is kept between
-- runs (`zeron.store`).

local git = require("@ds/git")
local Badge = require("@ds/badge")
local ListRow = require("@ds/list_row").ListRow
local IconButton = require("@ds/icon_button").IconButton
local Text = require("@ds/text")
local Tabs = require("@ds/tabs")
local SearchField = require("@ds/search_field")
local EmptyState = require("@ds/empty_state")
local Rail = require("@ds/rail")
local banner = require("@ds/banner")
local skeleton = require("@ds/skeleton")
local control = require("@ds/control")

local FILTER_KEYS = { "assigned", "reported", "all" }

-- Under this width (a pane's), dates and tags step aside.
local NARROW = 640

-- Every five minutes, asked again behind what's showing.
local REFRESH_MS = 5 * 60 * 1000

-- Rows' own heights (points), the hairline above each but the first added
-- in `heights`: the list lays every row out from these, measuring none.
local ISSUE_H = 40
local GROUP_H = 34
local RULE_H = 1

-- The groups' order: these first, as asked (Backlog, then Blocked, then
-- Ready to go); then every other state in its project's own order (the
-- order its admins set for its State field, as its board's columns
-- stand, asked of YouTrack: `api.states`); a state none of them names
-- after, by name.
local PINNED = { "backlog", "blocked", "ready to go" }

-- How issues' parts are drawn: shared with the issue's tab (look.luau).
local look = require("./look")
local state_hue, tag_hue, dot, short_date = look.state_hue, look.hue_of, look.dot, look.short_date
local function PriorityMark(p: string?): Node
	return look.PriorityMark(p, true)
end
local Initials = look.Initials

-- A state's place: pinned ones first; then where its project's order puts
-- it (`orders`: each project's states, in order); else last.
local function state_rank(state: string?, orders: { [string]: { string } }): number
	local s = string.lower(state or "")
	for i, name in PINNED do
		if s == name then
			return i
		end
	end
	for _, names in orders do
		for i, name in names do
			if string.lower(name) == s then
				return #PINNED + i
			end
		end
	end
	return math.huge
end

-- What a row says, lowered once per issue: the search reads this.
local function haystack(issue: any): string
	local tags = {}
	for _, t in issue.tags do
		table.insert(tags, t.name)
	end
	return string.lower(`{issue.id} {issue.summary} {issue.state or ""} {issue.priority or ""} {issue.type or ""} {(issue.assignee and issue.assignee.name) or ""} {table.concat(tags, " ")}`)
end

-- Whether every word of `query` is somewhere in `text`.
local function matches(text: string, query: string): boolean
	for word in string.gmatch(string.lower(query), "%S+") do
		if not string.find(text, word, 1, true) then
			return false
		end
	end
	return true
end

type Row = {
	key: string,
	kind: "group" | "issue",
	h: number,
	name: string?,
	count: number?,
	issue: any?,
}

-- A kept list younger than this is shown as is; an older one is shown and
-- asked again behind it.
local FRESH_SECONDS = 60

return function(zeron: any, api: any, cache: any): (props: { panel: any? }) -> Node
	return ui.component(function(props: { panel: any? }): Node
		-- The issue open in the page's panel (its row on the selection wash).
		local open_id = ui.use_state(nil :: string?)
		local kept = zeron.store("board", { filter = "assigned" })
		local folded = zeron.store("folded", {} :: { [string]: boolean })
		local query = ui.use_state("")
		local issues = ui.use_state({} :: { any })
		local state = ui.use_state("loading")
		local failed = ui.use_state(nil :: string?)
		local width = ui.use_state(0)
		local filter_value = ui.use_state((kept:peek() or {}).filter or "assigned")
		-- The list's scroll, and how tall its view stands (for the rail).
		local offset = ui.use_state(0)
		local seen = ui.use_state(0)
		local asked = 0

		local function narrow(): boolean
			local w = width:get()
			return w > 0 and w < NARROW
		end

		-- Backlog starts folded each time the page opens: opening it holds for
		-- this visit only (not kept). Every other group's fold is kept.
		local backlog_open = ui.use_state(false)
		local function is_backlog(name: string): boolean
			return string.lower(name) == "backlog"
		end

		local function is_folded(name: string): boolean
			if is_backlog(name) then
				return not backlog_open:get()
			end
			return ((folded:get() or {}) :: any)[name] == true
		end

		local function toggle(name: string)
			if is_backlog(name) then
				backlog_open:set(not backlog_open:peek())
				return
			end
			local next = table.clone((folded:peek() or {}) :: any)
			next[name] = if next[name] then nil else true
			folded:set(next)
		end

		-- Each project's states in its own order, kept between runs (so the
		-- groups stand in place at once) and asked again once a run per
		-- project, from one of its issues, as a list shows it.
		local orders = zeron.store("state_order", {} :: { [string]: { string } })
		local asked_order: { [string]: boolean } = {}
		local function ensure_orders(list: { any })
			for _, issue in list do
				local p = issue.project
				if p and not asked_order[p] then
					asked_order[p] = true
					api.states(issue.id):after(function(r: any)
						local names = api.parse_states(r)
						if names then
							local next = table.clone((orders:peek() or {}) :: any)
							next[p] = names
							orders:set(next)
						end
					end, function() end)
				end
			end
		end

		-- A list to show: each issue's search text made once, here.
		local function show(list: { any })
			for _, issue in list do
				issue.text = haystack(issue)
			end
			issues:set(list)
			failed:set(nil)
			state:set("ready")
			ensure_orders(list)
		end

		-- The list from YouTrack. `quiet`: behind what's showing, which stays
		-- (no skeleton), and stays if the ask fails.
		local function fetch(quiet: boolean?)
			asked += 1
			local mine = asked
			local filter = filter_value:peek()
			local key = api.key(filter)
			if not quiet then
				state:set("loading")
			end
			api.issues(filter):after(function(r: any)
				if mine ~= asked then
					return
				end
				local list, why = api.parse(r)
				if list then
					cache.put(key, list)
					show(table.clone(list))
				elseif not (quiet and state:peek() == "ready") then
					failed:set(why)
					state:set("failed")
				end
			end, function(err: any)
				if mine ~= asked or (quiet and state:peek() == "ready") then
					return
				end
				failed:set(if type(err) == "table" and err.message then tostring(err.message) else tostring(err))
				state:set("failed")
			end)
		end

		-- The list: what's kept for it shown at once (and, older than a
		-- minute, asked again behind it); nothing kept, asked with a skeleton.
		-- `refresh`: asked again whatever's kept.
		local function load(refresh: boolean?)
			local c = api.config()
			if c.token == "" or c.base == "" then
				asked += 1
				state:set("setup")
				return
			end
			if refresh then
				fetch(state:peek() == "ready")
				return
			end
			asked += 1
			local mine = asked
			cache.get(api.key(filter_value:peek()), function(value: any?, at: number?)
				if mine ~= asked then
					return
				end
				if type(value) == "table" then
					show(table.clone(value))
					if not at or os.time() - at > FRESH_SECONDS then
						fetch(true)
					end
				else
					fetch(false)
				end
			end)
		end
		load()

		-- An issue changed in its tab: the list asked again behind itself.
		require("./bus").listen(function(_id: string)
			load(true)
		end)

		-- The settings changing: asked again with them.
		zeron.on_setting(function()
			load()
		end)

		ui.every(REFRESH_MS, function()
			if state:peek() == "ready" then
				load(true)
			end
		end)

		-- A tab chosen. (ds/tabs sets `filter_value` itself before telling us,
		-- and tells us only of a change, so no "same as now" check here: it
		-- would always hold, and the list would never be asked again.)
		local function set_filter(f: string)
			filter_value:set(f)
			kept:set({ filter = f })
			offset:set(0)
			load()
		end

		-- The groups and issues as one run of rows: a group's header, then
		-- (unless folded) its issues, the groups in work's order. Followed as
		-- the issues, the search and the folds change.
		local rows = ui.computed(function(): { Row }
			local q = query:get()
			local by: { [string]: { any } } = {}
			local names: { string } = {}
			for _, issue in issues:get() do
				if matches(issue.text or "", q) then
					local name = issue.state or zeron.s("board.no_state")
					if not by[name] then
						by[name] = {}
						table.insert(names, name)
					end
					table.insert(by[name], issue)
				end
			end
			local by_project = (orders:get() or {}) :: any
			table.sort(names, function(a: string, b: string): boolean
				local ra, rb = state_rank(a, by_project), state_rank(b, by_project)
				if ra ~= rb then
					return ra < rb
				end
				return a < b
			end)
			local out: { Row } = {}
			for _, name in names do
				table.insert(out, { key = `g:{name}`, kind = "group", h = GROUP_H, name = name, count = #by[name] })
				if not is_folded(name) then
					for _, issue in by[name] do
						table.insert(out, { key = `i:{issue.id}:{issue.updated or 0}`, kind = "issue", h = ISSUE_H, issue = issue })
					end
				end
			end
			return out
		end)
		-- Each row by its key, for the list's row builder.
		local row_of = ui.computed(function(): { [string]: Row }
			local out: { [string]: Row } = {}
			for _, r in rows:get() do
				out[r.key] = r
			end
			return out
		end)
		local heights = ui.computed(function(): { number }
			local hs: { number } = {}
			for i, r in rows:get() do
				hs[i] = r.h + (if i > 1 then RULE_H else 0)
			end
			return hs
		end)
		local total = ui.computed(function(): number
			local sum = 0
			for _, h in heights:get() do
				sum += h
			end
			return sum
		end)
		local shown = ui.computed(function(): number
			local n = 0
			for _, r in rows:get() do
				if r.kind == "group" then
					n += r.count or 0
				end
			end
			return n
		end)

		local function head(): Node
			return ui.row {
				w_full = true,
				gap = "$space.3",
				items = "center",
				Text { zeron.t("board.title"), style = "title", heading = 1 },
				Text {
					function(): string
						if state:get() ~= "ready" then
							return ""
						end
						return zeron.s("board.count", { n = #issues:get() })
					end,
					style = "caption",
					tone = "tertiary",
					tabular = true,
					grow = 1,
					min_w = 0,
				},
				IconButton {
					icon = "refresh",
					label = zeron.s("board.refresh"),
					tone = "quiet",
					on_click = function()
						load(true)
					end,
				},
			}
		end

		local function filters(): Node
			local options = {}
			for _, f in FILTER_KEYS do
				table.insert(options, { value = f, label = zeron.s(`board.filters.{f}`) })
			end
			return ui.div {
				w_full = true,
				shrink = 0,
				Tabs {
					value = filter_value,
					options = options,
					label = zeron.s("board.filter"),
					on_change = function(f: any)
						set_filter(f)
					end,
				},
			}
		end

		local function search(): Node
			return ui.div {
				w_full = true,
				shrink = 0,
				p = "$space.1",
				theme = { radius = { md = control.nest(git.RADIUS, git.EDGE, "$space.1") } },
				SearchField {
					value = query,
					placeholder = zeron.s("board.search"),
					name = zeron.s("board.search"),
					size = "sm",
					quiet = true,
					w_full = true,
					results = function(): number
						return shown:get()
					end,
				},
			}
		end

		-- One issue, one line.
		local function issue_row(issue: any): Node
			local tags: { Node } = {}
			for i, t in issue.tags do
				if i > 3 then
					break
				end
				table.insert(tags, Badge.Tag { t.name, hue = tag_hue(t.name), size = "sm" })
			end
			return ListRow {
				class = "youtrack-row",
				label = `{issue.id} {issue.summary}`,
				h = ISSUE_H,
				selected = function(): boolean
					return open_id:get() == issue.id
				end,
				on_click = function()
					-- In the page's panel, as a tab (one already open comes
					-- forward), with what the list knows so it draws at once.
					open_id:set(issue.id)
					if props.panel then
						props.panel.open_tab {
							kind = "youtrack-issue",
							title = issue.id,
							icon = "checklist",
							data = {
								key = issue.id,
								id = issue.id,
								summary = issue.summary,
								state = issue.state,
								priority = issue.priority,
								type = issue.type,
								assignee = issue.assignee,
								updated = issue.updated,
								url = issue.url,
							},
						}
					else
						zeron.open_url(issue.url)
					end
				end,
				ui.row {
					w_full = true,
					h_full = true,
					px = "$space.4",
					gap = "$space.3",
					items = "center",
					PriorityMark(issue.priority),
					Text { issue.id, style = "mono", tone = "tertiary", w = 76, shrink = 0, truncate = true, tabular = true },
					dot(state_hue(issue.state)),
					Text { issue.summary, grow = 1, min_w = 0, truncate = true },
					if #tags > 0
						then ui.show(function(): boolean
							return not narrow()
						end, ui.row { gap = "$space.1", shrink = 0, items = "center", table.unpack(tags) })
						else nil,
					ui.row {
						w = 20,
						shrink = 0,
						justify = "center",
						tooltip = if issue.assignee then issue.assignee.name else zeron.s("board.unassigned"),
						if issue.assignee
							then Initials(issue.assignee)
							else ui.div { w = 16, h = 16, rounded = "$radius.full", border = 1, border_color = "$border" },
					},
					ui.show(function(): boolean
						return not narrow()
					end, Text { short_date(issue.updated), style = "caption", tone = "tertiary", w = 56, shrink = 0, align = "right", tabular = true }),
				},
			}
		end

		-- A state's header: its chevron, dot, name, how many; a click folds it.
		-- A light wash over the card, the theme's own hover ink, so it reads as
		-- a band on the card's glass and never as a hole in it.
		local function group_row(name: string, count: number): Node
			return ListRow {
				class = "youtrack-group",
				label = name,
				h = GROUP_H,
				on_click = function()
					toggle(name)
				end,
				ui.row {
					w_full = true,
					h_full = true,
					px = "$space.4",
					gap = "$space.2",
					items = "center",
					bg = "$hover",
					ui.div {
						w = 16,
						shrink = 0,
						color = "$text.tertiary",
						git.chevron(function(): number
							return if is_folded(name) then -90 else 0
						end, 12),
					},
					dot(state_hue(name), 8),
					Text { name, style = "label", tone = "secondary" },
					Text { tostring(count), style = "caption", tone = "tertiary", tabular = true },
				},
			}
		end

		-- A row of the list by its key, the hairline above it but the first.
		local function build(key: string, index: State<number>): Node
			local r = row_of:peek()[key]
			if not r then
				return ui.div { h = ISSUE_H }
			end
			return ui.column {
				w_full = true,
				ui.show(function(): boolean
					return index:get() > 1
				end, git.rule()),
				if r.kind == "group" then group_row(r.name :: string, r.count or 0) else issue_row(r.issue),
			}
		end

		-- The list: only the slice in view built, Zeron's rail over it.
		local function list(): Node
			return ui.div {
				w_full = true,
				grow = 1,
				min_h = 0,
				relative = true,
				on_resize = function(size)
					seen:set(size.h)
				end,
				ui.list {
					w_full = true,
					h_full = true,
					offset = offset,
					overscan = 6,
					label = zeron.s("board.title"),
					heights = function(): { number }
						return heights:get()
					end,
					key = function(i: number): string
						local r = rows:get()[i]
						return if r then r.key else `none:{i}`
					end,
					row = function(key: string, index: State<number>): Node
						return build(key, index)
					end,
					row_text = function(i: number): string
						local r = rows:peek()[i]
						if not r then
							return ""
						end
						return if r.kind == "group" then r.name or "" else `{r.issue.id} {r.issue.summary}`
					end,
				},
				Rail { offset = offset, extent = total, view = seen },
			}
		end

		-- What the card holds under its search: the list, or why it's empty.
		local function card_body(): Node
			return ui.presence(function(): string
				return if #rows:get() > 0 then "list" elseif query:get() ~= "" then "nomatch" else "none"
			end, function(key: string): Node
				if key == "list" then
					return list()
				end
				local q = query:peek()
				return ui.column {
					w_full = true,
					grow = 1,
					py = "$space.6",
					px = "$space.4",
					if key == "nomatch"
						then EmptyState { icon = "search", title = zeron.s("board.empty.nomatch_title", { q = q }), body = zeron.s("board.empty.nomatch_body") }
						else EmptyState { icon = "inbox", title = zeron.s("board.empty.none_title"), body = zeron.s("board.empty.none_body") },
				}
			end, { w_full = true, grow = 1, min_h = 0 })
		end

		local function body(): Node
			return ui.presence(function(): string
				return state:get()
			end, function(key: string): Node
				if key == "setup" then
					return EmptyState {
						icon = "settings",
						title = zeron.s("board.empty.setup_title"),
						body = zeron.s("board.empty.setup_body"),
						fill = true,
					}
				elseif key == "loading" then
					local rows_: { Node } = {}
					for _ = 1, 6 do
						table.insert(rows_, skeleton.Row { lead = 16, title = 280, trail = 56 })
					end
					return git.card(nil, rows_)
				elseif key == "failed" then
					return banner.Callout {
						tone = "danger",
						title = zeron.s("board.failed_title"),
						body = failed:peek() or "",
						action = {
							label = zeron.s("board.try_again"),
							on_click = function()
								load(true)
							end,
						},
					}
				end
				-- (A card that fills the room left: the list scrolls inside it,
				-- the head and the tabs above standing still.)
				return git.frame {
					fill = true,
					search(),
					git.rule(),
					card_body(),
				}
			end, { w_full = true, grow = 1, min_h = 0, enter = { opacity = { 0, 1 }, duration = 120 }, exit = { opacity = 0, duration = 60 }, mode = "wait" })
		end

		local function gutter(): string
			return if narrow() then "$space.4" else "$space.6"
		end

		local function page(): Node
			return ui.column {
				class = "youtrack-board",
				w_full = true,
				h_full = true,
				items = "center",
				px = gutter,
				pt = gutter,
				pb = gutter,
				on_resize = function(size)
					local w = math.floor(size.w)
					if w > 0 and w ~= width:peek() then
						width:set(w)
					end
				end,
				ui.column {
					w_full = true,
					h_full = true,
					min_h = 0,
					max_w = ui.raw(1040, "a list a little wider than the GitHub board"),
					gap = "$space.5",
					head(),
					filters(),
					body(),
				},
			}
		end

		-- (Tabs take words, not functions: built again as the language changes.)
		local locale = ui.shared("zeron.locale", "en")
		return ui.presence(function(): string
			local l = locale:get()
			return if type(l) == "string" then l else "en"
		end, function(): Node
			return page()
		end, { w_full = true, h_full = true })
	end)
end
