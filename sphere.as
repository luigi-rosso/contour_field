// A contour sphere: a domain warped heightmap whose iso lines float above a
// dark sphere, each on a shell lifted by its height, dust shed off the
// shells, Unreal style bloom and lens fringing, and a blob tracker locking
// onto the islands the contours enclose. Drag to spin it.

import { Context, Layout } from "rive/host";
import { PointerEvent } from "rive/events";
import { ImageFilter, ImageSampler, ImageWrap } from "rive/image";
import { Mat2D } from "rive/mat2d";
import { BlendMode } from "rive/paint";
import { Renderer } from "rive/renderer";
import { PropertyNumber, PropertyString } from "rive/data";
import { formatFixed, formatInt } from "rive/format";
import {
    GPUBindGroup,
    GPUBindGroupLayout,
    GPUBindGroupSampler,
    GPUBindGroupTexture,
    GPUBindGroupUBO,
    GPUBlendState,
    GPUBuffer,
    GPUCanvas,
    GPUColorAttachment,
    GPUColorTargetDesc,
    GPUPassDesc,
    GPUPipeline,
    GPUPipelineDesc,
    GPUSampler,
    GPUShaderModule,
    GPUTextureView,
} from "rive/gpu";
import { BlendFactor, BufferUsage, Filter, LoadOp, StoreOp, TextureFormat, WrapMode } from "rive/gpu_enums";
import { BlobList } from "./blob_list";
import { Orientation } from "./field";
import { Hud } from "./hud";
import { Intro } from "./intro";
import { DEEP, GLOW, HAZE, HOT, LINE, PaletteMix } from "./palette";
import { HDR, Post, loadShader, renderTexture } from "./post";
import { Tracker, shellLevels } from "./tracker";

const SCENE_FLOATS: i32 = 52;
// Triangles in the fan the shells draw on, as DISK_SEGMENTS in scene.wgsl.
const DISK_SEGMENTS: u32 = 24;
// Sparkles and dust motes, sparkles first as in scene.wgsl.
const PARTICLES: u32 = 1400 + 3200;
// Field time per second at speed 1, and spin in radians per second.
const MORPH: f64 = 0.12;
const SPIN: f64 = 0.06;
// Detail at an input of 1, in contour lines per line of the major relief.
const DETAIL: f64 = 0.16;
const LINE_GAIN: f32 = 1.2;
// The sphere spins in fast as it forms and coasts down to the idle spin.
const INTRO_SPIN: f64 = 1.6;
// Adaptive resolution: once most recent frames run slower than SLOW_FRAME
// the canvas drops a step, down to MIN_SCALE of the display's density, and
// it climbs back after RECOVER seconds of frames keeping up, but never to a
// scale that failed until RETRY seconds pass, so it cannot hunt.
const SLOW_FRAME: f64 = 1.0 / 50;
const MIN_SCALE: f64 = 0.6;
const SCALE_STEP: f64 = 0.1;
const RECOVER: f64 = 3;
const RETRY: f64 = 30;
// A hitch slows the motion for a frame rather than jumping it.
const MAX_STEP: f64 = 1.0 / 30;
const BACK_GAIN: f32 = 0.22;

function blend(src: BlendFactor, dst: BlendFactor, srcAlpha: BlendFactor, dstAlpha: BlendFactor): GPUBlendState {
    let b = new GPUBlendState();
    b.srcColor = src;
    b.dstColor = dst;
    b.srcAlpha = srcAlpha;
    b.dstAlpha = dstAlpha;
    return b;
}

function scenePipeline(shader: GPUShaderModule, vertex: string, fragment: string, layout: GPUBindGroupLayout?, mode: GPUBlendState?): GPUPipeline {
    let target = new GPUColorTargetDesc();
    target.format = HDR;
    target.blend = mode;
    let desc = new GPUPipelineDesc();
    desc.vertexModule = shader;
    desc.vertexEntryPoint = vertex;
    desc.fragmentModule = shader;
    desc.fragmentEntryPoint = fragment;
    desc.colorTargets = [target];
    if (layout != null) {
        desc.bindGroupLayouts = [layout];
    }
    return new GPUPipeline(desc);
}

function clearing(view: GPUTextureView?): GPUColorAttachment {
    let a = new GPUColorAttachment();
    a.view = view;
    a.loadOp = LoadOp.clear;
    a.storeOp = StoreOp.store;
    return a;
}

export class ContourSphere extends Layout {
    @input speed: f64 = 1;
    @input spin: f64 = 1;
    @input lines: f64 = 30;
    @input depth: f64 = 0.16;
    @input detail: f64 = 1;
    @input palette: f64 = 0;
    @input bloom: f64 = 1;
    @input aberration: f64 = 1;
    @input tracking: bool = true;

    // Replays the build sequence from the seed of light.
    @input rebuild(): void {
        this.intro.restart();
        this.tracker.clear();
        this.blobs.clear();
        this.spinY = INTRO_SPIN;
    }

    private context: Context? = null;
    private canvas: GPUCanvas? = null;
    private post: Post? = null;
    private fieldPass: GPUPipeline? = null;
    private backdrop: GPUPipeline? = null;
    private sphere: GPUPipeline? = null;
    private dust: GPUPipeline? = null;
    private sceneLayout: GPUBindGroupLayout? = null;
    private fieldGroup: GPUBindGroup? = null;
    private sceneGroup: GPUBindGroup? = null;
    // The contour value and glow of the heightmap over the disk.
    private contourMap: GPUTextureView? = null;
    private mapSize: u32 = 0;
    private sampler: GPUSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
    private sceneUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, SCENE_FLOATS * 4);
    private sceneData: Float32Array = new Float32Array(SCENE_FLOATS);
    private presentSampler: ImageSampler = ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear);
    private hud: Hud? = null;
    private tracker: Tracker = new Tracker();
    private intro: Intro = new Intro();
    private blobs: BlobList = new BlobList();
    private colors: PaletteMix = new PaletteMix();
    private pose: Orientation = new Orientation();

    private width: f64 = 1;
    private height: f64 = 1;
    // Canvas pixels per artboard point: the display's scale up to 2, times
    // the adaptive render scale.
    private density: f64 = 1;
    private displayDensity: f64 = 1;
    private maxTexture: f64 = 4096;
    private renderScale: f64 = 1;
    // Share of recent frames that ran slow, and how long they have kept up.
    private slowShare: f64 = 0;
    private keptUp: f64 = 0;
    private ceiling: f64 = 1;
    private sinceDrop: f64 = 0;
    private seconds: f64 = 0;
    private fieldTime: f64 = 0;
    // Angular velocity about the view's x and y axes, radians per second.
    private spinX: f64 = 0;
    private spinY: f64 = INTRO_SPIN;
    private dragging: bool = false;
    private dragX: f64 = 0;
    private dragY: f64 = 0;
    private lastX: f64 = 0;
    private lastY: f64 = 0;

    private trackLabel: PropertyString? = null;
    private fieldLabel: PropertyString? = null;
    private clockLabel: PropertyString? = null;
    private paletteLabel: PropertyString? = null;
    // How far the build sequence has run, for the panels to come up on.
    private buildProgress: PropertyNumber? = null;
    // The tracker's locks taken and lost so far, for the sound to cue on.
    private lockCount: PropertyNumber? = null;
    private lossCount: PropertyNumber? = null;
    private bound: bool = false;
    private labelClock: f64 = 0;

    override init(context: Context): bool {
        this.context = context;
        let canvas = context.gpuCanvas();
        if (canvas == null) {
            context.log("no GPU canvas on this host");
            return false;
        }
        this.canvas = canvas;
        // The contour map holds values far past 1, so it needs float targets.
        let features = context.features();
        if (features.known && !features.colorBufferHalfFloat) {
            context.log("needs half float render targets, which this device lacks");
            return false;
        }
        this.maxTexture = <f64>features.maxTextureSize2D;
        let shader = loadShader(context, "scene");
        let layout = GPUBindGroupLayout.fromShader(shader, 0);
        if (layout == null) {
            return false;
        }
        let over = blend(BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendFactor.one, BlendFactor.oneMinusSrcAlpha);
        let add = blend(BlendFactor.one, BlendFactor.one, BlendFactor.zero, BlendFactor.one);
        // The field pass has a module of its own, so its group holds only the
        // uniforms and never the map it renders into. Layouts are explicit
        // throughout, which older runtimes derive differently.
        let fieldShader = loadShader(context, "field");
        let fieldLayout = GPUBindGroupLayout.fromShader(fieldShader, 0);
        if (fieldLayout == null) {
            return false;
        }
        this.fieldPass = scenePipeline(fieldShader, "vs", "fs", fieldLayout, null);
        this.fieldGroup = new GPUBindGroup(fieldLayout, [new GPUBindGroupUBO(0, this.sceneUbo)]);
        this.backdrop = scenePipeline(shader, "vs_full", "fs_backdrop", layout, null);
        this.sphere = scenePipeline(shader, "vs_sphere", "fs_sphere", layout, over);
        this.dust = scenePipeline(shader, "vs_dust", "fs_dust", layout, add);
        this.sceneLayout = layout;
        this.post = new Post(context, <TextureFormat>canvas.format);
        this.hud = new Hud(context.font("JetBrainsMono"));
        this.pose.update();
        return true;
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.width = Math.max(width, 1);
        this.height = Math.max(height, 1);
        // Capped so the canvas never outgrows the device's largest texture.
        let fit = this.maxTexture / Math.max(this.width, this.height);
        this.displayDensity = Math.min(Math.min(Math.max(scale, 1), 2), fit);
        this.density = this.displayDensity * this.renderScale;
    }

    // --define=FIXED_RES pins the resolution, for benchmarks.
    private adaptResolution(seconds: f64): void {
        if (isDefined(FIXED_RES)) {
            return;
        }
        let slow = seconds > SLOW_FRAME;
        this.slowShare += ((slow ? 1.0 : 0.0) - this.slowShare) * 0.1;
        this.keptUp = slow ? 0 : this.keptUp + seconds;
        this.sinceDrop += seconds;
        if (this.sinceDrop > RETRY && this.ceiling < 1) {
            this.ceiling = Math.min(1, this.ceiling + SCALE_STEP);
            this.sinceDrop = 0;
        }
        let scale = this.renderScale;
        if (this.slowShare > 0.6 && scale > MIN_SCALE) {
            scale = Math.max(MIN_SCALE, scale - SCALE_STEP);
            this.ceiling = scale;
            this.sinceDrop = 0;
            this.slowShare = 0;
        } else if (this.keptUp > RECOVER && scale < this.ceiling) {
            scale = Math.min(this.ceiling, scale + SCALE_STEP);
            this.keptUp = 0;
        }
        if (scale != this.renderScale) {
            this.renderScale = scale;
            this.density = this.displayDensity * scale;
        }
    }

    // Sized so the highest shell keeps the same reach whatever the depth.
    private get radius(): f64 {
        return Math.min(this.height * 0.34, this.width * 0.31) / (1 + this.depth);
    }

    override advance(seconds: f64): bool {
        this.seconds += seconds;
        this.adaptResolution(seconds);
        this.intro.advance(seconds);
        let step = Math.min(seconds, MAX_STEP);
        this.fieldTime += step * MORPH * this.speed;
        let pose = this.pose;
        if (this.dragging) {
            // An arcball: the point under the pointer follows it, turning about
            // the view axis across the drag, with screen y pointing down.
            let r = this.radius;
            let dx = this.dragX / r;
            let dy = this.dragY / r;
            pose.turn(dy, dx, 0, Math.sqrt(dx * dx + dy * dy));
            if (seconds > 0) {
                this.spinX += (dy / seconds - this.spinX) * 0.5;
                this.spinY += (dx / seconds - this.spinY) * 0.5;
            }
            this.dragX = 0;
            this.dragY = 0;
        } else {
            // Flicks coast down to the idle turntable spin.
            let ease = 1 - Math.exp(-step * 1.2);
            this.spinX -= this.spinX * ease;
            this.spinY += (SPIN * this.spin - this.spinY) * ease;
            pose.turn(this.spinX, this.spinY, 0, Math.sqrt(this.spinX * this.spinX + this.spinY * this.spinY) * step);
        }

        this.colors.ease(this.palette, seconds);
        this.bindViewModel();

        let tracker = this.tracker;
        tracker.field.lines = <f32>this.lines;
        tracker.field.detail = <f32>(DETAIL * this.detail);
        tracker.levels = shellLevels(tracker.field.lines);
        tracker.depth = <f32>this.depth;
        if (this.tracking && this.intro.tracking) {
            tracker.step(<f32>this.fieldTime, pose);
            tracker.advance(step);
            this.blobs.sync(tracker.tracks, tracker.sweeps, seconds, this.width * 0.5, this.height * 0.5, this.radius, this.intro.panel);
        } else if (tracker.tracks.length > 0) {
            tracker.clear();
            this.blobs.clear();
        }
        let progress = this.buildProgress;
        if (progress != null && progress.value != this.intro.progress) {
            progress.value = this.intro.progress;
        }
        let locks = this.lockCount;
        if (locks != null && locks.value != <f64>tracker.locks) {
            locks.value = tracker.locks;
        }
        let losses = this.lossCount;
        if (losses != null && losses.value != <f64>tracker.losses) {
            losses.value = tracker.losses;
        }
        this.labelClock += seconds;
        if (this.labelClock >= 0.1) {
            this.labelClock = 0;
            this.writeLabels();
        }
        return true;
    }

    // Binds once the view model arrives; it can be missing at init.
    private bindViewModel(): void {
        let context = this.context;
        if (this.bound || context == null) {
            return;
        }
        let vm = context.viewModel();
        if (vm == null) {
            return;
        }
        this.bound = true;
        this.trackLabel = vm.getString("trackLabel");
        this.fieldLabel = vm.getString("fieldLabel");
        this.clockLabel = vm.getString("clockLabel");
        this.paletteLabel = vm.getString("paletteLabel");
        this.blobs.list = vm.getList("blobs");
        this.buildProgress = vm.getNumber("build");
        this.lockCount = vm.getNumber("locks");
        this.lossCount = vm.getNumber("losses");
    }

    private writeLabels(): void {
        let tracker = this.tracker;
        let locked = 0;
        for (let i = 0; i < tracker.tracks.length; i++) {
            if (tracker.tracks[i].lost < 0) {
                locked++;
            }
        }
        let track = this.trackLabel;
        let intro = this.intro;
        if (track != null) {
            if (intro.building) {
                track.value = "BUILD   " + formatInt(intro.progress * 100, 3, true) + "%   " + intro.phase;
            } else {
                track.value = this.tracking
                    ? "BLOB TRACK   " + formatInt(locked, 2, true) + " LOCKED   NEXT " + formatInt(tracker.nextId)
                    : "BLOB TRACK   OFF";
            }
        }
        let field = this.fieldLabel;
        if (field != null) {
            // The iso count climbs as the scan draws the lines in.
            let iso = Math.round(this.lines * intro.scanned);
            field.value = "FBM 3+2 OCT   WARP " + formatFixed(tracker.field.warp, 2) + "   ISO " + formatInt(iso, 2, true) + "   DEPTH " + formatFixed(this.depth * intro.raise, 2);
        }
        let clock = this.clockLabel;
        if (clock != null) {
            let s = this.seconds;
            clock.value = "T+ " + formatInt(Math.floor(s / 60), 2, true) + ":" + formatFixed(s % 60, 2, 5, true);
        }
        let palette = this.paletteLabel;
        if (palette != null) {
            palette.value = "PALETTE   " + this.colors.name;
        }
    }

    private writeScene(pw: u32, ph: u32): void {
        let d = this.sceneData;
        let density = this.density;
        let m = this.pose.m;
        let field = this.tracker.field;
        d[0] = <f32>pw;
        d[1] = <f32>ph;
        let intro = this.intro;
        d[2] = <f32>(this.radius * density * Math.max(intro.form, 0.001));
        d[3] = <f32>density;
        d[4] = <f32>((this.width * 0.5 + this.intro.shakeX) * density);
        d[5] = <f32>((this.height * 0.5 + this.intro.shakeY) * density);
        d[6] = <f32>this.fieldTime;
        d[7] = <f32>this.seconds;
        for (let c = 0; c < 3; c++) {
            d[8 + c * 4] = m[c * 3];
            d[9 + c * 4] = m[c * 3 + 1];
            d[10 + c * 4] = m[c * 3 + 2];
            d[11 + c * 4] = 0;
        }
        d[20] = field.frequency;
        d[21] = field.warp;
        d[22] = <f32>this.lines;
        d[23] = field.detail;
        d[24] = LINE_GAIN * <f32>(1 + 0.6 * intro.burst);
        d[25] = BACK_GAIN;
        d[26] = <f32>intro.fade;
        d[27] = <f32>(this.radius * density);
        d[28] = <f32>this.depth;
        d[29] = this.tracker.levels;
        d[30] = <f32>intro.raise;
        d[31] = <f32>intro.charge;
        let c = this.colors.colors;
        let slots: StaticArray<i32> = [LINE, HOT, GLOW, DEEP];
        for (let s = 0; s < 4; s++) {
            for (let k = 0; k < 3; k++) {
                d[32 + s * 4 + k] = c[slots[s] + k];
            }
            d[35 + s * 4] = 0;
        }
        d[48] = <f32>intro.front;
        d[49] = <f32>intro.flash;
        d[50] = <f32>intro.shock;
        d[51] = <f32>intro.burst;
        this.sceneUbo.update(0, d.buffer);
    }

    // Sizes the map past the sphere's diameter in canvas px, since its layout
    // by angle spreads the middle, where coarser texels make moving lines
    // wobble. Rebinds it.
    private sizeMap(): void {
        let size = <u32>Math.min(Math.max(16, Math.ceil(this.radius * this.density * 2.4)), 4096);
        if (size == this.mapSize) {
            return;
        }
        this.mapSize = size;
        let contour = renderTexture(size, size, HDR).view();
        this.contourMap = contour;
        this.sceneGroup = new GPUBindGroup(
            this.sceneLayout!,
            [new GPUBindGroupUBO(0, this.sceneUbo)],
            [new GPUBindGroupTexture(1, contour)],
            [new GPUBindGroupSampler(2, this.sampler)]);
    }

    override draw(renderer: Renderer): void {
        let canvas = this.canvas;
        let post = this.post;
        if (canvas == null || post == null || this.sceneLayout == null) {
            return;
        }
        let density = this.density;
        let pw = <u32>Math.max(1, Math.floor(this.width * density));
        let ph = <u32>Math.max(1, Math.floor(this.height * density));
        if (canvas.width != pw || canvas.height != ph) {
            canvas.resize(pw, ph);
        }
        post.resize(pw, ph);
        let c = this.colors.colors;
        post.setHaze(c[HAZE], c[HAZE + 1], c[HAZE + 2]);
        this.sizeMap();
        this.writeScene(pw, ph);

        let fieldDesc = new GPUPassDesc();
        fieldDesc.color = [clearing(this.contourMap)];
        fieldDesc.label = "field";
        let fieldPass = canvas.beginRenderPass(fieldDesc);
        fieldPass.setPipeline(this.fieldPass!);
        fieldPass.setBindGroup(0, this.fieldGroup!);
        fieldPass.draw(3);
        fieldPass.finish();

        let desc = new GPUPassDesc();
        desc.color = [clearing(post.scene)];
        desc.label = "scene";
        let pass = canvas.beginRenderPass(desc);
        pass.setBindGroup(0, this.sceneGroup!);
        pass.setPipeline(this.backdrop!);
        pass.draw(3);
        pass.setPipeline(this.sphere!);
        pass.draw(DISK_SEGMENTS * 3);
        pass.setPipeline(this.dust!);
        pass.draw(PARTICLES * 6);
        pass.finish();

        // The intro's hits flare the bloom and exposure, fringe the lens and
        // send a shockwave through the picture.
        let intro = this.intro;
        let p = post.params;
        p.exposure = intro.punch;
        // The intro's glitches fringe the sphere too.
        p.aberrationStart = 0.45 * (1 - Math.min(intro.glitch, 1));
        p.ripple[0] = 0.5 + intro.shakeX / this.width;
        p.ripple[1] = 0.5 + intro.shakeY / this.height;
        p.ripple[2] = intro.shock * this.radius / this.height;
        p.ripple[3] = intro.ripple;
        p.glitch = intro.mega;
        post.render(canvas, this.seconds,
            this.bloom * (1 + 0.6 * intro.flash + 0.8 * intro.burst),
            this.aberration * (1 + 6 * intro.glitch));

        renderer.save();
        renderer.transform(Mat2D.withUniformScale(<f32>(1.0 / density)));
        renderer.drawImage(canvas.image, this.presentSampler, BlendMode.srcOver, 1);
        renderer.restore();

        let hud = this.hud;
        if (hud != null && this.tracking && intro.tracking) {
            hud.draw(renderer, this.tracker.tracks, this.tracker.sweeps, this.width * 0.5, this.height * 0.5, this.radius);
        }
    }

    // Only presses on the sphere spin it, so the panels keep their scrolls
    // and clicks.
    override pointerDown(event: PointerEvent): void {
        let x = event.position.x;
        let y = event.position.y;
        let reach = this.radius * (1 + this.depth);
        if (Math.hypot(x - this.width * 0.5, y - this.height * 0.5) > reach) {
            return;
        }
        this.dragging = true;
        this.lastX = x;
        this.lastY = y;
        event.hit();
    }

    override pointerMove(event: PointerEvent): void {
        if (!this.dragging) {
            return;
        }
        this.dragX += event.position.x - this.lastX;
        this.dragY += event.position.y - this.lastY;
        this.lastX = event.position.x;
        this.lastY = event.position.y;
        event.hit();
    }

    override pointerUp(event: PointerEvent): void {
        if (this.dragging) {
            this.dragging = false;
            event.hit();
        }
    }
}
