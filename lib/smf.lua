-- smf.lua
-- minimal standard MIDI file reader for midarto
-- reads format 0 and 1 files into one time-sorted event list
-- with a tempo map, so playback can work in seconds or beats.

local smf = {}

local function u16(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
local function u32(s, i)
  return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3)
end

local function vlq(s, i)
  local v = 0
  local b
  repeat
    b = s:byte(i)
    if not b then error("truncated variable-length value") end
    v = v * 128 + (b % 128)
    i = i + 1
  until b < 128
  return v, i
end

-- sort key so note-offs come before note-ons on the same tick
local function prio(e)
  local hi = e.st - e.st % 16
  if hi == 0x80 or (hi == 0x90 and e.b == 0) then return 0 end
  if hi == 0x90 then return 2 end
  return 1
end

-- parse raw file data. yield_fn (optional) is called every so often
-- so a long parse can give time back to the norns clock.
function smf.parse(data, yield_fn)
  if #data < 14 or data:sub(1, 4) ~= "MThd" then return nil, "not a MIDI file" end
  local hlen = u32(data, 5)
  local format = u16(data, 9)
  local ntrks = u16(data, 11)
  local division = u16(data, 13)
  local smpte = division >= 0x8000
  local div
  if smpte then
    local fps = 256 - math.floor(division / 256)
    div = fps * (division % 256) -- ticks per second, treated as 60 bpm
  else
    div = division
  end
  if div <= 0 then return nil, "bad time division" end

  local tracks = {}  -- one time-ordered list per track, merged below
  local count = 0
  local tempos = {}
  local timesig = nil
  local maxtick = 0
  local pos = 9 + hlen

  for tr = 1, ntrks do
    if pos + 7 > #data then break end
    local id = data:sub(pos, pos + 3)
    local len = u32(data, pos + 4)
    local i = pos + 8
    local stop = math.min(i + len, #data + 1)
    pos = i + len
    if id == "MTrk" then
      local tick, running = 0, nil
      local tev = {}
      tracks[#tracks + 1] = tev
      local ok, err = pcall(function()
        while i < stop do
          local delta
          delta, i = vlq(data, i)
          tick = tick + delta
          local st = data:byte(i)
          if st == nil then break end
          if st == 0xFF then
            local typ = data:byte(i + 1)
            local l
            l, i = vlq(data, i + 2)
            if typ == 0x51 and l == 3 and not smpte then
              tempos[#tempos + 1] = { tick = tick, uspq = data:byte(i) * 65536 + data:byte(i + 1) * 256 + data:byte(i + 2) }
            elseif typ == 0x58 and l >= 2 and timesig == nil then
              timesig = { num = data:byte(i), den = 2 ^ data:byte(i + 1) }
            end
            if tick > maxtick then maxtick = tick end
            i = i + l
            if typ == 0x2F then break end
          elseif st == 0xF0 or st == 0xF7 then
            local l
            l, i = vlq(data, i + 1)
            i = i + l
          else
            if st >= 0x80 then
              running = st
              i = i + 1
            elseif not running then
              error("data byte without running status")
            end
            st = running
            local hi = st - st % 16
            local a, b = data:byte(i), nil
            if hi == 0xC0 or hi == 0xD0 then
              i = i + 1
            else
              b = data:byte(i + 1)
              i = i + 2
            end
            if a == nil then break end
            count = count + 1
            tev[#tev + 1] = { t = tick, st = st, a = a, b = b or 0 }
            if tick > maxtick then maxtick = tick end
            if yield_fn and count % 256 == 0 then yield_fn() end
          end
        end
      end)
      if not ok then print("midarto smf: track " .. tr .. ": " .. tostring(err)) end
    end
  end

  if count == 0 then return nil, "no notes found" end

  -- merge the tracks (each already in time order) a slice at a time,
  -- instead of one big sort, so a playing deck never has to wait long.
  -- on the same tick, note-offs go before other events and note-ons
  -- last; within one track the file's own order is kept.
  local events = {}
  local heads = {}
  for i = 1, #tracks do heads[i] = 1 end
  for k = 1, count do
    local best, bt, bp
    for i = 1, #tracks do
      local e = tracks[i][heads[i]]
      if e then
        local ep = prio(e)
        if not best or e.t < bt or (e.t == bt and ep < bp) then best, bt, bp = i, e.t, ep end
      end
    end
    events[k] = tracks[best][heads[best]]
    heads[best] = heads[best] + 1
    if yield_fn and k % 512 == 0 then yield_fn() end
  end
  tracks = nil

  -- tempo map: segments of constant tempo
  table.sort(tempos, function(x, y) return x.tick < y.tick end)
  local segs = { { tick = 0, sec = 0, uspq = smpte and 1000000 or 500000 } }
  for _, tp in ipairs(tempos) do
    local last = segs[#segs]
    if tp.tick == last.tick then
      last.uspq = tp.uspq
    else
      local sec = last.sec + (tp.tick - last.tick) * last.uspq / 1e6 / div
      segs[#segs + 1] = { tick = tp.tick, sec = sec, uspq = tp.uspq }
    end
  end

  local song = {
    events = events, n = count, div = div, segs = segs,
    format = format, ntrks = ntrks,
    bar_beats = timesig and (timesig.num * 4 / timesig.den) or 4,
  }

  -- seconds for every event (walk the tempo map once)
  local si = 1
  for k = 1, count do
    local e = events[k]
    while si < #segs and segs[si + 1].tick <= e.t do si = si + 1 end
    local sg = segs[si]
    e.s = sg.sec + (e.t - sg.tick) * sg.uspq / 1e6 / div
    if yield_fn and k % 2048 == 0 then yield_fn() end
  end
  song.len = smf.sec_at_tick(song, maxtick)
  if song.len <= 0 then song.len = events[count].s + 0.5 end
  return song
end

local function seg_for_tick(song, tick)
  local segs = song.segs
  local s = segs[1]
  for k = 2, #segs do
    if segs[k].tick <= tick then s = segs[k] else break end
  end
  return s
end

local function seg_for_sec(song, sec)
  local segs = song.segs
  local s = segs[1]
  for k = 2, #segs do
    if segs[k].sec <= sec then s = segs[k] else break end
  end
  return s
end

function smf.sec_at_tick(song, tick)
  local s = seg_for_tick(song, tick)
  return s.sec + (tick - s.tick) * s.uspq / 1e6 / song.div
end

function smf.tick_at_sec(song, sec)
  local s = seg_for_sec(song, sec)
  return s.tick + (sec - s.sec) * 1e6 * song.div / s.uspq
end

function smf.uspq_at_sec(song, sec)
  return seg_for_sec(song, sec).uspq
end

-- first event index with time >= sec
function smf.index_at(song, sec)
  local lo, hi = 1, song.n + 1
  local ev = song.events
  while lo < hi do
    local mid = (lo + hi) // 2
    if ev[mid].s < sec then lo = mid + 1 else hi = mid end
  end
  return lo
end

return smf
