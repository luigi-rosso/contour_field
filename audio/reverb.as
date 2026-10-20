// The music tray's shimmer reverb without its octave shifter, eight damped
// and modulated delay lines mixed through a Hadamard matrix.

import { Noise } from "./synth_kernel";

const kPi: f32 = 3.14159265358979;

// A power of two ring read at whole and at fractional delays; at(1) is the
// sample pushed last. Fractional reads are four point Hermite.
export class Line {
    b: StaticArray<f32> = new StaticArray<f32>(0);
    mask: u32 = 0;
    w: u32 = 0;

    init(seconds: f32, rate: f32): void {
        let want = <u32>(seconds * rate) + 8;
        let size: u32 = 1;
        while (size < want) {
            size <<= 1;
        }
        this.b = new StaticArray<f32>(<i32>size);
        this.mask = size - 1;
        this.w = 0;
    }

    @unchecked
    push(v: f32): void {
        this.b[<i32>(this.w & this.mask)] = v;
        this.w++;
    }

    @unchecked
    at(d: u32): f32 {
        return this.b[<i32>((this.w - d) & this.mask)];
    }

    @unchecked
    frac(d: f32): f32 {
        let i = <u32>d;
        let t: f32 = d - <f32>i;
        let pm1 = this.at(i - 1);
        let p0 = this.at(i);
        let p1 = this.at(i + 1);
        let p2 = this.at(i + 2);
        let c1: f32 = <f32>0.5 * (p1 - pm1);
        let c2: f32 = pm1 - <f32>2.5 * p0 + <f32>2 * p1 - <f32>0.5 * p2;
        let c3: f32 = <f32>0.5 * (p2 - pm1) + <f32>1.5 * (p0 - p1);
        return ((c3 * t + c2) * t + c1) * t + p0;
    }
}

export class OnePole {
    z: f32 = 0;
    a: f32 = 1;

    set(hz: f32, rate: f32): void {
        this.a = <f32>1 - Mathf.exp(<f32>-2 * kPi * hz / rate);
    }

    lp(x: f32): f32 {
        this.z += (x - this.z) * this.a;
        return this.z;
    }

    hp(x: f32): f32 {
        return x - this.lp(x);
    }
}

// A random target held for a random while and eased toward through two one
// poles, so the delay it drives and that delay's slope are both continuous
// and nothing ever repeats.
class Wander {
    rng: Noise = new Noise();
    y1: f32 = 0;
    y2: f32 = 0;
    target: f32 = 0;
    a: f32 = 0;
    left: u32 = 1;
    hold: u32 = 1;

    set(holdSeconds: f32, hz: f32, seed: u32, rate: f32): void {
        this.hold = <u32>(holdSeconds * rate);
        this.a = <f32>1 - Mathf.exp(<f32>-2 * kPi * hz / rate);
        this.rng.seed(seed);
        this.target = this.rng.next();
        this.y1 = this.target;
        this.y2 = this.target;
    }

    tick(): f32 {
        if (--this.left == 0) {
            this.target = this.rng.next();
            this.left = <u32>(<f32>this.hold * (<f32>0.5 + this.rng.unit())) + 1;
        }
        this.y1 += (this.target - this.y1) * this.a;
        this.y2 += (this.y1 - this.y2) * this.a;
        return this.y2;
    }
}

// A Schroeder allpass whose read can be moved.
class Allpass {
    line: Line = new Line();
    g: f32 = 0.6;
    d: f32 = 100;

    init(ms: f32, gain: f32, rate: f32): void {
        this.line.init(ms * <f32>0.001 + <f32>0.01, rate);
        this.d = ms * <f32>0.001 * rate;
        this.g = gain;
    }

    tick(x: f32, move: f32): f32 {
        let z = this.line.frac(this.d + move);
        let v: f32 = x + this.g * z;
        this.line.push(v);
        return z - this.g * v;
    }
}

// Four allpasses in series, two of them wandering, that smear whatever goes
// round the loop a little more each pass.
class Diffuser {
    ap: StaticArray<Allpass> = [new Allpass(), new Allpass(), new Allpass(), new Allpass()];
    w: StaticArray<Wander> = [new Wander(), new Wander()];
    move: f32 = 0;

    init(ms: StaticArray<f32>, seed: u32, rate: f32): void {
        for (let k = 0; k < 4; k++) {
            this.ap[k].init(ms[k], 0.62, rate);
        }
        this.w[0].set(0.9, 0.8, seed, rate);
        this.w[1].set(1.3, 0.8, seed * 7 + 1, rate);
        this.move = <f32>0.00025 * rate;
    }

    tick(x: f32): f32 {
        x = this.ap[0].tick(x, 0);
        x = this.ap[1].tick(x, this.move * this.w[0].tick());
        x = this.ap[2].tick(x, 0);
        return this.ap[3].tick(x, this.move * this.w[1].tick());
    }
}

// A line's loss each pass: its decay time at DC and a shorter one at the top,
// as a one pole (Jot's absorption filter), so highs die sooner but evenly.
class Absorb {
    b: f32 = 1;
    p: f32 = 0;
    z: f32 = 0;

    set(samples: f32, lowSeconds: f32, highSeconds: f32, rate: f32): void {
        let g = Mathf.pow(10, <f32>-3.0 * samples / (lowSeconds * rate));
        let top = Mathf.pow(10, <f32>-3.0 * samples / (highSeconds * rate));
        let ratio = top / g;
        this.p = (<f32>1 - ratio) / (<f32>1 + ratio);
        this.b = g * (<f32>1 - this.p);
    }

    tick(x: f32): f32 {
        this.z = this.b * x + this.p * this.z;
        return this.z;
    }
}

export class Reverb {
    line: StaticArray<Line> = new StaticArray<Line>(8);
    damp: StaticArray<Absorb> = new StaticArray<Absorb>(8);
    w: StaticArray<Wander> = new StaticArray<Wander>(8);
    len: StaticArray<f32> = new StaticArray<f32>(8);
    inL: Diffuser = new Diffuser();
    inR: Diffuser = new Diffuser();
    pre: Line = new Line();
    y: StaticArray<f32> = new StaticArray<f32>(8);
    h: StaticArray<f32> = new StaticArray<f32>(8);
    depth: f32 = 0;
    tapA: u32 = 0;
    tapB: u32 = 0;
    // The last tick's output.
    wetL: f32 = 0;
    wetR: f32 = 0;

    init(decaySeconds: f32, rate: f32): void {
        const ms: StaticArray<f32> = [31.7, 37.3, 41.9, 47.7, 53.3, 59.9, 67.1, 73.9];
        for (let i = 0; i < 8; i++) {
            let line = new Line();
            line.init(ms[i] * <f32>0.001 + <f32>0.01, rate);
            this.line[i] = line;
            this.len[i] = ms[i] * <f32>0.001 * rate;
            let damp = new Absorb();
            damp.set(this.len[i], decaySeconds, decaySeconds * <f32>0.3, rate);
            this.damp[i] = damp;
            let w = new Wander();
            w.set(<f32>0.6 + <f32>0.21 * <f32>i, 0.4, <u32>(9001 + 77 * i), rate);
            this.w[i] = w;
        }
        const left: StaticArray<f32> = [4.77, 7.31, 11.03, 17.57];
        const right: StaticArray<f32> = [5.19, 7.93, 12.41, 16.69];
        this.inL.init(left, 31, rate);
        this.inR.init(right, 59, rate);
        this.pre.init(0.05, rate);
        this.depth = <f32>0.0004 * rate;
        this.tapA = <u32>(<f32>0.025 * rate);
        this.tapB = <u32>(<f32>0.031 * rate);
    }

    @unchecked
    tick(l: f32, r: f32): void {
        let a = this.inL.tick(this.pre.at(this.tapA));
        let b = this.inR.tick(this.pre.at(this.tapB));
        this.pre.push(<f32>0.5 * (l + r));
        let y = this.y;
        let h = this.h;
        for (let i = 0; i < 8; i++) {
            y[i] = this.damp[i].tick(this.line[i].frac(this.len[i] + this.depth * this.w[i].tick()));
        }
        // Hadamard of order eight, normalised.
        for (let i = 0; i < 8; i++) {
            h[i] = y[i];
        }
        for (let span = 1; span < 8; span <<= 1) {
            for (let i = 0; i < 8; i += 2 * span) {
                for (let k = i; k < i + span; k++) {
                    let u = h[k];
                    let v = h[k + span];
                    h[k] = u + v;
                    h[k + span] = u - v;
                }
            }
        }
        for (let i = 0; i < 8; i++) {
            this.line[i].push(h[i] * <f32>0.35355339 + (i % 2 == 0 ? a : b));
        }
        this.wetL = <f32>0.5 * (y[0] - y[2] + y[4] + y[6]);
        this.wetR = <f32>0.5 * (y[1] + y[3] - y[5] + y[7]);
    }
}
