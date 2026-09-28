# Changelog

## 2.15
- Keep screen awake (while playing by default): stops the norns blanking its screen after 15 minutes without a key or knob press, for example while playing from the grid.
- "MIDARTO" scrolls across the grid during the splash screen.
- The MIDARTO brand lettering is used on the splash screen, the platter screen's status line and the grid scroller.

## 2.14
- Waveform view (screen view setting): both decks' MIDI activity scrolls past a fixed playhead, with kicks and snares standing out, a song overview with loop, cues and position, hot cue and pending-jump markers, a beat ruler with phrase markers, a beat-phase meter, the crossfader, output levels, and mutes shown in the waveform. Zoom from 2 to 32 seconds in PARAMS.
- Song library: hot cues and the last loop length are remembered per song, and each song's prepared data and waveform are cached so it loads much faster the second time. "clear song cache" in PARAMS.
- Screen drawing is batched and slows its frame rate automatically if it ever gets too busy, so notes stay on time. "show frame time" in PARAMS.
- Settings are saved a couple of seconds after any change (not only when leaving the script), and kept across updates. A settings version lets updates adjust old saved settings once, with a message saying what changed (deck B's channel shift 0 becomes 8 for one-device setups).

## 2.13
- Cue to first note (on by default): loading a song sets hot cue 1 and the deck to the start of the bar where the music begins, skipping silence at the start. Can use the first drum hit instead, or be turned off.
- Start on bar (on + sync by default): PLAY on a stopped deck while the other deck plays arms it; it starts exactly on the other deck's next bar line and syncs its tempo. PLAY again cancels.

## 2.12
- Pressing LOAD (or K1+K2/K3) again closes the file browser, in case it was opened by accident.

## 2.11
- Loading a song no longer makes the playing deck glitch. Files are now read in small slices (the tracks are merged step by step instead of in one big sort), so the norns is never busy for more than a few milliseconds at a time.

## 2.10
- CUE while playing jumps to the main cue and keeps playing (on the next bar when quantize jumps is on). CUE while paused still moves there and stays paused.

## 2.9
- Shared channels: the playing deck owns any channel both decks use on the same device. Loading, cueing or stopping the other deck no longer touches it, and when both play the louder deck owns it while the quieter deck's notes are scaled by velocity.
- Channels a file never gives an instrument now get piano (the General MIDI default).

## 2.8
- New "midi outputs" setting: one device (default, deck B follows deck A's device) or two devices. Deck B's channel shift defaults to 8.

## 2.7
- Splash screen with an animated 8-bit DJ next to the title, then the credits.

## 2.6
- Splash screen with the name and credits.

## 2.5
- Songs folder at dust/data/midarto/songs, seeded with the demo songs. Songs from older versions are moved into it.
- The browser's "no files here" message now shows.

## 2.4
- SYNC moved next to PLAY/PAUSE; BPM0 renamed BPM RESET and moved to the tempo row; deck B's tempo row mirrored.

## 2.3
- Deck B defaults to MIDI port 2. Settings are remembered between sessions.

## 2.2
- A deck's platter outline flashes as its song runs out ("end warning" setting).

## 2.1
- Long file names scroll on screen.

## 2.0
- New grid layout: CHAN 1-16 mute keys per deck (SHIFT solos, SHIFT on a soloed channel restores all), single CUE and PLAY/PAUSE keys, SHIFT + CUE stops.

## 1.0
- First release, tested on hardware: two decks, mixer, crossfader, file browser, grid controller, MIDI and nb output.
