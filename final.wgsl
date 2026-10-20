// Composites bloom over the scene through a lens: radial chromatic aberration
// on both, exposure, ACES, vignette and grain, encoded for the canvas.

struct Grade {
    a: vec4f, // bloom intensity, exposure in stops, vignette, grain
    b: vec4f, // aberration, aberration start radius, seconds, how hard the glow fringes
    c: vec4f, // the intro's shockwave: center in uv, radius in uv heights, strength
    d: vec4f, // the impact's glitch: strength, unused, unused, unused
}

@group(0) @binding(0) var hdr: texture_2d<f32>;
@group(0) @binding(1) var bloom: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@group(0) @binding(3) var<uniform> grade: Grade;

struct VsOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var o: VsOut;
    o.position = vec4f(p[i], 0.0, 1.0);
    o.uv = vec2f(p[i].x + 1.0, 1.0 - p[i].y) * 0.5;
    return o;
}

// Red is magnified most and blue least, so warm fringes land outside bright
// edges and cool ones inside, growing toward the frame's edge.
// How hard edges are sharpened before the bloom is added, and how much the
// lens fringes the scene inside its start radius.
const SHARPEN = 0.8;
const CENTER_FRINGE = 0.2;

// An unsharp mask clamped to the neighborhood, so edges steepen without the
// halos plain sharpening rings around bright lines.
fn sharpened(uv: vec2f) -> vec3f {
    let o = 1.0 / vec2f(textureDimensions(hdr));
    let c = textureSampleLevel(hdr, smp, uv, 0.0).rgb;
    let n = textureSampleLevel(hdr, smp, uv - vec2f(0.0, o.y), 0.0).rgb;
    let s = textureSampleLevel(hdr, smp, uv + vec2f(0.0, o.y), 0.0).rgb;
    let e = textureSampleLevel(hdr, smp, uv + vec2f(o.x, 0.0), 0.0).rgb;
    let w = textureSampleLevel(hdr, smp, uv - vec2f(o.x, 0.0), 0.0).rgb;
    let low = min(c, min(min(n, s), min(e, w)));
    let high = max(c, max(max(n, s), max(e, w)));
    return clamp(c + (c - (n + s + e + w) * 0.25) * SHARPEN, low, high);
}

// The glow spreads through the lens wavelength by wavelength, red the
// farthest, so every bright edge fringes while the lines stay crisp.
const GLOW_TAPS = 6;

fn fringedGlow(uv: vec2f) -> vec3f {
    let spread = (uv - 0.5) * grade.b.w;
    var sum = vec3f(0.0);
    var weight = vec3f(0.0);
    for (var i = 0; i < GLOW_TAPS; i++) {
        let t = f32(i) / f32(GLOW_TAPS - 1);
        let w = clamp(vec3f(1.5 - 2.0 * t, 1.0 - abs(2.0 * t - 1.0), 2.0 * t - 0.5), vec3f(0.0), vec3f(1.0));
        sum += textureSampleLevel(bloom, smp, uv - spread * (1.0 - t), 0.0).rgb * w;
        weight += w;
    }
    return sum / weight;
}

// Where the lens shifts the channels apart it fringes them, and where it
// does not it sharpens; the bloom is added after either.
fn lens(uv: vec2f, shift: vec2f) -> vec3f {
    let fringed = vec3f(
        textureSampleLevel(hdr, smp, uv - shift, 0.0).r,
        textureSampleLevel(hdr, smp, uv - shift * 0.5, 0.0).g,
        textureSampleLevel(hdr, smp, uv, 0.0).b);
    let shiftPx = length(shift * vec2f(textureDimensions(hdr)));
    let scene = mix(sharpened(uv), fringed, smoothstep(0.3, 1.0, shiftPx));
    return scene + fringedGlow(uv) * grade.a.x;
}

fn aces(x: vec3f) -> vec3f {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3f(0.0), vec3f(1.0));
}

fn toSrgb(c: vec3f) -> vec3f {
    return select(1.055 * pow(c, vec3f(1.0 / 2.4)) - 0.055, c * 12.92, c <= vec3f(0.0031308));
}

fn hash(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(12.9898, 78.233))) * 43758.5453);
}

fn hash3(p: vec3f) -> f32 {
    return fract(sin(dot(p, vec3f(12.9898, 78.233, 37.719))) * 43758.5453);
}

// The glitch jumps to a new pattern this many times a second, and does
// nothing at all below MEGA_FLOOR.
const GLITCH_RATE = 24.0;
const MEGA_FLOOR = 0.002;

// Where the impact's glitch moves this pixel: slices torn sideways, blocks
// thrown out of place and the frame rolled, a fresh pattern each step.
fn glitched(uv: vec2f, amount: f32) -> vec2f {
    if (amount < MEGA_FLOOR) {
        return uv;
    }
    let step = floor(grade.b.z * GLITCH_RATE);
    let slices = mix(8.0, 70.0, hash3(vec3f(step, 1.0, 0.0)));
    let slice = floor(uv.y * slices);
    var o = uv;
    if (hash3(vec3f(slice, step, 2.0)) < amount * 0.7) {
        o.x += (hash3(vec3f(slice, step, 3.0)) - 0.5) * amount * 0.35;
    }
    let block = floor(uv * vec2f(16.0, 9.0));
    if (hash3(vec3f(block + step * 0.37, 4.0)) < amount * 0.25) {
        o += (vec2f(hash3(vec3f(block, step + 5.0)), hash3(vec3f(block, step + 6.0))) - 0.5) * amount * 0.2;
    }
    o.y += (hash3(vec3f(step, 7.0, 0.0)) - 0.5) * amount * amount * 0.12;
    return o;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4f {
    let dims = vec2f(textureDimensions(hdr));
    let aspect = dims.x / dims.y;
    let mega = grade.d.x;
    // The intro's shockwave bends the picture as it rolls past.
    let toWave = (in.uv - grade.c.xy) * vec2f(aspect, 1.0);
    let dist = length(toWave);
    let wave = (dist - grade.c.z) / 0.04;
    let bend = toWave / max(dist, 1e-4) * exp(-wave * wave) * grade.c.w * 0.025;
    let uv = glitched(in.uv + bend / vec2f(aspect, 1.0), mega);
    let fromCenter = uv - 0.5;
    let q = fromCenter * vec2f(aspect, 1.0);
    let radius = length(q) / length(vec2f(aspect, 1.0) * 0.5);
    // A little fringe from the middle out, the full lens past the start radius.
    var ramp = mix(CENTER_FRINGE * radius, 1.0, clamp((radius - grade.b.y) / max(1.0 - grade.b.y, 1e-3), 0.0, 1.0));
    // The impact's glitch fringes the whole frame, center and all.
    ramp = mix(ramp, 1.0 + 3.0 * mega, min(mega * 3.0, 1.0));
    let shift = fromCenter * grade.b.x * ramp;
    var c = lens(uv, shift);
    if (mega >= MEGA_FLOOR) {
        // The channels tear apart along the slices.
        let step = floor(grade.b.z * GLITCH_RATE);
        let split = vec2f(mega * 0.03 * (hash3(vec3f(step, 8.0, 0.0)) + 0.5), mega * 0.006 * (hash3(vec3f(step, 10.0, 0.0)) - 0.5));
        c = vec3f(lens(uv + split, shift).r, c.g, lens(uv - split, shift).b);
    }
    c *= exp2(grade.a.y);
    c *= mix(1.0, smoothstep(1.35, 0.2, length(q)), grade.a.z);
    var o = toSrgb(aces(c));
    if (mega >= MEGA_FLOOR) {
        // Scanlines, static and, for the odd step, the whole frame inverted.
        let step = floor(grade.b.z * GLITCH_RATE);
        let line = 0.5 + 0.5 * sin(in.position.y * 1.9);
        o *= 1.0 - mega * 0.35 * line;
        let p = in.position.xy + step * 17.0;
        let colored = vec3f(hash(p), hash(p + 31.7), hash(p + 63.1)) - 0.5;
        o += colored * mega * 0.5;
        // Some slices give way to static altogether.
        let slice = floor(in.uv.y * mix(20.0, 90.0, hash3(vec3f(step, 11.0, 0.0))));
        if (hash3(vec3f(slice, step, 12.0)) < mega * 0.18) {
            o = mix(o, vec3f(hash(p + 5.3)) * vec3f(0.7, 0.85, 1.0), 0.75);
        }
        if (hash3(vec3f(step, 9.0, 0.0)) < mega * 0.3) {
            o = vec3f(1.0) - o;
        }
    }
    let n = hash(in.position.xy + fract(grade.b.z * 7.13) * 91.0);
    o += (n - 0.5) * grade.a.w + (hash(in.position.yx * 1.31) - 0.5) / 255.0;
    return vec4f(o, 1.0);
}
