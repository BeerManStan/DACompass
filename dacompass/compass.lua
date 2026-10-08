-- DACompass chart, bearing math, packet readers, and ledger helpers.
-- Keep Ashita and ImGui out of here so this can be tested with plain LuaJIT.
--
-- These directions come from the old "Synthing Compass" chart: arrow for
-- fewer breaks, crescent for HQs/skill-ups. Whether that actually works is
-- the whole argument. DASoccer can take it up with the CSV.

local M = {}

-- Use Vana'diel weekday order for the crystal buttons too.
M.ELEMENTS = { 'fire', 'earth', 'water', 'wind', 'ice', 'lightning', 'light', 'dark' }

M.INFO = {
  fire      = { label = 'Fire',      arrow = 'NW', crescent = 'W',  day = 'Firesday',     color = { 0.93, 0.13, 0.13 } },
  earth     = { label = 'Earth',     arrow = 'S',  crescent = 'SE', day = 'Earthsday',    color = { 1.00, 0.92, 0.15 } },
  water     = { label = 'Water',     arrow = 'W',  crescent = 'SW', day = 'Watersday',    color = { 0.20, 0.32, 0.95 } },
  wind      = { label = 'Wind',      arrow = 'SE', crescent = 'E',  day = 'Windsday',     color = { 0.25, 0.90, 0.20 } },
  ice       = { label = 'Ice',       arrow = 'E',  crescent = 'NW', day = 'Iceday',       color = { 0.30, 0.95, 0.95 } },
  lightning = { label = 'Lightning', arrow = 'SW', crescent = 'S',  day = 'Lightningday', color = { 0.95, 0.25, 0.95 } },
  light     = { label = 'Light',     arrow = 'NE', crescent = 'N',  day = 'Lightsday',    color = { 0.93, 0.93, 0.93 } },
  dark      = { label = 'Dark',      arrow = 'N',  crescent = 'NE', day = 'Darksday',     color = { 0.45, 0.45, 0.50 } },
}

M.DIRECTIONS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
M.BEARING = { N = 0, NE = 45, E = 90, SE = 135, S = 180, SW = 225, W = 270, NW = 315 }
local DIR16 = { 'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
                'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW' }

-- The dial needs to look up colors by heading instead of by crystal.
M.ARROW_AT, M.CRESCENT_AT = {}, {}
for key, info in pairs(M.INFO) do
  M.ARROW_AT[info.arrow] = key
  M.CRESCENT_AT[info.crescent] = key
end

-- ----------------------------
-- Names
-- ----------------------------
local ALIASES = {
  fire = 'fire', earth = 'earth', water = 'water', wind = 'wind', ice = 'ice',
  lightning = 'lightning', thunder = 'lightning', ltng = 'lightning', lightening = 'lightning',
  light = 'light', dark = 'dark', darkness = 'dark',
}

-- Accept shorthand and full crystal names; return nil for anything unknown.
function M.parse_element(s)
  if type(s) ~= 'string' then return nil end
  s = s:lower()
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  s = s:gsub('%s*crystal$', '')
  return ALIASES[s]
end

-- Normal crystals are 4096-4103; HQ crystals are 4104-4111
-- (Inferno, Glacier, Cyclone, Terra, Plasma, Fluid, Glimmer, Shadow).
M.CRYSTAL_IDS = {
  [4096] = 'fire', [4097] = 'ice', [4098] = 'wind', [4099] = 'earth',
  [4100] = 'lightning', [4101] = 'water', [4102] = 'light', [4103] = 'dark',
  [4104] = 'fire', [4105] = 'ice', [4106] = 'wind', [4107] = 'earth',
  [4108] = 'lightning', [4109] = 'water', [4110] = 'light', [4111] = 'dark',
}

-- Fall back to the item name. Check lightning first or it gets read as light.
local NAME_HINTS = {
  { 'lightning', 'lightning' }, { 'plasma', 'lightning' }, { 'thunder', 'lightning' },
  { 'inferno', 'fire' },  { 'fire', 'fire' },
  { 'glacier', 'ice' },   { 'ice', 'ice' },
  { 'cyclone', 'wind' },  { 'wind', 'wind' },
  { 'terra', 'earth' },   { 'earth', 'earth' },
  { 'fluid', 'water' },   { 'water', 'water' },
  { 'glimmer', 'light' }, { 'light', 'light' },
  { 'shadow', 'dark' },   { 'dark', 'dark' },
}

function M.element_for_item(id, name)
  local el = M.CRYSTAL_IDS[id]
  if el then return el end
  if type(name) ~= 'string' then return nil end
  local n = name:lower()
  for _, h in ipairs(NAME_HINTS) do
    if n:find(h[1], 1, true) then return h[2] end
  end
  return nil
end

-- ----------------------------
-- Bearings
-- ----------------------------
function M.norm(deg)
  return deg % 360
end

-- Convert radians to a clockwise bearing with north at zero.
-- North defaults to a yaw of 270 degrees. /dac setnorth lets you calibrate it.
function M.yaw_to_bearing(yaw, north_yaw_deg, reverse)
  if type(yaw) ~= 'number' then return nil end
  local d = math.deg(yaw)
  if reverse then d = -d end
  return M.norm(d - (north_yaw_deg or 270))
end

-- Take the short way around. Positive means turn right.
function M.turn(target, bearing)
  return ((target - bearing + 540) % 360) - 180
end

function M.nearest_direction(bearing)
  local i = math.floor(bearing / 45 + 0.5) % 8
  return M.DIRECTIONS[i + 1]
end

function M.direction16(bearing)
  local i = math.floor(bearing / 22.5 + 0.5) % 16
  return DIR16[i + 1]
end

-- Return the chart heading and bearing: arrow for safe, crescent for HQ.
function M.target(element, goal)
  local info = M.INFO[element]
  if not info then return nil, nil end
  local dir = (goal == 'hq') and info.crescent or info.arrow
  return dir, M.BEARING[dir]
end

-- Group ledger entries by the nearest 45-degree compass point.
-- The chime tolerance doesn't affect these groups.
function M.sector(element, bearing)
  local info = M.INFO[element]
  if not info or type(bearing) ~= 'number' then return 'other' end
  local n = M.nearest_direction(bearing)
  if n == info.arrow then return 'arrow' end
  if n == info.crescent then return 'crescent' end
  return 'other'
end

-- ----------------------------
-- Vana'diel clock
-- ----------------------------
-- The game counts weekdays from zero, starting with Firesday.
function M.weekday_element(wd)
  if type(wd) ~= 'number' then return nil end
  return M.ELEMENTS[(math.floor(wd) % 8) + 1]
end

M.MOON_NAMES = {
  'New Moon', 'Waxing Crescent', 'Waxing Crescent', 'First Quarter',
  'Waxing Gibbous', 'Waxing Gibbous', 'Full Moon', 'Waning Gibbous',
  'Waning Gibbous', 'Last Quarter', 'Waning Crescent', 'Waning Crescent',
}

function M.moon_name(phase)
  if type(phase) ~= 'number' then return nil end
  return M.MOON_NAMES[(math.floor(phase) % 12) + 1]
end

-- ----------------------------
-- Packets
-- ----------------------------
-- Packet offsets start at zero and include the header. Lua strings start at
-- one, so do the +1 here instead of scattering it through the packet readers.
local function u8(s, off)
  return s:byte(off + 1) or 0
end

local function u16(s, off)
  local a, b = s:byte(off + 1, off + 2)
  return (a or 0) + (b or 0) * 256
end

local function u32(s, off)
  local a, b, c, d = s:byte(off + 1, off + 4)
  return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

M.u8, M.u16, M.u32 = u8, u16, u32

M.OUTCOMES = { [0] = 'NQ', [1] = 'BREAK', [2] = 'HQ1', [3] = 'HQ2', [4] = 'HQ3' }

-- Outgoing 0x096: crystal ID at 0x06, inventory slot at 0x08, ingredient
-- count at 0x09. Ingredient IDs follow at 0x0A; we don't need those yet.
function M.parse_synth_request(data)
  if type(data) ~= 'string' or #data < 0x0A then return nil end
  return {
    crystal_id       = u16(data, 0x06),
    crystal_index    = u8(data, 0x08),
    ingredient_count = u8(data, 0x09),
  }
end

-- Incoming 0x030: crafter's entity index at 0x08, result at 0x0C.
-- The result is already there when the animation starts.
function M.parse_synth_animation(data)
  if type(data) ~= 'string' or #data < 0x0D then return nil end
  local code = u8(data, 0x0C)
  return {
    target_index = u16(data, 0x08),
    code         = code,
    outcome      = M.OUTCOMES[code] or ('OTHER' .. tostring(code)),
  }
end

-- Incoming 0x06F: result at 0x04 (zero = success), quality at 0x05,
-- count at 0x06, item ID at 0x08. Item/count were
-- checked against a Phoenix XI ledger on 2026-10-07.
-- Skill-ups on Phoenix arrive in 0x029, not this packet.
function M.parse_synth_result(data)
  if type(data) ~= 'string' or #data < 0x0A then return nil end
  local q = u8(data, 0x05)
  if q > 127 then q = q - 256 end
  return {
    result  = u8(data, 0x04),
    quality = q,
    count   = u8(data, 0x06),
    item_id = u16(data, 0x08),
  }
end

-- Incoming 0x029 (message basic): actor/target IDs at 0x04/0x08,
-- params at 0x0C/0x10, actor/target indexes at 0x14/0x16, message at 0x18.
-- Message 38 is a skill gain: param1 is the skill ID, param2 is tenths gained.
M.MSG_SKILL_GAIN = 38

M.CRAFT_SKILLS = {
  [49] = 'Woodworking', [50] = 'Smithing',     [51] = 'Goldsmithing', [52] = 'Clothcraft',
  [53] = 'Leathercraft', [54] = 'Bonecraft',   [55] = 'Alchemy',      [56] = 'Cooking',
}

function M.parse_message_basic(data)
  if type(data) ~= 'string' or #data < 0x1A then return nil end
  return {
    actor_id     = u32(data, 0x04),
    target_id    = u32(data, 0x08),
    param1       = u32(data, 0x0C),
    param2       = u32(data, 0x10),
    actor_index  = u16(data, 0x14),
    target_index = u16(data, 0x16),
    message      = u16(data, 0x18),
  }
end

-- ----------------------------
-- Ledger (CSV)
-- ----------------------------
M.CSV_HEADER = 'utc,crystal,goal,facing_deg,facing_dir,arrow_dir,arrow_off_deg,'
  .. 'crescent_dir,crescent_off_deg,sector,vana_day,moon_pct,result,item_id,item_name,qty,skillup_tenths'

local function csv_escape(s)
  s = tostring(s == nil and '' or s)
  if s:find('[,"\n]') then return '"' .. s:gsub('"', '""') .. '"' end
  return s
end

function M.csv_row(rec)
  local info = M.INFO[rec.crystal] or {}
  local b = rec.facing_deg
  local function off(dir)
    if type(b) ~= 'number' or not dir then return '' end
    return ('%.1f'):format(M.turn(M.BEARING[dir], b))
  end
  return table.concat({
    rec.utc or '',
    rec.crystal or '',
    rec.goal or '',
    (type(b) == 'number') and ('%.1f'):format(b) or '',
    (type(b) == 'number') and M.direction16(b) or '',
    info.arrow or '', off(info.arrow),
    info.crescent or '', off(info.crescent),
    rec.sector or '',
    rec.vana_day or '',
    (rec.moon_pct ~= nil) and tostring(rec.moon_pct) or '',
    rec.result or '',
    (rec.item_id ~= nil) and tostring(rec.item_id) or '',
    csv_escape(rec.item_name or ''),
    (rec.qty ~= nil) and tostring(rec.qty) or '',
    (rec.skillup_tenths ~= nil) and tostring(rec.skillup_tenths) or '',
  }, ',')
end

-- Item names can contain commas and quotes, so a plain split won't do.
function M.csv_fields(line)
  local out, field, inq = {}, {}, false
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if inq then
      if c == '"' then
        if line:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 1
        else
          inq = false
        end
      else
        field[#field + 1] = c
      end
    elseif c == '"' then
      inq = true
    elseif c == ',' then
      out[#out + 1] = table.concat(field)
      field = {}
    else
      field[#field + 1] = c
    end
    i = i + 1
  end
  out[#out + 1] = table.concat(field)
  return out
end

-- Read just the fields needed to rebuild stats. Skip headers and bad rows.
function M.csv_parse(line)
  if type(line) ~= 'string' or line == '' or line:sub(1, 4) == 'utc,' then return nil end
  local f = M.csv_fields(line)
  if #f < 13 or not M.INFO[f[2]] then return nil end
  return {
    crystal        = f[2],
    goal           = f[3],
    facing_deg     = tonumber(f[4]),
    sector         = f[10],
    result         = f[13],
    skillup_tenths = tonumber(f[17]) or 0,
  }
end

-- ----------------------------
-- Tally
-- ----------------------------
M.SECTORS = { 'arrow', 'crescent', 'other' }

local function bucket()
  return { n = 0, breaks = 0, hq = 0, nq = 0, skillup_tenths = 0 }
end

local function group()
  return { arrow = bucket(), crescent = bucket(), other = bucket() }
end

function M.tally_new()
  return { all = group() }
end

function M.tally_add(t, rec)
  local sector = rec.sector
  if sector ~= 'arrow' and sector ~= 'crescent' then sector = 'other' end
  local function bump(g)
    local b = g[sector]
    b.n = b.n + 1
    local r = tostring(rec.result or '')
    if r == 'BREAK' then b.breaks = b.breaks + 1
    elseif r:sub(1, 2) == 'HQ' then b.hq = b.hq + 1
    elseif r == 'NQ' then b.nq = b.nq + 1 end
    b.skillup_tenths = b.skillup_tenths + (tonumber(rec.skillup_tenths) or 0)
  end
  bump(t.all)
  if M.INFO[rec.crystal] then
    t[rec.crystal] = t[rec.crystal] or group()
    bump(t[rec.crystal])
  end
end

function M.pct(n, d)
  if not d or d <= 0 then return nil end
  return n / d * 100
end

-- Leave rates blank when a sector has no synths yet; zero would be misleading.
function M.tally_rows(t, key)
  local g = t[key or 'all']
  if not g then return {} end
  local rows = {}
  for _, s in ipairs(M.SECTORS) do
    local b = g[s]
    rows[#rows + 1] = {
      sector = s, n = b.n, breaks = b.breaks, hq = b.hq, nq = b.nq,
      break_pct = M.pct(b.breaks, b.n),
      hq_pct    = M.pct(b.hq, b.n),
      skillup   = b.skillup_tenths / 10,
    }
  end
  return rows
end

-- Only list crystals we've logged, in weekday order.
function M.tally_keys(t)
  local keys = {}
  for _, el in ipairs(M.ELEMENTS) do
    if t[el] then keys[#keys + 1] = el end
  end
  return keys
end

return M
