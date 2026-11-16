--!strict
-- YouTrack's REST API: the issues a query finds, flattened to what the board
-- draws; one issue whole (description, comments, attachments); and the few
-- changes the issue's tab makes: a field's value (state, priority, type,
-- assignee) and its tags. Nothing else is ever written.

export type Person = { login: string, name: string, avatar: string? }
export type Tag = { id: string?, name: string }
export type Issue = {
	id: string,
	summary: string,
	updated: number?,
	project: string?,
	state: string?,
	priority: string?,
	type: string?,
	assignee: Person?,
	tags: { Tag },
	url: string,
}
-- A field an issue's tab can change: YouTrack's name for it and the type of
-- its value (`$type`), which says how a value is sent.
export type Field = { name: string, kind: string }
-- A value a field can take: what's sent (`value`, a name or a login) and
-- what's shown.
export type Option = { value: string, label: string }

local FIELDS = table.concat({
	"idReadable",
	"summary",
	"updated",
	"project(shortName)",
	"tags(name)",
	"customFields(name,value(name,login,fullName,avatarUrl))",
}, ",")

-- The fields the tab offers to change, as YouTrack names them, and which
-- of the issue's own keys each one is.
local EDITABLE: { [string]: string } = { State = "state", Priority = "priority", Type = "type", Assignee = "assignee" }

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

local function trim_slash(s: string): string
	return (string.gsub(s, "/+$", ""))
end

local function person(v: any, base: string): Person?
	if type(v) ~= "table" or not v.login then
		return nil
	end
	local avatar = v.avatarUrl
	if type(avatar) == "string" and string.sub(avatar, 1, 1) == "/" then
		avatar = base .. avatar
	end
	return { login = v.login, name = v.fullName or v.login, avatar = if type(avatar) == "string" then avatar else nil }
end

local function flatten(raw: any, base: string): Issue
	local issue: Issue = {
		id = raw.idReadable or "?",
		summary = raw.summary or "",
		updated = raw.updated,
		project = raw.project and raw.project.shortName,
		tags = {},
		url = `{base}/issue/{raw.idReadable or ""}`,
	}
	for _, t in raw.tags or {} do
		if type(t) == "table" and t.name then
			table.insert(issue.tags, { id = t.id, name = t.name })
		end
	end
	for _, f in raw.customFields or {} do
		local v = f.value
		-- (A multi-value field: its first value.)
		if type(v) == "table" and v[1] ~= nil then
			v = v[1]
		end
		if f.name == "State" and type(v) == "table" then
			issue.state = v.name
		elseif f.name == "Priority" and type(v) == "table" then
			issue.priority = v.name
		elseif f.name == "Type" and type(v) == "table" then
			issue.type = v.name
		elseif f.name == "Assignee" then
			issue.assignee = person(v, base)
		end
	end
	return issue
end

-- Why a response isn't what was asked for, in YouTrack's words.
local function failure(r: any): string
	local why = (type(r.json) == "table" and (r.json.error_description or r.json.error)) or r.body or ""
	return `HTTP {r.status}: {string.sub(tostring(why), 1, 300)}`
end

return function(zeron: any)
	local M = {}
	M.EDITABLE = EDITABLE

	-- What the settings say, now.
	function M.config(): { base: string, token: string, project: string, extra: string }
		local s = zeron.settings() or {}
		return {
			base = trim_slash(s.base_url or ""),
			token = s.token or "",
			project = s.project or "",
			extra = s.extra_query or "",
		}
	end

	local function headers(): { [string]: string }
		return { Authorization = `Bearer {M.config().token}`, Accept = "application/json" }
	end

	local function call(path: string, opts: { method: string?, body: any? }?): any
		local o = opts or {}
		return ui.fetch(`{M.config().base}{path}`, { method = o.method, body = o.body, headers = headers() })
	end

	-- The query a filter asks: the project, the filter's own part, the
	-- extra query, newest updates first.
	function M.query(filter: string): string
		local c = M.config()
		local parts = {}
		if c.project ~= "" then
			table.insert(parts, `project: {c.project}`)
		end
		if filter == "assigned" then
			table.insert(parts, "for: me")
		elseif filter == "reported" then
			table.insert(parts, "reporter: me")
		end
		if c.extra ~= "" then
			table.insert(parts, c.extra)
		end
		table.insert(parts, "sort by: updated desc")
		return table.concat(parts, " ")
	end

	-- What a list is kept under: where it was asked and what.
	function M.key(filter: string): string
		return `{M.config().base}|{M.query(filter)}`
	end

	-- The request for the issues `filter` finds (200 at most): a promise of
	-- YouTrack's response, to read with `M.parse`.
	function M.issues(filter: string): any
		return call(`/api/issues?fields={encode(FIELDS)}&$top=200&query={encode(M.query(filter))}`)
	end

	-- The issues in a response, or (as text) why there are none.
	function M.parse(r: any): ({ Issue }?, string?)
		if not r.ok then
			return nil, failure(r)
		end
		local base = M.config().base
		local list: { Issue } = {}
		for _, raw in (if type(r.json) == "table" then r.json else {}) do
			table.insert(list, flatten(raw, base))
		end
		return list, nil
	end

	-- One issue, whole: its description, who reported it and when, its
	-- comments (deleted ones left out) oldest first, and its attachments by
	-- name, each at its signed address (YouTrack's `url`, which needs no
	-- token, so a picture can load it).
	local ISSUE_FIELDS = table.concat({
		"idReadable",
		"summary",
		"description",
		"created",
		"updated",
		"resolved",
		"project(shortName,name)",
		"reporter(login,fullName)",
		"tags(id,name)",
		"customFields(name,$type,value(name,login,fullName))",
		"attachments(name,url)",
		"comments(id,text,created,deleted,author(login,fullName),attachments(name,url))",
	}, ",")

	function M.issue(id: string): any
		return call(`/api/issues/{encode(id)}?fields={encode(ISSUE_FIELDS)}`)
	end

	type Comment = { id: string, text: string, created: number?, author: Person? }
	type Detail = Issue & {
		description: string?,
		created: number?,
		resolved: number?,
		project_name: string?,
		reporter: Person?,
		comments: { Comment },
		files: { [string]: string },
		fields: { [string]: Field },
	}

	function M.parse_issue(r: any): (Detail?, string?)
		if not r.ok then
			return nil, failure(r)
		end
		local raw = r.json
		if type(raw) ~= "table" then
			return nil, "YouTrack sent something that isn't an issue"
		end
		local base = M.config().base
		local d: any = flatten(raw, base)
		d.description = raw.description
		d.created = raw.created
		d.resolved = raw.resolved
		d.project_name = raw.project and raw.project.name
		d.reporter = person(raw.reporter, base)
		d.files = {}
		d.fields = {}
		local function files(list: any)
			for _, a in list or {} do
				if type(a) == "table" and type(a.name) == "string" and type(a.url) == "string" then
					d.files[a.name] = if string.sub(a.url, 1, 1) == "/" then base .. a.url else a.url
				end
			end
		end
		files(raw.attachments)
		for _, f in raw.customFields or {} do
			if type(f) == "table" and EDITABLE[f.name] and type(f["$type"]) == "string" then
				d.fields[f.name] = { name = f.name, kind = f["$type"] }
			end
		end
		d.comments = {}
		for _, cm in raw.comments or {} do
			if type(cm) == "table" and not cm.deleted then
				files(cm.attachments)
				table.insert(d.comments, {
					id = tostring(cm.id or #d.comments + 1),
					text = cm.text or "",
					created = cm.created,
					author = person(cm.author, base),
				})
			end
		end
		table.sort(d.comments, function(a: any, b: any): boolean
			return (a.created or 0) < (b.created or 0)
		end)
		return d :: Detail, nil
	end

	-- What each changeable field of an issue can be set to, from its
	-- project's settings for it: a state's or a priority's values (archived
	-- ones left out), an assignee's people. A promise of the response, read
	-- with `M.parse_options`.
	function M.options(id: string): any
		local f = "name,projectCustomField(bundle(values(name,archived,login,fullName),aggregatedUsers(login,fullName)))"
		return call(`/api/issues/{encode(id)}/customFields?fields={encode(f)}`)
	end

	function M.parse_options(r: any): ({ [string]: { Option } }?, string?)
		if not r.ok then
			return nil, failure(r)
		end
		local out: { [string]: { Option } } = {}
		for _, f in (if type(r.json) == "table" then r.json else {}) do
			if type(f) == "table" and EDITABLE[f.name] then
				local bundle = f.projectCustomField and f.projectCustomField.bundle or {}
				local list: { Option } = {}
				if f.name == "Assignee" then
					for _, u in bundle.aggregatedUsers or bundle.values or {} do
						if type(u) == "table" and u.login then
							table.insert(list, { value = u.login, label = u.fullName or u.login })
						end
					end
					table.sort(list, function(a, b)
						return string.lower(a.label) < string.lower(b.label)
					end)
				else
					for _, v in bundle.values or {} do
						if type(v) == "table" and v.name and not v.archived then
							table.insert(list, { value = v.name, label = v.name })
						end
					end
				end
				out[f.name] = list
			end
		end
		return out, nil
	end

	-- The states of an issue's project, in the order its admins set
	-- (YouTrack's `ordinal`, as its board's columns stand): a promise of the
	-- response, read with `M.parse_states`.
	function M.states(id: string): any
		local f = "name,projectCustomField(bundle(values(name,ordinal,archived)))"
		return call(`/api/issues/{encode(id)}/customFields?fields={encode(f)}`)
	end

	function M.parse_states(r: any): ({ string }?, string?)
		if not r.ok then
			return nil, failure(r)
		end
		for _, f in (if type(r.json) == "table" then r.json else {}) do
			if type(f) == "table" and f.name == "State" then
				local values = {}
				for _, v in (f.projectCustomField and f.projectCustomField.bundle and f.projectCustomField.bundle.values) or {} do
					if type(v) == "table" and v.name and not v.archived then
						table.insert(values, v)
					end
				end
				table.sort(values, function(a: any, b: any): boolean
					return (a.ordinal or 0) < (b.ordinal or 0)
				end)
				local names = {}
				for _, v in values do
					table.insert(names, v.name)
				end
				return names, nil
			end
		end
		return nil, "the project has no State field"
	end

	-- Every tag you can put on an issue: a promise of the response, read
	-- with `M.parse_tags`.
	function M.tags(): any
		return call(`/api/tags?fields={encode("id,name")}&$top=500`)
	end

	function M.parse_tags(r: any): ({ Tag }?, string?)
		if not r.ok then
			return nil, failure(r)
		end
		local out: { Tag } = {}
		for _, t in (if type(r.json) == "table" then r.json else {}) do
			if type(t) == "table" and t.id and t.name then
				table.insert(out, { id = t.id, name = t.name })
			end
		end
		table.sort(out, function(a, b)
			return string.lower(a.name) < string.lower(b.name)
		end)
		return out, nil
	end

	-- A field set to a value (a person's login for a user field, else the
	-- value's name), as YouTrack's issue update takes it.
	function M.set_field(id: string, field: Field, value: string): any
		local v = if string.find(field.kind, "User", 1, true) then { login = value } else { name = value }
		return call(`/api/issues/{encode(id)}?fields=idReadable`, {
			method = "POST",
			body = { customFields = { { name = field.name, ["$type"] = field.kind, value = v } } },
		})
	end

	function M.add_tag(id: string, tag_id: string): any
		return call(`/api/issues/{encode(id)}/tags?fields=id`, { method = "POST", body = { id = tag_id } })
	end

	function M.remove_tag(id: string, tag_id: string): any
		return call(`/api/issues/{encode(id)}/tags/{encode(tag_id)}`, { method = "DELETE" })
	end

	-- Why a change was refused, or nil when it went through.
	function M.refused(r: any): string?
		return if r.ok then nil else failure(r)
	end

	return M
end
