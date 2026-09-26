-- midarto
-- two-deck MIDI file DJ
-- v2.9
--
-- E1 crossfader
-- E2/E3 deck A/B volume
-- K2/K3 play/pause A/B
--
-- hold K1:
-- E1 tempo both decks
-- E2/E3 tempo A/B
-- K2/K3 load file to A/B
--
-- songs: dust/data/midarto/songs
-- grid: 16x8 controller
-- see README for the map

local Deck = include("lib/deck")
local DJ_ART = include("lib/splash_art")

local has_nb, nb = pcall(require, "nb/lib/nb")
if not has_nb then nb = nil end

local DATA_DIR = _path.data .. "midarto/"
local SONGS_DIR = DATA_DIR .. "songs/"          -- the browser opens here
local SETTINGS = DATA_DIR .. "settings.pset" -- remembered between sessions
local LOOPS = { 1, 2, 4, 8, 16 }

local mdev = {}
local decks = {}
local ids = { "a", "b" }
local xf = 0.5
local master = "a"
local k1 = false
local grid_shift = 0
local mode = "decks"
local browse = { dir = SONGS_DIR, list = {}, sel = 1, target = "a" }
local SPLASH_SECS = 5
local splash_start = 0
local splash_until = 0
local message = nil
local message_until = 0
local frame = 0
local flashes = {}
local mst_held = {}
local g = grid.connect()

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function other(id) return id == "a" and decks.b or decks.a end
local function shifted() return k1 or grid_shift > 0 end

local function notify(s)
  message = s
  message_until = util.time() + 2
end

local function flash(k) flashes[k] = util.time() + 0.18 end
local function flashing(k) return (flashes[k] or 0) > util.time() end

-- ---------- outputs ----------

-- MIDI setup: one GM device shared by both decks (default), or two
-- devices with one per deck. in one-device mode deck B plays to
-- deck A's device, and deck B's channel shift keeps them apart.
local one_device = true
local dev_a = 1

-- channel router. for every MIDI device and channel in use it picks
-- an owner deck: the louder of the playing decks (or of all decks
-- when neither plays). the owner's instrument, controllers and
-- all-notes-off go to that channel; the other deck stays out of it.
-- channel volume (CC7) is the owner's level, and the other deck's
-- notes on a shared channel are scaled to its own level instead.
local route = {}

local function devnum(id)
  local o = decks[id].out
  if o.voice then return nil end
  if id == "b" and one_device then return dev_a end
  return o.dev
end

local function route_key(id, oc)
  local dv = devnum(id)
  return dv and (dv * 16 + oc - 1) or nil
end

local function route_update(force)
  local cand = {}
  for _, id in ipairs({ "a", "b" }) do
    local d = decks[id]
    local dv = devnum(id)
    if d.song and dv then
      for ch in pairs(d.used) do
        local oc = d.out.map(ch)
        local k = dv * 16 + oc - 1
        cand[k] = cand[k] or { dv = dv, oc = oc, list = {} }
        table.insert(cand[k].list, { id = id, ch = ch, lvl = d:cc7_level(ch), playing = d.playing })
      end
    end
  end
  for k, c in pairs(cand) do
    local r = route[k] or {}
    route[k] = r
    local any_playing = false
    for _, e in ipairs(c.list) do if e.playing then any_playing = true end end
    local best
    for _, e in ipairs(c.list) do
      if e.playing or not any_playing then
        if not best or e.lvl > best.lvl + 0.5 or (math.abs(e.lvl - best.lvl) <= 0.5 and e.id == r.owner) then best = e end
      end
    end
    r.lv = {}
    for _, e in ipairs(c.list) do r.lv[e.id] = e.lvl end
    r.shared = #c.list > 1
    if r.owner ~= best.id then
      r.owner = best.id
      decks[best.id]:setup_channel(best.ch)
    end
    local v = math.floor(best.lvl + 0.5)
    if force or r.cc7 ~= v then
      mdev[c.dv]:cc(7, v, c.oc)
      r.cc7 = v
    end
  end
  for k in pairs(route) do if not cand[k] then route[k] = nil end end
end

-- forget all owners, so the next update sets every channel up again
local function route_reset()
  route = {}
  if decks.a and decks.b then route_update(true) end
end

local function make_out(id)
  local o = { voice = false, dev = 1, shift = 0, drums = true }
  local function dev()
    if id == "b" and one_device then return mdev[dev_a] end
    return mdev[o.dev]
  end
  local function player()
    local p = params:lookup_param("midarto_voice_" .. id)
    return p and p:get_player() or nil
  end
  -- channel shift. with "drums stay on 10", melodic channels
  -- rotate through the other 15 so they never land on 10.
  local MEL = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16 }
  local MEL_IDX = {}
  for i, c in ipairs(MEL) do MEL_IDX[c] = i end
  function o.map(ch)
    if o.shift == 0 then return ch end
    if o.drums then
      if ch == 10 then return 10 end
      return MEL[(MEL_IDX[ch] - 1 + o.shift) % 15 + 1]
    end
    return (ch - 1 + o.shift) % 16 + 1
  end
  function o.note_on(n, v, ch)
    if o.voice then
      local p = player(); if p then p:note_on(n, v) end
    else
      local m = dev(); if m then m:note_on(n, v, ch) end
    end
  end
  function o.note_off(n, ch)
    if o.voice then
      local p = player(); if p then p:note_off(n) end
    else
      local m = dev(); if m then m:note_off(n, 0, ch) end
    end
  end
  function o.cc(num, val, ch) local m = dev(); if m then m:cc(num, val, ch) end end
  function o.program(p, ch) local m = dev(); if m then m:program_change(p, ch) end end
  function o.send(bytes) local m = dev(); if m then m:send(bytes) end end
  -- does this deck own output channel oc (see the router)?
  function o.owns(oc)
    local k = route_key(id, oc)
    if not k then return true end
    local r = route[k]
    return (not r) or r.owner == nil or r.owner == id
  end
  -- velocity scale for this deck's notes on output channel oc
  function o.vel_scale(oc)
    local k = route_key(id, oc)
    local r = k and route[k]
    if not r or not r.shared or r.owner == id then return 1 end
    local own, mine = r.lv[r.owner] or 0, r.lv[id] or 0
    if own <= 0 then return mine > 0 and 1 or 0 end
    return math.min(1, mine / own)
  end
  function o.panic()
    local m = dev()
    if m and not o.voice then
      for ch = 1, 16 do
        m:cc(64, 0, ch); m:cc(123, 0, ch); m:cc(120, 0, ch)
      end
    end
  end
  return o
end

-- ---------- mixer ----------

local function xf_gains()
  if params:string("midarto_xfcurve") == "smooth" then
    return math.cos(xf * math.pi / 2), math.sin(xf * math.pi / 2)
  end
  return math.min(1, 2 * (1 - xf)), math.min(1, 2 * xf)
end

local function panic()
  for _, id in ipairs(ids) do
    local d = decks[id]
    d.playing = false
    d.pending = nil
    d:stop_notes()
    d.out.panic()
  end
  route_reset()
  notify("PANIC")
end

-- ---------- file browser ----------

local function scan(dir)
  local dirs, files = {}, {}
  for _, e in ipairs(util.scandir(dir) or {}) do
    if e:sub(-1) == "/" then dirs[#dirs + 1] = e
    elseif e:lower():match("%.midi?$") then files[#files + 1] = e end
  end
  table.sort(dirs)
  table.sort(files)
  local list = {}
  if dir ~= _path.dust then list[1] = "../" end
  for _, e in ipairs(dirs) do list[#list + 1] = e end
  for _, e in ipairs(files) do list[#list + 1] = e end
  browse.list = list
  browse.sel = clamp(browse.sel, 1, math.max(1, #list))
end

local function open_browser(id)
  browse.target = id
  if not util.file_exists(browse.dir) then browse.dir = SONGS_DIR end
  scan(browse.dir)
  mode = "browse"
end

local function load_into(id, path)
  local d = decks[id]
  d.playing = false
  d.pending = nil
  d:stop_notes()
  d.loading = true
  d.name = "LOADING"
  clock.run(function()
    local ok, err = d:load(path, function() clock.sleep(0.001) end)
    d.loading = false
    if ok then
      d.quantize = params:string("midarto_quantize") == "on"
      d:chase(true)   -- work out the song's starting setup
      route_update()  -- decide who owns each channel
      d:chase()       -- then set up the channels this deck owns
      notify(id:upper() .. " < " .. d.name)
    else
      d:clear()
      notify("load failed: " .. tostring(err))
      print("midarto: " .. path .. ": " .. tostring(err))
    end
  end)
end

local function browse_enter()
  local e = browse.list[browse.sel]
  if not e then return end
  if e == "../" then
    browse.dir = browse.dir:match("^(.*/)[^/]+/$") or _path.dust
    browse.sel = 1
    scan(browse.dir)
  elseif e:sub(-1) == "/" then
    browse.dir = browse.dir .. e
    browse.sel = 1
    scan(browse.dir)
  else
    load_into(browse.target, browse.dir .. e)
    mode = "decks"
  end
end

-- ---------- norns controls ----------

local function splash_on() return util.time() < splash_until end
local function skip_splash()
  if splash_on() then splash_until = 0; return true end
  return false
end

function key(n, z)
  if n == 1 then k1 = (z == 1); return end
  if z == 1 and skip_splash() then return end
  if z == 0 then return end
  if mode == "browse" then
    if n == 2 then mode = "decks" else browse_enter() end
    return
  end
  local id = (n == 2) and "a" or "b"
  if k1 then open_browser(id) else decks[id]:toggle_play() end
end

function enc(n, delta)
  if skip_splash() then return end
  local step = 0.005 * params:get("midarto_sens")
  if mode == "browse" then
    if n == 1 then browse.target = delta > 0 and "b" or "a"
    elseif n == 2 then browse.sel = clamp(browse.sel + delta, 1, math.max(1, #browse.list))
    else browse.sel = clamp(browse.sel + delta * 5, 1, math.max(1, #browse.list)) end
    return
  end
  if k1 then
    local targets = (n == 1) and { decks.a, decks.b } or { (n == 2) and decks.a or decks.b }
    for _, d in ipairs(targets) do
      d.tempo = clamp(d.tempo + delta * 0.1, -50, 50)
      d.sync = false
    end
  elseif n == 1 then
    xf = clamp(xf + delta * step, 0, 1)
  else
    local d = (n == 2) and decks.a or decks.b
    d.vol = clamp(d.vol + delta * step, 0, 1)
  end
end

-- ---------- grid ----------

-- v2.9 layout. rows 1-3 and 5-6 run in the same order on both decks.
-- row 4 (tempo) and rows 7-8 are mirrored, so NDG, CUE, PLAY and
-- SYNC sit on the outer edges; -/+ pairs still read left to right.
local ROWS = {
  { { "seek", 1 }, { "seek", 2 }, { "seek", 3 }, { "seek", 4 }, { "seek", 5 }, { "seek", 6 } },
  { { "hot", 1 }, { "hot", 2 }, { "hot", 3 }, { "hot", 4 }, { "bar", -1 }, { "bar", 1 } },
  { { "loop", 1 }, { "loop", 2 }, { "loop", 4 }, { "loop", 8 }, { "loop", 16 }, { "reloop" } },
  false, -- row 4 differs per deck, see ROW4
  { { "ch", 1 }, { "ch", 2 }, { "ch", 3 }, { "ch", 4 }, { "ch", 5 }, { "ch", 6 } },
  { { "ch", 7 }, { "ch", 8 }, { "ch", 9 }, { "ch", 10 }, { "ch", 11 }, { "ch", 12 } },
}
local ROW4 = {
  a = { { "nudge", -1 }, { "nudge", 1 }, { "tempo", -1 }, { "tempo", 1 }, { "free" }, { "tempo0" } },
  b = { { "tempo0" }, { "free" }, { "tempo", -1 }, { "tempo", 1 }, { "nudge", -1 }, { "nudge", 1 } },
}
local ROW7 = {
  a = { { "cue" }, { "free" }, { "ch", 13 }, { "ch", 14 }, { "ch", 15 }, { "ch", 16 } },
  b = { { "ch", 13 }, { "ch", 14 }, { "ch", 15 }, { "ch", 16 }, { "free" }, { "cue" } },
}
local ROW8 = {
  a = { { "play" }, { "sync" }, { "free" }, { "load" }, { "free" }, { "shift" } },
  b = { { "shift" }, { "free" }, { "load" }, { "free" }, { "sync" }, { "play" } },
}

-- what a deck key does: returns { kind, value } for deck id and local column 1-6
local function deck_fn(id, c, y)
  if y == 4 then return ROW4[id][c] end
  if y <= 6 then return ROWS[y][c] end
  if y == 7 then return ROW7[id][c] end
  return ROW8[id][c]
end

local function deck_key(d, id, c, y, z)
  local f = deck_fn(id, c, y)
  local kind, v = f[1], f[2]
  local fk = id .. y .. "-" .. c
  if kind == "shift" then
    grid_shift = math.max(0, grid_shift + (z == 1 and 1 or -1))
    return
  end
  if z == 0 then
    if kind == "nudge" then d.nudge = 0 end
    return
  end
  if kind == "load" then open_browser(id); return end
  if kind == "free" or not d.song then return end
  local bb = d:bar_beats()
  local shift = shifted()
  if kind == "seek" then
    local b = d:beat_at_sec(d.song.len * (v - 1) / 6)
    d:jump(d:sec_at_beat(math.floor(b / bb) * bb), fk)
  elseif kind == "hot" then
    if shift then d.cues[v] = nil
    elseif d.cues[v] then d:jump(d.cues[v], fk)
    else d.cues[v] = d:bar_start_sec(0) end
    flash(fk)
  elseif kind == "bar" then
    d:jump(d:bar_start_sec(v), fk)
  elseif kind == "loop" then
    d:toggle_loop(v)
  elseif kind == "reloop" then
    d:reloop()
  elseif kind == "nudge" then
    d.nudge = 4 * v
  elseif kind == "tempo" then
    if shift then d:set_trans(d.trans + v)
    else d.tempo = clamp(d.tempo + 0.5 * v, -50, 50); d.sync = false end
    flash(fk)
  elseif kind == "tempo0" then
    if shift then d:set_trans(0) else d.tempo = 0; d.sync = false end
    flash(fk)
  elseif kind == "sync" then
    if d.sync then d.sync = false else d:sync_to(other(id)) end
  elseif kind == "ch" then
    if shift then d:solo_chan(v) else d:toggle_chan(v) end
  elseif kind == "cue" then
    if shift then d:stop() else d:cue_return() end
    flash(fk)
  elseif kind == "play" then
    d:toggle_play()
  end
end

local function deck_led(d, id, c, y)
  local f = deck_fn(id, c, y)
  local kind, v = f[1], f[2]
  local fk = id .. y .. "-" .. c
  if kind == "free" then return 0 end
  if kind == "load" then return flashing(fk) and 15 or 3 end
  if kind == "shift" then return shifted() and 15 or 3 end
  local song = d.song
  if not song then return 0 end
  if d.pending and d.pending.key == fk then return (frame % 4 < 2) and 15 or 3 end
  if flashing(fk) then return 15 end
  if kind == "seek" then
    local seg = math.min(6, math.floor(d.pos / song.len * 6) + 1)
    return seg == v and 15 or 3
  elseif kind == "hot" then
    return d.cues[v] and 8 or 3
  elseif kind == "bar" then
    return 3
  elseif kind == "loop" then
    return (d.loop and d.loop.bars == v) and 15 or 3
  elseif kind == "reloop" then
    return d.loop and 15 or (d.last_loop > 0 and 8 or 3)
  elseif kind == "nudge" then
    return (d.nudge * v > 0) and 15 or 3
  elseif kind == "tempo" then
    return 3
  elseif kind == "tempo0" then
    local off = shifted() and d.trans ~= 0 or (not shifted() and math.abs(d.tempo) > 0.01)
    return off and 8 or 3
  elseif kind == "sync" then
    return d.sync and 15 or 3
  elseif kind == "ch" then
    if not d.used[v] then return 0 end
    if d:muted(v) then return 3 end
    local hit = d.act[v]
    if d.solo[v] then return hit and 15 or 12 end
    return hit and 13 or 8
  elseif kind == "cue" then
    return d.cues[1] and 8 or 3
  elseif kind == "play" then
    if d.playing then return ((d:beat() % 1) < 0.2) and 15 or 8 end
    return 3
  end
  return 0
end

local function mix_key(x, y, z)
  if y <= 6 then
    if x == 7 or x == 10 then
      if z == 1 then (x == 7 and decks.a or decks.b).vol = (7 - y) / 6 end
    else
      (x == 8 and decks.a or decks.b).cut = (z == 1)
    end
  elseif y == 7 then
    if z == 0 then return end
    local posn = (x - 7) / 3
    local centred = math.abs(xf - 0.5) < 0.03
    local here = math.abs(xf - posn) < 0.03
    if (x == 8 or x == 9) and here and not centred then xf = 0.5 else xf = posn end
  else
    if x == 8 or x == 9 then
      mst_held[x] = (z == 1)
      if mst_held[8] and mst_held[9] then panic(); return end
    end
    if z == 0 then return end
    if x == 7 then decks.a.kill = not decks.a.kill
    elseif x == 10 then decks.b.kill = not decks.b.kill
    elseif x == 8 then master = "a"
    else master = "b" end
  end
end

local function grid_key(x, y, z)
  if z == 1 and skip_splash() then return end
  if x <= 6 then deck_key(decks.a, "a", x, y, z)
  elseif x >= 11 and x <= 16 then deck_key(decks.b, "b", x - 10, y, z)
  elseif x >= 7 and x <= 10 then mix_key(x, y, z) end
end

local function mix_led(x, y)
  if y <= 6 then
    local h = 7 - y
    if x == 7 or x == 10 then
      local k = math.floor((x == 7 and decks.a or decks.b).vol * 6 + 0.5)
      if h == k then return 15 end
      return h < k and 8 or 3
    end
    local m = math.floor((x == 8 and decks.a or decks.b).meter * 6 + 0.5)
    if h > m then return 0 end
    return h == m and 15 or 8
  elseif y == 7 then
    local centred = math.abs(xf - 0.5) < 0.03
    local near = math.floor(xf * 3 + 0.5)
    local on = (centred and (x == 8 or x == 9)) or (not centred and x - 7 == near)
    return on and 15 or 3
  else
    if x == 7 then return decks.a.kill and 15 or 3 end
    if x == 10 then return decks.b.kill and 15 or 3 end
    if x == 8 then return master == "a" and 15 or 3 end
    return master == "b" and 15 or 3
  end
end

local function grid_redraw()
  if not g.device then return end
  g:all(0)
  for y = 1, 8 do
    for x = 1, 16 do
      local l
      if x <= 6 then l = deck_led(decks.a, "a", x, y)
      elseif x >= 11 then l = deck_led(decks.b, "b", x - 10, y)
      else l = mix_led(x, y) end
      if l > 0 then g:led(x, y, l) end
    end
  end
  g:refresh()
end

-- ---------- screen ----------

local function trim(s, w)
  while #s > 1 and screen.text_extents(s) > w do s = s:sub(1, -2) end
  return s
end

-- long file names scroll: hold at the start, step one character
-- at a time until the end shows, hold, then jump back.
local SCROLL_HOLD, SCROLL_STEP = 24, 4 -- frames (15 fps)
local function scroll_name(d, w)
  local name = d.name
  local sc = d.scroll
  if not sc or sc.name ~= name then
    local last = 1
    while last < #name and screen.text_extents(name:sub(last)) > w do last = last + 1 end
    sc = { name = name, last = last, start = frame }
    d.scroll = sc
  end
  if sc.last == 1 then return name end
  local steps = sc.last - 1
  local t = (frame - sc.start) % (SCROLL_HOLD * 2 + steps * SCROLL_STEP)
  local o
  if t < SCROLL_HOLD then o = 1
  elseif t < SCROLL_HOLD + steps * SCROLL_STEP then o = 1 + (t - SCROLL_HOLD) // SCROLL_STEP
  else o = sc.last end
  return trim(name:sub(o), w)
end

local function fmt_time(sec)
  sec = math.max(0, sec)
  return string.format("-%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

local function fmt_tempo(t)
  local r = math.floor(t + 0.5)
  if r == 0 then return "0%" end
  return string.format("%+d%%", r)
end

local function circle(x, y, r, lvl, fill)
  screen.level(lvl)
  screen.move(x + r, y)
  screen.circle(x, y, r)
  if fill then screen.fill() else screen.stroke() end
end

local function seg(x1, y1, x2, y2, lvl)
  screen.level(lvl)
  screen.move(x1, y1)
  screen.line(x2, y2)
  screen.stroke()
end

-- true while the platter outline should be lit for the end warning.
-- blinks about once a second, twice as fast in the last 10 seconds.
local WARN_SECS = { 0, 10, 20, 30, 60 }
local function end_flash(d)
  if not (d.song and d.playing) or d.loop then return false end
  local warn = WARN_SECS[params:get("midarto_warn")] or 0
  if warn == 0 then return false end
  local rem = (d.song.len - d.pos) / d:rate()
  if rem > warn then return false end
  local period = rem <= 10 and 4 or 8
  return frame % period < period / 2
end

local function draw_platter(d, cx, label_lvl, side)
  local loaded = d.song ~= nil
  local th = (d:beat() / d:bar_beats()) * 2 * math.pi - math.pi / 2
  local c, s = math.cos(th), math.sin(th)
  screen.aa(1)
  screen.line_width(1)
  if end_flash(d) then
    circle(cx, 30, 17, 15)
    circle(cx, 30, 18.5, 15)
  else
    circle(cx, 30, 17, loaded and 4 or 1)
  end
  circle(cx, 30, 14, 1)
  circle(cx, 30, 11, 1)
  if loaded then
    seg(cx - 7 * c, 30 - 7 * s, cx - 16 * c, 30 - 16 * s, 2)
    seg(cx + 7 * c, 30 + 7 * s, cx + 16 * c, 30 + 16 * s, d.playing and 15 or 6)
  end
  circle(cx, 30, 6, loaded and label_lvl or 2, true)
  if loaded then circle(cx + 3.2 * c, 30 + 3.2 * s, 1, 1, true) end
  circle(cx, 30, 1, 0, true)
  local px = side == "a" and 41 or 86
  local nx, ny
  if d.playing then nx, ny = (side == "a" and 32 or 95), 24 else nx, ny = (side == "a" and 42 or 85), 27 end
  seg(px, 13, nx, ny, d.playing and 6 or 2)
  circle(px, 13, 1.5, 5, true)
  screen.aa(0)
end

local function draw_deck_text(d, side)
  local loaded = d.song ~= nil
  -- name
  screen.level(loaded and 15 or 4)
  local name = scroll_name(d, 42)
  if side == "a" then screen.move(0, 6); screen.text(name)
  else screen.move(127, 6); screen.text_right(name) end
  if not loaded then return end
  -- progress
  local bx = side == "a" and 4 or 89
  screen.level(2); screen.rect(bx, 49, 35, 2); screen.fill()
  screen.level(12); screen.rect(bx, 49, math.floor(35 * d.pos / d.song.len + 0.5), 2); screen.fill()
  if d.loop then
    local lx = bx + math.floor(35 * d.loop.start / d.song.len)
    local lw = math.max(1, math.floor(35 * (d.loop.stop - d.loop.start) / d.song.len))
    screen.level(6); screen.rect(lx, 47, lw, 1); screen.fill()
  end
  if d.cues[1] then
    screen.level(15); screen.rect(bx + math.floor(35 * d.cues[1] / d.song.len), 48, 1, 4); screen.fill()
  end
  -- readouts
  local bpm = string.format("%.1f", d:bpm())
  local tp = fmt_tempo(d.tempo + d.nudge)
  local rem = fmt_time((d.song.len - d.pos) / d:rate())
  local tl = (math.abs(d.tempo + d.nudge) < 0.5) and 4 or 15
  if d.sync and frame % 16 < 8 then tl = 8 end
  if side == "a" then
    screen.level(15); screen.move(0, 57); screen.text(bpm)
    screen.level(tl); screen.move(42, 57); screen.text_right(tp)
    screen.level(6); screen.move(0, 63); screen.text(rem)
  else
    screen.level(tl); screen.move(86, 57); screen.text(tp)
    screen.level(15); screen.move(127, 57); screen.text_right(bpm)
    screen.level(6); screen.move(127, 63); screen.text_right(rem)
  end
  -- play state
  local gx = side == "a" and 35 or 89
  screen.level(15)
  if d.playing then
    screen.move(gx, 58); screen.line(gx, 63); screen.line(gx + 4, 60.5); screen.close(); screen.fill()
  else
    screen.rect(gx, 59, 1, 4); screen.fill()
    screen.rect(gx + 3, 59, 1, 4); screen.fill()
  end
end

local function draw_mixer()
  -- header
  screen.level(4)
  screen.move(64, 6)
  screen.text_center("MASTER " .. master:upper())
  -- meters
  for _, m in ipairs({ { decks.a, 58 }, { decks.b, 68 } }) do
    local h = math.floor(m[1].meter * 32 + 0.5)
    screen.level(1); screen.rect(m[2], 12, 2, 32); screen.fill()
    if h > 0 then
      screen.level(8); screen.rect(m[2], 44 - h, 2, h); screen.fill()
      screen.level(15); screen.rect(m[2], 44 - h, 2, 1); screen.fill()
    end
  end
  -- faders
  for _, f in ipairs({ { decks.a, 51, 48, "A" }, { decks.b, 76, 73, "B" } }) do
    seg(f[2] + 0.5, 12, f[2] + 0.5, 44, 2)
    local fy = math.floor(44 - f[1].vol * 32 - 1 + 0.5)
    screen.level(f[1].kill and 4 or 15); screen.rect(f[3], fy, 7, 3); screen.fill()
    screen.level(8); screen.rect(f[3], fy + 1, 7, 1); screen.fill()
    screen.level(f[1].kill and 15 or 4)
    screen.move(f[2] + 1, 51)
    screen.text_center(f[1].kill and "X" or f[4])
  end
  for _, ty in ipairs({ 12, 28, 43 }) do
    seg(46, ty + 0.5, 47, ty + 0.5, 4)
    seg(81, ty + 0.5, 82, ty + 0.5, 4)
  end
  -- crossfader
  seg(46, 55.5, 81, 55.5, 2)
  for _, tx in ipairs({ 46.5, 63.5, 80.5 }) do seg(tx, 53, tx, 58, 4) end
  screen.level(15)
  screen.rect(math.floor(46 + xf * 35 - 1 + 0.5), 52, 3, 7)
  screen.fill()
  -- status
  local status, lvl = "MIDARTO", 4
  if message and util.time() < message_until then status, lvl = message, 15
  elseif k1 then status, lvl = "SHIFT", 15
  elseif decks.a.sync or decks.b.sync then status = "SYNC" end
  screen.level(lvl)
  screen.move(64, 63)
  screen.text_center(trim(status, 40))
end

local function draw_browser()
  screen.level(3); screen.rect(0, 0, 128, 9); screen.fill()
  screen.level(15); screen.move(2, 7); screen.text("LOAD > " .. browse.target:upper())
  local dir = browse.dir:gsub("^" .. _path.dust:gsub("%p", "%%%0"), "/")
  screen.level(8); screen.move(126, 7); screen.text_right(trim(dir, 70))
  local n = #browse.list
  local only_up = (n == 0) or (n == 1 and browse.list[1] == "../")
  if only_up then
    screen.level(4); screen.move(6, 29); screen.text("no .mid files here")
    screen.move(6, 39); screen.text("add songs to")
    screen.move(6, 49); screen.text("data/midarto/songs")
  end
  local first = clamp(browse.sel - 2, 1, math.max(1, n - 4))
  for row = 0, 4 do
    local i = first + row
    local e = browse.list[i]
    if e then
      local y = 19 + row * 10
      if i == browse.sel then
        screen.level(15); screen.move(0, y); screen.text(">")
      else
        screen.level(4)
      end
      screen.move(6, y)
      screen.text(trim(e, 78))
    end
  end
  if n > 5 then
    screen.level(2); screen.rect(87, 11, 1, 50); screen.fill()
    local th = math.max(4, math.floor(50 * 5 / n))
    local ty = 11 + math.floor((50 - th) * (browse.sel - 1) / math.max(1, n - 1))
    screen.level(8); screen.rect(87, ty, 1, th); screen.fill()
  end
  -- target deck
  screen.aa(1)
  circle(108, 26, 9, 4)
  circle(108, 26, 4, browse.target == "a" and 6 or 9, true)
  screen.aa(0)
  screen.level(8)
  screen.move(108, 44)
  screen.text_center("DECK " .. browse.target:upper())
  local function st(d) return d.song and (d.playing and ">" or "||") or "-" end
  screen.level(4)
  screen.move(108, 58)
  screen.text_center("A" .. st(decks.a) .. " B" .. st(decks.b))
end

-- pre-split each art row into runs of one grey level, so drawing is cheap
local DJ_RUNS = {}
for f, rows in ipairs(DJ_ART) do
  DJ_RUNS[f] = {}
  for y, row in ipairs(rows) do
    local x = 1
    while x <= #row do
      local ch = row:sub(x, x)
      local len = 1
      while row:sub(x + len, x + len) == ch do len = len + 1 end
      if ch ~= "." then
        table.insert(DJ_RUNS[f], { x - 1, y - 1, len, tonumber(ch, 16) })
      end
      x = x + len
    end
  end
end

local function fade(t, t0, t1) return math.max(0, math.min(1, (t - t0) / (t1 - t0))) end

-- the DJ on the left, bobbing between two frames; the title on the right,
-- with the tagline first and then the credits underneath it
local function draw_splash()
  local t = util.time() - splash_start
  local f_in = fade(t, 0, 0.5)
  local frame_n = (math.floor(t / 0.28) % 2) + 1
  for _, r in ipairs(DJ_RUNS[frame_n]) do
    local lvl = math.floor(r[4] * f_in + 0.5)
    if lvl > 0 then
      screen.level(lvl)
      screen.rect(r[1], r[2], r[3], 1)
      screen.fill()
    end
  end
  local cx = 88
  screen.font_face(1)
  screen.font_size(16)
  screen.level(math.floor(15 * f_in + 0.5))
  screen.move(cx, 17)
  screen.text_center("MIDARTO")
  screen.font_size(8)
  local tag = f_in * (1 - fade(t, 2.3, 2.5))
  local cred = fade(t, 2.5, 2.8)
  if tag > 0 then
    screen.level(math.floor(11 * tag + 0.5))
    screen.move(cx, 32); screen.text_center("Midi file DJ")
    screen.move(cx, 41); screen.text_center("Mixing for")
    screen.move(cx, 50); screen.text_center("Monome Norns.")
  end
  if cred > 0 then
    screen.level(math.floor(6 * cred + 0.5))
    screen.move(cx, 29); screen.text_center("Created by")
    screen.level(math.floor(11 * cred + 0.5))
    screen.move(cx, 38); screen.text_center("Glenn Jones,")
    screen.move(cx, 47); screen.text_center("Cutie Suzuki &")
    screen.move(cx, 56); screen.text_center("DJ FingaBlasta")
  end
end

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if splash_on() then
    draw_splash()
  elseif mode == "browse" then
    draw_browser()
  else
    draw_platter(decks.a, 21, 6, "a")
    draw_platter(decks.b, 106, 9, "b")
    draw_mixer()
    draw_deck_text(decks.a, "a")
    draw_deck_text(decks.b, "b")
  end
  screen.update()
end

-- ---------- engine ----------

local function engine()
  local last = util.time()
  local vol_t, clock_t = 0, 0
  while true do
    clock.sleep(0.002)
    local now = util.time()
    local dt = math.min(0.1, now - last)
    last = now
    local ga, gb = xf_gains()
    decks.a.xg, decks.b.xg = ga, gb
    for _, id in ipairs(ids) do
      local d = decks[id]
      if d.sync and id ~= master then d:match_tempo(other(id)) end
      d:update(dt)
    end
    vol_t = vol_t + dt
    if vol_t >= 0.03 then
      vol_t = 0
      route_update()
    end
    clock_t = clock_t + dt
    if clock_t >= 0.5 then
      clock_t = 0
      local m = decks[master]
      if params:string("midarto_clock") == "on" and m.song then
        local bpm = math.floor(m:set_bpm() * 10 + 0.5) / 10
        if math.abs(params:get("clock_tempo") - bpm) > 0.05 then params:set("clock_tempo", bpm) end
      end
    end
  end
end

local function ui_loop()
  while true do
    clock.sleep(1 / 15)
    frame = frame + 1
    for _, id in ipairs(ids) do decks[id].meter = decks[id].meter * 0.82 end
    redraw()
    grid_redraw()
    decks.a.act, decks.b.act = {}, {}
  end
end

-- ---------- params ----------

local function add_params()
  params:add_separator("midarto", "MIDARTO")
  params:add_option("midarto_outputs", "midi outputs", { "one device", "two devices" }, 1)
  params:set_action("midarto_outputs", function(v)
    decks.a:stop_notes(); decks.b:stop_notes()
    one_device = (v == 1)
    route_reset()
    pcall(function()
      if one_device then params:hide("midarto_dev_b") else params:show("midarto_dev_b") end
      _menu.rebuild_params()
    end)
  end)
  for _, id in ipairs(ids) do
    local out = decks[id].out
    params:add_separator("midarto_deck_" .. id, "deck " .. id:upper())
    local outs = has_nb and { "midi", "nb voice" } or { "midi" }
    params:add_option("midarto_out_" .. id, "output", outs, 1)
    params:set_action("midarto_out_" .. id, function(v)
      decks[id]:stop_notes()
      out.voice = (outs[v] == "nb voice")
      route_reset()
    end)
    params:add {
      type = "number", id = "midarto_dev_" .. id, name = "midi device",
      min = 1, max = 16, default = (id == "a") and 1 or 2,
      formatter = function(p)
        local vp = midi.vports[p:get()]
        return p:get() .. ": " .. ((vp and vp.name) or "none")
      end,
      action = function(v)
        decks.a:stop_notes(); decks.b:stop_notes()
        out.dev = v
        if id == "a" then dev_a = v end
        route_reset()
      end,
    }
    -- deck B defaults to a shift of 8 so both decks can share one GM device
    params:add_number("midarto_shift_" .. id, "channel shift", 0, 15, id == "b" and 8 or 0)
    params:set_action("midarto_shift_" .. id, function(v) decks[id]:stop_notes(); out.shift = v; route_reset() end)
    params:add_option("midarto_drums_" .. id, "drums stay on 10", { "yes", "no" }, 1)
    params:set_action("midarto_drums_" .. id, function(v) decks[id]:stop_notes(); out.drums = (v == 1); route_reset() end)
    if has_nb then nb:add_param("midarto_voice_" .. id, "nb voice") end
  end
  params:add_separator("midarto_mix", "mix")
  params:add_option("midarto_xfcurve", "crossfader curve", { "dj", "smooth" }, 1)
  params:add_option("midarto_quantize", "quantize jumps", { "on", "off" }, 1)
  params:set_action("midarto_quantize", function(v)
    for _, id in ipairs(ids) do decks[id].quantize = (v == 1) end
  end)
  params:add_number("midarto_sens", "knob sensitivity", 1, 8, 2)
  params:add_option("midarto_warn", "end warning", { "off", "10s", "20s", "30s", "60s" }, 4)
  params:add_option("midarto_clock", "clock follows master", { "off", "on" }, 1)
  params:add_trigger("midarto_panic", "panic: all notes off")
  params:set_action("midarto_panic", panic)
  if has_nb then nb:add_player_params() end
end

local function is_song(e) return e:lower():match("%.midi?$") ~= nil end

-- set up the songs folder. the first time it's created, move any
-- songs left in dust/data/midarto/ by older versions into it, and
-- put the demo songs in whenever the folder is empty.
local function seed_data()
  util.make_dir(DATA_DIR)
  local fresh = not util.file_exists(SONGS_DIR)
  util.make_dir(SONGS_DIR)
  if fresh then
    for _, e in ipairs(util.scandir(DATA_DIR) or {}) do
      if is_song(e) then os.rename(DATA_DIR .. e, SONGS_DIR .. e) end
    end
  end
  if #(util.scandir(SONGS_DIR) or {}) == 0 then
    local demo = norns.state.path .. "demo/"
    if util.file_exists(demo) then os.execute("cp " .. demo .. "*.mid " .. SONGS_DIR) end
  end
end

function init()
  for i = 1, 16 do mdev[i] = midi.connect(i) end
  if has_nb then nb:init() end
  decks.a = Deck.new("a", make_out("a"))
  decks.b = Deck.new("b", make_out("b"))
  add_params()
  seed_data()
  if util.file_exists(SETTINGS) then params:read(SETTINGS, true) end
  params:bang()
  g.key = grid_key
  splash_start = util.time()
  splash_until = splash_start + SPLASH_SECS
  clock.run(engine)
  clock.run(ui_loop)
end

function cleanup()
  params:write(SETTINGS, "midarto")
  for _, id in ipairs(ids) do
    if decks[id] then
      decks[id].playing = false
      decks[id]:stop_notes()
    end
  end
end
