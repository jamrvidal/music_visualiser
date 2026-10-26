# JVisuals

A macOS visualiser that taps the audio your Mac is playing (Spotify, Music, a browser, anything) and draws it.

- **Scope**: triggered oscilloscope trace with phosphor persistence, as a line or wrapped into a circle.
- **X · Y**: Lissajous mode: stereo (left vs right) or delay (the signal against itself a few ms earlier, which moves even for mono music), with width, spin and auto gain.
- **Spectrum**: smooth 128-band curve, drawn as a line, vertical bars, horizontal bars (8–128 bars) or a 3D terrain of ridges receding into the distance.
- **Pulse**: a shape (circle, triangle, square, hexagon or star) that throbs with the bass and fires
  expanding rings on each beat.

Glowing lines on plain black. Customisation is a deck of knobs (drag to turn, double-click to reset)
that slides up from the bottom: colours (colour wheel, hex or R/G/B knobs, with an optional bass-to-treble
gradient, automatic colour cycling, or colours taken from the playing album's artwork), glow, trails, line weight, CRT lines and per-mode options. Settings persist between launches.

When Spotify is playing, the title, artist, album, artwork and progress show under the logo, and briefly
appear on each track change even with the interface hidden.

Keys: ←/→ or 1–4 switch modes, S opens the controls, H hides the interface, F toggles full screen,
Esc closes panels.

Requires macOS 14.2+ (Core Audio process taps).

## Build and run

```sh
./build.sh --run
```

The first launch asks for permission to capture audio from other apps. If you deny it, the visuals stay
flat; re-enable it in System Settings → Privacy & Security → Screen & System Audio Recording.
The app is ad-hoc signed, so macOS may ask again after a rebuild.

## Layout

| File | Role |
| --- | --- |
| `AudioCapture.swift` | Lists audio processes, creates the process tap + aggregate device |
| `SampleRing.swift` | Stereo ring buffer between the audio thread and the renderer |
| `Spectrum.swift` | FFT and log-spaced band levels for Bars |
| `Config.swift` | Persisted settings, hex parsing and the derived colour palette |
| `Renderer.swift` | Per-mode geometry, spectrum smoothing, persistence buffer, Metal passes |
| `Shaders.swift` | Metal shaders (compiled at runtime, so no Xcode needed) |
| `JVisualsApp.swift` | App entry point and the Metal view |
| `NowPlaying.swift` | Follows Spotify's playback notifications, plus one AppleScript query for artwork |
| `Interface.swift` | Overlay: mode menu, source list, knob deck, keys |
