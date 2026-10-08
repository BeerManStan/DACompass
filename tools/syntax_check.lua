-- Compile each file without running it. loadfile reports any syntax error.
-- Run under LuaJIT to check against the Lua 5.1 syntax used by Ashita.
--
-- Usage: luajit tools/syntax_check.lua <file.lua> [file.lua ...]

local files = { ... }
if #files == 0 then
    io.stderr:write('usage: luajit tools/syntax_check.lua <file.lua> [...]\n')
    os.exit(2)
end

local failed = 0
for _, path in ipairs(files) do
    local chunk, err = loadfile(path)
    if chunk then
        print(('  OK    %s'):format(path))
    else
        failed = failed + 1
        print(('  FAIL  %s'):format(path))
        print(('        %s'):format(tostring(err)))
    end
end

print(('\n%d file(s) checked, %d failed'):format(#files, failed))
os.exit(failed == 0 and 0 or 1)
