# Contour Field

A glowing contour-line sphere with a blob tracking HUD and a synth score, built with the Rive CLI from AnimaScript, WGSL on a GPU canvas, and RML.

- **The field.** A domain-warped, terraced heightmap made of 3D gradient noise. Its major peaks and valleys hold still while the detail inside them flows. Each contour level floats on its own shell above the sphere, lifted by its height. Lines bunch into bright bundles at the terrace cliffs, thicken as the surface turns away and fade where a shell is seen edge on.
- **The tracker.** A CPU copy of the same heightmap is swept on a grid. The widest closed contour ring around each hill and hollow is kept and tracked under a stable id, then drawn as brackets, crosshairs, links and `id  x, y` labels.
- **The look.** Unreal-style bloom, chromatic aberration on the glow with a little on the lines, a clamped sharpen, ACES, vignette and grain. GPU dust and sparkles sit on the contours under them.
- **The intro.** A 4.6 s build sequence:
  1. Dust implodes into a seed of light.
  2. The sphere slams out of it on a shockwave, with a full-screen glitch.
  3. A scan sweeps the contours in.
  4. The shells slam up as the dust erupts.
  5. The tracker locks on while the panels snap in.
- **The sound.** A Tron Legacy-style score on a 112.5 BPM grid locked to the intro's beats. It has unison saw braaams, synth timpani and a screaming lead hit (a port of the Vicious River lead from our Reach project), then an evolving arp, bass and pumping pad. Locks, losses and hovers blip. Each palette is its own key, and switching palettes slides the score into the new key under a low-pass dip.
- **The panels.** RML on the right: a scrolling list of tracked blobs, and a palette chooser.

## Controls

- **Drag the sphere** to spin it. The arcball keeps the surface under the pointer, and a flick coasts back to the idle spin.
- **Swatches** (bottom right) recolor everything and change the key.
- **REBUILD** (bottom left) replays the intro.
- **Hovering** a button blips as the pointer enters and bloops as it leaves.

## Run

You need a Rive CLI build with AnimaScript threading and audio processors.

```sh
rive .                                  # live window that rebuilds on save
rive . --screenshot --advance=300       # headless capture to build/
rive . --render-audio --advance=600     # headless 10 s of the sound to build/
rive . --publish=web                    # sign and publish the page (rive.yaml names it)
```

Set `RIVE_WAMRC` to a `wamrc` binary to run the scripts compiled ahead of time. Without it they run on the interpreter, which still keeps up.

The published web page currently plays silently, because the web runtime has no AnimaScript audio yet. Only the sound script fails there; the visuals and panels run.

## Inputs

These live on the `Field` view model, so they can be set from the editor or with `--data=<name>=<value>`, for example `--data=depth=0.25`.

| Name | Default | Effect |
|---|---|---|
| `speed` | 1 | how fast the detail flows and the relief drifts |
| `detail` | 1 | how strongly the flowing detail reshapes the interiors; 0 leaves only the relief |
| `spin` | 1 | idle rotation speed |
| `lines` | 30 | contour lines per unit of height |
| `depth` | 0.16 | how far the highest contour floats off the sphere, in radii |
| `palette` | 0 | Cobalt, Ember, Aurora, Ultraviolet or Ivory (0 to 4), which also picks D, F, C, G or B minor |
| `bloom` | 1 | bloom intensity scale |
| `aberration` | 1 | chromatic aberration scale |
| `tracking` | true | blob tracking overlay |

## Files

| File | Holds |
|---|---|
| `scene.rml` | the artboard, captions, blob list and palette panels, listeners, and the `Field` view model bound to the scripts |
| `blob_row.rml` | the `BlobRow` list component and its `Blob` view model |
| `sphere.as` | the `ContourSphere` layout: the GPU passes, the arcball, adaptive resolution and the view model labels |
| `field.wgsl`, `field.as` | the heightmap on the GPU, and its CPU copy for the tracker |
| `scene.wgsl` | the contour shells, backdrop and dust |
| `post.as`, `bloom.wgsl`, `final.wgsl` | HDR targets, the bloom chain, and the lens and glitch composite |
| `tracker.as`, `hud.as`, `blob_list.as` | blob detection and tracking, the overlay, and the list the panel repeats |
| `intro.as` | the build sequence's timeline, which the shaders, panels and sound all follow |
| `palette.as` | the palettes and their crossfade |
| `soundtrack.as`, `audio/` | the sound: a script of its own that cues a synth processor from the view model |
| `assets/` | JetBrains Mono, under the SIL Open Font License (`OFL-JetBrainsMono.txt`) |

`NOTES.md` covers how each part works, the tuning knobs and what we learned building it.

## Performance

On an Apple silicon Mac at 2x (a 2800 × 2000 canvas), a frame costs about 1 ms of GPU time. The scripts take about 0.2 ms per frame compiled, or about 0.8 ms on the interpreter. The sound processor uses a few percent of a core compiled.

When most recent frames run slower than 50 fps, the canvas steps its resolution down to as low as 60% of the display density. It climbs back once frames keep up, and never retries a failed step for 30 s. `--define=FIXED_RES` pins the resolution for benchmarks.
