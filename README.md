# Phosphor

A macOS visualiser that taps the audio your Mac is playing (Spotify, Music, a browser, anything) and draws it.

- **Scope**: triggered Y–T oscilloscope trace with phosphor persistence.
- **X · Y**: Lissajous mode, left channel on X and right on Y.
- **Spectrum**: smooth 128-band curve, drawn as a line, filled, mirrored or as bars.

Glowing lines on plain black. The settings panel sets the colours (colour wheel, hex or RGB, with an optional
bass-to-treble gradient), glow, trails, line weight, CRT lines and per-mode options.
Settings persist between launches.

Keys: ←/→ or 1–3 switch modes, S opens settings, H hides the interface, F toggles full screen,
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
| `PhosphorApp.swift` | App entry point and the Metal view |
| `Interface.swift` | Overlay: mode menu, source list, settings panel, keys |
