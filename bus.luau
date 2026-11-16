--!strict
-- An issue changed in its tab: the board hears it and asks again, so a
-- state moved or an assignee given shows in the list (and an issue that no
-- longer fits the list leaves it). One listener: the page's board, the
-- latest built.

local M = {}

local listener: ((id: string) -> ())? = nil

function M.listen(fn: (id: string) -> ())
	listener = fn
end

function M.changed(id: string)
	if listener then
		listener(id)
	end
end

return M
