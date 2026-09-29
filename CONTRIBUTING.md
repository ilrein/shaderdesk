# Contributing to Shaderdesk

The best contribution is a new scene. Bug fixes and performance work are very welcome too.

## Adding a scene

1. **Write it live.** Put `MyScene.metal` in `~/Library/Application Support/Shaderdesk/Scenes/`.
   It shows up in the picker and reloads every time you save. The [README](README.md#writing-a-scene)
   covers the entry points (`scene_frame`, plus optional `scene_bake` and `scene_lut`) and the uniforms.
   [`Scenes/Common.metal`](Scenes/Common.metal) has the shared helpers: tiling noise (`pfbm`),
   `starLayer`, `globalPoint` and `present`.
2. **Add the header** at the top of the file:
   ```metal
   //! title: My Scene
   //! order: 9          // position in the picker
   //! bloom: 0.1        // HDR glow strength (default 0.06)
   //! tags: Neon        // sidebar group(s): Stars, Planets, Exotic, Neon, or a new one
   ```
3. **Move it into `Scenes/`** in your fork and open a PR.

### The quality bar

Scenes are wallpapers. People look at them all day, on everything from a 13" laptop to a 6K display.

- **Looks great at full Retina resolution.** Antialias edges analytically (`fwidth`, or the
  pixel size from `U.view`) and fade detail out before it can shimmer or moiré.
- **Cheap.** Aim for under about 8 ms per frame at 4K on Apple silicon. Put anything static
  into `scene_bake`. Measure with:
  ```sh
  swift build -c release
  .build/release/Shaderdesk --snapshot out.png --scene myscene --size 1920x1080 --scale 2 --no-data --bench 300
  ```
- **No seams in time.** Use the scene clock `U.target.z` (seconds, wrapping at midnight), and
  make every period divide 86,400 so nothing jumps when the day wraps.
- **Lays out per display.** Use `U.display` (the rect in global points) so the composition
  works at any aspect ratio: 16:10, 16:9 and ultrawide.
- **Calm.** Motion should be slow and continuous. No strobing and no sudden flashes.

### Preview clip for the website

Render your scene's looping clip and poster (ffmpeg required), then add an entry to the
`SCENES` list in `docs/index.html` and a line to the README:

```sh
scripts/render-previews.sh myscene   # -> docs/previews/myscene.{mp4,jpg}
```

## Other changes

Keep PRs focused, and describe what you checked (displays, performance, macOS version).
`swift build -c release` must pass. Open an issue first for bigger changes to the app itself.

By contributing, you agree that your work is released under the [MIT License](LICENSE).
