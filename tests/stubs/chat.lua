-- Keep chat plain for assertions, but preserve the '[name] ' header.
-- Addons can use that prefix to recognize their own messages.

local mt = {}
mt.__index = mt

function mt:append(other)
    self.text = self.text .. tostring(other)
    return self
end

mt.__tostring = function(self)
    return self.text
end

mt.__concat = function(a, b)
    return tostring(a) .. tostring(b)
end

local function wrap(s)
    return setmetatable({ text = tostring(s) }, mt)
end

local M = {}

function M.header(name)
    return wrap('[' .. tostring(name) .. '] ')
end

function M.message(s) return wrap(s) end
function M.error(s)   return wrap(s) end
function M.warning(s) return wrap(s) end
function M.success(s) return wrap(s) end
function M.color1(_, s) return wrap(s) end
function M.color2(_, s) return wrap(s) end

return M
