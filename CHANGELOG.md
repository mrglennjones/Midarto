# Changelog

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
