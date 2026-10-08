-- Start each test with the addon defaults instead of a saved character profile.
-- Count saves without writing settings to disk.

local M = {}

M.save_count = 0
M.current = nil

function M.load(defaults)
    M.current = defaults
    return defaults
end

function M.save()
    M.save_count = M.save_count + 1
end

function M.register(_, _, _) end
function M.reload() end

return M
