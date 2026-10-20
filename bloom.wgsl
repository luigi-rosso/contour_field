// Unreal style bloom: a soft threshold into half res, a chain of box
// downsamples to 1/64, then per level a separable gaussian whose vertical pass
// tints the level and adds the next smaller one on top.

struct Params {
    a: vec4f, // blur: uv step along the axis, radius in texels, taps per side. setup: threshold
    b: vec4f, // blur: level tint, weight of the smaller level added in
}

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var<uniform> params: Params;
@group(0) @binding(3) var smaller: texture_2d<f32>;

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

fn luma(c: vec3f) -> f32 {
    return dot(c, vec3f(0.2126, 0.7152, 0.0722));
}

// Four bilinear taps over the 4x4 source texels under one output texel.
fn tap(uv: vec2f, o: vec2f) -> vec3f {
    return textureSampleLevel(src, smp, uv + o, 0.0).rgb;
}

@fragment
fn fs_setup(in: VsOut) -> @location(0) vec4f {
    let o = 1.0 / vec2f(textureDimensions(src));
    let a = tap(in.uv, vec2f(-o.x, -o.y));
    let b = tap(in.uv, vec2f(o.x, -o.y));
    let c = tap(in.uv, vec2f(-o.x, o.y));
    let d = tap(in.uv, vec2f(o.x, o.y));
    // Weighting each tap down by its brightness keeps lone hot sparks from
    // flickering the whole bloom.
    let wa = 1.0 / (1.0 + luma(a));
    let wb = 1.0 / (1.0 + luma(b));
    let wc = 1.0 / (1.0 + luma(c));
    let wd = 1.0 / (1.0 + luma(d));
    let color = (a * wa + b * wb + c * wc + d * wd) / (wa + wb + wc + wd);
    // Unreal's ramp: full bloom two units of luminance past the threshold.
    let amount = clamp((luma(color) - params.a.x) * 0.5, 0.0, 1.0);
    return vec4f(color * amount, 1.0);
}

@fragment
fn fs_down(in: VsOut) -> @location(0) vec4f {
    let o = 1.0 / vec2f(textureDimensions(src));
    let c = tap(in.uv, vec2f(-o.x, -o.y)) + tap(in.uv, vec2f(o.x, -o.y))
        + tap(in.uv, vec2f(-o.x, o.y)) + tap(in.uv, vec2f(o.x, o.y));
    return vec4f(c * 0.25, 1.0);
}

// Gaussian exp(-x^2 / r^2) along one axis, two texels per bilinear tap.
fn gaussian(uv: vec2f) -> vec3f {
    let axis = params.a.xy;
    let inv = 1.0 / (params.a.z * params.a.z);
    let taps = i32(params.a.w);
    var sum = textureSampleLevel(src, smp, uv, 0.0).rgb;
    var total = 1.0;
    for (var i = 1; i <= taps; i += 2) {
        let x0 = f32(i);
        let x1 = x0 + 1.0;
        let w0 = exp(-x0 * x0 * inv);
        let w1 = exp(-x1 * x1 * inv);
        let w = w0 + w1;
        let o = axis * ((x0 * w0 + x1 * w1) / w);
        sum += (textureSampleLevel(src, smp, uv + o, 0.0).rgb + textureSampleLevel(src, smp, uv - o, 0.0).rgb) * w;
        total += 2.0 * w;
    }
    return sum / total;
}

@fragment
fn fs_blur_x(in: VsOut) -> @location(0) vec4f {
    return vec4f(gaussian(in.uv), 1.0);
}

@fragment
fn fs_blur_y(in: VsOut) -> @location(0) vec4f {
    let level = gaussian(in.uv) * params.b.rgb;
    let below = textureSampleLevel(smaller, smp, in.uv, 0.0).rgb * params.b.w;
    return vec4f(level + below, 1.0);
}
