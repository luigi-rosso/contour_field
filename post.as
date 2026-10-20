// Unreal style post: the scene renders into an HDR target, bloom runs as six
// gaussian levels from half res to 1/64 with Unreal's default sizes and tints,
// then final.wgsl composites it through the lens into the canvas.

import { Context } from "rive/host";
import {
    GPUBindGroup,
    GPUBindGroupLayout,
    GPUBindGroupSampler,
    GPUBindGroupTexture,
    GPUBindGroupUBO,
    GPUBuffer,
    GPUCanvas,
    GPUColorAttachment,
    GPUColorTargetDesc,
    GPUPassDesc,
    GPUPipeline,
    GPUPipelineDesc,
    GPUSampler,
    GPUShaderModule,
    GPUTexture,
    GPUTextureDesc,
    GPUTextureView,
} from "rive/gpu";
import { BufferUsage, Filter, LoadOp, StoreOp, TextureFormat, WrapMode } from "rive/gpu_enums";

const LEVELS: i32 = 6;
// Unreal's Bloom1Size..Bloom6Size, percent of a level's width before
// BloomSizeScale, and Bloom1Tint..Bloom6Tint.
const SIZES: StaticArray<f32> = [0.3, 1, 2, 10, 30, 64];
const TINTS: StaticArray<f32> = [0.3465, 0.138, 0.1176, 0.066, 0.066, 0.061];
const SIZE_SCALE: f32 = 4;
const MAX_TAPS: f32 = 64;

export const HDR: TextureFormat = TextureFormat.rgba16float;

export function renderTexture(width: u32, height: u32, format: TextureFormat): GPUTexture {
    let desc = new GPUTextureDesc();
    desc.width = max<u32>(width, 1);
    desc.height = max<u32>(height, 1);
    desc.format = format;
    desc.renderTarget = true;
    return new GPUTexture(desc);
}

export function loadShader(context: Context, name: string): GPUShaderModule {
    let shader = context.shader(name);
    if (shader == null) {
        throw new Error("missing shader " + name);
    }
    return shader;
}

function fullscreen(shader: GPUShaderModule, entry: string, format: TextureFormat, layout: GPUBindGroupLayout? = null): GPUPipeline {
    let target = new GPUColorTargetDesc();
    target.format = format;
    let desc = new GPUPipelineDesc();
    desc.vertexModule = shader;
    desc.vertexEntryPoint = "vs";
    desc.fragmentModule = shader;
    desc.fragmentEntryPoint = entry;
    desc.colorTargets = [target];
    if (layout != null) {
        desc.bindGroupLayouts = [layout];
    }
    return new GPUPipeline(desc);
}

export class PostParams {
    // Our lines peak near 1 in HDR, far below the emissive levels Unreal's
    // defaults assume, so the glow needs a low threshold and a high intensity.
    bloom: f64 = 4.5;
    threshold: f64 = 0.3;
    exposure: f64 = 0.0;
    vignette: f64 = 0.5;
    grain: f64 = 0.018;
    // Per channel uv scale at the frame's corner.
    aberration: f64 = 0.022;
    // Where the fringing starts, as a share of the way to the frame's corner:
    // just outside the sphere, so its lines stay crisp.
    aberrationStart: f64 = 0.45;
    // How far the glow's red spreads from its blue, in uv per uv from the
    // center; the glow fringes from the middle out, unlike the scene.
    glowAberration: f64 = 0.07;
    // The intro's shockwave: center in uv, radius in uv heights, strength.
    ripple: StaticArray<f64> = [0, 0, 0, 0];
    // The impact's screen glitch, 0 for none.
    glitch: f64 = 0;
}

class Level {
    down: GPUTextureView;
    across: GPUTextureView;
    bloom: GPUTextureView;
    blurX: GPUBuffer = new GPUBuffer(BufferUsage.uniform, 32);
    blurY: GPUBuffer = new GPUBuffer(BufferUsage.uniform, 32);

    constructor(width: u32, height: u32) {
        this.down = renderTexture(width, height, HDR).view();
        this.across = renderTexture(width, height, HDR).view();
        this.bloom = renderTexture(width, height, HDR).view();
    }
}

export class Post {
    params: PostParams = new PostParams();
    width: u32 = 0;
    height: u32 = 0;
    scene: GPUTextureView? = null;

    private sampler: GPUSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
    private setupUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, 32);
    private gradeUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, 64);
    private gradeData: Float32Array = new Float32Array(16);
    private data: Float32Array = new Float32Array(8);
    private setup: GPUPipeline;
    private down: GPUPipeline;
    private blurX: GPUPipeline;
    private blurY: GPUPipeline;
    private final: GPUPipeline;
    private bloomLayout: GPUBindGroupLayout;
    private levels: Array<Level> = [];
    private groups: Array<GPUBindGroup> = [];
    // The tint of the three widest levels, the haze around the sphere.
    private haze: StaticArray<f32> = [1, 1, 1];

    constructor(context: Context, canvasFormat: TextureFormat) {
        let bloom = loadShader(context, "bloom");
        let layout = GPUBindGroupLayout.fromShader(bloom, 0);
        if (layout == null) {
            throw new Error("bloom layout refused");
        }
        this.bloomLayout = layout;
        this.setup = fullscreen(bloom, "fs_setup", HDR, layout);
        this.down = fullscreen(bloom, "fs_down", HDR, layout);
        this.blurX = fullscreen(bloom, "fs_blur_x", HDR, layout);
        this.blurY = fullscreen(bloom, "fs_blur_y", HDR, layout);
        this.final = fullscreen(loadShader(context, "final"), "fs", canvasFormat);
    }

    resize(width: u32, height: u32): void {
        if (width == this.width && height == this.height) {
            return;
        }
        this.width = width;
        this.height = height;
        let scene = renderTexture(width, height, HDR).view();
        this.scene = scene;
        let levels = new Array<Level>();
        for (let i = 0; i < LEVELS; i++) {
            let shift = <u32>(i + 1);
            levels.push(new Level(max<u32>(width >> shift, 1), max<u32>(height >> shift, 1)));
        }
        this.levels = levels;
        this.writeBlurs();

        let g = new Array<GPUBindGroup>();
        g.push(this.group(scene, null, this.setupUbo));
        for (let i = 1; i < LEVELS; i++) {
            g.push(this.group(levels[i - 1].down, null, null));
        }
        for (let i = LEVELS - 1; i >= 0; i--) {
            let level = levels[i];
            // The smallest level adds nothing; its weight is zero.
            let smaller = i < LEVELS - 1 ? levels[i + 1].bloom : level.down;
            g.push(this.group(level.down, null, level.blurX));
            g.push(this.group(level.across, smaller, level.blurY));
        }
        g.push(this.finalGroup(scene, levels[0].bloom));
        this.groups = g;
    }

    setHaze(r: f32, g: f32, b: f32): void {
        let haze = this.haze;
        if (Mathf.abs(haze[0] - r) + Mathf.abs(haze[1] - g) + Mathf.abs(haze[2] - b) < 1e-3) {
            return;
        }
        haze[0] = r;
        haze[1] = g;
        haze[2] = b;
        this.writeBlurs();
    }

    private writeBlurs(): void {
        let d = this.data;
        let levels = this.levels;
        for (let i = 0; i < levels.length; i++) {
            let w = max<u32>(this.width >> <u32>(i + 1), 1);
            let h = max<u32>(this.height >> <u32>(i + 1), 1);
            // Unreal's GetBlurRadius: the kernel's diameter is a percentage of
            // the level's own width, clamped to what the taps can reach.
            let radius = Mathf.min(<f32>w * SIZES[i] * SIZE_SCALE * 0.01 * 0.5, MAX_TAPS - 1);
            let taps = Mathf.min(Mathf.ceil(radius * 1.5), MAX_TAPS);
            // Sigma is half the radius; the shader takes exp(-x^2 / r^2).
            let r = Mathf.max(radius * 0.7071, 0.5);
            let level = levels[i];
            d[0] = 1 / <f32>w;
            d[1] = 0;
            d[2] = r;
            d[3] = taps;
            d[4] = 1;
            d[5] = 1;
            d[6] = 1;
            d[7] = 0;
            level.blurX.update(0, d.buffer);
            d[0] = 0;
            d[1] = 1 / <f32>h;
            let haze = i >= 3;
            d[4] = TINTS[i] * (haze ? this.haze[0] : 1);
            d[5] = TINTS[i] * (haze ? this.haze[1] : 1);
            d[6] = TINTS[i] * (haze ? this.haze[2] : 1);
            d[7] = i < LEVELS - 1 ? 1 : 0;
            level.blurY.update(0, d.buffer);
        }
    }

    // Bindings follow bloom.wgsl: source, sampler, params, smaller level.
    // Every pass shares the module's whole layout, so a pass that reads no
    // params or smaller level is handed stand-ins it never touches.
    private group(src: GPUTextureView, smaller: GPUTextureView?, ubo: GPUBuffer?): GPUBindGroup {
        return new GPUBindGroup(
            this.bloomLayout,
            [new GPUBindGroupUBO(2, ubo != null ? ubo : this.setupUbo)],
            [new GPUBindGroupTexture(0, src), new GPUBindGroupTexture(3, smaller != null ? smaller : src)],
            [new GPUBindGroupSampler(1, this.sampler)]);
    }

    private finalGroup(scene: GPUTextureView, bloom: GPUTextureView): GPUBindGroup {
        return new GPUBindGroup(
            this.final.getBindGroupLayout(0),
            [new GPUBindGroupUBO(3, this.gradeUbo)],
            [new GPUBindGroupTexture(0, scene), new GPUBindGroupTexture(1, bloom)],
            [new GPUBindGroupSampler(2, this.sampler)]);
    }

    private writeParams(seconds: f64, bloom: f64, aberration: f64): void {
        let p = this.params;
        let d = this.data;
        d[0] = <f32>p.threshold;
        for (let i = 1; i < 8; i++) {
            d[i] = 0;
        }
        this.setupUbo.update(0, d.buffer);
        let g = this.gradeData;
        g[0] = <f32>(p.bloom * bloom);
        g[1] = <f32>p.exposure;
        g[2] = <f32>p.vignette;
        g[3] = <f32>p.grain;
        g[4] = <f32>(p.aberration * aberration);
        g[5] = <f32>p.aberrationStart;
        g[6] = <f32>seconds;
        // Held to a few times its own, or the intro's glitches smear the glow
        // across the frame.
        g[7] = <f32>(p.glowAberration * Math.min(aberration, 2));
        for (let i = 0; i < 4; i++) {
            g[8 + i] = <f32>p.ripple[i];
            g[12 + i] = 0;
        }
        g[12] = <f32>p.glitch;
        this.gradeUbo.update(0, g.buffer);
    }

    private pass(canvas: GPUCanvas, view: GPUTextureView?, pipeline: GPUPipeline, group: GPUBindGroup, label: string): void {
        let attachment = new GPUColorAttachment();
        attachment.view = view;
        attachment.loadOp = LoadOp.clear;
        attachment.storeOp = StoreOp.store;
        let desc = new GPUPassDesc();
        desc.color = [attachment];
        desc.label = label;
        let pass = canvas.beginRenderPass(desc);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.draw(3);
        pass.finish();
    }

    // Bloom and aberration scale the params, as the scene's inputs do.
    render(canvas: GPUCanvas, seconds: f64, bloom: f64, aberration: f64): void {
        if (this.groups.length == 0) {
            return;
        }
        this.writeParams(seconds, bloom, aberration);
        let g = this.groups;
        let levels = this.levels;
        let k = 0;
        this.pass(canvas, levels[0].down, this.setup, g[k++], "bloom setup");
        for (let i = 1; i < LEVELS; i++) {
            this.pass(canvas, levels[i].down, this.down, g[k++], "bloom down");
        }
        for (let i = LEVELS - 1; i >= 0; i--) {
            this.pass(canvas, levels[i].across, this.blurX, g[k++], "bloom blur x");
            this.pass(canvas, levels[i].bloom, this.blurY, g[k++], "bloom blur y");
        }
        this.pass(canvas, null, this.final, g[k++], "final");
    }
}
