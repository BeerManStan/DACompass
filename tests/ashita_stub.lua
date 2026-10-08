-- Fake Ashita v4 host for running addon tests without the game.
-- Printed chat feeds back into text_in, just as it does in Ashita.
-- Keep that behavior: it catches addons accidentally replying to themselves.

local H = {}

local dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*[\\/])') or './'
package.path = dir .. 'stubs/?.lua;' .. package.path

-- Stop recursive chat loops before they take the test process down with them.
H.RUNAWAY_LIMIT = 64

H.events = {}       -- event name -> handler fn
H.commands = {}     -- QueueCommand calls: { mode = , cmd = }
H.printed = {}      -- lines the addon printed
H.sounds = {}       -- ashita.misc.play_sound paths
H.max_depth = 0     -- deepest text_in nesting seen
H.runaway = false
H.clock_ms = 100000 -- non-zero: real ashita.time.clock() ms is a large uptime

-- Fake client state for addons that read memory (see ashita.memory below).
H.sig_found = true  -- does ashita.memory.find() resolve the signature?
H.weather_id = 0    -- byte the weather pointer chain lands on
H.zoning = 0        -- GetPlayer():GetIsZoning(); non-zero means mid-zone

local depth = 0

function H.reset()
    H.commands = {}
    H.printed = {}
    H.sounds = {}
    H.max_depth = 0
    H.runaway = false
    depth = 0
end

-- Feed a chat line to the addon's text_in handler, as Ashita would.
function H.feed(line)
    local fn = H.events['text_in']
    if not fn then return end

    depth = depth + 1
    if depth > H.max_depth then H.max_depth = depth end
    if depth > H.RUNAWAY_LIMIT then
        H.runaway = true
        depth = depth - 1
        return
    end

    local e = { message = line, mode = 0, blocked = false, message_modified = line }
    fn(e)
    depth = depth - 1
end

-- Send a slash command, as Ashita would.
function H.command(str)
    local fn = H.events['command']
    if not fn then return end
    local e = { command = str, blocked = false }
    fn(e)
end

-- Deliver an incoming packet, as Ashita would.
function H.packet(id, data)
    local fn = H.events['packet_in']
    if not fn then return end
    fn({ id = id, size = data and #data or 0, data = data or '', data_modified = data or '', blocked = false })
end

-- Deliver an outgoing packet (one the client is sending), as Ashita would.
function H.packet_out(id, data)
    local fn = H.events['packet_out']
    if not fn then return end
    fn({ id = id, size = data and #data or 0, data = data or '', data_modified = data or '', blocked = false })
end

-- Run one frame of the render loop.
function H.present()
    local fn = H.events['d3d_present']
    if fn then fn() end
end

-- Fire the load event, as Ashita does after the addon's chunk runs.
function H.load_event()
    local fn = H.events['load']
    if fn then fn() end
end

function H.advance(ms)
    H.clock_ms = H.clock_ms + ms
end

-- ----------------------------
-- Globals the addon expects
-- ----------------------------
_G.addon = {
    path = dir,
    name = '',
    author = '',
    version = '',
    desc = '',
    link = '',
    commands = {},
}

_G.ashita = {
    events = {
        register = function(event, _id, fn)
            H.events[event] = fn
        end,
        unregister = function(event, _id)
            H.events[event] = nil
        end,
    },
    time = {
        clock = function()
            return { ms = H.clock_ms, s = math.floor(H.clock_ms / 1000) }
        end,
    },
    fs = {
        exists = function(_) return false end,
        create_dir = function(_) return true end,
    },
    misc = {
        play_sound = function(path) table.insert(H.sounds, tostring(path)) end,
    },
    -- Fake memory pointer chain: find -> 0x1000,
    -- uint32 at 0x1002 -> 0x2000, byte at 0x2000 -> H.weather_id.
    memory = {
        find = function(_module, _count, _pattern, _offset, _usage)
            return H.sig_found and 0x1000 or 0
        end,
        read_uint32 = function(addr)
            if addr == 0x1002 then return 0x2000 end
            return 0
        end,
        read_uint8 = function(addr)
            if addr == 0x2000 then return H.weather_id end
            return 0
        end,
    },
}

local default_player = {
    GetIsZoning = function(_self) return H.zoning end,
}

local default_memory_manager = {
    GetPlayer = function(_self) return default_player end,
}

local chat_manager = {
    QueueCommand = function(_self, mode, cmd)
        table.insert(H.commands, { mode = mode, cmd = cmd })
    end,
    AddChatMessage = function(_self, _mode, _indent, text)
        -- Same re-entrancy as print().
        table.insert(H.printed, tostring(text))
        H.feed(tostring(text))
    end,
}

_G.AshitaCore = {
    GetChatManager   = function(_self) return chat_manager end,
    GetInstallPath   = function(_self) return dir end,
    GetMemoryManager = function(_self) return H.memory or default_memory_manager end,
    GetResourceManager = function(_self) return H.resources or {} end,
}

-- Send printed output back through text_in so tests can catch chat loops.
local real_print = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring((select(i, ...)))
    end
    local line = table.concat(parts, '\t')
    table.insert(H.printed, line)
    H.feed(line)
end

H.real_print = real_print

-- Load an addon source file into this fake host.
function H.load_addon(relpath)
    local path = dir .. relpath
    local chunk, err = loadfile(path)
    if not chunk then
        error(('failed to load %s: %s'):format(path, tostring(err)), 2)
    end
    return chunk()
end

return H
