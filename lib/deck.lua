-- deck.lua
-- one midarto deck: plays a parsed MIDI file to an output,
-- with tempo, nudge, cues, loops, sync, channel mute/solo and volume.

local smf = include("lib/smf")

local Deck = {}
Deck.__index = Deck

local CHASE_CC = { 0, 32, 1, 10, 11, 91, 93 }

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function Deck.new(id, out)
  local d = setmetatable({}, Deck)
  d.id = id
  d.out = out
  d.vol = 0.8
  d.xg = 1          -- crossfader gain, set by the mixer
  d.quantize = true
  d:clear()
  return d
end

function Deck:clear()
  self.song = nil
  self.name = "EMPTY"
  self.path = nil
  self.pos = 0
  self.idx = 1
  self.playing = false
  self.tempo = 0     -- percent
  self.nudge = 0     -- percent, while held
  self.kill = false
  self.cut = false
  self.chmute = {}   -- channel -> true when muted
  self.solo = {}     -- channel -> true when soloed
  self.act = {}      -- channel -> true when a note played since the last frame
  self.cues = {}
  self.loop = nil
  self.last_loop = 0
  self.trans = 0
  self.sync = false
  self.pending = nil
  self.armed = nil   -- waiting to start on the other deck's next bar
  self.wave = nil    -- waveform data (see lib/wave), set by the script
  self.wmix = nil    -- the waveform mixed for the channels you can hear
  self.mute_version = (self.mute_version or 0) + 1
  self.lib_dirty = false
  self.held = {}
  self.prog = {}
  self.init_prog = {}
  self.file_cc7 = {}   -- the file's own channel volume, per channel
  self.ccs = {}        -- latest controller values the file set, per channel
  self.bend = {}       -- latest pitch bend, per channel
  self.used = {}
  self.meter = 0
  self.loading = false
end

-- ---------- loading ----------

local function basename(path)
  local name = path:match("([^/]+)$") or path
  name = name:gsub("%.[Mm][Ii][Dd][Ii]?$", "")
  return name:upper()
end

function Deck:load(path, yield_fn)
  local f = io.open(path, "rb")
  if not f then return false, "can't open file" end
  local data = f:read("*a")
  f:close()
  local song, err = smf.parse(data, yield_fn)
  if not song then return false, err end
  return self:set_song(song, path, yield_fn)
end

-- take a prepared song (parsed now, or read from the song library)
function Deck:set_song(song, path, yield_fn)
  self:stop_notes()
  local vol, quantize = self.vol, self.quantize
  self:clear()
  self.vol, self.quantize = vol, quantize
  self.song = song
  self.path = path
  self.name = basename(path)

  -- which channels play notes, and their first program
  for k = 1, song.n do
    local e = song.events[k]
    local hi = e.st - e.st % 16
    local ch = e.st % 16 + 1
    if hi == 0xC0 and self.init_prog[ch] == nil then self.init_prog[ch] = e.a end
    if hi == 0x90 then self.used[ch] = true end
    if yield_fn and k % 4096 == 0 then yield_fn() end
  end
  self:seek(0, false)
  return true
end

-- where the music starts: the start of the bar holding the first note
-- (mode "note") or the first drum hit on channel 10 (mode "drum",
-- falling back to the first note if there are no drums)
function Deck:first_bar_sec(mode)
  local song = self.song
  if not song then return 0 end
  local first, first_drum
  for k = 1, song.n do
    local e = song.events[k]
    if e.st - e.st % 16 == 0x90 and e.b > 0 then
      first = first or e
      if e.st % 16 == 9 then first_drum = e; break end
      if mode ~= "drum" then break end
    end
  end
  local e = (mode == "drum" and first_drum) or first
  if not e then return 0 end
  local bb = song.bar_beats
  local bar_beat = math.floor(e.t / song.div / bb + 1e-6) * bb
  return smf.sec_at_tick(song, bar_beat * song.div)
end

-- ---------- timing helpers ----------

function Deck:beat()
  if not self.song then return 0 end
  return smf.tick_at_sec(self.song, self.pos) / self.song.div
end

function Deck:beat_at_sec(sec)
  return smf.tick_at_sec(self.song, sec) / self.song.div
end

function Deck:sec_at_beat(b)
  if b < 0 then b = 0 end
  return smf.sec_at_tick(self.song, b * self.song.div)
end

function Deck:bar_beats()
  return self.song and self.song.bar_beats or 4
end

function Deck:rate()
  return math.max(0.05, 1 + (self.tempo + self.nudge) / 100)
end

function Deck:native_bpm()
  if not self.song then return 120 end
  return 60e6 / smf.uspq_at_sec(self.song, self.pos)
end

-- bpm without momentary nudge (used for sync)
function Deck:set_bpm()
  return self:native_bpm() * (1 + self.tempo / 100)
end

function Deck:bpm()
  return self:native_bpm() * self:rate()
end

function Deck:bar_start_sec(offset_bars)
  local bb = self:bar_beats()
  return self:sec_at_beat((math.floor(self:beat() / bb + 1e-6) + (offset_bars or 0)) * bb)
end

-- ---------- output ----------

function Deck:gain()
  if self.kill or self.cut then return 0 end
  return self.vol * self.xg
end

function Deck:any_solo()
  return next(self.solo) ~= nil
end

-- silent because muted, or because other channels are soloed
function Deck:muted(ch)
  if self:any_solo() then return not self.solo[ch] end
  return self.chmute[ch] == true
end

-- channel volume this deck wants on file channel ch (0-127, unrounded).
-- the mixer's router turns these into CC7 messages, and on a channel
-- both decks share it sends the louder deck's level.
function Deck:cc7_level(ch)
  return (self.file_cc7[ch] or 100) * self:gain()
end

function Deck:note_on(ch, note, vel)
  if self:muted(ch) then return end
  local out = self.out
  local g = self:gain()
  if out.voice and g <= 0 then return end
  local oc = out.map(ch)
  local v = vel
  if not out.voice then
    -- on a shared channel the other deck owns the volume, so scale
    -- this deck's notes to its own level instead
    local scale = out.vel_scale(oc)
    if scale <= 0 then return end
    v = clamp(math.floor(vel * scale + 0.5), 1, 127)
  end
  local key = ch * 128 + note
  if self.held[key] then self:note_off(ch, note) end
  local on = note
  if ch ~= 10 then on = clamp(note + self.trans, 0, 127) end
  if out.voice then
    out.note_on(on, clamp(vel / 127 * g, 0, 1), oc)
  else
    out.note_on(on, v, oc)
  end
  self.held[key] = { oc, on }
  self.act[ch] = true
  local m = vel / 127 * g
  if m > self.meter then self.meter = m end
end

function Deck:note_off(ch, note)
  local key = ch * 128 + note
  local h = self.held[key]
  if h then
    self.out.note_off(h[2], h[1])
    self.held[key] = nil
  end
end

function Deck:dispatch(e)
  local st = e.st
  local hi = st - st % 16
  local ch = st % 16 + 1
  local out = self.out
  if hi == 0x90 and e.b > 0 then
    self:note_on(ch, e.a, e.b)
  elseif hi == 0x80 or hi == 0x90 then
    self:note_off(ch, e.a)
  elseif out.voice then
    if hi == 0xC0 then self.prog[ch] = e.a end
  elseif hi == 0xB0 then
    if e.a == 7 then
      self.file_cc7[ch] = e.b          -- sent by the router
    else
      self.ccs[ch] = self.ccs[ch] or {}
      self.ccs[ch][e.a] = e.b
      local oc = out.map(ch)
      if out.owns(oc) then out.cc(e.a, e.b, oc) end
    end
  elseif hi == 0xC0 then
    self.prog[ch] = e.a
    local oc = out.map(ch)
    if out.owns(oc) then out.program(e.a, oc) end
  elseif hi == 0xE0 then
    self.bend[ch] = { e.a, e.b }
    local oc = out.map(ch)
    if out.owns(oc) then out.send({ hi + oc - 1, e.a, e.b }) end
  else
    local oc = out.map(ch)
    if out.owns(oc) then
      if hi == 0xD0 then out.send({ hi + oc - 1, e.a }) else out.send({ hi + oc - 1, e.a, e.b }) end
    end
  end
end

-- note-offs for everything this deck is holding. sustain-off and
-- all-notes-off only go to channels this deck owns, so the other
-- deck's notes on a shared channel are left alone.
function Deck:stop_notes()
  local out = self.out
  local chans = {}
  for _, h in pairs(self.held) do
    out.note_off(h[2], h[1])
    chans[h[1]] = true
  end
  self.held = {}
  if not out.voice then
    for ch in pairs(self.used) do chans[out.map(ch)] = true end
    for oc in pairs(chans) do
      if out.owns(oc) then
        out.cc(64, 0, oc)
        out.cc(123, 0, oc)
      end
    end
  end
end

function Deck:release_where(fn)
  for key, h in pairs(self.held) do
    local ch = key // 128
    if fn(ch) then
      self.out.note_off(h[2], h[1])
      self.held[key] = nil
    end
  end
end

-- send one channel's instrument and controller setup (not volume,
-- which the router handles). a channel the file never gives an
-- instrument gets piano, the General MIDI default, so it doesn't
-- keep whatever was left on that channel before.
function Deck:setup_channel(ch)
  local out = self.out
  if out.voice or not self.used[ch] then return end
  local oc = out.map(ch)
  local c = self.ccs[ch] or {}
  if c[0] then out.cc(0, c[0], oc) end
  if c[32] then out.cc(32, c[32], oc) end
  out.program(self.prog[ch] or 0, oc)
  for _, n in ipairs(CHASE_CC) do
    if n ~= 0 and n ~= 32 and c[n] then out.cc(n, c[n], oc) end
  end
  local b = self.bend[ch] or { 0, 64 }
  out.send({ 0xE0 + oc - 1, b[1], b[2] })
end

-- after a jump, work out the programs and controllers the file set
-- before this point, and send them on the channels this deck owns
function Deck:chase(record_only)
  if not self.song then return end
  local ev = self.song.events
  local prog, cc, cc7, bend = {}, {}, {}, {}
  for k = 1, self.idx - 1 do
    local e = ev[k]
    local hi = e.st - e.st % 16
    local ch = e.st % 16 + 1
    if hi == 0xC0 then prog[ch] = e.a
    elseif hi == 0xB0 then
      if e.a == 7 then cc7[ch] = e.b
      else cc[ch] = cc[ch] or {}; cc[ch][e.a] = e.b end
    elseif hi == 0xE0 then bend[ch] = { e.a, e.b } end
  end
  for ch in pairs(self.used) do
    self.prog[ch] = prog[ch] or self.init_prog[ch] or 0
    self.ccs[ch] = cc[ch] or {}
    self.file_cc7[ch] = cc7[ch] or 100
    self.bend[ch] = bend[ch]
    if not record_only and not self.out.voice and self.out.owns(self.out.map(ch)) then self:setup_channel(ch) end
  end
end

-- ---------- transport ----------

function Deck:seek(sec, chase)
  if not self.song then return end
  self:stop_notes()
  self.pos = clamp(sec, 0, self.song.len)
  self.idx = smf.index_at(self.song, self.pos)
  if chase then self:chase() end
end

-- jump, waiting for the next bar line when quantize is on
function Deck:jump(sec, key)
  if not self.song then return end
  if self.playing and self.quantize then
    local bb = self:bar_beats()
    self.pending = { target = sec, at = (math.floor(self:beat() / bb + 1e-6) + 1) * bb, key = key }
  else
    self.pending = nil
    self:seek(sec, true)
  end
end

function Deck:toggle_play()
  if not self.song then return end
  self.armed = nil
  if self.playing then
    self.playing = false
    self.pending = nil
    self:stop_notes()
  else
    if self.pos >= self.song.len then self:seek(0, true) end
    self.playing = true
  end
end

function Deck:stop()
  if not self.song then return end
  self.armed = nil
  self.playing = false
  self.pending = nil
  self.loop = nil
  self:seek(0, true)
end

function Deck:restart()
  if not self.song then return end
  self.pending = nil
  self:seek(0, true)
  self.playing = true
end

-- CUE: go to the main cue (hot cue 1, else the start). while playing
-- it jumps there and keeps playing (on the next bar when quantize is
-- on); while paused it moves there and stays paused.
function Deck:cue_return(key)
  if not self.song then return end
  local target = self.cues[1] or 0
  self.armed = nil
  if self.playing then
    self:jump(target, key)
  else
    self.pending = nil
    self:seek(target, true)
  end
end

function Deck:set_loop(bars)
  if not self.song then return end
  local bb = self:bar_beats()
  local start_beat = math.floor(self:beat() / bb + 1e-6) * bb
  local start = self:sec_at_beat(start_beat)
  local stop = math.min(self.song.len, self:sec_at_beat(start_beat + bars * bb))
  if stop - start < 0.05 then return end
  self.loop = { bars = bars, start = start, stop = stop }
  if self.last_loop ~= bars then self.lib_dirty = true end
  self.last_loop = bars
end

function Deck:toggle_loop(bars)
  if self.loop and self.loop.bars == bars then self.loop = nil else self:set_loop(bars) end
end

function Deck:reloop()
  if self.loop then self.loop = nil else self:set_loop(self.last_loop > 0 and self.last_loop or 4) end
end

function Deck:set_trans(n)
  self:release_where(function(ch) return ch ~= 10 end)
  self.trans = clamp(n, -24, 24)
end

-- press: mute or unmute one channel
function Deck:toggle_chan(ch)
  if not self.used[ch] then return end
  self.chmute[ch] = not self.chmute[ch]
  self.mute_version = self.mute_version + 1
  self:release_where(function(c) return self:muted(c) end)
end

-- shift + press: solo a channel (adds to the solo set).
-- shift + a soloed channel restores all channels.
function Deck:solo_chan(ch)
  if not self.used[ch] then return end
  if self.solo[ch] then
    self.solo = {}
    self.chmute = {}
  else
    self.solo[ch] = true
  end
  self.mute_version = self.mute_version + 1
  self:release_where(function(c) return self:muted(c) end)
end

-- match the other deck's tempo (and optionally bar phase)
function Deck:match_tempo(o)
  if not (self.song and o.song) then return end
  local native = self:native_bpm()
  self.tempo = clamp((o:set_bpm() / native - 1) * 100, -50, 50)
end

function Deck:sync_to(o)
  if not (self.song and o.song) then return end
  self:match_tempo(o)
  local bb = self:bar_beats()
  local diff = (o:beat() % o:bar_beats()) - (self:beat() % bb)
  if diff > bb / 2 then diff = diff - bb elseif diff < -bb / 2 then diff = diff + bb end
  local b = self:beat() + diff
  if b < 0 then b = b + bb end
  local held_playing = self.playing
  self:seek(self:sec_at_beat(b), false)
  self.playing = held_playing
  self.sync = true
end

-- ---------- the clock tick ----------

function Deck:update(dt)
  local song = self.song
  if not song or not self.playing then return end
  self.pos = self.pos + dt * self:rate()
  local ev = song.events
  while self.idx <= song.n and ev[self.idx].s <= self.pos do
    self:dispatch(ev[self.idx])
    self.idx = self.idx + 1
  end
  if self.pending and (self:beat() >= self.pending.at - 1e-6 or (self.loop and self.pos >= self.loop.stop)) then
    local target = self.pending.target
    self.pending = nil
    self:seek(target, true)
    return
  end
  if self.loop and self.pos >= self.loop.stop then
    local over = self.pos - self.loop.stop
    self:seek(self.loop.start + over, false)
    return
  end
  if self.pos >= song.len then
    self.playing = false
    self.loop = nil
    self:stop_notes()
    self.pos = song.len
  end
end

return Deck
