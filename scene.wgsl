// The sphere scene in HDR. Each contour level of the map field.wgsl renders
// floats on its own shell above the sphere, lifted by its height, along with
// a dark backdrop and stateless dust and sparkles built from vertex_index.
// shellRadius() must stay in step with tracker.as.

struct Scene {
    view: vec4f,   // canvas size in px, sphere radius in px, canvas px per point
    center: vec4f, // sphere center in px, field time, seconds
    rotX: vec4f,   // view to object rotation, by column
    rotY: vec4f,
    rotZ: vec4f,
    field: vec4f,  // frequency, warp, contour lines per unit height, detail lines per relief line
    look: vec4f,   // line gain, gain of the far side through the sphere, intro fade, full sphere radius in px
    shell: vec4f,  // depth of the highest level, levels each side of zero, how far the intro has raised them, how far its dust has imploded
    line: vec4f,   // the palette: line colour
    hot: vec4f,    // the white hot cores of bright lines
    glow: vec4f,   // rim, haze and dust
    deep: vec4f,   // backdrop and the sphere's fill
    build: vec4f,  // the intro: scan front in view y, seed flash, shockwave radius in sphere radii, dust burst
}

@group(0) @binding(0) var<uniform> scene: Scene;
// Contour value of the front and back hemisphere, and how brightly each
// stretch of contour glows there.
@group(0) @binding(1) var contourMap: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;

// Overshoots past 1 and settles back.
fn backOut(x: f32) -> f32 {
    let u = x - 1.0;
    return 1.0 + 2.9 * u * u * u + 1.9 * u * u;
}

// The shell a contour level floats on: the lowest on the sphere, the highest
// shell.x radii above it. As the intro raises them, low levels slam up first
// and the peaks last, each overshooting.
fn shellRadius(level: f32) -> f32 {
    let height = clamp(0.5 + 0.5 * level / scene.shell.y, 0.0, 1.0);
    let rise = backOut(clamp(scene.shell.z * 1.4 - height * 0.4, 0.0, 1.0));
    return 1.0 + scene.shell.x * height * rise;
}

// Lines and dust show above the intro's scan front as it sweeps down.
fn scanned(y: f32) -> f32 {
    return smoothstep(scene.build.x, scene.build.x + 0.03, y);
}

fn toView(o: vec3f) -> vec3f {
    return vec3f(dot(scene.rotX.xyz, o), dot(scene.rotY.xyz, o), dot(scene.rotZ.xyz, o));
}

fn toClip(px: vec2f) -> vec4f {
    return vec4f(px.x / scene.view.x * 2.0 - 1.0, 1.0 - px.y / scene.view.y * 2.0, 0.0, 1.0);
}

const HALF_PI = 1.5707963;

// Where the contour map holds the view direction projecting to q in the
// unit disk, y up: its radius is the angle from the view axis, as fs in
// field.wgsl lays it out.
fn mapUv(q: vec2f) -> vec2f {
    let s = min(length(q), 1.0);
    let p = q * (asin(s) / HALF_PI / max(s, 1e-6));
    return vec2f(p.x, -p.y) * 0.5 + 0.5;
}

struct FullOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs_full(@builtin(vertex_index) i: u32) -> FullOut {
    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var o: FullOut;
    o.position = vec4f(p[i], 0.0, 1.0);
    o.uv = vec2f(p[i].x + 1.0, 1.0 - p[i].y) * 0.5;
    return o;
}

@fragment
fn fs_backdrop(in: FullOut) -> @location(0) vec4f {
    let px = in.uv * scene.view.xy;
    // In full sphere radii, so it holds still while the intro scales the
    // sphere in.
    let r = length(px - scene.center.xy) / scene.look.w;
    let corner = length(scene.view.xy) * 0.5 / scene.look.w;
    let fall = clamp(r / corner, 0.0, 1.0);
    var c = mix(scene.deep.rgb, scene.deep.rgb * 0.25, fall);
    c += scene.glow.rgb * scene.glow.rgb * 0.07 * exp(-max(r - 1.0, 0.0) * 4.0);
    c *= scene.look.z;
    // The intro's seed of light, and the shockwave the sphere throws off.
    c += scene.hot.rgb * scene.build.y * (exp(-r * r * 60.0) * 8.0 + exp(-r * 3.0) * 0.12);
    let shock = scene.build.z;
    let ring = (r - shock) * scene.look.w / (10.0 * scene.view.w);
    let wane = pow(clamp(1.0 - shock / 3.5, 0.0, 1.0), 2.0);
    c += scene.glow.rgb * exp(-ring * ring) * select(0.0, wane * 1.4, shock > 0.0);
    return vec4f(c, 1.0);
}

struct SphereOut {
    @builtin(position) position: vec4f,
    @location(0) q: vec2f,
}

// Past the highest shell, wide enough to hold the rim's glow.
const QUAD_MARGIN = 0.12;
// The shells draw on a fan of this many triangles around the disk, which
// shades a fifth fewer pixels than a square would.
const DISK_SEGMENTS = 24u;

@vertex
fn vs_sphere(@builtin(vertex_index) i: u32) -> SphereOut {
    let corner = i % 3u;
    let angle = f32(i / 3u + select(0u, 1u, corner == 2u)) * 6.2831853 / f32(DISK_SEGMENTS);
    // The fan's edges sit outside the circle it has to cover.
    let reach = (1.0 + scene.shell.x + QUAD_MARGIN) / cos(3.14159265 / f32(DISK_SEGMENTS));
    let q = select(vec2f(cos(angle), sin(angle)) * reach, vec2f(0.0), corner == 0u);
    var o: SphereOut;
    o.position = toClip(scene.center.xy + vec2f(q.x, -q.y) * scene.view.z);
    o.q = q;
    return o;
}

// One contour line, d contour units away with fv units per px, width in px.
// Lines packed closer than about two px share their light instead of
// stacking it, so the limb glows instead of shimmering.
// A neon tube: a crisp core with a white hot center, and a halo twice the
// core's width that carries as much light as a tight one would.
fn line(d: f32, fv: f32, width: f32) -> vec2f {
    let px = abs(d) / fv;
    let core = clamp(0.5 * width + 0.5 - px, 0.0, 1.0);
    let center = clamp(0.2 * width + 0.5 - px, 0.0, 1.0);
    let halo = exp(-px * px / (8.0 * width * width)) * 0.125;
    return vec2f(core + halo, center) * min(1.0, 0.6 / fv);
}

// Contour units per px, per pixel rather than per 2x2 block, or arcs near
// the limb, where the slope changes fastest, step in blocks. fwidth's sum of
// both axes would read diagonals up to half again too steep.
fn slope(v: f32) -> f32 {
    return max(length(vec2f(dpdxFine(v), dpdyFine(v))), 1e-4);
}

// Lines thicken by up to this much where the shell turns away from the view.
const LIMB_WIDEN = 1.1;

// facing is the shell's normal toward the view, 1 face on and 0 at the limb.
fn lineColor(level: f32, d: f32, fv: f32, glow: f32, facing: f32) -> vec3f {
    let dpr = scene.view.w;
    let away = 1.0 - facing;
    let width = 1.1 * dpr * (1.0 + LIMB_WIDEN * away * away);
    // Lines brighten where they bunch, per px of separation at 1x.
    let dense = smoothstep(0.015, 0.09, fv / dpr);
    let gain = 0.78 + 0.22 * sin(level * 0.9 + 1.0);
    let tube = line(d, fv, width) * mix(0.32, 1.0, dense) * glow * gain * scene.look.x;
    let i = tube.x;
    return scene.line.rgb * i + scene.hot.rgb * (max(i - 0.9, 0.0) * 0.6 + tube.y * 0.22);
}

@fragment
fn fs_sphere(in: SphereOut) -> @location(0) vec4f {
    let q = in.q;
    let r = length(q);
    let rpx = scene.view.z;
    // The far halves of the shells show faintly through the sphere.
    let behind = select(1.0, scene.look.y, r < 1.0) * scene.glow.rgb;

    // No early outs: the loop's bound is uniform, so derivatives stay legal.
    var c = vec3f(0.0);
    let levels = i32(scene.shell.y);
    for (var k = -levels; k <= levels; k++) {
        let level = f32(k);
        let shell = shellRadius(level);
        let qs = q / shell;
        // Anti-aliased at the shell's silhouette, or every shell steps the rim.
        let on = clamp((1.0 - length(qs)) * shell * rpx + 0.5, 0.0, 1.0);
        let contour = textureSampleLevel(contourMap, smp, mapUv(qs), 0.0);
        let facing = sqrt(max(1.0 - dot(qs, qs), 0.0));
        let front = lineColor(level, contour.x - level, slope(contour.x), contour.z, facing);
        let back = lineColor(level, contour.y - level, slope(contour.y), contour.w, facing);
        // Seen edge on, every shell piles its lines into a band at its own
        // silhouette, and the stacked bands comb the rim.
        let grazing = smoothstep(0.04, 0.28, facing);
        c += (front + back * behind) * on * grazing;
    }
    // Lines appear behind the scan, brightest just past it, with the scan
    // itself a bright band across the shells.
    let fromFront = (q.y - scene.build.x) * rpx / scene.view.w;
    c *= scanned(q.y) * (1.0 + 2.0 * exp(-fromFront * fromFront / 400.0));
    let inside = 1.0 - smoothstep(0.98, 1.0, r);
    c += scene.hot.rgb * exp(-fromFront * fromFront / 4.0) * inside * 1.5;

    let z = sqrt(max(1.0 - r * r, 0.0));
    let base = textureSampleLevel(contourMap, smp, mapUv(q), 0.0);
    var fill = scene.deep.rgb * 0.4;
    fill += scene.deep.rgb * 0.6 * smoothstep(-0.25, 0.35, base.x / scene.field.z);
    fill += scene.glow.rgb * scene.glow.rgb * 0.5 * pow(1.0 - z, 6.0);

    let cover = clamp((1.0 - r) * rpx + 0.5, 0.0, 1.0);
    let edge = (r - 1.0) * rpx;
    let rim = exp(-edge * edge / (2.0 * 1.4 * 1.4 * scene.view.w * scene.view.w));
    // Zero by the quad's edge so no seam shows.
    let reach = scene.shell.x + QUAD_MARGIN;
    let halo = pow(clamp(1.0 - (r - 1.0) / reach, 0.0, 1.0), 3.0) * (1.0 - cover);
    var o = fill * cover + c;
    o += scene.glow.rgb * rim * 0.36;
    o += scene.glow.rgb * scene.glow.rgb * 0.25 * halo;

    return vec4f(o, cover * 0.96);
}

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

fn rand(seed: u32) -> f32 {
    return f32(pcg(seed) >> 8u) / 16777216.0;
}

// The first SPARKS twinkle on the contours; the rest drift off as dust.
const SPARKS = 1400u;

struct DustOut {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f, // along and across the streak, in px from its head
    @location(1) color: vec3f,
    @location(2) shape: vec2f, // streak length and half width, in px
}

@vertex
fn vs_dust(@builtin(vertex_index) vi: u32) -> DustOut {
    let id = vi / 6u;
    var corners = array<vec2f, 6>(
        vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(0.0, 1.0),
        vec2f(0.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
    let corner = corners[vi % 6u];
    let seed = id * 8u;
    let zr = rand(seed) * 2.0 - 1.0;
    let a = rand(seed + 1u) * 6.2831853;
    let s = sqrt(max(1.0 - zr * zr, 0.0));
    let v = toView(vec3f(s * cos(a), s * sin(a), zr));
    let t = scene.center.w;
    let dpr = scene.view.w;

    // Each mote starts on the shell of the contour level under it.
    let contour = textureSampleLevel(contourMap, smp, mapUv(v.xy), 0.0);
    let value = select(contour.y, contour.x, v.z >= 0.0);
    var radius = shellRadius(round(value));
    var bright = 0.0;
    var travel = 0.0;
    let burst = scene.build.w;
    if (id < SPARKS) {
        // Sparkles light up where a contour passes under them.
        let d = abs(fract(value + 0.5) - 0.5);
        let rate = mix(0.2, 0.9, rand(seed + 2u));
        let phase = fract(t * rate + rand(seed + 3u));
        let twinkle = 0.35 + 0.65 * pow(max(sin(phase * 3.14159), 0.0), 6.0);
        bright = exp(-d * d * 60.0) * twinkle * mix(0.5, 2.2, rand(seed + 4u));
    } else {
        let life = mix(1.4, 4.0, rand(seed + 2u));
        let age = fract(t / life + rand(seed + 3u));
        // The intro's burst throws the dust out further as the shells rise.
        let reach = mix(0.01, 0.42, pow(rand(seed + 4u), 4.0)) * (1.0 + 3.0 * burst);
        radius += reach * pow(age, 0.7);
        travel = reach / life * scene.view.z;
        bright = smoothstep(0.0, 0.06, age) * (1.0 - age) * (1.0 - age) * mix(0.35, 1.8, rand(seed + 5u)) * (1.0 + 2.0 * burst);
    }
    let p = v * radius;
    bright *= scanned(p.y) * scene.look.z;
    if (p.z < 0.0 && length(p.xy) < 1.0) {
        bright *= 0.12;
    }
    var head = scene.center.xy + vec2f(p.x, -p.y) * scene.view.z;
    let rl = length(p.xy);
    var dir = select(vec2f(1.0, 0.0), vec2f(p.x, -p.y) / rl, rl > 1e-4);
    // Only the motion across the screen streaks; dust over the disk mostly
    // comes toward the viewer.
    var len = min(travel * rl * 0.06 * dpr + 0.8 * dpr, 8.0 * dpr);

    // The intro's charge: the dust falls in from far out to the seed before
    // the sphere exists, streaking along its fall.
    let charge = scene.shell.w;
    if (charge > 0.0) {
        let outward = vec2f(cos(a), sin(a));
        let far = mix(1.2, 4.5, rand(seed + 7u)) * scene.look.w;
        head = scene.center.xy + outward * far * (1.0 - charge);
        dir = -outward;
        len = min(far * charge * 0.08 + 1.0 * dpr, 60.0 * dpr);
        bright = select(0.0, smoothstep(0.0, 0.25, charge) * mix(0.5, 2.0, rand(seed + 5u)) * (1.0 + 2.0 * charge), id >= SPARKS);
    }
    let side = vec2f(-dir.y, dir.x);
    let width = 0.8 * dpr;
    // Streaks trail back toward the sphere along the way they move.
    let alongPx = corner.x * (len + width * 2.0) - len - width;
    let acrossPx = corner.y * width * 2.0;
    var o: DustOut;
    o.position = toClip(head + dir * alongPx + side * acrossPx);
    o.local = vec2f(alongPx, acrossPx);
    o.color = mix(scene.glow.rgb, scene.hot.rgb, rand(seed + 6u)) * bright;
    o.shape = vec2f(len, width);
    return o;
}

@fragment
fn fs_dust(in: DustOut) -> @location(0) vec4f {
    let len = in.shape.x;
    let w = in.shape.y;
    let behind = clamp(-in.local.x, 0.0, len);
    let d = vec2f(in.local.x + behind, in.local.y);
    let core = exp(-dot(d, d) / (w * w));
    let tail = 1.0 - behind / max(len, 1e-3) * 0.85;
    return vec4f(in.color * core * tail, 0.0);
}
