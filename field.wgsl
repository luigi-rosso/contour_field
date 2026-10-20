// The contour map: the heightmap's contour value over the visible disk, front
// and back hemisphere, laid out by angle from the view axis so it keeps its
// detail out to the limb. scene.wgsl draws the shells from it. Its own module,
// so its pipeline binds only the uniforms. field() and contourValue() must stay
// in step with field.as, which finds blobs on the CPU.

// The leading fields of Scene in scene.wgsl, bound from the same buffer.
struct Scene {
    view: vec4f,
    center: vec4f, // sphere center in px, field time, seconds
    rotX: vec4f,   // view to object rotation, by column
    rotY: vec4f,
    rotZ: vec4f,
    field: vec4f,  // frequency, warp, contour lines per unit height, detail lines per relief line
}

@group(0) @binding(0) var<uniform> scene: Scene;

fn hash3(i: vec3<i32>) -> u32 {
    var h = (bitcast<u32>(i.x) * 0x8da6b343u) ^ (bitcast<u32>(i.y) * 0xd8163841u) ^ (bitcast<u32>(i.z) * 0xcb1ab31fu);
    h = (h ^ (h >> 16u)) * 0x7feb352du;
    h = (h ^ (h >> 15u)) * 0x846ca68bu;
    return h ^ (h >> 16u);
}

// Perlin's twelve cube edge gradients.
fn grad(h: u32, p: vec3f) -> f32 {
    let b = h & 15u;
    let u = select(p.y, p.x, b < 8u);
    let v = select(select(p.z, p.x, b == 12u || b == 14u), p.y, b < 4u);
    return select(-u, u, (b & 1u) == 0u) + select(-v, v, (b & 2u) == 0u);
}

fn noise3(p: vec3f) -> f32 {
    let fl = floor(p);
    let i = vec3<i32>(fl);
    let f = p - fl;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n000 = grad(hash3(i), f);
    let n100 = grad(hash3(i + vec3<i32>(1, 0, 0)), f - vec3f(1.0, 0.0, 0.0));
    let n010 = grad(hash3(i + vec3<i32>(0, 1, 0)), f - vec3f(0.0, 1.0, 0.0));
    let n110 = grad(hash3(i + vec3<i32>(1, 1, 0)), f - vec3f(1.0, 1.0, 0.0));
    let n001 = grad(hash3(i + vec3<i32>(0, 0, 1)), f - vec3f(0.0, 0.0, 1.0));
    let n101 = grad(hash3(i + vec3<i32>(1, 0, 1)), f - vec3f(1.0, 0.0, 1.0));
    let n011 = grad(hash3(i + vec3<i32>(0, 1, 1)), f - vec3f(0.0, 1.0, 1.0));
    let n111 = grad(hash3(i + vec3<i32>(1, 1, 1)), f - vec3f(1.0, 1.0, 1.0));
    let x00 = n000 + (n100 - n000) * u.x;
    let x10 = n010 + (n110 - n010) * u.x;
    let x01 = n001 + (n101 - n001) * u.x;
    let x11 = n011 + (n111 - n011) * u.x;
    let y0 = x00 + (x10 - x00) * u.y;
    let y1 = x01 + (x11 - x01) * u.y;
    return y0 + (y1 - y0) * u.z;
}

// The major peaks and valleys drift this fast per unit of field time, and
// the detail across them flows this fast.
const BASE_DRIFT = 0.15;
const DETAIL_FLOW = 1.5;
// The detail rides a slow stirring flow rather than drifting through the
// noise's own depth, so its rings glide and stretch instead of boiling.
const STIR = 0.9;
const SEEP = 0.25;

// Height on the unit sphere as the major relief, the detail animating over
// it, and the first warp component, which modulates how brightly each
// stretch of a contour glows.
fn field(n: vec3f) -> vec3f {
    let t = scene.center.z;
    let p = n * scene.field.x;
    let q = p * 0.6;
    let drift = t * BASE_DRIFT;
    let w = vec3f(
        noise3(q + vec3f(0.0, 0.0, drift)),
        noise3(q + vec3f(5.2, 1.3, 2.8 - drift)),
        noise3(q + vec3f(-3.7, 2.9 + drift, 7.1)));
    let warped = p + w * scene.field.y;
    var s = warped;
    var base = 0.0;
    var amp = 0.5;
    for (var i = 0; i < 3; i++) {
        base += amp * noise3(s);
        s = s * 2.03 + vec3f(1.7, -3.1, 2.3);
        amp *= 0.45;
    }
    let flow = t * DETAIL_FLOW;
    let sq = q * 1.3;
    let stir = vec3f(
        noise3(sq + vec3f(1.9, 7.3, flow)),
        noise3(sq + vec3f(8.1, -2.4, -flow)),
        noise3(sq + vec3f(-5.5, flow, 4.4)));
    var d = (warped + stir * STIR) * 1.9 + vec3f(0.0, 0.0, flow * SEEP);
    var detail = 0.0;
    amp = 0.5;
    for (var i = 0; i < 2; i++) {
        detail += amp * noise3(d);
        d = d * 2.03 + vec3f(-2.9, 1.1, 0.7);
        amp *= 0.4;
    }
    return vec3f(base, detail, w.x);
}

// Contour lines bunch into bright bundles at the terrace cliffs of the major
// relief, which hold still; the detail added after makes the rings that
// wander across the flat plateaus between them.
const STEP_LINES = 5.0;
const TERRACE = 0.85;
const CLIFF = 0.3;

// Contour value of a field() sample, whole numbers falling on lines.
fn contourValue(h: vec3f) -> f32 {
    let u = h.x * scene.field.z;
    let t = u / STEP_LINES;
    let stepped = floor(t) + smoothstep(0.5 - CLIFF, 0.5 + CLIFF, fract(t));
    return mix(u, stepped * STEP_LINES, TERRACE) + h.y * scene.field.z * scene.field.w;
}

fn toObject(v: vec3f) -> vec3f {
    return scene.rotX.xyz * v.x + scene.rotY.xyz * v.y + scene.rotZ.xyz * v.z;
}

const HALF_PI = 1.5707963;

struct FullOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

@vertex
fn vs(@builtin(vertex_index) i: u32) -> FullOut {
    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var o: FullOut;
    o.position = vec4f(p[i], 0.0, 1.0);
    o.uv = vec2f(p[i].x + 1.0, 1.0 - p[i].y) * 0.5;
    return o;
}

@fragment
fn fs(in: FullOut) -> @location(0) vec4f {
    let p = vec2f(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    let angle = min(length(p), 1.0) * HALF_PI;
    let q = p / max(length(p), 1e-6) * sin(angle);
    let z = cos(angle);
    let front = field(toObject(vec3f(q, z)));
    let back = field(toObject(vec3f(q, -z)));
    return vec4f(
        contourValue(front),
        contourValue(back),
        clamp(0.6 + 0.8 * front.z, 0.25, 1.4),
        clamp(0.6 + 0.8 * back.z, 0.25, 1.4));
}
