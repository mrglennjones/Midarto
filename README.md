# Midarto

![Midarto on norns and grid](https://raw.githubusercontent.com/mrglennjones/midarto/main/docs/images/mockup.gif)

A two-deck MIDI file DJ for monome norns. Load `.mid` files into deck A and deck B, mix them with a crossfader and play them out to a MIDI sound module (such as a General MIDI module) or to nb voices. It works on the norns alone, and a 16×8 grid adds cues, loops, mutes, sync and big transport keys.

Version 2.9.

## Install

**From maiden (once the repo is public):** in the maiden REPL, type `;install https://github.com/mrglennjones/midarto`.

**By copying:**

1. Unzip `midarto.zip`. You get a folder called `midarto` containing `midarto.lua`, `lib/`, `demo/` and this README.
2. Copy the whole `midarto` folder into `dust/code/` on your norns. Any of these works:
   - From a computer on the same network, open the norns file share (`smb://norns.local` on macOS or `\\norns.local` on Windows, user `we`, password `sleep` unless you changed it). Drop the folder into `dust/code/`.
   - Or from a terminal: `scp -r midarto we@norns.local:~/dust/code/`
3. On the norns, go to SELECT and choose MIDARTO. A 5-second splash screen shows an 8-bit DJ at the decks next to the title, then the credits; press any key or knob, or any grid key, to skip it.

The first time it runs, Midarto creates a songs folder, `dust/data/midarto/songs/`, and puts two demo songs in it (`acid_trk.mid` at 120 BPM and `breaks.mid` at 98.5 BPM), so you can try it straight away.

### Your own files

Fill the songs folder, `dust/data/midarto/songs/`, with your own `.mid` or `.midi` files. Subfolders are fine, for example one per set or genre. The browser always opens in the songs folder, and you can go up to browse anywhere in `dust`. You can delete the demo songs once you've added your own; if the folder is ever empty, Midarto puts them back.

**Upgrading from v2.4 or earlier:** songs you kept directly in `dust/data/midarto/` are moved into the songs folder the first time v2.5 runs.

### Optional: nb voices

To play a deck through nb voices instead of MIDI, install the nb library (`dust/code/nb`) plus any nb voice mods you want, then restart Midarto. An "nb voice" output option and a voice selector then appear in each deck's parameters. If nb isn't installed, Midarto simply offers MIDI output only.

## First setup

Open PARAMS > EDIT > MIDARTO. Midarto remembers these settings between sessions (in `dust/data/midarto/settings.pset`).

| Parameter | What it does |
|---|---|
| midi outputs | `one device` (default): both decks play to deck A's MIDI device. `two devices`: each deck has its own device |
| output | `midi` or `nb voice` (nb only if installed) |
| midi device | Which MIDI port the deck plays to (1–16, names shown). With one device, only deck A's shows and both decks use it. With two, deck B defaults to port 2 |
| channel shift | Moves the file's channels up by this amount, so two decks don't fight over the same channels. Deck A defaults to 0, deck B to 8 |
| drums stay on 10 | Keeps channel 10 drums on 10 when shifting; other channels skip 10 |
| nb voice | Voice for the deck when output is `nb voice` |
| crossfader curve | `dj` (both full at the centre) or `smooth` (constant power) |
| quantize jumps | Seek, cue and bar jumps wait for the next bar line |
| knob sensitivity | How far the faders move per encoder step |
| end warning | How long before the end of a song its platter outline starts flashing: off, 10, 20, 30 (default) or 60 seconds |
| clock follows master | Sets the norns clock tempo from the master deck, so clocked gear follows |
| panic | All notes off on both decks' outputs |

**One General MIDI module (the default):** plug your GM module into the norns and set deck A's midi device to it. Deck B plays to the same device automatically.

General MIDI has only 16 channels, so deck B's channel shift (8 by default) moves its parts out of deck A's way. For example, deck B's channels 1–7 play on 9 and 11–16 (10 is skipped), while deck A keeps 1–8. Both decks share drums on channel 10, because General MIDI has only one drum channel. Files that use more than 8 channels will still overlap. Shared channels are handled for you: see "Shared channels" below.

**Two General MIDI modules:** give each deck its own module, so nothing collides and both files keep all 16 channels, drums included.

1. Plug both USB MIDI modules (or USB MIDI interfaces) into the norns.
2. Go to SYSTEM > DEVICES > MIDI and check which port each one is on.
3. In PARAMS > EDIT > MIDARTO, set **midi outputs** to `two devices`. Deck B's midi device setting appears.
4. Set deck A's midi device to the first module and deck B's to the second. The device names show next to the numbers.
5. Set deck B's channel shift to 0.

**Upgrading from v2.3–v2.7:** your saved settings keep deck B's old channel shift (0). For one device, set deck B's channel shift to 8.

## Norns controls

| Control | Normal | Hold K1 |
|---|---|---|
| E1 | Crossfader | Tempo of both decks |
| E2 | Deck A volume | Deck A tempo (0.1% steps) |
| E3 | Deck B volume | Deck B tempo |
| K2 | Deck A play/pause | Open file browser for deck A |
| K3 | Deck B play/pause | Open file browser for deck B |

A quick tap on K1 still opens the norns menu, as usual.

**In the browser:** E2 scrolls, E3 scrolls a page, E1 switches the target deck, K3 opens a folder or loads the file, and K2 closes the browser. The other deck keeps playing while you browse.

**On screen:** each deck shows its file name (long names scroll), a platter outline that flashes as the song runs out, a platter that turns once per bar, a progress bar (with a hot cue 1 mark and the loop region), BPM, tempo offset and time remaining. The mixer in the middle shows both volume faders, output meters and the crossfader. An X under a fader means that deck is killed.

## Grid (16×8)

Deck A is on columns 1–6, the mixer on 7–10 and deck B on 11–16. Rows 1–3, 5 and 6 run in the same order on both decks. Row 4 (tempo) and rows 7–8 are mirrored, so NDG, CUE, PLAY/PAUSE and SYNC sit on the outer edges; −/+ pairs still read left to right.

| Row | Deck A x1–x6 | Mixer x7–x10 | Deck B x11–x16 |
|---|---|---|---|
| 1 | SEEK 1–6 | VOL A · MTR A · MTR B · VOL B | SEEK 1–6 |
| 2 | CUE1–4, <BAR, BAR> | volume and meters | CUE1–4, <BAR, BAR> |
| 3 | LOOP 1, 2, 4, 8, 16, LOOP | volume and meters | LOOP 1, 2, 4, 8, 16, LOOP |
| 4 | NDG−, NDG+, BPM−, BPM+, free, BPM RESET | volume and meters | BPM RESET, free, BPM−, BPM+, NDG−, NDG+ |
| 5 | CHAN 1–6 | volume and meters | CHAN 1–6 |
| 6 | CHAN 7–12 | volume and meters | CHAN 7–12 |
| 7 | CUE, free, CHAN 13–16 | XF A · XF 1/3 · XF 2/3 · XF B | CHAN 13–16, free, CUE |
| 8 | PLAY/PAUSE, SYNC, free, LOAD A, free, SHIFT | KILL A · MSTR A · MSTR B · KILL B | SHIFT, free, LOAD B, free, SYNC, PLAY/PAUSE |

Deck keys:

- **SEEK 1–6** jumps to that sixth of the file.
- **CUE1–4 (hot cues):** press an empty one to store the current bar, press a stored one to jump there. SHIFT + hot cue erases it.
- **<BAR / BAR>** jump back or forward one bar.
- **LOOP 1–16** loops that many bars from the current bar; press the lit one again to release. **LOOP** turns the last loop length back on or off.
- **NDG− / NDG+** nudge slower or faster (4%) while held.
- **BPM− / BPM+** change tempo by 0.5%. With SHIFT they transpose by a semitone (drums are never transposed). **BPM RESET** returns to the file tempo straight away (and releases SYNC), or resets transpose with SHIFT.
- **SYNC** (next to PLAY/PAUSE) matches the other deck's tempo, lines up the bar position and keeps following. Press again to release. The master deck never follows.
- **CHAN 1–16** mute or unmute that MIDI channel of the file. These are the file's own channel numbers, so CHAN 10 is the drums even with channel shift.
  - **SHIFT + CHAN** solos that channel. SHIFT + more channels adds them to the solo.
  - **SHIFT + a soloed channel** restores all channels (clears solos and mutes).
  - A channel the file doesn't use stays dark. Muted or solo-silenced channels are dim, playing channels are medium, soloed channels are bright, and every channel flickers brighter each time it plays a note.
- **CUE** returns to hot cue 1 (or the start) and pauses. **SHIFT + CUE** stops the deck and returns to the start.
- **PLAY/PAUSE** starts or pauses the deck and pulses on each beat.
- **LOAD** opens the browser for that deck. **SHIFT** is shared by both decks; there's one next to the mixer on each side.
- **free** keys do nothing yet.

Mixer:

- **VOL A / VOL B:** press a row to set the level (top = 100%).
- **MTR A / MTR B** show each deck's output after volume, crossfader, kill and mutes. Holding a meter key cuts that deck until you let go.
- **XF:** press to jump the crossfader. Pressing a lit middle key moves it to the centre.
- **KILL** mutes a deck's whole output. **MSTR** sets the tempo master for sync and for "clock follows master".
- Press MSTR A and MSTR B together for panic.

Brightness: dark = nothing there, dim = available (or muted), medium = set or stored, bright = on. A key blinks while its jump waits for the next bar.

## How volume works

For MIDI outputs, Midarto sets each channel's volume (CC7) from the file's own volume multiplied by the deck fader, the crossfader and kill. So moving a fader fades held notes too, and each file's own mix balance is kept. For nb voices there's no channel volume, so note velocity is scaled instead, which only affects new notes.

**Instruments:** when a file never chooses an instrument for a channel, Midarto sets piano (the General MIDI default), so the part doesn't pick up whatever instrument was left on that channel. Channel shift moves each part's instrument with it.

**Shared channels:** when both decks use the same channel on the same device (always true for drums on channel 10 with one GM device), the playing deck owns it. Loading, cueing or stopping the other deck sends nothing to that channel: no volume, instrument, controller or all-notes-off messages, so the playing deck carries on untouched. When both decks play, the louder one owns the channel and sets its volume and instrument, and the quieter deck's notes there are played at its own level through velocity. So crossfading hands the drums over from one deck to the other.

## Notes and limits

- If anything misbehaves, the maiden REPL shows messages starting with `midarto`.
- Midarto reads MIDI file formats 0 and 1 and follows tempo changes inside the file. Files timed in SMPTE frames play at their real speed but show 60 BPM.
- Bars are taken from the file's first time signature (4/4 if there isn't one).
- Each deck's nb voice plays every channel of the file on that one voice.
- The layout is built for a 16×8 grid. Other sizes are not supported yet.

## Repository layout

- `midarto.lua`, `lib/`, `demo/`: the norns script (this folder is what goes in `dust/code/midarto`).
- `docs/midarto-guide.pdf`: the full user guide ([download](https://github.com/mrglennjones/midarto/raw/main/docs/midarto-guide.pdf)).
- `docs/images/`: screen, grid and splash images.
- `CHANGELOG.md`: what changed in each version.
- `LICENSE`: the MIT License.

## Thanks

- [monome](https://monome.org) (brian crabtree and the norns contributors) for norns, maiden and the grid.
- [sixolet](https://github.com/sixolet) for [nb](https://github.com/sixolet/nb) (nota bene), which Midarto can play through.
- [sonoCircuit](https://github.com/sonocircuit) for [midiplayer](https://norns.community/midiplayer/), which showed MIDI file playback on norns and inspired Midarto.
- [adamstaff](https://github.com/adamstaff) for [turntable](https://norns.community/turntable), whose norns DJ controls inspired Midarto's keys and knobs.
- denki oto for the norns Shield XL and the grid clone that Midarto was developed and tested on.

The guide uses IBM Plex Mono and the mockup images use Silkscreen, both under the SIL Open Font License.

## Licence

Midarto is released under the [MIT License](LICENSE). You're free to use, change and share it, as long as the copyright notice stays with it.

## Credits

Created by Glenn Jones, Cutie Suzuki & DJ FingaBlasta.

- Email: mailmrg@gmail.com
- Social: @mrglennjones
- GitHub: [github.com/mrglennjones](https://github.com/mrglennjones)
- Project: [github.com/mrglennjones/midarto](https://github.com/mrglennjones/midarto)
