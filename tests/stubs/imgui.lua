-- Skip drawing in tests: Begin returns nil and widgets report no changes.
-- ImGui constants default to zero so window flag calculations still work.
-- This doesn't test rendering; check the actual overlay in game.

local noop = function() return nil end

local M = setmetatable({}, {
    __index = function(_, _key)
        return noop
    end,
})

local g_mt = getmetatable(_G)
if g_mt == nil then
    g_mt = {}
    setmetatable(_G, g_mt)
end
local prev_index = g_mt.__index
g_mt.__index = function(t, k)
    if type(k) == 'string' and k:sub(1, 5) == 'ImGui' then
        return 0
    end
    if type(prev_index) == 'function' then return prev_index(t, k) end
    if type(prev_index) == 'table' then return prev_index[k] end
    return nil
end

return M
