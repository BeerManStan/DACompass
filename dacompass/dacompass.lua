--[[
  DACompass - because apparently a crafting argument needed its own addon.

  DASoccer says facing doesn't matter. Fine. We're keeping receipts.
  This follows the old "Synthing Compass" chart: arrow for fewer breaks,
  crescent for HQs and skill-ups. That's the theory, anyway.

  The dial shows your heading to a tenth of a degree. Every synth goes in
  the ledger with its facing and result; /dac stats compares arrow,
  crescent, and everything else. The breaks count too, unfortunately.

  Install:  Ashita/addons/dacompass/   (dacompass.lua, compass.lua, sounds/)
  Load:     /addon load dacompass

  Commands:
    /dac                      show/hide the compass
    /dac <crystal>            fire earth water wind ice lightning light dark
    /dac none                 clear the crystal (auto-lock still applies)
    /dac safe | hq            goal: fewer fails (arrow) / HQ + skill-ups (crescent)
    /dac north | heading      dial orientation: needle turns / dial turns
    /dac config               settings window
    /dac stats                ledger tallies in chat
    /dac cal                  raw yaw + bearing (calibration)
    /dac setnorth             calibrate: "I am facing north right now"
    /dac help                 everything else
--]]

addon.name     = 'dacompass'
addon.author   = 'BeerManStan'
addon.version  = '0.1.2'
addon.desc     = 'DACompass - synthesis facing compass: which way to face for your crystal (safe or HQ), how far off you are, and a synth ledger.'
addon.link     = ''
addon.commands = { '/dacompass', '/dac' }

require('common')
local chat     = require('chat')
local imgui    = require('imgui')
local settings = require('settings')
local bit      = bit or require('bit')
local compass  = require('compass')   -- chart, bearing math, packets, and ledger

-- ffxi.time can fail to load if its memory signatures don't match the client.
-- Leave day/moon blank if that happens; the compass still works.
local timelib = nil
do
  local ok, t = pcall(require, 'ffxi.time')
  if ok and type(t) == 'table' then timelib = t end
end

local DEG = '\194\176'   -- UTF-8 degree sign; keep it out of game chat

-- --------------------------------------------
-- Settings
-- --------------------------------------------
local default_settings = T{
  visible    = T{ true },
  locked     = T{ false },
  x          = T{ 300 },
  y          = T{ 300 },
  size       = T{ 200 },        -- dial diameter, px
  bg_alpha   = T{ 0.6 },
  show_frame = T{ false },      -- title bar + border

  orient_mode  = T{ 'north' },  -- 'north' (needle turns) | 'heading' (dial turns)
  goal         = T{ 'safe' },   -- 'safe' = arrow, 'hq' = crescent
  crystal      = T{ '' },       -- selected element, '' = none
  auto_crystal = T{ true },     -- pick up the crystal when a synth starts
  show_all     = T{ true },     -- keep the other crystal colors dimly visible
  show_text    = T{ true },     -- heading readout under the dial
  show_time    = T{ true },     -- Vana'diel day + moon line

  tolerance_deg = T{ 3.0 },     -- "on target" band, +/- degrees
  chime         = T{ true },
  chime_sound   = T{ 'xylophone_e4.wav' },
  cooldown_ms   = T{ 1500 },

  ledger = T{ true },           -- append every synth to dacompass_ledger.csv

  -- Default yaw, in degrees, for facing north.
  -- /dac setnorth replaces it; yaw_reverse flips the direction of rotation.
  north_yaw_deg = T{ 270 },
  yaw_reverse   = T{ false },

  debug = T{ false },
}

local cfg = settings.load(default_settings)

-- --------------------------------------------
-- State
-- --------------------------------------------
local state = {
  bearing     = nil,     -- degrees; nil while the player heading is unavailable
  yaw         = nil,     -- original yaw in radians
  on_target   = false,
  last_chime  = 0,
  pending     = nil,     -- current synth, waiting for result packets
  last_synth  = nil,     -- last completed synth shown below the dial
  tally       = compass.tally_new(),
  ledger_rows = 0,
  config_open = T{ false },
  vana        = nil,     -- cached day/moon reading
  vana_at     = 0,
}

-- These messages only go out to chat; we don't parse our own output.
local function say(msg)
  print(chat.header(addon.name):append(chat.message(msg)))
end

local function warn(msg)
  print(chat.header(addon.name):append(chat.error(msg)))
end

local function dbg(msg)
  if cfg.debug[1] then say('debug: ' .. tostring(msg)) end
end

local function now_ms()
  return ashita.time.clock()['ms']
end

local function play(file)
  file = tostring(file or '')
  if file == '' then return end
  ashita.misc.play_sound((addon.path:gsub('[\\/]+$', '')) .. '\\sounds\\' .. file)
end

-- --------------------------------------------
-- Heading
-- --------------------------------------------
local function player_index()
  local ok, idx = pcall(function()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0)
  end)
  if ok and type(idx) == 'number' and idx > 0 then return idx end
  return nil
end

-- GetLocalPositionYaw returns radians, not degrees.
local function read_yaw()
  local idx = player_index()
  if idx == nil then return nil end
  local ok, yaw = pcall(function()
    return AshitaCore:GetMemoryManager():GetEntity():GetLocalPositionYaw(idx)
  end)
  if ok and type(yaw) == 'number' then return yaw end
  return nil
end

local function read_bearing()
  local yaw = read_yaw()
  if yaw == nil then return nil, nil end
  return compass.yaw_to_bearing(yaw, cfg.north_yaw_deg[1], cfg.yaw_reverse[1]), yaw
end

-- --------------------------------------------
-- Vana'diel clock
-- --------------------------------------------
local function vana_now()
  if timelib == nil then return nil end
  local ok, v = pcall(function()
    local wd  = timelib.get_game_weekday()
    local el  = compass.weekday_element(wd)
    local inf = el and compass.INFO[el] or nil
    return {
      weekday   = wd,
      element   = el,
      day       = inf and inf.day or ('day ' .. tostring(wd)),
      moon_pct  = tonumber(timelib.get_game_moon_percent()),
      moon_name = compass.moon_name(timelib.get_game_moon_phase()),
    }
  end)
  if ok then return v end
  return nil
end

local function vana_cached()
  local n = now_ms()
  if state.vana == nil or (n - state.vana_at) > 1000 then
    state.vana = vana_now()
    state.vana_at = n
  end
  return state.vana
end

-- --------------------------------------------
-- Target + per-frame update
-- --------------------------------------------
-- No selected crystal means there's nothing to aim at yet.
local function current_target()
  local el = cfg.crystal[1]
  if el == nil or el == '' or compass.INFO[el] == nil then return nil end
  local dir, b = compass.target(el, cfg.goal[1])
  return el, dir, b
end

local function goal_label()
  return (cfg.goal[1] == 'hq') and 'HQ / skill-ups (crescent)' or 'Safe (arrow)'
end

local function update_heading()
  local b, yaw = read_bearing()
  state.bearing, state.yaw = b, yaw
  local el, _, tb = current_target()
  local on = false
  if el and b ~= nil then
    on = math.abs(compass.turn(tb, b)) <= (cfg.tolerance_deg[1] or 3)
  end
  -- Ring once when we enter the target band. Standing still isn't an encore.
  if on and not state.on_target and cfg.chime[1] then
    local n = now_ms()
    if (n - state.last_chime) >= (cfg.cooldown_ms[1] or 0) then
      state.last_chime = n
      play(cfg.chime_sound[1])
    end
  end
  state.on_target = on
end

-- --------------------------------------------
-- Ledger
-- --------------------------------------------
local function ledger_path()
  return (addon.path:gsub('[\\/]+$', '')) .. '\\dacompass_ledger.csv'
end

local function ledger_load()
  state.tally = compass.tally_new()
  state.ledger_rows = 0
  local ok, f = pcall(io.open, ledger_path(), 'r')
  if not ok or f == nil then return end
  for line in f:lines() do
    local rec = compass.csv_parse(line)
    if rec then
      compass.tally_add(state.tally, rec)
      state.ledger_rows = state.ledger_rows + 1
    end
  end
  f:close()
end

local function ledger_append(rec)
  local path = ledger_path()
  local existed = false
  local probe = io.open(path, 'r')
  if probe then existed = true; probe:close() end
  local ok, f = pcall(io.open, path, 'a')
  if not ok or f == nil then
    warn('Could not write ' .. path)
    return false
  end
  if not existed then f:write(compass.CSV_HEADER .. '\n') end
  f:write(compass.csv_row(rec) .. '\n')
  f:close()
  return true
end

local function fmt_pct(p)
  if p == nil then return '-' end
  return ('%.1f%%'):format(p)
end

-- Stats use 45-degree sectors, not the much narrower chime tolerance.
-- "Arrow" here means the nearest compass point is the chart's arrow heading.
local function tally_lines(key)
  local rows  = compass.tally_rows(state.tally, key)
  local info  = compass.INFO[key]
  local label = info and (info.label .. ' crystal') or 'All crystals'
  local total = 0
  for _, r in ipairs(rows) do total = total + r.n end
  local lines = { ('%s: %d synths'):format(label, total) }
  if total == 0 then return lines end
  lines[#lines + 1] = ('  %-14s %5s %7s %7s %7s'):format('faced', 'n', 'break', 'HQ', 'skill')
  for _, r in ipairs(rows) do
    local name = r.sector
    if info and r.sector == 'arrow' then name = 'arrow ' .. info.arrow
    elseif info and r.sector == 'crescent' then name = 'crescent ' .. info.crescent end
    lines[#lines + 1] = ('  %-14s %5d %7s %7s %7s'):format(
      name, r.n, fmt_pct(r.break_pct), fmt_pct(r.hq_pct), ('+%.1f'):format(r.skillup))
  end
  return lines
end

-- --------------------------------------------
-- Synth tracking
-- --------------------------------------------
local function item_name(id)
  if type(id) ~= 'number' or id <= 0 then return nil end
  local ok, n = pcall(function()
    local it = AshitaCore:GetResourceManager():GetItemById(id)
    return it and it.Name and it.Name[1] or nil
  end)
  if ok and type(n) == 'string' then return n end
  return nil
end

local function set_crystal(el, quiet)
  el = el or ''
  if cfg.crystal[1] == el then return end
  cfg.crystal[1] = el
  settings.save()
  if quiet then return end
  if el == '' then
    say('Crystal cleared.')
  else
    local info = compass.INFO[el]
    say(('%s crystal: face %s for fewer fails, %s for HQ / skill-ups.'):format(
      info.label, info.arrow, info.crescent))
  end
end

-- Only count synths that actually got a result. No guessing for the ledger.
local function finish_pending(reason)
  local p = state.pending
  if p == nil then return end
  state.pending = nil
  if p.outcome == nil then
    dbg('synth dropped with no result (' .. tostring(reason) .. ')')
    return
  end
  local rec = {
    utc            = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    crystal        = p.element,
    goal           = p.goal,
    facing_deg     = p.bearing,
    sector         = p.sector,
    vana_day       = p.day,
    moon_pct       = p.moon_pct,
    result         = p.outcome,
    item_id        = p.item_id,
    item_name      = p.item_name,
    qty            = p.qty,
    skillup_tenths = p.skillup_tenths or 0,
    skill          = p.skill,
  }
  state.last_synth = rec
  compass.tally_add(state.tally, rec)
  if cfg.ledger[1] and ledger_append(rec) then
    state.ledger_rows = state.ledger_rows + 1
  end
  dbg(('logged: %s, facing %s, %s sector -> %s'):format(
    rec.crystal, rec.facing_deg and ('%.1f'):format(rec.facing_deg) or '?', rec.sector, rec.result))
end

-- 0x096 goes out when you confirm the synth. Take the heading now, before
-- the animation; selecting a crystal in the menu doesn't send this packet.
local function on_synth_request(data)
  local req = compass.parse_synth_request(data)
  if req == nil then return end
  local el = compass.element_for_item(req.crystal_id, item_name(req.crystal_id))
  if el == nil then
    dbg(('synth with unknown crystal item %d'):format(req.crystal_id))
    return
  end
  if cfg.auto_crystal[1] and cfg.crystal[1] ~= el then
    set_crystal(el, true)
    say(('Locked on %s crystal.'):format(compass.INFO[el].label))
  end
  finish_pending('next synth started')
  local b = read_bearing()
  local v = vana_now()
  state.pending = {
    t        = now_ms(),
    element  = el,
    goal     = cfg.goal[1],
    bearing  = b,
    sector   = compass.sector(el, b),
    day      = v and v.day or '',
    moon_pct = v and v.moon_pct or nil,
  }
  dbg(('synth started: %s crystal, facing %s (%s sector)'):format(
    compass.INFO[el].label, b and ('%.1f'):format(b) or '?', state.pending.sector))
end

-- 0x030 includes nearby players' synths, so check the player index first.
local function on_synth_animation(data)
  local a = compass.parse_synth_animation(data)
  if a == nil then return end
  local me = player_index()
  if me == nil or a.target_index ~= me then return end
  local p = state.pending
  if p == nil then
    dbg('synth result with nothing in flight (' .. a.outcome .. ')')
    return
  end
  if p.outcome == nil then
    p.outcome = a.outcome
    p.outcome_t = now_ms()
  end
  dbg('synth result: ' .. a.outcome)
end

-- 0x06F gives the result and output item. Skill-ups arrive separately in 0x029.
local function on_synth_result(data)
  local r = compass.parse_synth_result(data)
  if r == nil then return end
  local p = state.pending
  if p == nil then return end
  if p.outcome == nil then
    -- Missed the animation packet? We can still get the result from this one.
    if r.result ~= 0 then p.outcome = 'BREAK'
    elseif r.quality > 0 then p.outcome = 'HQ' .. math.min(r.quality, 3)
    else p.outcome = 'NQ' end
  end
  if r.result == 0 and r.item_id > 0 then
    p.item_id   = r.item_id
    p.item_name = item_name(r.item_id)
    p.qty       = r.count
  end
  -- Give late skill-up messages a moment to arrive before writing the row.
  -- check_pending handles the delay.
  p.done_t = now_ms()
end

-- Attach our crafting skill-ups to the pending synth, including sub-crafts.
-- Ignore other players' gains and non-crafting skills.
local function on_message_basic(data)
  local m = compass.parse_message_basic(data)
  if m == nil or m.message ~= compass.MSG_SKILL_GAIN then return end
  local skill = compass.CRAFT_SKILLS[m.param1]
  if skill == nil then return end
  local me = player_index()
  if me == nil or (m.target_index ~= me and m.actor_index ~= me) then return end
  local p = state.pending
  if p == nil then
    dbg(('%s +%.1f with no synth in flight'):format(skill, m.param2 / 10))
    return
  end
  p.skillup_tenths = (p.skillup_tenths or 0) + m.param2
  p.skill = skill
  dbg(('skill-up: %s +%.1f'):format(skill, m.param2 / 10))
end

local SETTLE_MS = 1500

-- Finish after the grace period, or stop waiting if a packet never arrives.
local function check_pending()
  local p = state.pending
  if p == nil then return end
  local n = now_ms()
  if p.done_t ~= nil then
    if (n - p.done_t) >= SETTLE_MS then finish_pending('settled') end
  elseif p.outcome ~= nil and (n - (p.outcome_t or n)) > 30000 then
    finish_pending('no result packet in 30s')
  elseif p.outcome == nil and (n - p.t) > 120000 then
    finish_pending('no animation packet in 120s')
  end
end

-- --------------------------------------------
-- Drawing
-- --------------------------------------------
local WHITE  = { 1.00, 1.00, 1.00 }
local GRAY   = { 0.62, 0.62, 0.62 }
local GREEN  = { 0.35, 1.00, 0.35 }
local YELLOW = { 1.00, 0.85, 0.30 }
local BLACK  = { 0.00, 0.00, 0.00 }

local function rgba(c, a)
  return imgui.GetColorU32({ c[1], c[2], c[3], a or 1 })
end

local function col4(c, a)
  return { c[1], c[2], c[3], a or 1 }
end

-- Screen bearings start at the top and run clockwise, like the compass.
local function pt(cx, cy, b, r)
  local a = math.rad(b - 90)
  return { cx + math.cos(a) * r, cy + math.sin(a) * r }
end

-- Build the curved band from triangles when the arc binding isn't available.
local function ring_strip(dl, cx, cy, b0, b1, r_in, r_out, col, steps)
  steps = steps or 10
  local span = b1 - b0
  local p_in, p_out = pt(cx, cy, b0, r_in), pt(cx, cy, b0, r_out)
  for i = 1, steps do
    local b = b0 + span * i / steps
    local n_in, n_out = pt(cx, cy, b, r_in), pt(cx, cy, b, r_out)
    dl:AddTriangleFilled(p_out, n_out, n_in, col)
    dl:AddTriangleFilled(p_out, n_in, p_in, col)
    p_in, p_out = n_in, n_out
  end
end

-- A stroked arc avoids seams. Try it once, then use triangles if this
-- ImGui binding doesn't support PathArcTo/PathStroke.
local arc_ok = nil
local function arc_band(dl, cx, cy, b0, b1, r_in, r_out, col)
  if arc_ok ~= false then
    local ok = pcall(function()
      dl:PathArcTo({ cx, cy }, (r_in + r_out) / 2, math.rad(b0 - 90), math.rad(b1 - 90), 24)
      dl:PathStroke(col, 0, r_out - r_in)
    end)
    if ok then arc_ok = true; return end
    arc_ok = false
    pcall(function() dl:PathClear() end)
  end
  ring_strip(dl, cx, cy, b0, b1, r_in, r_out, col, 12)
end

-- Two triangles make one point of the compass rose, with a darker right half.
local function kite(dl, cx, cy, b, tip_r, wing_r, wing_deg, col, col_dark)
  local tip = pt(cx, cy, b, tip_r)
  local l   = pt(cx, cy, b - wing_deg, wing_r)
  local r   = pt(cx, cy, b + wing_deg, wing_r)
  local c   = { cx, cy }
  dl:AddTriangleFilled(tip, l, c, col)
  dl:AddTriangleFilled(tip, c, r, col_dark or col)
end

local addtext_ok = nil
local function text_at(dl, x, y, col, s)
  if addtext_ok == false then return end
  local ok = pcall(function()
    dl:AddText({ x + 1, y + 1 }, rgba(BLACK, 0.9), s)
    dl:AddText({ x, y }, col, s)
  end)
  if not ok then addtext_ok = false end
end

local function draw_dial(dl, cx, cy, R)
  local heading_up = (cfg.orient_mode[1] == 'heading')
  local bearing = state.bearing
  local rot = (heading_up and bearing ~= nil) and -bearing or 0   -- screen = world + rot
  local sel, _, sel_b = current_target()
  local info = sel and compass.INFO[sel] or nil
  local dim  = cfg.show_all[1] and 0.30 or 0

  local r_band_out, r_band_in = R * 1.00, R * 0.95   -- on-target band
  local r_ring_out, r_ring_in = R * 0.93, R * 0.80   -- crescent ring
  local r_tip, r_wing         = R * 0.72, R * 0.20   -- arrow rose

  dl:AddCircleFilled({ cx, cy }, R, rgba(BLACK, 0.55), 48)

  -- Outer ring uses the chart's crescent colors.
  for _, dir in ipairs(compass.DIRECTIONS) do
    local b   = compass.BEARING[dir] + rot
    local cel = compass.CRESCENT_AT[dir]
    local ca  = (info and info.crescent == dir) and 1.0 or dim
    if ca > 0 then
      arc_band(dl, cx, cy, b - 22.5, b + 22.5, r_ring_in, r_ring_out, rgba(compass.INFO[cel].color, ca))
    end
  end
  for _, dir in ipairs(compass.DIRECTIONS) do
    local b = compass.BEARING[dir] + 22.5 + rot
    dl:AddLine(pt(cx, cy, b, r_ring_in - 1), pt(cx, cy, b, r_ring_out + 1), rgba(BLACK, 0.85), 1.5)
  end
  dl:AddCircle({ cx, cy }, r_ring_out, rgba(BLACK, 0.8), 48, 1.0)
  dl:AddCircle({ cx, cy }, r_ring_in, rgba(BLACK, 0.8), 48, 1.0)

  -- Inner arrows use the chart's arrow colors. Highlight the selected crystal.
  for _, dir in ipairs(compass.DIRECTIONS) do
    local b   = compass.BEARING[dir] + rot
    local ael = compass.ARROW_AT[dir]
    local aa  = (info and info.arrow == dir) and 1.0 or dim
    if aa > 0 then
      local c = compass.INFO[ael].color
      kite(dl, cx, cy, b, r_tip, r_wing, 20, rgba(c, aa), rgba({ c[1] * 0.55, c[2] * 0.55, c[3] * 0.55 }, aa))
    end
  end

  -- Mark the target and its tolerance band just outside the ring.
  if info then
    local tb  = sel_b + rot
    local tol = math.max(0.5, cfg.tolerance_deg[1] or 3)
    local bc  = state.on_target and GREEN or WHITE
    arc_band(dl, cx, cy, tb - tol, tb + tol, r_band_in, r_band_out, rgba(bc, 0.95))
    dl:AddTriangleFilled(pt(cx, cy, tb, r_ring_in - 2),
      pt(cx, cy, tb - 5, r_ring_out + 1), pt(cx, cy, tb + 5, r_ring_out + 1), rgba(bc, 0.95))
  end

  -- Label both choices while there's enough room to read them.
  if info and R >= 60 then
    local pa = pt(cx, cy, compass.BEARING[info.arrow] + rot, R * 0.46)
    text_at(dl, pa[1] - 14, pa[2] - 7, rgba(WHITE, 0.95), 'SAFE')
    local pc = pt(cx, cy, compass.BEARING[info.crescent] + rot, R * 0.62)
    text_at(dl, pc[1] - 7, pc[2] - 7, rgba(WHITE, 0.95), 'HQ')
  end

  -- The needle follows the player, whatever DASoccer thinks of the destination.
  if bearing ~= nil then
    local nb = heading_up and 0 or bearing
    local nc = state.on_target and rgba(GREEN, 1) or rgba(WHITE, 0.95)
    local tail, head = pt(cx, cy, nb + 180, R * 0.18), pt(cx, cy, nb, R * 0.70)
    dl:AddLine(tail, head, rgba(BLACK, 0.9), 4.0)
    dl:AddLine(tail, head, nc, 2.0)
    dl:AddTriangleFilled(pt(cx, cy, nb, R * 0.80),
      pt(cx, cy, nb - 10, R * 0.64), pt(cx, cy, nb + 10, R * 0.64), nc)
  end
  dl:AddCircleFilled({ cx, cy }, R * 0.05, rgba(WHITE, 0.9), 16)

  -- Keep N/E/S/W outside the colored rings.
  for _, dir in ipairs({ 'N', 'E', 'S', 'W' }) do
    local p = pt(cx, cy, compass.BEARING[dir] + rot, R + 9)
    text_at(dl, p[1] - 3.5, p[2] - 7, rgba(dir == 'N' and YELLOW or WHITE, 0.95), dir)
  end
end

local function render_window()
  local size = cfg.size[1] or 200
  imgui.SetNextWindowPos({ cfg.x[1], cfg.y[1] }, ImGuiCond_Once)
  imgui.SetNextWindowBgAlpha(cfg.bg_alpha[1] or 0.6)
  local flags = bit.bor(
    ImGuiWindowFlags_NoScrollbar,
    ImGuiWindowFlags_NoScrollWithMouse,
    ImGuiWindowFlags_NoCollapse,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_AlwaysAutoResize
  )
  if cfg.locked[1] then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end
  if not cfg.show_frame[1] then flags = bit.bor(flags, ImGuiWindowFlags_NoTitleBar) end

  local shown = imgui.Begin('DACompass##dac', cfg.visible, flags)
  if shown then
    local dl = imgui.GetWindowDrawList()
    local ox, oy = imgui.GetCursorScreenPos()
    -- Long readouts widen the window, so keep the dial centered above them.
    local availW = imgui.GetContentRegionAvail()
    local dx = 0
    if type(availW) == 'number' and availW > size then dx = (availW - size) / 2 end
    draw_dial(dl, ox + dx + size / 2, oy + size / 2, size / 2 - 14)
    imgui.Dummy({ size, size })

    if cfg.show_text[1] then
      local b = state.bearing
      local sel, _, sel_b = current_target()
      local facing = (b ~= nil)
        and ('Facing %6.1f%s  %s'):format(b, DEG, compass.direction16(b))
        or  'Facing  --'
      if sel then
        local info = compass.INFO[sel]
        local hq = (cfg.goal[1] == 'hq')
        imgui.TextColored(col4(info.color), info.label .. ' crystal')
        -- Show both chart headings; '>' marks the goal used by the band/chime.
        imgui.TextColored(col4(hq and GRAY or WHITE), ('%s Arrow %s %d%s: fewer fails'):format(
          hq and ' ' or '>', info.arrow, compass.BEARING[info.arrow], DEG))
        imgui.TextColored(col4(hq and WHITE or GRAY), ('%s Crescent %s %d%s: HQ + skill-ups'):format(
          hq and '>' or ' ', info.crescent, compass.BEARING[info.crescent], DEG))
        imgui.Text(facing)
        if b ~= nil then
          local t = compass.turn(sel_b, b)
          if state.on_target then
            imgui.TextColored(col4(GREEN), ('ON TARGET  (%.1f%s off)'):format(math.abs(t), DEG))
          else
            imgui.TextColored(col4(YELLOW), ('Turn %s %.1f%s'):format(
              (t > 0) and 'RIGHT' or 'LEFT', math.abs(t), DEG))
          end
        end
      else
        imgui.Text(facing)
        imgui.Text('No crystal selected.')
        imgui.Text('Type /dac fire (or earth, water, ...),')
        imgui.Text('or just synth once: it locks on by itself.')
        imgui.TextColored(col4(GRAY), 'Arrow = fewer fails')
        imgui.TextColored(col4(GRAY), 'Crescent = HQ + skill-ups')
      end
      if cfg.show_time[1] then
        local v = vana_cached()
        if v then
          local dc = v.element and compass.INFO[v.element].color or WHITE
          imgui.TextColored(col4(dc), v.day)
          if v.moon_pct ~= nil then
            imgui.SameLine()
            imgui.Text(('| Moon %d%%%s'):format(math.floor(v.moon_pct),
              v.moon_name and (' ' .. v.moon_name) or ''))
          end
        end
      end
      if state.last_synth then
        local ls = state.last_synth
        local gain = ''
        if (ls.skillup_tenths or 0) > 0 then
          gain = (', %s +%.1f'):format(ls.skill or 'skill', ls.skillup_tenths / 10)
        end
        imgui.Text(('Last synth: %s, faced %s%s'):format(ls.result,
          (ls.sector == 'other') and 'elsewhere' or ('the ' .. ls.sector), gain))
      end
    end

    if not cfg.locked[1] then
      local wx, wy = imgui.GetWindowPos()
      if type(wx) == 'number' and type(wy) == 'number' then
        cfg.x[1] = math.floor(wx)
        cfg.y[1] = math.floor(wy)
      end
    end
  end
  imgui.End()
end

-- --------------------------------------------
-- Config window
-- --------------------------------------------
local function render_tally()
  imgui.Text(('Ledger: %d synths in dacompass_ledger.csv'):format(state.ledger_rows))
  imgui.Text('Sectors are the 45-degree slice around each chart heading.')
  local keys = compass.tally_keys(state.tally)
  table.insert(keys, 1, 'all')
  for _, k in ipairs(keys) do
    for _, line in ipairs(tally_lines(k)) do imgui.Text(line) end
  end
end

local function render_config()
  if not state.config_open[1] then return end
  if imgui.Begin('DACompass Config##daccfg', state.config_open, ImGuiWindowFlags_AlwaysAutoResize) then
    imgui.Text('Crystal')
    for i, el in ipairs(compass.ELEMENTS) do
      local info = compass.INFO[el]
      local c = info.color
      local selected = (cfg.crystal[1] == el)
      local dark_text = (el == 'earth' or el == 'ice' or el == 'light' or el == 'wind')
      imgui.PushStyleColor(ImGuiCol_Button, { c[1] * 0.7, c[2] * 0.7, c[3] * 0.7, selected and 1.0 or 0.55 })
      imgui.PushStyleColor(ImGuiCol_ButtonHovered, { c[1], c[2], c[3], 0.9 })
      imgui.PushStyleColor(ImGuiCol_ButtonActive, { c[1], c[2], c[3], 1.0 })
      imgui.PushStyleColor(ImGuiCol_Text, dark_text and { 0, 0, 0, 1 } or { 1, 1, 1, 1 })
      local label = (selected and '[%s]' or '%s'):format(info.label) .. '##cry_' .. el
      if imgui.Button(label, { 84, 0 }) then set_crystal(el) end
      imgui.PopStyleColor(4)
      if i % 4 ~= 0 then imgui.SameLine() end
    end
    if imgui.Button('None##cry_none', { 84, 0 }) then set_crystal('') end
    imgui.SameLine()
    imgui.Checkbox('Auto-lock to the crystal I synth with', cfg.auto_crystal)

    imgui.Separator()
    imgui.Text('Goal:')
    imgui.SameLine()
    if imgui.RadioButton('Safe - fewer fails (arrow)', cfg.goal[1] ~= 'hq') then cfg.goal[1] = 'safe' end
    imgui.SameLine()
    if imgui.RadioButton('HQ + skill-ups (crescent)', cfg.goal[1] == 'hq') then cfg.goal[1] = 'hq' end

    imgui.Text('Dial:')
    imgui.SameLine()
    if imgui.RadioButton('North-up (needle turns)', cfg.orient_mode[1] ~= 'heading') then cfg.orient_mode[1] = 'north' end
    imgui.SameLine()
    if imgui.RadioButton('Heading-up (dial turns)', cfg.orient_mode[1] == 'heading') then cfg.orient_mode[1] = 'heading' end

    imgui.SliderInt('Size (px)', cfg.size, 120, 400)
    imgui.SliderFloat('On-target band (+/- deg)', cfg.tolerance_deg, 0.5, 22.5, '%.1f')
    imgui.SliderFloat('Background alpha', cfg.bg_alpha, 0.0, 1.0, '%.2f')

    imgui.Checkbox('Chime when on target', cfg.chime)
    imgui.SameLine()
    imgui.Checkbox('Show all eight colours', cfg.show_all)
    imgui.Checkbox('Heading readout', cfg.show_text)
    imgui.SameLine()
    imgui.Checkbox('Day / moon', cfg.show_time)
    imgui.Checkbox('Window frame', cfg.show_frame)
    imgui.SameLine()
    imgui.Checkbox('Lock position', cfg.locked)
    imgui.SameLine()
    imgui.Checkbox('Visible', cfg.visible)
    imgui.Checkbox('Log every synth to dacompass_ledger.csv', cfg.ledger)

    imgui.Separator()
    if imgui.CollapsingHeader('Ledger - does facing matter?') then render_tally() end

    imgui.Separator()
    if imgui.Button('Save') then settings.save() end
    imgui.SameLine()
    if imgui.Button('Close') then state.config_open[1] = false end
  end
  imgui.End()
end

-- --------------------------------------------
-- Commands
-- --------------------------------------------
local function print_help()
  say('Commands:\n' ..
    '  /dac                     show/hide the compass\n' ..
    '  /dac <crystal>           fire earth water wind ice lightning light dark\n' ..
    '  /dac none                clear the crystal\n' ..
    '  /dac safe | hq           goal: fewer fails (arrow) / HQ + skill-ups (crescent)\n' ..
    '  /dac north | heading     needle turns / dial turns\n' ..
    '  /dac status              where you face vs the target\n' ..
    '  /dac config              settings window\n' ..
    '  /dac lock | unlock       window position\n' ..
    '  /dac size <px>           dial size\n' ..
    '  /dac tol <deg>           on-target band (+/- degrees)\n' ..
    '  /dac chime on|off        sound when you reach the target\n' ..
    '  /dac auto on|off         lock onto the crystal of each synth\n' ..
    '  /dac ledger on|off       log every synth to dacompass_ledger.csv\n' ..
    '  /dac stats               ledger tallies\n' ..
    '  /dac cal                 raw yaw + bearing\n' ..
    '  /dac setnorth            calibrate: I am facing north right now\n' ..
    '  /dac debug on|off')
end

local function show_status()
  local b = state.bearing
  local sel, sel_dir, sel_b = current_target()
  local facing = (b ~= nil) and ('%.1f deg (%s)'):format(b, compass.direction16(b)) or 'unknown'
  if not sel then
    say(('Facing %s. No crystal selected - /dac <crystal>, or synth once.'):format(facing))
    return
  end
  local t = compass.turn(sel_b, b or sel_b)
  local verdict
  if b == nil then
    verdict = 'heading unavailable'
  elseif state.on_target then
    verdict = ('on target, %.1f deg off'):format(math.abs(t))
  else
    verdict = ('turn %s %.1f deg'):format((t > 0) and 'right' or 'left', math.abs(t))
  end
  say(('%s crystal, %s: face %s (%d deg). Facing %s - %s.'):format(
    compass.INFO[sel].label, goal_label(), sel_dir, sel_b, facing, verdict))
end

local function on_off(v)
  v = string.lower(tostring(v or ''))
  return (v == 'on' or v == 'true' or v == '1')
end

ashita.events.register('command', 'dacompass_cmd', function(e)
  local args = e.command:args()
  if #args == 0 or not args[1]:any('/dacompass', '/dac') then return end
  e.blocked = true

  local sub = (#args >= 2) and string.lower(args[2]) or ''

  if sub == '' then
    cfg.visible[1] = not cfg.visible[1]
    say(cfg.visible[1] and 'Compass shown.' or 'Compass hidden.')
    settings.save()
    return
  end
  if sub == 'help' then print_help(); return end
  if sub == 'status' then show_status(); return end
  if sub == 'show' or sub == 'hide' then
    cfg.visible[1] = (sub == 'show')
    settings.save()
    return
  end
  if sub == 'config' then
    state.config_open[1] = not state.config_open[1]
    return
  end
  if sub == 'lock' or sub == 'unlock' then
    cfg.locked[1] = (sub == 'lock')
    say(cfg.locked[1] and 'Window locked.' or 'Window unlocked.')
    settings.save()
    return
  end
  if sub == 'none' or sub == 'clear' then set_crystal(''); return end
  if sub == 'safe' or sub == 'hq' then
    cfg.goal[1] = sub
    say('Goal: ' .. goal_label())
    settings.save()
    show_status()
    return
  end
  if sub == 'north' or sub == 'heading' then
    cfg.orient_mode[1] = sub
    say((sub == 'north') and 'North-up: the needle turns.' or 'Heading-up: the dial turns.')
    settings.save()
    return
  end
  if sub == 'size' and #args >= 3 then
    local v = tonumber(args[3])
    if not v or v < 80 or v > 800 then warn('Size must be 80-800 px.'); return end
    cfg.size[1] = math.floor(v)
    say(('Size: %d px'):format(cfg.size[1]))
    settings.save()
    return
  end
  if sub == 'tol' and #args >= 3 then
    local v = tonumber(args[3])
    if not v or v <= 0 or v > 45 then warn('Tolerance must be 0-45 degrees.'); return end
    cfg.tolerance_deg[1] = v
    say(('On-target band: +/- %.1f deg'):format(v))
    settings.save()
    return
  end
  if sub == 'chime' and #args >= 3 then
    cfg.chime[1] = on_off(args[3])
    say('Chime: ' .. tostring(cfg.chime[1]))
    settings.save()
    return
  end
  if sub == 'auto' and #args >= 3 then
    cfg.auto_crystal[1] = on_off(args[3])
    say('Auto-lock to the synth crystal: ' .. tostring(cfg.auto_crystal[1]))
    settings.save()
    return
  end
  if sub == 'ledger' and #args >= 3 then
    cfg.ledger[1] = on_off(args[3])
    say('Ledger: ' .. tostring(cfg.ledger[1]))
    settings.save()
    return
  end
  if sub == 'debug' and #args >= 3 then
    cfg.debug[1] = on_off(args[3])
    say('Debug: ' .. tostring(cfg.debug[1]))
    settings.save()
    return
  end
  if sub == 'reverse' and #args >= 3 then
    cfg.yaw_reverse[1] = on_off(args[3])
    say('Reverse bearings: ' .. tostring(cfg.yaw_reverse[1]))
    settings.save()
    return
  end
  if sub == 'test' then
    play(cfg.chime_sound[1])
    say('Played the chime.')
    return
  end
  if sub == 'stats' then
    local keys = compass.tally_keys(state.tally)
    table.insert(keys, 1, 'all')
    local lines = { ('Ledger: %d synths'):format(state.ledger_rows) }
    for _, k in ipairs(keys) do
      for _, l in ipairs(tally_lines(k)) do lines[#lines + 1] = l end
    end
    say(table.concat(lines, '\n'))
    return
  end
  if sub == 'cal' then
    local b, yaw = read_bearing()
    say(('cal: yaw=%s (%s deg)  bearing=%s  north_yaw=%s reverse=%s'):format(
      tostring(yaw), yaw and ('%.1f'):format(math.deg(yaw)) or '?',
      b and ('%.1f %s'):format(b, compass.direction16(b)) or '?',
      tostring(cfg.north_yaw_deg[1]), tostring(cfg.yaw_reverse[1])))
    return
  end
  if sub == 'setnorth' then
    local yaw = read_yaw()
    if yaw == nil then warn('Cannot read your heading.'); return end
    local d = math.deg(yaw)
    if cfg.yaw_reverse[1] then d = -d end
    cfg.north_yaw_deg[1] = compass.norm(d)
    say(('North set: yaw %.1f deg is now bearing 0.'):format(cfg.north_yaw_deg[1]))
    settings.save()
    return
  end

  local el = compass.parse_element(sub)
  if el then
    set_crystal(el)
    show_status()
    return
  end
  warn('Unknown command. Try /dac help')
end)

-- --------------------------------------------
-- Events
-- --------------------------------------------
settings.register('settings', 'dacompass_settings', function(s)
  if s ~= nil then cfg = s end
end)

ashita.events.register('load', 'dacompass_load', function()
  ledger_load()
  say(('v%s loaded - /dac help. Ledger: %d synths.'):format(addon.version, state.ledger_rows))
end)

ashita.events.register('unload', 'dacompass_unload', function()
  finish_pending('addon unloading')
  settings.save()
end)

ashita.events.register('packet_out', 'dacompass_packet_out', function(e)
  if e.id == 0x096 then on_synth_request(e.data_modified or e.data) end
end)

ashita.events.register('packet_in', 'dacompass_packet_in', function(e)
  if e.id == 0x030 then
    on_synth_animation(e.data_modified or e.data)
  elseif e.id == 0x06F then
    on_synth_result(e.data_modified or e.data)
  elseif e.id == 0x029 then
    on_message_basic(e.data_modified or e.data)
  end
end)

ashita.events.register('d3d_present', 'dacompass_present', function()
  update_heading()
  check_pending()
  if cfg.visible[1] then render_window() end
  render_config()
end)
