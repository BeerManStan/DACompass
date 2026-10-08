-- DACompass tests: chart and packet helpers first, then the addon in a fake
-- Ashita host. Covers headings, chimes, synth tracking, the ledger, and commands.
-- Run: luajit tests/dacompass_spec.lua (or .\check.ps1)

local dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*[\\/])') or './'
package.path = dir .. '?.lua;' .. dir .. 'stubs/?.lua;' .. dir .. '../dacompass/?.lua;' .. package.path

local H = require('ashita_stub')
local settings = require('settings')
local out = H.real_print

-- ----------------------------
-- Assertions
-- ----------------------------
local passed, failed = 0, 0

local function ok(name, cond, detail)
    if cond then
        passed = passed + 1
        out(('  pass  %s'):format(name))
    else
        failed = failed + 1
        out(('  FAIL  %s'):format(name))
        if detail then out(('        %s'):format(detail)) end
    end
end

local function eq(name, got, want)
    ok(name, got == want, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function near(name, got, want, eps)
    ok(name, type(got) == 'number' and math.abs(got - want) <= (eps or 0.01),
        ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function printed_text()
    return table.concat(H.printed, '\n')
end

-- Start with a zeroed packet and fill the offsets needed for each test.
local function packet(len, bytes)
    local t = {}
    for i = 1, len do t[i] = 0 end
    for off, v in pairs(bytes or {}) do t[off + 1] = v end
    return string.char(unpack(t))
end

local compass = require('compass')

-- ============================
-- Chart and helpers
-- ============================
out('-- chart --')
local seen_a, seen_c = {}, {}
for _, el in ipairs(compass.ELEMENTS) do
    local i = compass.INFO[el]
    ok(el .. ': arrow and crescent differ', i.arrow ~= i.crescent)
    seen_a[i.arrow] = (seen_a[i.arrow] or 0) + 1
    seen_c[i.crescent] = (seen_c[i.crescent] or 0) + 1
end
local all_once = true
for _, d in ipairs(compass.DIRECTIONS) do
    if seen_a[d] ~= 1 or seen_c[d] ~= 1 then all_once = false end
end
ok('each of the 8 headings is exactly one arrow and one crescent', all_once)
eq('fire arrow NW', compass.INFO.fire.arrow, 'NW')
eq('fire crescent W', compass.INFO.fire.crescent, 'W')
eq('dark arrow N', compass.INFO.dark.arrow, 'N')
eq('light crescent N', compass.INFO.light.crescent, 'N')
eq('ARROW_AT[NW] is fire', compass.ARROW_AT.NW, 'fire')
eq('CRESCENT_AT[N] is light', compass.CRESCENT_AT.N, 'light')

out('\n-- bearings --')
near('yaw 270 deg faces north', compass.yaw_to_bearing(math.rad(270)), 0)
near('yaw 0 faces east', compass.yaw_to_bearing(math.rad(0)), 90)
near('yaw 90 faces south', compass.yaw_to_bearing(math.rad(90)), 180)
near('yaw 180 faces west', compass.yaw_to_bearing(math.rad(180)), 270)
near('yaw -90 (atan2 range) faces north', compass.yaw_to_bearing(math.rad(-90)), 0)
near('custom north reference', compass.yaw_to_bearing(math.rad(0), 0), 0)
near('reverse flips the direction', compass.yaw_to_bearing(math.rad(90), 0, true), 270)
eq('non-number yaw -> nil', compass.yaw_to_bearing(nil), nil)
near('turn right 2.6', compass.turn(315, 312.4), 2.6)
near('turn left 5', compass.turn(315, 320), -5)
near('turn across north, right', compass.turn(10, 350), 20)
near('turn across north, left', compass.turn(350, 10), -20)
eq('nearest 340 -> N', compass.nearest_direction(340), 'N')
eq('nearest 335 -> NW', compass.nearest_direction(335), 'NW')
eq('nearest 100 -> E', compass.nearest_direction(100), 'E')
eq('dir16 292.5 -> WNW', compass.direction16(292.5), 'WNW')
eq('dir16 0 -> N', compass.direction16(0), 'N')
eq('dir16 359 -> N', compass.direction16(359), 'N')
local d, b = compass.target('fire', 'safe')
eq('fire safe target NW', d, 'NW')
eq('... at 315', b, 315)
d, b = compass.target('fire', 'hq')
eq('fire hq target W', d, 'W')
eq('... at 270', b, 270)
eq('unknown element target nil', (compass.target('mud', 'safe')), nil)
eq('sector fire 315 arrow', compass.sector('fire', 315), 'arrow')
eq('sector fire 300 still arrow (within 22.5)', compass.sector('fire', 300), 'arrow')
eq('sector fire 270 crescent', compass.sector('fire', 270), 'crescent')
eq('sector fire 0 other', compass.sector('fire', 0), 'other')
eq('sector with nil bearing other', compass.sector('fire', nil), 'other')

out('\n-- names --')
eq('parse Fire', compass.parse_element('Fire'), 'fire')
eq('parse thunder -> lightning', compass.parse_element('thunder'), 'lightning')
eq('parse "ice crystal"', compass.parse_element('ice crystal'), 'ice')
eq('parse bogus', compass.parse_element('bogus'), nil)
eq('item 4100 lightning', compass.element_for_item(4100), 'lightning')
eq('item 4108 (Plasma) lightning', compass.element_for_item(4108), 'lightning')
eq('item 4103 dark', compass.element_for_item(4103), 'dark')
eq('unknown id, name Inferno Crystal', compass.element_for_item(9999, 'Inferno Crystal'), 'fire')
eq('unknown id, name Light Crystal', compass.element_for_item(9999, 'Light Crystal'), 'light')
eq('unknown id, name Lightning Crystal', compass.element_for_item(9999, 'Lightning Crystal'), 'lightning')
eq('unknown id, no name', compass.element_for_item(9999), nil)
eq('weekday 0 fire', compass.weekday_element(0), 'fire')
eq('weekday 7 dark', compass.weekday_element(7), 'dark')
eq('weekday 8 wraps to fire', compass.weekday_element(8), 'fire')
eq('moon 6 full', compass.moon_name(6), 'Full Moon')

out('\n-- packets --')
local req = compass.parse_synth_request(packet(0x24, { [0x06] = 0x03, [0x07] = 0x10, [0x08] = 5, [0x09] = 2 }))
eq('request crystal id (earth 4099)', req.crystal_id, 4099)
eq('request ingredient count', req.ingredient_count, 2)
eq('request too short -> nil', compass.parse_synth_request('abc'), nil)
local anim = compass.parse_synth_animation(packet(0x10, { [0x08] = 0x23, [0x09] = 0x01, [0x0C] = 2 }))
eq('animation target index', anim.target_index, 0x123)
eq('animation outcome HQ1', anim.outcome, 'HQ1')
eq('animation code 1 BREAK', compass.parse_synth_animation(packet(0x10, { [0x0C] = 1 })).outcome, 'BREAK')
eq('animation unknown code', compass.parse_synth_animation(packet(0x10, { [0x0C] = 9 })).outcome, 'OTHER9')
local res = compass.parse_synth_result(packet(0x24, {
    [0x04] = 0, [0x05] = 1, [0x06] = 3, [0x08] = 0x39, [0x09] = 0x30 }))
eq('result success', res.result, 0)
eq('result quality', res.quality, 1)
eq('result count', res.count, 3)
eq('result item id', res.item_id, 0x3039)
eq('result negative quality', compass.parse_synth_result(packet(0x24, { [0x05] = 0xFF })).quality, -1)
local mb = compass.parse_message_basic(packet(0x1C, {
    [0x04] = 0x01, [0x0C] = 54, [0x10] = 1, [0x14] = 0x23, [0x15] = 0x01, [0x16] = 0x23, [0x17] = 0x01, [0x18] = 38 }))
eq('message basic: skill id', mb.param1, 54)
eq('message basic: tenths', mb.param2, 1)
eq('message basic: target index', mb.target_index, 0x123)
eq('message basic: message id', mb.message, 38)
eq('message basic too short -> nil', compass.parse_message_basic('abc'), nil)
eq('skill 54 is Bonecraft', compass.CRAFT_SKILLS[54], 'Bonecraft')
eq('skill 1 is not a craft', compass.CRAFT_SKILLS[1], nil)

out('\n-- ledger csv --')
local rec = {
    utc = '2026-10-07T00:00:00Z', crystal = 'fire', goal = 'safe', facing_deg = 312.4,
    sector = 'arrow', vana_day = 'Firesday', moon_pct = 57, result = 'HQ1',
    item_id = 12345, item_name = 'Bottle, of "stuff"', qty = 1, skillup_tenths = 2,
}
local row = compass.csv_row(rec)
ok('row quotes the item name', row:find('"Bottle, of ""stuff"""', 1, true) ~= nil, row)
local fields = compass.csv_fields(row)
eq('row has 17 fields', #fields, 17)
eq('field 15 item name unescaped', fields[15], 'Bottle, of "stuff"')
near('arrow offset recorded', tonumber(fields[7]), 2.6)
near('crescent offset recorded', tonumber(fields[9]), -42.4)
eq('facing dir recorded', fields[5], 'NW')
local back = compass.csv_parse(row)
eq('parse crystal', back.crystal, 'fire')
eq('parse sector', back.sector, 'arrow')
eq('parse result', back.result, 'HQ1')
eq('parse skillup', back.skillup_tenths, 2)
eq('header parses to nil', compass.csv_parse(compass.CSV_HEADER), nil)
eq('junk parses to nil', compass.csv_parse('hello,world'), nil)

out('\n-- tally --')
local t = compass.tally_new()
compass.tally_add(t, { crystal = 'fire', sector = 'arrow', result = 'NQ' })
compass.tally_add(t, { crystal = 'fire', sector = 'arrow', result = 'BREAK' })
compass.tally_add(t, { crystal = 'fire', sector = 'arrow', result = 'HQ2', skillup_tenths = 3 })
compass.tally_add(t, { crystal = 'fire', sector = 'arrow', result = 'HQ1' })
compass.tally_add(t, { crystal = 'earth', sector = 'bogus', result = 'NQ' })
local rows = compass.tally_rows(t, 'fire')
eq('fire arrow n', rows[1].n, 4)
eq('fire arrow breaks', rows[1].breaks, 1)
near('fire arrow break pct', rows[1].break_pct, 25)
near('fire arrow hq pct', rows[1].hq_pct, 50)
near('fire arrow skillup', rows[1].skillup, 0.3)
eq('fire crescent n', rows[2].n, 0)
eq('fire crescent pct nil', rows[2].break_pct, nil)
eq('unknown sector lands in other', compass.tally_rows(t, 'earth')[3].n, 1)
eq('all bucket counts everything', compass.tally_rows(t, 'all')[1].n + compass.tally_rows(t, 'all')[3].n, 5)
eq('tally keys in day order', table.concat(compass.tally_keys(t), ','), 'fire,earth')

-- ============================
-- Addon behavior with the fake Ashita host
-- ============================
out('\n-- host --')
local FAKE = { yaw = math.rad(270), index = 0x123 }
_G.FAKE_VANA = { weekday = 6, moon_pct = 57, moon_phase = 4 }   -- Lightsday
H.memory = {
    GetPlayer = function() return { GetIsZoning = function() return 0 end } end,
    GetParty  = function() return { GetMemberTargetIndex = function(_, _i) return FAKE.index end } end,
    GetEntity = function() return { GetLocalPositionYaw = function(_, _idx) return FAKE.yaw end } end,
}
local ITEMS = { [4096] = 'Fire Crystal', [4099] = 'Earth Crystal', [12345] = 'Bronze Ingot' }
H.resources = {
    GetItemById = function(_, id)
        if ITEMS[id] then return { Name = { ITEMS[id] } } end
        return nil
    end,
}

-- The fake addon writes its ledger into tests/, not the live addon folder.
local ledger = dir .. 'dacompass_ledger.csv'
os.remove(ledger)

local function ledger_lines()
    local f = io.open(ledger, 'r')
    if not f then return {} end
    local lines = {}
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
    return lines
end

-- Convert the test bearing back to the yaw the entity would report.
local function face(bearing)
    FAKE.yaw = math.rad(bearing + 270)
end

local function frame(ms)
    H.advance(ms or 50)
    H.present()
end

H.load_addon('../dacompass/dacompass.lua')
local cfg = settings.current
out(('dacompass %s loaded into stub host'):format(_G.addon.version))
ok('registers packet_in', H.events['packet_in'] ~= nil)
ok('registers packet_out', H.events['packet_out'] ~= nil)
ok('registers d3d_present', H.events['d3d_present'] ~= nil)
ok('registers command', H.events['command'] ~= nil)
ok('no text_in handler (no self-echo surface)', H.events['text_in'] == nil)
H.reset()
H.load_event()
ok('load announces itself', printed_text():find('loaded', 1, true) ~= nil, printed_text())

out('\n-- heading + chime --')
H.reset()
H.command('/dac fire')
eq('/dac fire selects fire', cfg.crystal[1], 'fire')
ok('and names both headings', printed_text():find('face NW for fewer fails, W for HQ', 1, true) ~= nil, printed_text())
face(100); frame()
eq('facing east-ish: no chime', #H.sounds, 0)
H.reset()
face(313.5); frame()
eq('within 3 deg of NW: chime', #H.sounds, 1)
ok('uses the bundled chime', (H.sounds[1] or ''):find('xylophone_e4.wav', 1, true) ~= nil, H.sounds[1])
frame()
eq('staying on target does not re-chime', #H.sounds, 1)
face(100); frame(2000)
face(316); frame()
eq('leaving and returning chimes again', #H.sounds, 2)
H.reset()
H.command('/dac status')
ok('status says on target', printed_text():find('on target, 1.0 deg off', 1, true) ~= nil, printed_text())
face(320); frame()
H.reset()
H.command('/dac status')
ok('status says turn left 5.0', printed_text():find('turn left 5.0 deg', 1, true) ~= nil, printed_text())
ok('status reads the facing to a tenth', printed_text():find('Facing 320.0 deg (NW)', 1, true) ~= nil, printed_text())

H.reset()
face(100); frame(2000)
H.command('/dac hq')
face(270); frame()
eq('hq goal retargets to the crescent (W)', #H.sounds, 1)
H.command('/dac safe')

H.reset()
face(100); frame(2000)
H.command('/dac tol 0.5')
face(316); frame()
eq('tighter band: 1 deg off is no longer on target', #H.sounds, 0)
H.command('/dac tol 3')

H.reset()
H.command('/dac chime off')
face(100); frame(2000)
face(315); frame()
eq('chime off stays silent', #H.sounds, 0)
H.command('/dac chime on')

out('\n-- synth flow --')
local function synth_request(crystal_id)
    H.packet_out(0x096, packet(0x24, {
        [0x06] = crystal_id % 256, [0x07] = math.floor(crystal_id / 256), [0x09] = 2 }))
end
local function synth_anim(code, index)
    index = index or FAKE.index
    H.packet(0x030, packet(0x10, {
        [0x08] = index % 256, [0x09] = math.floor(index / 256), [0x0C] = code }))
end
local function synth_result(result, quality, count, item_id)
    H.packet(0x06F, packet(0x24, {
        [0x04] = result, [0x05] = quality, [0x06] = count,
        [0x08] = item_id % 256, [0x09] = math.floor(item_id / 256) }))
end
-- Build the same skill-gain message the server sends, with the gain in tenths.
local function skill_msg(skill_id, tenths, target_index, message)
    target_index = target_index or FAKE.index
    message = message or 38
    H.packet(0x029, packet(0x1C, {
        [0x0C] = skill_id, [0x10] = tenths,
        [0x16] = target_index % 256, [0x17] = math.floor(target_index / 256),
        [0x18] = message % 256, [0x19] = math.floor(message / 256) }))
end
-- Advance past the grace period so any late skill-up is included in the row.
local function settle()
    frame(2000)
end

H.reset()
face(180); frame()                 -- due south = earth's arrow
synth_request(4099)                -- earth crystal
eq('auto-lock switches to earth', cfg.crystal[1], 'earth')
ok('and says so', printed_text():find('Locked on Earth', 1, true) ~= nil, printed_text())
synth_anim(2)                      -- HQ1
skill_msg(54, 1)                   -- Bonecraft rises 0.1
synth_result(0, 1, 1, 12345)
eq('nothing is written until the result settles', #ledger_lines(), 0)
settle()
local L = ledger_lines()
eq('ledger has header + 1 row', #L, 2)
eq('ledger starts with the header', L[1], compass.CSV_HEADER)
ok('row: earth, safe, 180.0 S, arrow 0.0 off, crescent -45.0 off, arrow sector',
    (L[2] or ''):find(',earth,safe,180.0,S,S,0.0,SE,-45.0,arrow,', 1, true) ~= nil, L[2])
ok('row: Lightsday, moon 57, HQ1, Bronze Ingot x1, skill +1 tenth',
    (L[2] or ''):find(',Lightsday,57,HQ1,12345,Bronze Ingot,1,1', 1, true) ~= nil, L[2])

H.reset()
H.command('/dac stats')
ok('stats show the earth crystal', printed_text():find('Earth crystal: 1 synths', 1, true) ~= nil, printed_text())
ok('stats show 100% HQ and +0.1 skill on the arrow', printed_text():find('arrow S', 1, true) ~= nil
    and printed_text():find('100.0%', 1, true) ~= nil
    and printed_text():find('+0.1', 1, true) ~= nil, printed_text())

-- Late main/sub-craft gains should count; unrelated messages shouldn't.
synth_request(4099)
synth_anim(0)
synth_result(0, 0, 1, 12345)
skill_msg(54, 2)                   -- after the result, inside the grace
skill_msg(55, 1)                   -- sub-craft (Alchemy) gain in the same synth
skill_msg(1, 3)                    -- hand-to-hand: not a craft
skill_msg(54, 5, 0x200)            -- someone else's Bonecraft
skill_msg(54, 7, FAKE.index, 53)   -- "reaches level": not a gain amount
settle()
L = ledger_lines()
eq('two data rows now', #L, 3)
ok('late + sub-craft gains add up to 3 tenths; the noise is ignored',
    (L[3] or ''):find(',NQ,12345,Bronze Ingot,1,3', 1, true) ~= nil, L[3])

-- A nearby player's break shouldn't end up in our ledger.
synth_request(4099)
synth_anim(1, 0x200)               -- someone else broke theirs
synth_anim(0)                      -- ours is NQ
synth_result(0, 0, 1, 12345)
settle()
L = ledger_lines()
eq('three data rows now', #L, 4)
ok('our row is NQ, not their BREAK', (L[4] or ''):find(',NQ,', 1, true) ~= nil, L[4])

-- Count breaks even when we're facing neither of earth's chart headings.
face(90); frame()
synth_request(4099)
synth_anim(1)
synth_result(1, 0, 0, 0)
settle()
L = ledger_lines()
ok('break logged in the other sector with no item',
    (L[5] or ''):find(',other,', 1, true) ~= nil and (L[5] or ''):find(',BREAK,,,,0', 1, true) ~= nil, L[5])

-- Losing the animation packet shouldn't lose the synth result.
face(180); frame()
synth_request(4099)
synth_result(0, 2, 1, 12345)
settle()
L = ledger_lines()
ok('result packet alone yields HQ2', (L[6] or ''):find(',HQ2,', 1, true) ~= nil, L[6])

H.reset()
H.command('/dac auto off')
synth_request(4096)                -- fire
eq('auto off keeps the selection', cfg.crystal[1], 'earth')
synth_anim(0)
synth_result(0, 0, 1, 12345)
settle()
L = ledger_lines()
ok('but the synth is still logged under fire', (L[7] or ''):find(',fire,', 1, true) ~= nil, L[7])
H.command('/dac auto on')

H.command('/dac ledger off')
synth_request(4096)
synth_anim(0)
synth_result(0, 0, 1, 12345)
settle()
eq('ledger off writes nothing', #ledger_lines(), 7)
H.command('/dac ledger on')

H.reset()
H.load_event()
ok('reload counts the ledger rows', printed_text():find('Ledger: 6 synths', 1, true) ~= nil, printed_text())

synth_request(4099)
synth_anim(0)
frame(31000)
eq('a result with no item packet is flushed after 30s', #ledger_lines(), 8)
synth_request(4099)
frame(121000)
eq('a synth with no result at all is dropped', #ledger_lines(), 8)

-- Starting another synth should finish the previous row immediately.
synth_request(4099)
synth_anim(0)
synth_result(0, 0, 1, 12345)
synth_request(4099)
eq('a new synth flushes the finished one at once', #ledger_lines(), 9)
synth_anim(0)
synth_result(0, 0, 1, 12345)
settle()
eq('and the new one lands once it settles', #ledger_lines(), 10)

out('\n-- commands --')
H.reset()
H.command('/dac none')
eq('none clears the crystal', cfg.crystal[1], '')
H.reset()
H.command('/dac status')
ok('status with no crystal hints at the command', printed_text():find('No crystal', 1, true) ~= nil, printed_text())
H.reset()
H.command('/dac thunder')
eq('thunder alias -> lightning', cfg.crystal[1], 'lightning')
H.command('/dac heading')
eq('heading mode', cfg.orient_mode[1], 'heading')
H.command('/dac north')
eq('north mode', cfg.orient_mode[1], 'north')
H.reset()
H.command('/dac size 50')
ok('size out of range warns', printed_text():find('Size must', 1, true) ~= nil, printed_text())
eq('size unchanged', cfg.size[1], 200)
H.command('/dac size 260')
eq('size set', cfg.size[1], 260)
H.reset()
H.command('/dac cal')
ok('cal prints yaw and bearing', printed_text():find('bearing=', 1, true) ~= nil, printed_text())
face(123)
H.command('/dac setnorth')
near('setnorth makes the current yaw north', cfg.north_yaw_deg[1], compass.norm(123 + 270))
frame()
H.reset()
H.command('/dac status')
ok('now the facing reads 0.0', printed_text():find('Facing 0.0 deg (N)', 1, true) ~= nil, printed_text())
cfg.north_yaw_deg[1] = 270
H.reset()
H.command('/dac bogus')
ok('unknown subcommand warns', printed_text():find('Unknown command', 1, true) ~= nil, printed_text())
H.command('/dac')
eq('/dac toggles visibility off', cfg.visible[1], false)
H.command('/dac')
eq('... and back on', cfg.visible[1], true)
H.reset()
H.command('/dac help')
ok('help lists stats', printed_text():find('/dac stats', 1, true) ~= nil, printed_text())

out('\n-- heading unavailable --')
FAKE.index = 0
frame()
H.reset()
H.command('/dac status')
ok('no player index: status says the heading is unknown', printed_text():find('unknown', 1, true) ~= nil, printed_text())
FAKE.index = 0x123

os.remove(ledger)
out(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
