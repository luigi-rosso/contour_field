# Notes

How Contour Field works, the knobs worth turning, and what we learned building it.

## The heightmap

`field()` in `field.wgsl` samples classic 3D gradient noise (hashed cube-edge gradients, quintic fade, no textures) at the point on the unit sphere in object space. Rotating the sphere rotates the field with it, with no seams or poles. It is built in layers:

1. **Warp.** Three low-frequency lookups that drift very slowly (`BASE_DRIFT`) push the sample point around. This gives the marbled shapes.
2. **Relief.** 3-octave fBm at the warped point: the major peaks and valleys, which barely move.
3. **Detail.** 2-octave fBm whose input is carried along by another 3D noise "stir" field (`STIR`, `SEEP`, `DETAIL_FLOW`). Features advect instead of boiling in place, which is what makes the motion read as liquid.

`contourValue()` scales the height to 30 lines per unit (`lines`). It terraces the relief with a smoothstep staircase every 5 lines (`STEP_LINES`, `TERRACE`, `CLIFF`), so plateaus flatten and lines bunch at the cliffs between them. The detail is added after the terracing, so its rings wander across the plateaus while the bundles stay put.

## Drawing the contours

There is no line geometry. A field pass writes the contour value of the front and back hemispheres into an `rgba16float` map. The map is laid out by angle from the view axis, so the limb keeps its resolution.

The shell pass loops over the contour levels (about 35). For each one:

- **Placement.** The level floats at radius `1 + depth × height`, and the pixel is projected onto that shell and looked up in the map.
- **Coverage.** The distance to the line in pixels is `(value − level) / |∇value|`, from the exact gradient length (`dpdxFine`, `dpdyFine`). `fwidth` overestimates diagonals by up to √2 and softens them. The line is drawn as a neon tube: a crisp core, a thin white-hot center and a halo twice as wide.
- **Facing.** The shell's normal at the pixel widens lines as the surface turns away (`LIMB_WIDEN`). It also fades them where the shell is seen edge on, because ~35 shells each crowd their lines into a band at their own silhouette and the stacked bands comb the rim.

There is no early-out in the loop. Its bound is uniform, which keeps the derivatives legal.

## Tracking blobs

The GPU canvas has no readback, so the tracker recomputes the field on the CPU. `Field.contour` in `field.as` is a line-for-line copy of `field()` plus `contourValue()`. **Keep the two in step.** The same goes for `shellRadius` in `scene.wgsl` and `tracker.as`, or the boxes slide off the lines.

- **Sweep.** 64 × 64 cells over the visible disk, 8 rows a frame, about 7.5 sweeps a second. Each sweep snapshots the pose and field time.
- **Detect.** From the mean height outward, flood-fill the cells above each cliff level for peaks, and below it for hollows. Keep an island between 8 cells and 8% of the disk, then claim it, so the rings nested inside are skipped. The result is the widest closed ring around each hill or hollow.
- **Track.** Greedy nearest matching keeps ids stable. Boxes glide between sweeps on critically damped springs (`GLIDE_RATE`) and sit on the shell of their bounding contour.
- **List.** Rows append in id order. A lost lock keeps its slot as LOST for 4 s, so the list never reshuffles.

## Post

- **Bloom.** A soft-threshold setup, five downsamples, and six Gaussian levels using Unreal's Bloom1–6 sizes and tints, with the three widest levels tinted by the palette's haze. Unreal's default threshold (0.7) and intensity (1) added only about 2% here, because our lines peak near 1.0 in HDR. We run threshold 0.3 and intensity 4.5 (`post.as`).
- **Chromatic aberration.** The glow gets a strong 6-tap spectral radial fringe from the frame center (`glowAberration`). The scene gets only a little inside the sphere (`CENTER_FRINGE`) and the full lens outside it (`aberrationStart`). Fringing the scene from the center smeared 2 px lines into blur.
- **Sharpen.** A min/max-clamped unsharp mask on the HDR scene, applied before the bloom is added, so the glow stays soft and nothing rings.
- **Glitch.** At the impact, `Grade.d.x` drives slice tears, displaced blocks, a frame roll, an RGB tear, full-frame aberration, colored static, noise slices and the odd inverted frame (`final.wgsl`). It ends outright 0.9 s after the hit.

## The intro

`intro.as` is a pure function of time, so REBUILD only restarts the clock. Its beats are exported constants (`IMPACT`, `SCAN_START`, `RAISE`, `TRACK_AT` and the rest) that the shaders, the panels and the sound all follow.

- **Shaders.** They get the seed flash, shockwave, scan front, shell rise, dust charge and burst, exposure punch, shake and glitch as uniforms.
- **Panels.** RML range mappers on the `build` progress value bring them in. List rows are nested artboards, and neither their panel's opacity nor the list's reaches them, so `blob_list.as` multiplies each row's alpha by `Intro.panel`.

## The sound

`soundtrack.as` is a separate `Node` script, so a host without audio processors loses only the sound. It reads `build`, `palette`, `locks` and `losses` from the view model and listens to the `hoverIn` and `hoverOut` triggers. It sends cues through a shared ring to the `Sound` processor (`audio/sound.as`), and only while the processor publishes blocks, so a browser that holds audio until a gesture gets no backlog.

- **Grid.** 112.5 BPM, anchored on the second hit at 2.25 s, with the impact exactly 3 beats earlier. Intro beats are scheduled on the processor's own sample clock. Locks, losses and palette stabs wait for the next sixteenth; hovers play at once.
- **Voices** (`audio/voices.as`):
  - `Section`: up to 8 unison saws fanned left to right, with a Haas delay into the side and a sub. Used for the braaams, the pad and the stabs.
  - `Mono`: two detuned saws. Used for the arp, the bass and the derez.
  - `Drum`: a pitched membrane, for the timpani and the boom.
  - `Scream`: the Vicious River lead from Reach. A saw stack with an octave under and noise goes through a resonant low pass at 1.5 kHz, then a two-stage tanh at about 43 dB, oversampled 2×, then an ah-to-ae throat. It has two decorrelated takes panned hard.
- **Key.** Each palette is a key (`KEYS`). Every pitch goes through `key`, `degree`, `inKey` or `hzInKey`. A palette change warps the whole mix: a short delay swell of about 9 cents (`WARP_DEPTH`) with a low-pass dip to 1 kHz (`WARP_FLOOR`). The warp filter runs wide open between warps so it never clicks.
- **Master.** The side is cut below 120 Hz and lifted above it. Hits run through a decaying mix saturator (`HIT_DRIVE`, `CRUSH_SECONDS`) into a peak limiter at −1 dBFS.

## Tuning knobs

| Knob | File | Effect |
|---|---|---|
| `DETAIL_FLOW`, `STIR`, `SEEP` | `field.wgsl` and `field.as` | how the interiors flow (change both files) |
| `STEP_LINES`, `TERRACE`, `CLIFF` | `field.wgsl` and `field.as` | how tightly lines bundle at the cliffs |
| `LIMB_WIDEN` | `scene.wgsl` | how much lines thicken toward the limb |
| `tube.y` gain in `lineColor` | `scene.wgsl` | the white-hot core of each line |
| `bloom`, `threshold`, `glowAberration`, `aberrationStart` | `post.as` | glow strength and fringing |
| `SHARPEN`, `CENTER_FRINGE`, `GLITCH_RATE` | `final.wgsl` | edge crispness, fringe on the lines, glitch speed |
| `BUILD_SECONDS` and the beat constants | `intro.as` | intro pacing; the sound follows them |
| `SCREAM_GAIN`, `HIT_DRIVE`, `KEYS`, `WARP_DEPTH`, `VERB_GAIN` | `audio/sound.as` | scream level, hit grit, keys, key-change wobble, reverb |

## Lessons

- **Per-note filter sweeps.** A fast resonant filter envelope on short saw notes reads as a pitch zap ("pew"), and even a gentle one reads as brass. The arp and bass hold their filter still and shape only the amplitude.
- **Mix saturation.** It sounds like clipping. Grit belongs on a voice (the scream's own drive), with the mix saturator kept light.
- **Web runtime.** The CDN web runtime derives automatic bind group layouts module-wide, so every pipeline here uses an explicit `GPUBindGroupLayout.fromShader` layout, and the field pass lives in its own module. That runtime also lacks shared memory and audio, which is why the page is silent.
- **Headless pointers.** `--pointer` coordinates are artboard points at 1x. After the UI was scaled up, Ember sits at (1184, 910).
- **Adaptive resolution.** It must not hunt: each step reallocates the canvas and shows as a pop.
- **Glass.** We tried a refracting glass shell (after the PRISM glass plan) and removed it. The piece reads better without it.

## Checking changes

```sh
rive . --verify                                          # compiles RML, scripts and shaders
rive inspect . --summary                                 # problems must be []
rive . --screenshot=a.png --advance=420 --define=FIXED_RES --compare=b.png
rive . --render-audio --advance=600                      # then check levels and beats
rive . --gpu-manifest=gpu.json                           # replay in Dawn to validate for WebGPU
```

`--gpu-manifest` output replays through the Rive CLI's `tools/webgpu_validate`, which runs Dawn's own pipeline and bind group validation headless. For per-pass GPU time, record a Metal System Trace of `--bench` (passes are labeled) and compare A/B builds inside one trace.
