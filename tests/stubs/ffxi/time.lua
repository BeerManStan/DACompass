-- Tests set FAKE_VANA to control the weekday and moon readings.
-- Missing values fall back to weekday/phase zero and 50 percent.

local M = {}

local function v(key, default)
    local t = _G.FAKE_VANA or {}
    local x = t[key]
    if x == nil then return default end
    return x
end

function M.get_game_time_raw()     return v('raw', 0) end
function M.get_game_weekday()      return v('weekday', 0) end
function M.get_game_moon_phase()   return v('moon_phase', 0) end
function M.get_game_moon_percent() return v('moon_pct', 50) end

return M
