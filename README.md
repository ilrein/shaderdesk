# Shaderdesk

Live Metal shader wallpapers for macOS, from the menu bar. Built-in scenes:

- **Red Giant**: a molten, boiling star with streaming corona rays, prominences rising
  off the limb and a planet transiting in front of it.
- **Ringed World**: a banded gas giant backlit by its star, with rings that cast
  shadows on it (and catch its shadow), ice glints, and a moon that slips into eclipse.
- **Binary**: an amber giant spilling a stream of gas onto a
  white-hot companion's spinning accretion disk, with a flickering hot spot and faint jets.
- **Black Hole**: a ray-traced Schwarzschild black hole. Every pixel's light path is
  integrated through curved spacetime, so the lensed far side of the accretion disk,
  the photon ring and the Einstein-ring sky come out of the physics.
- **Neon Horizon**: synthwave in hot pink and cyan. A striped sun sinking between
  rim-lit mountain ridges, and a neon grid scrolling across a wet floor that mirrors it all.
- **Rain City**: a cyberpunk skyline in the rain. Five layers of towers fading into haze,
  windows that come and go, flickering neon signs, blinking beacons, searchlights sweeping
  a city-lit cloud deck, and flying cars weaving between the towers.

Every scene renders in HDR and goes through a shared bloom pass (a mip-pyramid lens
glow) before tone mapping; set its strength per scene with `//! bloom: 0.06`. `//! tags: Stars, Planets` groups
scenes in the picker's sidebar (it appears once there's more than one tag).

- **Native and light.** Swift + Metal, about 5% of one CPU core and a few ms of GPU per
  frame at full Retina resolution on two displays. The app is under 1 MB.
- **No flicker.** One borderless window per display at the desktop level, on every
  Space. When a display is covered (full-screen app, sleep, lock), drawing stops but
  everything stays in memory, so it resumes instantly without reloading.
- **Pluggable scenes.** Each scene is a single `.metal` file compiled at runtime. Drop
  your own into a folder and it shows up in the menu.
- **Private.** Nothing leaves your machine. The optional agent-activity layer (off by
  default) only reads local Claude Code / Codex log files.

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools). The Metal
compiler isn't needed, because shaders compile at runtime.

```sh
scripts/build-app.sh            # -> build/Shaderdesk.app
scripts/build-app.sh --install  # also copy to /Applications and launch
```

For development, run `swift run Shaderdesk`. Set `SHADERDESK_DEBUG=1` to log
pause/resume events and per-display frame stats to stderr.

## Using it

Click the menu bar icon: every scene is shown as a thumbnail (hover to see it move).
Click one and it becomes the wallpaper. Right-click the icon for Launch at Login and
Quit. That's all there is.

## Writing a scene

Scenes live in two places:

- built-in: `Scenes/` in this repo, copied into the app bundle
- yours: `~/Library/Application Support/Shaderdesk/Scenes/`

A file in your folder with the same name as a built-in scene
replaces it. The folder is watched, so saving a file reloads it.

Each file is compiled on its own, with [`Scenes/Common.metal`](Scenes/Common.metal)
prepended. That file provides the uniforms, noise, star helpers, tone mapping and
dithering. If a scene fails to compile, it's marked in the menu with the error, and the
other scenes keep working.

```metal
//! title: Plasma
//! order: 10

fragment float4 scene_frame(VOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]],
                            constant Galaxy* G [[buffer(1)]],
                            constant Flare* F [[buffer(2)]],
                            texture2d<float> bg [[texture(0)]],
                            texture2d<float> lut [[texture(1)]]) {
    float2 p = globalPoint(in.pos, U) / 400.0;   // desktop points, continuous across displays
    float t = U.view.w;                           // seconds
    float act = U.motion.z;                       // agent activity 0..1 (smoothed)
    float v = sin(p.x + t * 0.2) + sin(p.y * 1.3 - t * 0.15) + sin((p.x + p.y) * 0.7);
    float3 col = 0.02 + 0.03 * (0.5 + 0.5 * cos(v + float3(0, 2, 4))) * (1.0 + act);
    return present(col * U.misc.x, in.pos.xy);   // tone-map + dither for the display
}
```

Entry points:

| Function | When | Output |
| --- | --- | --- |
| `scene_frame` (required) | every frame | the display (sRGB) |
| `scene_bake` (optional) | once per display and resize | `bg`, rgba16Float, covers the display plus a 56 pt margin for drift |
| `scene_lut` (optional) | every frame, before `scene_frame` | `lut`, a (width × 8) rgba16Float texture. Put anything that depends only on x here, so it's computed per column, not per pixel |

What's in `Uniforms` (see `Common.metal` for the full layout):

- `view`: target size in px, px per point, time
- `motion`: drift, activity, token pulse
- `misc`: brightness, galaxy count, flare count, per-display seed
- `display` and `desk`: this display's rect and the whole desktop's, in global points

`G` holds up to 8 project galaxies (position, size, look, tint). `F` holds 16 flares
(position, start time, size, colour).

Tips: keep per-pixel work in `scene_frame` small, and move anything static into
`scene_bake`. Use `Shaderdesk --snapshot out.png --scene <id> --demo --bench 60` to
render a PNG offscreen and print the median GPU time per frame.

## Data layer

Read incrementally every 2 s, from the local logs only:

- **Claude Code**: `~/.claude/projects/**/*.jsonl`. Assistant `message.usage`, deduped by message id.
- **Codex**: `~/.codex/{sessions,archived_sessions}/**/*.jsonl`. `token_usage_record`,
  deduped by response id, falling back to `token_count` for older logs.
- **Agent processes**: counted by name (claude, codex, aider, gemini, opencode, …).

A session counts as *working* if its log changed in the last 25 s. A project counts as
*active* if any of its sessions changed in the last 15 minutes. Token totals include
cache reads and writes, and reset at local midnight.

## License

MIT, see [LICENSE](LICENSE).
