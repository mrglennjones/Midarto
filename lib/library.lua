-- library.lua
-- per-song memory for midarto, kept in dust/data/midarto/library/
--
--   <song>.cues            hot cues and last loop length (kept for good)
--   <song>-<print>.cache   the prepared song and waveform, so the next
--                          load is quick. <print> is a fingerprint of the
--                          file, so an edited file gets a fresh cache.
--
-- everything here is safe to delete: caches are rebuilt on the next load.

local Library = {}
Library.dir = nil -- set by the script
local MAGIC = "MIDARTO-CACHE-3\n"

local function safe_name(path)
  local name = path:match("([^/]+)$") or path
  name = name:gsub("%.[Mm][Ii][Dd][Ii]?$", "")
  name = name:gsub("[^%w%-_]", "_")
  return name
end

function Library.init(dir)
  Library.dir = dir
  util.make_dir(dir)
end

-- quick fingerprint: length plus a checksum of every 61st byte
function Library.fingerprint(data, yield_fn)
  local sum = #data % 4294967296
  local count = 0
  for i = 1, #data, 61 do
    sum = (sum * 31 + data:byte(i)) % 4294967296
    count = count + 1
    if yield_fn and count % 4096 == 0 then yield_fn() end
  end
  return string.format("%08x", sum)
end

local function cache_path(path, fp) return Library.dir .. safe_name(path) .. "-" .. fp .. ".cache" end
local function cues_path(path) return Library.dir .. safe_name(path) .. ".cues" end

-- ---------- cues ----------

function Library.load_cues(path)
  local f = io.open(cues_path(path), "r")
  if not f then return nil end
  local c = { cues = {}, loop = 0 }
  for line in f:lines() do
    local k, v = line:match("^(%w+)%s+([%d%.]+)")
    if k and v then
      local n = tonumber(v)
      local i = k:match("^cue(%d)$")
      if i then c.cues[tonumber(i)] = n
      elseif k == "loop" then c.loop = math.floor(n) end
    end
  end
  f:close()
  return c
end

function Library.save_cues(path, cues, loop)
  local f = io.open(cues_path(path), "w")
  if not f then return end
  f:write("# midarto cue points for " .. (path:match("([^/]+)$") or path) .. "\n")
  for i = 1, 4 do
    if cues[i] then f:write(string.format("cue%d %.6f\n", i, cues[i])) end
  end
  f:write(string.format("loop %d\n", loop or 0))
  f:close()
end

-- ---------- cache ----------

-- write in slices: pack a few thousand items, then yield
function Library.save_cache(path, fp, song, wave, yield_fn)
  -- remove older caches of this song (a different fingerprint)
  local prefix = safe_name(path) .. "-"
  for _, e in ipairs(util.scandir(Library.dir) or {}) do
    if e:sub(1, #prefix) == prefix and e:match("%.cache$") then os.remove(Library.dir .. e) end
  end
  local tmp = cache_path(path, fp) .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  local parts = { MAGIC, string.pack("<I4dI4d", song.div, song.bar_beats, #song.segs, song.len) }
  for _, sg in ipairs(song.segs) do parts[#parts + 1] = string.pack("<ddd", sg.tick, sg.sec, sg.uspq) end
  parts[#parts + 1] = string.pack("<I4", song.n)
  f:write(table.concat(parts))
  local ev = song.events
  parts = {}
  for k = 1, song.n do
    local e = ev[k]
    parts[#parts + 1] = string.pack("<dI4BBB", e.s, e.t, e.st, e.a, e.b)
    if k % 2048 == 0 then
      f:write(table.concat(parts)); parts = {}
      if yield_fn then yield_fn() end
    end
  end
  f:write(table.concat(parts))
  local chans = {}
  for ch in pairs(wave.chans) do chans[#chans + 1] = ch end
  table.sort(chans)
  f:write(string.pack("<I4B", wave.nbins, #chans))
  for _, ch in ipairs(chans) do
    local c = wave.chans[ch]
    f:write(string.pack("<B", ch))
    for _, arr in ipairs({ c.act, c.hit }) do
      local buf = {}
      for i = 1, wave.nbins, 200 do
        buf[#buf + 1] = string.char(table.unpack(arr, i, math.min(i + 199, wave.nbins)))
      end
      f:write(table.concat(buf))
      if yield_fn then yield_fn() end
    end
  end
  f:close()
  os.rename(tmp, cache_path(path, fp))
  return true
end

-- returns song, wave or nil if there's no usable cache
function Library.load_cache(path, fp, yield_fn)
  local f = io.open(cache_path(path, fp), "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if data:sub(1, #MAGIC) ~= MAGIC then return nil end
  local ok, song, wave = pcall(function()
    local pos = #MAGIC + 1
    local div, bar_beats, nsegs, len
    div, bar_beats, nsegs, len, pos = string.unpack("<I4dI4d", data, pos)
    local segs = {}
    for i = 1, nsegs do
      local tick, sec, uspq
      tick, sec, uspq, pos = string.unpack("<ddd", data, pos)
      segs[i] = { tick = tick, sec = sec, uspq = uspq }
    end
    local n
    n, pos = string.unpack("<I4", data, pos)
    local events = {}
    for k = 1, n do
      local s, t, st, a, b
      s, t, st, a, b, pos = string.unpack("<dI4BBB", data, pos)
      events[k] = { s = s, t = t, st = st, a = a, b = b }
      if yield_fn and k % 2048 == 0 then yield_fn() end
    end
    local sng = { events = events, n = n, div = div, segs = segs, len = len, bar_beats = bar_beats }
    local nbins, nch
    nbins, nch, pos = string.unpack("<I4B", data, pos)
    local w = { nbins = nbins, chans = {} }
    for _ = 1, nch do
      local ch
      ch, pos = string.unpack("<B", data, pos)
      local act = { data:byte(pos, pos + nbins - 1) }
      pos = pos + nbins
      local hit = { data:byte(pos, pos + nbins - 1) }
      pos = pos + nbins
      w.chans[ch] = { act = act, hit = hit }
      if yield_fn then yield_fn() end
    end
    return sng, w
  end)
  if not ok then
    print("midarto: cache unreadable, rebuilding: " .. tostring(song))
    return nil
  end
  return song, wave
end

-- remove every cache file (cue files are kept)
function Library.clear_cache()
  local n = 0
  for _, e in ipairs(util.scandir(Library.dir) or {}) do
    if e:match("%.cache$") or e:match("%.cache%.tmp$") then
      os.remove(Library.dir .. e); n = n + 1
    end
  end
  return n
end

return Library
