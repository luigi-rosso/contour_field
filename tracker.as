// Blob detection on the heightmap: samples the visible hemisphere on a grid,
// finds each hill and hollow as the widest island a terrace cliff closes
// around it that is not too big, and tracks them from sweep to sweep under
// stable ids.
// Positions are in disk units, the sphere's radius, with y down.

import { Text } from "rive/text";
import { Field, Orientation, STEP_LINES } from "./field";

const GRID: i32 = 64;
// A sweep spreads its rows over a few frames.
const ROWS_PER_FRAME: i32 = 8;
// Cells past this radius sit on the limb, too foreshortened to trust.
const DISK_LIMIT: f32 = 0.975;
const MIN_CELLS: i32 = 8;
// The largest island kept, as a share of the visible disk.
const MAX_SHARE: f32 = 0.08;
const MAX_TRACKS: i32 = 16;
// How far a blob may move between sweeps and keep its id.
const MATCH_RADIUS: f64 = 0.28;
const LOST_FADE: f64 = 0.3;
// Values a track glides, and how quickly; about a third of a second to settle.
const GLIDES: i32 = 7;
const GLIDE_RATE: f64 = 10;
const FIRST_ID: i32 = 2080;
// Contour levels each side of zero that get a shell of their own.
export function shellLevels(lines: f32): f32 {
    return Mathf.ceil(lines * 0.55);
}

// How high a contour level floats, from 0 on the sphere to 1 at the top
// shell, as in shellRadius in scene.wgsl.
function shellHeight(level: f32, levels: f32): f32 {
    return Mathf.min(Mathf.max(0.5 + 0.5 * level / levels, 0), 1);
}

class Detection {
    x: f64 = 0;
    y: f64 = 0;
    x0: f64 = 0;
    y0: f64 = 0;
    x1: f64 = 0;
    y1: f64 = 0;
    cells: i32 = 0;
    peak: bool = true;
    // How high its bounding contour floats, 0 to 1, and the radius of the
    // shell that puts it on.
    height: f64 = 0;
    lift: f64 = 1;
    track: Track? = null;
}

export class Track {
    id: i32;
    // What is drawn, gliding toward the latest detection's: the centroid, the
    // box's corners and the shell lift.
    private now: StaticArray<f64> = new StaticArray<f64>(GLIDES);
    private goal: StaticArray<f64> = new StaticArray<f64>(GLIDES);
    private rate: StaticArray<f64> = new StaticArray<f64>(GLIDES);
    peak: bool = true;
    height: f64 = 0;
    age: f64 = 0;
    // Seconds since it was last seen, or below zero while seen.
    lost: f64 = -1;
    alpha: f64 = 0;
    // Whether the box is drawn closed rather than as corners.
    framed: bool;
    text: Text = new Text();
    label: string = "";

    constructor(id: i32, d: Detection) {
        this.id = id;
        this.framed = id % 5 == 2;
        this.aim(d);
        for (let i = 0; i < GLIDES; i++) {
            this.now[i] = this.goal[i];
        }
    }

    get x(): f64 {
        return this.now[0];
    }

    get y(): f64 {
        return this.now[1];
    }

    get x0(): f64 {
        return this.now[2];
    }

    get y0(): f64 {
        return this.now[3];
    }

    get x1(): f64 {
        return this.now[4];
    }

    get y1(): f64 {
        return this.now[5];
    }

    get lift(): f64 {
        return this.now[6];
    }

    get tx(): f64 {
        return this.goal[0];
    }

    get ty(): f64 {
        return this.goal[1];
    }

    aim(d: Detection): void {
        let goal = this.goal;
        goal[0] = d.x;
        goal[1] = d.y;
        goal[2] = d.x0;
        goal[3] = d.y0;
        goal[4] = d.x1;
        goal[5] = d.y1;
        goal[6] = d.lift;
        this.peak = d.peak;
        this.height = d.height;
        this.lost = -1;
    }

    // Where the latest detection's centroid sits in artboard points.
    pointX(cx: f64, r: f64): f64 {
        return Math.round(cx + this.goal[0] * r * this.goal[6]);
    }

    pointY(cy: f64, r: f64): f64 {
        return Math.round(cy + this.goal[1] * r * this.goal[6]);
    }

    // A critically damped spring per value, stepped exactly, so a new goal
    // bends the motion rather than kicking it.
    glide(seconds: f64): void {
        let decay = Math.exp(-GLIDE_RATE * seconds);
        for (let i = 0; i < GLIDES; i++) {
            let offset = this.now[i] - this.goal[i];
            let push = (this.rate[i] + GLIDE_RATE * offset) * seconds;
            this.rate[i] = (this.rate[i] - GLIDE_RATE * push) * decay;
            this.now[i] = this.goal[i] + (offset + push) * decay;
        }
    }
}

export class Tracker {
    field: Field = new Field();
    tracks: Array<Track> = [];
    // Bumped whenever a sweep lands, so labels know to refresh.
    sweeps: i32 = 0;
    nextId: i32 = FIRST_ID;
    // Locks lost so far.
    losses: i32 = 0;
    levels: f32 = 17;
    depth: f32 = 0.16;

    private heights: StaticArray<f32> = new StaticArray<f32>(GRID * GRID);
    private inside: StaticArray<bool> = new StaticArray<bool>(GRID * GRID);
    // Which flood last visited each cell, and the cells already inside a blob.
    private labels: StaticArray<i32> = new StaticArray<i32>(GRID * GRID);
    private claimed: StaticArray<bool> = new StaticArray<bool>(GRID * GRID);
    private stamp: i32 = 0;
    private queue: StaticArray<i32> = new StaticArray<i32>(GRID * GRID);
    private pose: Orientation = new Orientation();
    private sweepTime: f32 = 0;
    private row: i32 = GRID;
    private found: Array<Detection> = [];

    // Samples the next rows of the sweep, starting a new one from the field's
    // current time and pose when the last has landed.
    step(time: f32, pose: Orientation): void {
        if (this.row >= GRID) {
            this.row = 0;
            this.sweepTime = time;
            this.pose.copyFrom(pose);
        }
        let field = this.field;
        field.time = this.sweepTime;
        let m = this.pose.m;
        let end = min(this.row + ROWS_PER_FRAME, GRID);
        let limit2 = DISK_LIMIT * DISK_LIMIT;
        for (let j = this.row; j < end; j++) {
            let vy = 1 - (<f32>j + 0.5) / <f32>GRID * 2;
            for (let i = 0; i < GRID; i++) {
                let vx = (<f32>i + 0.5) / <f32>GRID * 2 - 1;
                let r2 = vx * vx + vy * vy;
                let k = j * GRID + i;
                if (r2 >= limit2) {
                    this.inside[k] = false;
                    continue;
                }
                let vz = Mathf.sqrt(1 - r2);
                this.inside[k] = true;
                // In terrace steps, so each cliff's center sits on a half.
                this.heights[k] = field.contour(
                    m[0] * vx + m[3] * vy + m[6] * vz,
                    m[1] * vx + m[4] * vy + m[7] * vz,
                    m[2] * vx + m[5] * vy + m[8] * vz) / STEP_LINES;
            }
        }
        this.row = end;
        if (end >= GRID) {
            this.detect();
        }
    }

    // Locks taken so far.
    get locks(): i32 {
        return this.nextId - FIRST_ID;
    }

    advance(seconds: f64): void {
        let tracks = this.tracks;
        for (let i = tracks.length - 1; i >= 0; i--) {
            let t = tracks[i];
            t.age += seconds;
            t.glide(seconds);
            if (t.lost >= 0) {
                t.lost += seconds;
                t.alpha = Math.max(0, 1 - t.lost / LOST_FADE);
                if (t.lost >= LOST_FADE) {
                    t.text.release();
                    tracks.splice(i, 1);
                }
            } else if (t.age < 0.3) {
                // A new lock blinks in.
                t.alpha = (<i32>(t.age * 22)) % 2 == 0 ? 1.0 : 0.2;
            } else {
                t.alpha = 1;
            }
        }
    }

    clear(): void {
        let tracks = this.tracks;
        for (let i = 0; i < tracks.length; i++) {
            tracks[i].text.release();
        }
        this.tracks = [];
    }

    private detect(): void {
        let count = 0;
        let sum: f32 = 0;
        let tmin: f32 = Infinity;
        let tmax: f32 = -Infinity;
        for (let k = 0; k < GRID * GRID; k++) {
            if (!this.inside[k]) {
                continue;
            }
            let t = this.heights[k];
            tmin = Mathf.min(tmin, t);
            tmax = Mathf.max(tmax, t);
            sum += t;
            count++;
        }
        if (count == 0) {
            return;
        }
        let mean = sum / <f32>count;
        let maxCells = <i32>(<f32>count * MAX_SHARE);
        this.found = [];
        // Cliffs from the outermost in, so each hill keeps the widest ring that
        // fits and the rings inside it are skipped.
        this.unclaim();
        for (let level = Mathf.ceil(mean - 0.5) + 0.5; level < tmax; level += 1) {
            this.sweepLevel(level, 1, maxCells);
        }
        this.unclaim();
        for (let level = Mathf.floor(mean + 0.5) - 0.5; level > tmin; level -= 1) {
            this.sweepLevel(level, -1, maxCells);
        }
        this.match();
        this.sweeps++;
    }

    private unclaim(): void {
        for (let k = 0; k < GRID * GRID; k++) {
            this.claimed[k] = false;
        }
    }

    private within(k: i32, level: f32, side: i32): bool {
        if (!this.inside[k] || this.claimed[k]) {
            return false;
        }
        let t = this.heights[k];
        return side > 0 ? t >= level : t <= level;
    }

    private sweepLevel(level: f32, side: i32, maxCells: i32): void {
        let stamp = ++this.stamp;
        for (let k = 0; k < GRID * GRID; k++) {
            if (this.labels[k] != stamp && this.within(k, level, side)) {
                this.flood(k, stamp, level, side, maxCells);
            }
        }
    }

    // Labels one island by flood fill and keeps it when its size fits.
    private flood(seed: i32, stamp: i32, level: f32, side: i32, maxCells: i32): void {
        let labels = this.labels;
        let queue = this.queue;
        let head = 0;
        let tail = 0;
        queue[tail++] = seed;
        labels[seed] = stamp;
        let imin = GRID;
        let jmin = GRID;
        let imax = -1;
        let jmax = -1;
        let sx: f64 = 0;
        let sy: f64 = 0;
        while (head < tail) {
            let k = queue[head++];
            let i = k % GRID;
            let j = k / GRID;
            imin = min(imin, i);
            imax = max(imax, i);
            jmin = min(jmin, j);
            jmax = max(jmax, j);
            sx += <f64>i;
            sy += <f64>j;
            if (i > 0) tail = this.visit(k - 1, stamp, level, side, tail);
            if (i < GRID - 1) tail = this.visit(k + 1, stamp, level, side, tail);
            if (j > 0) tail = this.visit(k - GRID, stamp, level, side, tail);
            if (j < GRID - 1) tail = this.visit(k + GRID, stamp, level, side, tail);
        }
        if (tail < MIN_CELLS || tail > maxCells) {
            return;
        }
        for (let q = 0; q < tail; q++) {
            this.claimed[queue[q]] = true;
        }
        let cell = 2.0 / <f64>GRID;
        let d = new Detection();
        d.cells = tail;
        d.x = (sx / <f64>tail + 0.5) * cell - 1;
        d.y = (sy / <f64>tail + 0.5) * cell - 1;
        d.x0 = <f64>imin * cell - 1;
        d.y0 = <f64>jmin * cell - 1;
        d.x1 = <f64>(imax + 1) * cell - 1;
        d.y1 = <f64>(jmax + 1) * cell - 1;
        d.peak = side > 0;
        d.height = shellHeight(level * STEP_LINES, this.levels);
        d.lift = 1 + d.height * this.depth;
        this.found.push(d);
    }

    private visit(k: i32, stamp: i32, level: f32, side: i32, tail: i32): i32 {
        if (this.labels[k] == stamp || !this.within(k, level, side)) {
            return tail;
        }
        this.labels[k] = stamp;
        this.queue[tail] = k;
        return tail + 1;
    }

    // Pairs detections with tracks nearest first, starts tracks for the rest
    // and lets the unpaired fade.
    private match(): void {
        let found = this.found;
        found.sort((a: Detection, b: Detection): i32 => b.cells - a.cells);
        if (found.length > MAX_TRACKS) {
            found.length = MAX_TRACKS;
        }
        let tracks = this.tracks;
        let paired = new Array<bool>(tracks.length);
        for (let pass = 0; pass < found.length; pass++) {
            let best = MATCH_RADIUS;
            let bestD = -1;
            let bestT = -1;
            for (let a = 0; a < found.length; a++) {
                let d = found[a];
                if (d.track != null) {
                    continue;
                }
                for (let b = 0; b < tracks.length; b++) {
                    if (paired[b]) {
                        continue;
                    }
                    let t = tracks[b];
                    let dist = Math.hypot(d.x - t.tx, d.y - t.ty);
                    if (dist < best) {
                        best = dist;
                        bestD = a;
                        bestT = b;
                    }
                }
            }
            if (bestD < 0) {
                break;
            }
            paired[bestT] = true;
            let t = tracks[bestT];
            found[bestD].track = t;
            t.aim(found[bestD]);
        }
        for (let b = 0; b < tracks.length; b++) {
            if (!paired[b] && tracks[b].lost < 0) {
                tracks[b].lost = 0;
                this.losses++;
            }
        }
        for (let a = 0; a < found.length; a++) {
            let d = found[a];
            if (d.track == null) {
                tracks.push(new Track(this.nextId++, d));
            }
        }
    }
}
