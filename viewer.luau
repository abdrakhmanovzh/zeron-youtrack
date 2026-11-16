--!strict
-- An issue in the page's panel (the `youtrack-issue` tab), as Linear's
-- issue view reads in a side pane: its id and project with a way to
-- YouTrack and to ask again; its title; its properties as a quiet card,
-- where state, priority, type and assignee are pickers (the design
-- system's dropdown, their values from the issue's project) and tags come
-- off with their × and go on from a picker; its description as markdown,
-- pictures and all; then what was said, each comment a card of the design
-- system's (ds/comment) with its words as markdown.
--
-- It draws at once from what the list knew (the tab's data), and from what
-- was read before (kept for this run), then asks YouTrack for the whole
-- issue behind it. A change shows at once, is sent, and the issue is asked
-- again; refused, it goes back and a toast says why. The list hears of it
-- (bus.luau) and asks again too.
--
-- Pictures: YouTrack serves attachments only to a signed-in request, which
-- a picture can't make; but each attachment comes with a signed address
-- (its `url`) that needs no token, so a picture named in the words is shown
-- from its attachment's signed address.

local git = require("@ds/git")
local Badge = require("@ds/badge")
local IconButton = require("@ds/icon_button").IconButton
local Dropdown = require("@ds/dropdown")
local Markdown = require("@ds/markdown")
local Text = require("@ds/text")
local comment = require("@ds/comment")
local banner = require("@ds/banner")
local skeleton = require("@ds/skeleton")
local look = require("./look")
local bus = require("./bus")

-- What's been read this run: issues by id, and each project's choices
-- (its fields' values, and every tag), so a picker opens on them at once.
local known: { [string]: any } = {}
local choices: { [string]: { [string]: { any } } } = {}
local all_tags: { any }? = nil

-- YouTrack's markdown, made plain markdown: an attachment's size after a
-- picture (`![](a.png){width=70%}`) dropped, which would show as words.
local function clean(text: string?): string
	local s = text or ""
	s = string.gsub(s, "(!%b[]%b())%b{}", "%1")
	return s
end

local function unescape(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function message(err: any): string
	return if type(err) == "table" and err.message then tostring(err.message) else tostring(err)
end

local function section(title: string | Message, trail: string?): Node
	return ui.row {
		w_full = true,
		gap = "$space.2",
		items = "baseline",
		Text { title, style = "label", tone = "secondary" },
		if trail then Text { trail, style = "caption", tone = "tertiary", tabular = true } else nil,
	}
end

-- A property: its name in a column of names, its value beside it.
local function prop(name: string, value: Node): Node
	return ui.row {
		w_full = true,
		min_h = 32,
		gap = "$space.3",
		items = "center",
		Text { name, style = "caption", tone = "tertiary", w = 84, shrink = 0 },
		ui.row { grow = 1, min_w = 0, gap = "$space.1", items = "center", flex_wrap = true, value },
	}
end

-- A field's picker: its mark (a state's dot, a priority's bars, a face),
-- then the design system's dropdown as a quiet chip saying the value now,
-- its choices asked for as it first opens.
type PickProps = {
	lead: Node?,
	say: () -> string?,
	value: string?,
	items: () -> { any },
	loading: () -> boolean,
	search: string | boolean,
	placeholder: string,
	on_open: () -> (),
	on_choose: (value: string) -> (),
	enabled: boolean,
}

local Pick = ui.component(function(props: PickProps): Node
	local chosen = ui.use_state(props.value :: string?)
	if not props.enabled then
		return ui.row {
			gap = "$space.2",
			items = "center",
			props.lead,
			Text { props.say() or props.placeholder, style = "caption", tone = if props.say() then "primary" else "tertiary" },
		}
	end
	return ui.row {
		gap = "$space.1",
		items = "center",
		min_w = 0,
		props.lead,
		Dropdown {
			value = chosen,
			items = props.items,
			tone = "ghost",
			search = props.search,
			placeholder = props.placeholder,
			say = props.say,
			loading = props.loading,
			on_open = props.on_open,
			on_choose = function(v: string)
				chosen:set(v)
				props.on_choose(v)
			end,
			width = 248,
		},
	}
end)

return function(zeron: any, api: any): (props: { tab: any }) -> Node
	return ui.component(function(props: { tab: any }): Node
		local seed = props.tab.data or {}
		local id: string = seed.id or props.tab.title
		local detail = ui.use_state(known[id] :: any)
		local state = ui.use_state(if known[id] then "ready" else "loading")
		local failed = ui.use_state(nil :: string?)
		-- The project's choices: asked as a picker first opens.
		local options = ui.use_state("idle")
		local tag_list = ui.use_state(all_tags or {} :: { any })
		local tags_state = ui.use_state(if all_tags then "ready" else "idle")
		-- The tag picker's own value: nothing (a pick adds, then it's empty).
		local tag_pick = ui.use_state(nil :: string?)
		local asked = 0

		local function load()
			asked += 1
			local mine = asked
			api.issue(id):after(function(r: any)
				if mine ~= asked then
					return
				end
				local d, why = api.parse_issue(r)
				if d then
					known[id] = d
					detail:set(d)
					failed:set(nil)
					state:set("ready")
				elseif state:peek() ~= "ready" then
					failed:set(why)
					state:set("failed")
				end
			end, function(err: any)
				if mine ~= asked or state:peek() == "ready" then
					return
				end
				failed:set(message(err))
				state:set("failed")
			end)
		end
		load()

		-- A field: the whole issue's once it's here, else what the list knew.
		local function field(name: string): any
			local d = detail:get()
			if d and d[name] ~= nil then
				return d[name]
			end
			return seed[name]
		end

		local function project(): string
			local d = detail:peek()
			return (d and d.project) or string.match(id, "^(.-)%-%d+$") or "?"
		end

		-- The project's fields' values, asked once a run per project.
		local function ensure_options()
			local p = project()
			if choices[p] then
				options:set("ready")
				return
			end
			if options:peek() == "loading" then
				return
			end
			options:set("loading")
			api.options(id):after(function(r: any)
				local got, why = api.parse_options(r)
				if got then
					choices[p] = got
					options:set("ready")
				else
					options:set("failed")
					zeron.toast(zeron.s("issue.options_failed", { why = why or "" }))
				end
			end, function(err: any)
				options:set("failed")
				zeron.toast(zeron.s("issue.options_failed", { why = message(err) }))
			end)
		end

		local function ensure_tags()
			if all_tags then
				tags_state:set("ready")
				return
			end
			if tags_state:peek() == "loading" then
				return
			end
			tags_state:set("loading")
			api.tags():after(function(r: any)
				local got, why = api.parse_tags(r)
				if got then
					all_tags = got
					tag_list:set(got)
					tags_state:set("ready")
				else
					tags_state:set("failed")
					zeron.toast(zeron.s("issue.options_failed", { why = why or "" }))
				end
			end, function(err: any)
				tags_state:set("failed")
				zeron.toast(zeron.s("issue.options_failed", { why = message(err) }))
			end)
		end

		-- A change: shown at once, sent, then the issue asked again (and the
		-- list told); refused, what was there comes back and a toast says why.
		local function apply(next: any, send: () -> any)
			local prev = detail:peek()
			known[id] = next
			detail:set(next)
			local function revert(why: string)
				known[id] = prev
				detail:set(prev)
				zeron.toast(zeron.s("issue.not_saved", { why = why }))
			end
			send():after(function(r: any)
				local why = api.refused(r)
				if why then
					revert(why)
				else
					load()
					bus.changed(id)
				end
			end, function(err: any)
				revert(message(err))
			end)
		end

		local function choose(name: string, value: string)
			local d = detail:peek()
			local f = d and d.fields[name]
			if not f then
				return
			end
			local next = table.clone(d)
			if name == "Assignee" then
				local label = value
				for _, o in (choices[project()] or {})[name] or {} do
					if o.value == value then
						label = o.label
					end
				end
				next.assignee = { login = value, name = label }
			else
				next[api.EDITABLE[name]] = value
			end
			apply(next, function(): any
				return api.set_field(id, f, value)
			end)
		end

		local function remove_tag(tag: any)
			local d = detail:peek()
			if not d or not tag.id then
				return
			end
			local next = table.clone(d)
			next.tags = {}
			for _, t in d.tags do
				if t.id ~= tag.id then
					table.insert(next.tags, t)
				end
			end
			apply(next, function(): any
				return api.remove_tag(id, tag.id)
			end)
		end

		local function add_tag(tag_id: string)
			local d = detail:peek()
			if not d then
				return
			end
			local tag: any = nil
			for _, t in tag_list:peek() do
				if t.id == tag_id then
					tag = t
				end
			end
			if not tag then
				return
			end
			local next = table.clone(d)
			next.tags = table.clone(d.tags)
			table.insert(next.tags, { id = tag.id, name = tag.name })
			apply(next, function(): any
				return api.add_tag(id, tag.id)
			end)
		end

		-- A field's choices as the dropdown's items.
		local function items_of(name: string): () -> { any }
			return function(): { any }
				options:get()
				local out = {}
				for _, o in (choices[project()] or {})[name] or {} do
					local hue = if name == "State" then look.state_hue(o.value) elseif name == "Assignee" then look.hue_of(o.value) else nil
					table.insert(out, { value = o.value, label = o.label, hue = hue })
				end
				return out
			end
		end

		-- A picture in the words: its attachment's signed address, or a web
		-- address on the same YouTrack; else its alt text.
		local function picture(src: string): string?
			local d = detail:peek()
			local files = (d and d.files) or {}
			local found = files[src] or files[unescape(src)]
			if found then
				return found
			end
			local base = api.config().base
			if base ~= "" and string.sub(src, 1, #base) == base then
				return src
			end
			return nil
		end

		local function top(): Node
			return ui.row {
				w_full = true,
				gap = "$space.2",
				items = "center",
				Text { id, style = "mono", tone = "tertiary", tabular = true },
				Text {
					function(): string
						local p = field("project_name")
						return if p then `· {p}` else ""
					end,
					style = "caption",
					tone = "tertiary",
					truncate = true,
					grow = 1,
					min_w = 0,
				},
				IconButton {
					icon = "refresh",
					label = zeron.s("issue.refresh"),
					tone = "quiet",
					size = "sm",
					on_click = load,
				},
				IconButton {
					icon = "arrow-up-right",
					label = zeron.s("issue.open"),
					tone = "quiet",
					size = "sm",
					on_click = function()
						local url = field("url")
						if url then
							zeron.open_url(url)
						end
					end,
				},
			}
		end

		local function title(): Node
			return Text {
				function(): string
					return field("summary") or ""
				end,
				style = "title",
				heading = 1,
				text_size = "$font.size.xl",
				line_height = "$font.line.xl",
				w_full = true,
			}
		end

		-- The properties: built again as the issue changes (a pick, an answer).
		local function properties(): Node
			return ui.presence(function(): string
				local d = detail:get()
				if not d then
					return "seed"
				end
				local tags = {}
				for _, t in d.tags do
					table.insert(tags, t.name)
				end
				return `{d.updated or 0}|{d.state or ""}|{d.priority or ""}|{d.type or ""}|{d.assignee and d.assignee.login or ""}|{table.concat(tags, ",")}`
			end, function(): Node
				local d = detail:peek()
				local function editable(name: string): boolean
					return d ~= nil and d.fields[name] ~= nil
				end
				local none = zeron.s("issue.none")
				local rows: { Node } = {}

				local st = field("state")
				table.insert(rows, prop(zeron.s("issue.state"), Pick {
					lead = look.dot(look.state_hue(st), 8),
					value = st,
					say = function(): string?
						return st
					end,
					items = items_of("State"),
					loading = function(): boolean
						return options:get() == "loading"
					end,
					search = false,
					placeholder = none,
					on_open = ensure_options,
					on_choose = function(v: string)
						choose("State", v)
					end,
					enabled = editable("State"),
				}))

				local pr = field("priority")
				table.insert(rows, prop(zeron.s("issue.priority"), Pick {
					lead = look.PriorityMark(pr),
					value = pr,
					say = function(): string?
						return pr
					end,
					items = items_of("Priority"),
					loading = function(): boolean
						return options:get() == "loading"
					end,
					search = false,
					placeholder = none,
					on_open = ensure_options,
					on_choose = function(v: string)
						choose("Priority", v)
					end,
					enabled = editable("Priority"),
				}))

				local ty = field("type")
				if ty or editable("Type") then
					table.insert(rows, prop(zeron.s("issue.type"), Pick {
						value = ty,
						say = function(): string?
							return ty
						end,
						items = items_of("Type"),
						loading = function(): boolean
							return options:get() == "loading"
						end,
						search = false,
						placeholder = none,
						on_open = ensure_options,
						on_choose = function(v: string)
							choose("Type", v)
						end,
						enabled = editable("Type"),
					}))
				end

				local who = field("assignee")
				table.insert(rows, prop(zeron.s("issue.assignee"), Pick {
					lead = if who then look.Initials(who, 18) else nil,
					value = who and who.login,
					say = function(): string?
						return who and who.name
					end,
					items = items_of("Assignee"),
					loading = function(): boolean
						return options:get() == "loading"
					end,
					search = zeron.s("issue.search_people"),
					placeholder = zeron.s("issue.unassigned"),
					on_open = ensure_options,
					on_choose = function(v: string)
						choose("Assignee", v)
					end,
					enabled = editable("Assignee"),
				}))

				if d then
					local reporter = d.reporter
					table.insert(rows, prop(zeron.s("issue.reporter"), if reporter
						then ui.row {
							gap = "$space.2",
							items = "center",
							min_w = 0,
							look.Initials(reporter, 18),
							Text { reporter.name, style = "caption", truncate = true, min_w = 0 },
						}
						else Text { none, style = "caption", tone = "tertiary" }))

					-- Tags: each comes off with its ×; a picker puts one on.
					local tags: { Node } = {}
					local on: { [string]: boolean } = {}
					for _, t in d.tags do
						if t.id then
							on[t.id] = true
						end
						table.insert(tags, Badge.Tag {
							t.name,
							hue = look.hue_of(t.name),
							size = "sm",
							on_remove = if t.id
								then function()
									remove_tag(t)
								end
								else nil,
						})
					end
					table.insert(tags, Dropdown {
						value = tag_pick,
						items = function(): { any }
							local out = {}
							for _, t in tag_list:get() do
								if not on[t.id] then
									table.insert(out, { value = t.id, label = t.name, hue = look.hue_of(t.name) })
								end
							end
							return out
						end,
						tone = "ghost",
						icon = "plus",
						placeholder = zeron.s("issue.add_tag"),
						search = zeron.s("issue.search_tags"),
						loading = function(): boolean
							return tags_state:get() == "loading"
						end,
						on_open = ensure_tags,
						on_choose = function(tag_id: string)
							tag_pick:set(nil)
							add_tag(tag_id)
						end,
						width = 248,
					})
					table.insert(rows, prop(zeron.s("issue.tags"), ui.row { gap = "$space.1", items = "center", flex_wrap = true, table.unpack(tags) }))
					table.insert(rows, prop(zeron.s("issue.created"), Text { look.short_date(d.created), style = "caption", tabular = true }))
				end
				table.insert(rows, prop(zeron.s("issue.updated"), Text { look.short_date(field("updated")), style = "caption", tabular = true }))
				return git.frame {
					padded = true,
					ui.column { w_full = true, gap = "$space.1", table.unpack(rows) },
				}
			end, { w_full = true })
		end

		local function description(): Node
			return ui.presence(function(): string
				local s = state:get()
				local d = detail:get()
				return if s == "ready" and d then `ready:{d.updated or 0}` else s
			end, function(key: string): Node
				if key == "loading" then
					return ui.column {
						w_full = true,
						gap = "$space.2",
						skeleton.Bar { w_full = true, h = 12 },
						skeleton.Bar { w_full = true, h = 12 },
						skeleton.Bar { w = 220, h = 12 },
					}
				elseif key == "failed" then
					return banner.Callout {
						tone = "danger",
						title = zeron.s("issue.failed"),
						body = failed:peek() or "",
						action = { label = zeron.s("issue.try_again"), on_click = load },
					}
				end
				local text = clean((detail:peek() or {}).description)
				if string.match(text, "^%s*$") then
					return Text { zeron.t("issue.no_description"), style = "body", tone = "tertiary" }
				end
				return Markdown { text = text, breaks = true, image = picture }
			end, { w_full = true, enter = { opacity = { 0, 1 }, duration = 120 }, exit = { opacity = 0, duration = 60 }, mode = "wait" })
		end

		local function comments(): Node
			return ui.presence(function(): string
				local d = detail:get()
				return if d then `{d.updated or 0}:{#d.comments}` else "none"
			end, function(): Node
				local d = detail:peek()
				if not d or #d.comments == 0 then
					return ui.div {}
				end
				local cards: { Node } = {}
				for _, c in d.comments do
					local a = c.author or { login = "?", name = zeron.s("issue.someone") }
					table.insert(cards, comment.CommentCard {
						author = { id = a.login, name = a.name },
						at = if c.created then c.created // 1000 else nil,
						body = c.text,
						content = Markdown { text = clean(c.text), breaks = true, image = picture },
					})
				end
				return ui.column {
					w_full = true,
					gap = "$space.3",
					section(zeron.t("issue.comments"), tostring(#d.comments)),
					ui.column { w_full = true, gap = "$space.4", table.unpack(cards) },
				}
			end, { w_full = true })
		end

		-- (One picture opened whole over the window, on a click.)
		local Lightbox = require("@ds/lightbox")

		return ui.scroll {
			w_full = true,
			h_full = true,
			selectable = true,
			ui.column {
				w_full = true,
				px = "$space.5",
				pt = "$space.4",
				pb = "$space.8",
				gap = "$space.5",
				ui.column { w_full = true, gap = "$space.2", top(), title() },
				properties(),
				ui.column { w_full = true, gap = "$space.3", section(zeron.t("issue.description")), description() },
				comments(),
				Lightbox.Host(),
			},
		}
	end)
end
