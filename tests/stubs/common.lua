-- Only the common.lua helpers needed by these tests.
-- T returns a plain table here; add the real helper methods if a test needs them.

if not _G.T then
    function _G.T(t)
        return t or {}
    end
end

-- FFXI embeds colour codes as 0x1E/0x1F followed by one byte.
function string.strip_colors(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub('[\30\31].', ''))
end

-- Ashita's string.any: case-insensitive compare against any of the arguments.
function string.any(s, ...)
    local n = select('#', ...)
    for i = 1, n do
        local v = select(i, ...)
        if type(v) == 'string' and string.lower(s) == string.lower(v) then
            return true
        end
    end
    return false
end

-- Ashita's string.args: split on whitespace, honouring double quotes.
function string.args(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c:match('%s') then
            i = i + 1
        elseif c == '"' then
            local close = s:find('"', i + 1, true)
            if close then
                table.insert(out, s:sub(i + 1, close - 1))
                i = close + 1
            else
                table.insert(out, s:sub(i + 1))
                break
            end
        else
            local sp = s:find('%s', i)
            if sp then
                table.insert(out, s:sub(i, sp - 1))
                i = sp + 1
            else
                table.insert(out, s:sub(i))
                break
            end
        end
    end
    return out
end

-- Ashita's string.trim: strip leading and trailing whitespace.
function string.trim(s)
    return (tostring(s):match('^%s*(.-)%s*$'))
end
