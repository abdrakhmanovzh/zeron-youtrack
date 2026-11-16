--!strict
-- The lists last read, kept so a page or a tab opens on them at once and is
-- asked again behind them (as the GitHub plugin keeps its pull requests):
-- this run's in memory, and every run's in the plugin's own database, so a
-- relaunch opens on them too. Keyed by what was asked (the address and the
-- query), so changing a setting never shows another list's issues.

return function(zeron: any)
	local M = {}

	-- The table, made once; every read and write waits for it.
	local ready = zeron.db.exec("CREATE TABLE IF NOT EXISTS lists (key TEXT PRIMARY KEY, value TEXT NOT NULL, at INTEGER NOT NULL)")

	local memory: { [string]: { value: any, at: number } } = {}

	-- `ok(value, at)` with what's kept for `key` (nil, nil when nothing is):
	-- at once from memory, else a beat later from the database.
	function M.get(key: string, ok: (value: any?, at: number?) -> ())
		local known = memory[key]
		if known then
			ok(known.value, known.at)
			return
		end
		ready:after(function()
			zeron.db.query("SELECT value, at FROM lists WHERE key = ?", { key }):after(function(rows: any)
				local row = type(rows) == "table" and rows[1] or nil
				if not row then
					ok(nil, nil)
					return
				end
				local decoded, value = pcall(ui.json.decode, row.value)
				if decoded and value ~= nil then
					if not memory[key] then
						memory[key] = { value = value, at = row.at }
					end
					ok(value, row.at)
				else
					ok(nil, nil)
				end
			end, function()
				ok(nil, nil)
			end)
		end, function()
			ok(nil, nil)
		end)
	end

	function M.put(key: string, value: any)
		local now = os.time()
		memory[key] = { value = value, at = now }
		ready:after(function()
			zeron.db.exec("INSERT OR REPLACE INTO lists (key, value, at) VALUES (?, ?, ?)", { key, ui.json.encode(value), now })
		end)
	end

	return M
end
