-- wave.lua
-- MIDI activity "waveform" for midarto's waveform view.
--
-- a song is cut into 50 ms slots. for every channel we keep:
--   act[i]  how busy the channel is in slot i (0-255, scaled so 200 is
--           a loud moment for this song)
--   hit[i]  2 = kick, 1 = snare/clap (drum channel 10), or 1 = a bass
--           note starting (only in songs without drums)
-- the screen mixes the channels you can hear, so mutes and solos show.

local Wave = {}
Wave.STEP = 0.05

local DECAY = { 1, 0.6, 0.35, 0.2, 0.1 }

-- build from a parsed song. yield_fn is called now and then so the other
-- deck keeps playing smoothly.
function Wave.build(song, yield_fn)
  local step = Wave.STEP
  local nbins = math.floor(song.len / step) + 2
  local ev = song.events
  local has_drums = false
  for k = 1, song.n do
    local e = ev[k]
    if e.st == 0x99 and e.b > 0 then has_drums = true; break end
  end
  local act, hit = {}, {}
  for k = 1, song.n do
    local e = ev[k]
    if e.st - e.st % 16 == 0x90 and e.b > 0 then
      local ch = e.st % 16 + 1
      local a = act[ch]
      if not a then
        a = {}
        act[ch] = a
        hit[ch] = {}
      end
      local b = math.floor(e.s / step) + 1
      local w = e.b / 127
      for j = 1, #DECAY do
        local i = b + j - 1
        if i <= nbins then a[i] = (a[i] or 0) + w * DECAY[j] end
      end
      local v = 0
      if ch == 10 then
        if e.a == 35 or e.a == 36 then v = 2
        elseif e.a >= 37 and e.a <= 40 then v = 1 end
      elseif not has_drums and e.a < 48 then
        v = 1
      end
      if v > 0 then
        local h = hit[ch]
        if (h[b] or 0) < v then h[b] = v end
        if v == 2 and b + 1 <= nbins and (h[b + 1] or 0) < 1 then h[b + 1] = 1 end
      end
    end
    if yield_fn and k % 1024 == 0 then yield_fn() end
  end
  -- scale against the song's own loud moments (95th percentile of the total)
  local totals = {}
  for i = 1, nbins do
    local t = 0
    for _, a in pairs(act) do t = t + (a[i] or 0) end
    if t > 0 then totals[#totals + 1] = t end
    if yield_fn and i % 2048 == 0 then yield_fn() end
  end
  table.sort(totals)
  local p95 = totals[math.max(1, math.floor(#totals * 0.95))] or 1
  if p95 <= 0 then p95 = 1 end
  local wave = { nbins = nbins, chans = {} }
  for ch, a in pairs(act) do
    local q, h = {}, {}
    local src_h = hit[ch]
    for i = 1, nbins do
      local v = a[i] or 0
      q[i] = math.min(255, math.floor(v / p95 * 200 + 0.5))
      h[i] = src_h[i] or 0
      if yield_fn and i % 4096 == 0 then yield_fn() end
    end
    wave.chans[ch] = { act = q, hit = h }
  end
  return wave
end

-- mix the channels the listener can hear. audible(ch) -> bool.
-- also makes the 120-column overview of the whole song.
function Wave.mix(wave, audible, yield_fn)
  local n = wave.nbins
  local act, hit = {}, {}
  local on = {}
  for ch, c in pairs(wave.chans) do
    if audible(ch) then on[#on + 1] = c end
  end
  for i = 1, n do
    local a, h = 0, 0
    for j = 1, #on do
      local c = on[j]
      a = a + c.act[i]
      local x = c.hit[i]
      if x > h then h = x end
    end
    act[i] = a > 255 and 255 or a
    hit[i] = h
    if yield_fn and i % 2048 == 0 then yield_fn() end
  end
  local ov = {}
  local per = n / 120
  local peak = 0
  for x = 1, 120 do
    local i0 = math.floor((x - 1) * per) + 1
    local i1 = math.max(i0, math.floor(x * per))
    local sum = 0
    for i = i0, math.min(i1, n) do sum = sum + act[i] end
    ov[x] = sum / (i1 - i0 + 1)
    if ov[x] > peak then peak = ov[x] end
  end
  for x = 1, 120 do
    local v = ov[x]
    ov[x] = (v < 2) and 0 or (1 + math.floor(v / math.max(peak, 1) * 3 + 0.5))
  end
  return { act = act, hit = hit, ov = ov, n = n }
end

return Wave
