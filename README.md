# vtrax

A terminal (TUI) module player for `.mod` / `.xm` / `.it` / `.s3m` / `.mtm`
(and anything else libopenmpt reads), written in **V**. Per-channel level
meters, a scrolling pattern view, a master spectrum analyzer, a master output
meter, and themeable colors. macOS + Linux.

This is a V port of [ztrax](../ztrax) (Zig) / rtrax (Rust). Playback and theming
aim to match them closely.

## Dependencies

vtrax links one system library (resolved via `pkg-config`) plus a vendored,
single-header audio backend.

```sh
# macOS
brew install vlang libopenmpt

# Debian / Ubuntu
sudo apt install libopenmpt-dev
# (install V from https://vlang.io)
```

- **libopenmpt** — module decoding.
- **miniaudio** — audio output (callback-driven). Vendored as a single header
  under `vendor/`; no system package needed.
- **term.ui** — terminal UI (part of V's standard library).

## Build & run

```sh
v -o vtrax src            # build the vtrax binary (sources live in src/)
v test src                # run the unit tests (fft, rng, spsc, toml)
./vtrax some_song.xm      # launch the TUI on a file
./vtrax ~/mods            # browse a directory
./vtrax a.xm b.xm c.xm    # play several files as a queue
./vtrax --playlist favs.m3u           # play an M3U as a queue
./vtrax --playlist favs.m3u ~/mods    # browse, press `a` to add to favs
./vtrax --shuffle ~/mods              # start shuffled
./vtrax --theme dracula ~/mods        # override the theme for one run

# Headless helpers (no UI):
./vtrax --load-print song.xm   # print module metadata (FFI smoke test)
./vtrax --play song.xm 5       # play 5s through miniaudio, no UI
./vtrax --render 110x34 song.xm  # render one TUI frame to stdout (self-test)
```

If a file or no argument is given, the player opens on it; `n`/`p` walk the
other module files in the same folder, and playback auto-advances at end of
song.

> On Homebrew macOS the Boehm GC that V links lives under `/opt/homebrew/lib`;
> the build adds that to the linker search path automatically.

## Keybindings

| Key       | Action                          |
|-----------|---------------------------------|
| `space`   | Play / pause                    |
| `s`       | Stop                            |
| `n` / `p` | Next / previous in folder       |
| `/`       | Focus browser / queue           |
| `Tab`     | Cycle focus                     |
| `↑` `↓`   | Move selection (browser / queue)|
| `Enter`   | Open folder / load / jump       |
| `a`       | Add current track to playlist   |
| `z`       | Toggle shuffle                  |
| `←` / `→` | Seek −5 s / +5 s                |
| `[` / `]` | Gain down / up (2 dB steps)     |
| `\`       | Reset gain to unity (0 dB)      |
| `t`       | Cycle theme                     |
| `b`       | Cycle progress-bar style        |
| `w`       | Cycle pattern stack (1/2/4 lanes) |
| `c`       | Toggle compact cells            |
| `i`       | Toggle info panel               |
| `m`       | Song message overlay            |
| `?`       | Help overlay                    |
| `q`       | Quit                            |

## Configuration

vtrax reads `$XDG_CONFIG_HOME/vtrax/config.toml` (or `~/.config/vtrax/config.toml`):

```toml
theme = "dracula"              # built-in name or a custom theme file stem
progress_bar_style = "blocks"  # triangle | blocks | line | segments
auto_layout = true             # auto-size the pattern lanes per module
default_browse_path = "~/mods" # where the browser opens with no path argument
```

CLI flags override the file: `--theme <name>` picks a theme for one run, and
`--no-config` ignores the file entirely.

## Themes

Built-ins: `default`, `high-contrast`, `sixteen`, `neon-blue`, `neon-green`,
`neon-orange`, `c64`, `mono`. Press `t` to cycle every built-in plus any custom
themes found in your config themes directory.

Custom themes are `.toml` files under `$XDG_CONFIG_HOME/vtrax/themes/`. This repo
ships a library of them in [`themes/`](themes/) (Dracula, Nord, Catppuccin,
Gruvbox, Tokyo Night, …):

```sh
mkdir -p ~/.config/vtrax/themes
cp themes/dracula.toml ~/.config/vtrax/themes/
```

A theme file may `extends` a built-in (or another custom theme) and override any
subset of color keys; values are `#rrggbb`, `reset`, or an ANSI color name:

```toml
extends = "default"
accent = "#ffb454"
instrument = "light-cyan"
current_row_bg = "#302414"
```

Keys: `bg`, `fg`, `fg_dim`, `border`, `border_focus`, `accent`, `note`,
`instrument`, `volume`, `effect`, `meter_low`, `meter_mid`, `meter_high`,
`current_row_bg`.

## Architecture

A tiny C glue file (`vendor/ma.c`) creates the miniaudio playback device; its
data callback does nothing but hand control to the V function `vtrax_fill`,
where all real-time work lives. Inside that callback vtrax decodes interleaved
f32 stereo straight into the device buffer, pushes a downsampled mono copy into
a lock-free ring for the FFT, and publishes order/row/BPM/VU/peak into atomic
shared state (`vendor/atomics.c` provides the memory-ordered primitives). The UI
thread (~30 fps, driven by `term.ui`) reads those atomics, drains the FFT ring,
and renders a frame. The callback never allocates, locks, or logs; the previous
module from a load is handed back over a drop ring and freed on the UI thread.

## Status

Feature-complete against ztrax's playback/UI: audio playback, transport,
per-channel meters, master meter, spectrum analyzer, scrolling pattern view
(stacked lanes / compact cells / auto-layout), header with four progress-bar
styles, info / song-message / help overlays, a navigable file browser, M3U
playlists with a queue panel (`a` to add, `z` to shuffle), eight built-in themes
plus custom `.toml` themes with `extends`, a `config.toml`, and the full CLI
(`--playlist`, `--shuffle`, `--theme`, `--no-config`).
