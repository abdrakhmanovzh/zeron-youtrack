local zeron = require("./zeron")("youtrack")

-- YouTrack: your issues on a page of their own in the sidebar, read-only.
-- The board (board.luau) asks YouTrack's REST API (api.luau) with the token
-- set in this plugin's settings; an issue opens in the page's panel as a
-- tab (viewer.luau), its description and comments as markdown.

-- (Made once for the plugin's run, so its cache outlives the page: closed
-- and opened again, the page shows what it showed at once.)
local api = require("./api")(zeron)
local Board = require("./board")(zeron, api, require("./cache")(zeron))
local Viewer = require("./viewer")(zeron, api)

-- A link in an issue's markdown opens where your links open ("links.open").
require("@ds/links").opener = function(url: string): boolean
	zeron.open_url(url)
	return true
end

zeron.tab("youtrack-issue", function(tab: any): Node
	return Viewer { tab = tab }
end)

zeron.page {
	id = "issues",
	title = zeron.t("page.title"),
	icon = "checklist",
	build = function(_page: any): Node
		-- (Its panel: the page's own, where an issue opens as a tab.)
		return Board { panel = zeron.context("panel") }
	end,
}
