// Banshee's tape echo, ported from dsp/src/processors.cpp. Heads read at
// their distance behind an integrated tape position, so a time change is a
// speed change and the repeats bend in pitch until the tape written at the
// old speed clears the head. It renders only its wet side.

import { Biquad } from "./biquad";
import { Noise } from "./synth_kernel";

const kPi: f32 = 3.14159265358979;
const kHeads: i32 = 3;
const kSide: i32 = 8;
// Both half band passes of the saturator.
const kLoopLatency: u64 = 16;

const kWowA: i32 = 0;
const kWowB: i32 = 1;
const kFlutterA: i32 = 2;
const kFlutterB: i32 = 3;
const kHum: i32 = 4;
const kRotors: i32 = 5;

// A sine by rotation, renormalized once per block.
class Rotor {
    c: f32 = 1;
    s: f32 = 0;
    dc: f32 = 1;
    ds: f32 = 0;

    set(hz: f32, rate: f32): void {
        let w: f32 = <f32>2 * kPi * hz / rate;
        this.dc = Mathf.cos(w);
        this.ds = Mathf.sin(w);
    }

    reset(): void {
        this.c = 1;
        this.s = 0;
    }

    tick(): f32 {
        let nc = this.c * this.dc - this.s * this.ds;
        this.s = this.s * this.dc + this.c * this.ds;
        this.c = nc;
        return this.s;
    }

    renormalize(): void {
        let g: f32 = <f32>1.5 - <f32>0.5 * (this.c * this.c + this.s * this.s);
        this.c *= g;
        this.s *= g;
    }
}

// A random target held for a while and eased toward: slow for wow's drift,
// fast for flutter's scrape.
class Wander {
    value: f32 = 0;
    target: f32 = 0;
    coef: f32 = 0;
    hold: u32 = 1;
    left: u32 = 1;

    set(holdSeconds: f32, hz: f32, rate: f32): void {
        this.hold = max<u32>(1, <u32>(holdSeconds * rate));
        this.coef = <f32>1.0 - Mathf.exp(<f32>-2.0 * kPi * hz / rate);
    }

    reset(): void {
        this.value = 0;
        this.target = 0;
        this.left = 1;
    }

    due(): bool {
        if (--this.left != 0) {
            return false;
        }
        this.left = this.hold;
        return true;
    }

    ease(): f32 {
        this.value += (this.target - this.value) * this.coef;
        return this.value;
    }

    tick(noise: Noise): f32 {
        if (this.due()) {
            this.target = noise.next();
        }
        return this.ease();
    }
}

// Half band FIR polyphase so a nonlinearity runs at twice the rate; up and
// down each lag eight input samples.
export class Oversampler {
    input: StaticArray<f32> = new StaticArray<f32>(32);
    even: StaticArray<f32> = new StaticArray<f32>(32);
    odd: StaticArray<f32> = new StaticArray<f32>(32);
    pos: u32 = 0;
    // The two samples up writes, at the even and the odd instant.
    a: f32 = 0;
    b: f32 = 0;

    clear(): void {
        this.input.fill(0);
        this.even.fill(0);
        this.odd.fill(0);
        this.pos = 0;
    }

    @unchecked
    up(c: StaticArray<f32>, x: f32): void {
        let input = this.input;
        let pos = this.pos;
        input[pos & 31] = x;
        this.a = input[(pos - kSide) & 31];
        let sum: f32 = 0;
        for (let i = 0; i < kSide; i++) {
            sum += c[i] * (input[(pos - kSide - i) & 31] + input[(pos - kSide + 1 + i) & 31]);
        }
        this.b = sum;
    }

    @unchecked
    down(c: StaticArray<f32>, a: f32, b: f32): f32 {
        let pos = this.pos;
        this.even[pos & 31] = a;
        this.odd[pos & 31] = b;
        let odd = this.odd;
        let y: f32 = <f32>0.5 * this.even[(pos - kSide) & 31];
        for (let i = 0; i < kSide; i++) {
            y += <f32>0.5 * c[i] * (odd[(pos - kSide - 1 - i) & 31] + odd[(pos - kSide + i) & 31]);
        }
        this.pos = pos + 1;
        return y;
    }
}

function bessel0(x: f32): f32 {
    let sum: f32 = 1;
    let term: f32 = 1;
    let half: f32 = x * 0.5;
    for (let k = 1; k < 30; k++) {
        term *= half / <f32>k;
        sum += term * term;
    }
    return sum;
}

// Kaiser windowed sinc, the odd taps of a 33 tap half band, scaled so the
// pair sums to unity at DC.
export function designHalfband(c: StaticArray<f32>): void {
    const beta: f32 = 7;
    let total: f32 = 0;
    for (let i = 0; i < kSide; i++) {
        let k: f32 = <f32>(2 * i + 1);
        let window = bessel0(beta * Mathf.sqrt(<f32>1.0 - (k / 16) * (k / 16))) / bessel0(beta);
        c[i] = (i % 2 == 0 ? <f32>2.0 : <f32>-2.0) / (kPi * k) * window;
        total += c[i];
    }
    for (let i = 0; i < kSide; i++) {
        c[i] *= <f32>0.5 / total;
    }
}

export function fastTanh(x: f32): f32 {
    x = min(max(x, <f32>-4.97), <f32>4.97);
    let x2 = x * x;
    return x * (<f32>135135.0 + x2 * (<f32>17325.0 + x2 * (<f32>378.0 + x2))) /
        (<f32>135135.0 + x2 * (<f32>62370.0 + x2 * (<f32>3150.0 + x2 * <f32>28.0)));
}

export const kTapeTime: i32 = 0;
export const kTapeFeedback: i32 = 1;
export const kTapeMix: i32 = 2;
export const kTapeDrive: i32 = 3;
export const kTapeTone: i32 = 4;
export const kTapeAge: i32 = 5;
export const kTapeWow: i32 = 6;
export const kTapeFlutter: i32 = 7;
export const kTapeSpread: i32 = 8;
export const kTapeHeads: i32 = 9;

export class Tape {
    // Banshee's descriptors: min, max, default and smoothing in ms, eased
    // once a block like its Block.
    mins: StaticArray<f32> = [20, 0, 0, 0, 0, 0, 0, 0, 0, 1];
    maxs: StaticArray<f32> = [1200, 1.1, 1, 1, 1, 1, 1, 1, 1, 3];
    targets: StaticArray<f32> = [380, 0.4, 0.35, 0.3, 0.6, 0.3, 0.2, 0.2, 0.25, 1];
    smoothing: StaticArray<f32> = [0, 20, 20, 20, 50, 50, 50, 50, 50, 50];
    values: StaticArray<f32> = new StaticArray<f32>(10);

    rate: f32 = 48000;
    wetL: StaticArray<f32> = new StaticArray<f32>(0);
    wetR: StaticArray<f32> = new StaticArray<f32>(0);

    trackL: StaticArray<f32> = new StaticArray<f32>(0);
    trackR: StaticArray<f32> = new StaticArray<f32>(0);
    position: StaticArray<f64> = new StaticArray<f64>(0);
    mask: u64 = 0;
    now: u64 = 0;
    tapePos: f64 = 0;
    headDistance: StaticArray<f64> = new StaticArray<f64>(kHeads);
    headIndex: StaticArray<u64> = new StaticArray<u64>(kHeads);
    headGain: StaticArray<f32> = new StaticArray<f32>(kHeads);
    speed: f32 = 1;
    speedTarget: f32 = 1;
    motorUp: f32 = 0;
    motorDown: f32 = 0;
    // Each side records only its own input and plays back into the other,
    // so a repeat bounces from the side it came in on.
    pingPong: bool = false;

    preEmphasis: Biquad = new Biquad();
    deEmphasis: Biquad = new Biquad();
    bump: Biquad = new Biquad();
    gapLoss: Biquad = new Biquad();
    rumbleCoef: f32 = 0;
    rumble: StaticArray<f32> = new StaticArray<f32>(2);
    rumbleIn: StaticArray<f32> = new StaticArray<f32>(2);
    magnet: StaticArray<f32> = new StaticArray<f32>(2);
    over: StaticArray<Oversampler> = [new Oversampler(), new Oversampler()];
    halfband: StaticArray<f32> = new StaticArray<f32>(kSide);

    noise: Noise = new Noise();
    hiss: StaticArray<Noise> = [new Noise(), new Noise()];
    pink: StaticArray<f32> = new StaticArray<f32>(6);
    rotor: StaticArray<Rotor> = [new Rotor(), new Rotor(), new Rotor(), new Rotor(), new Rotor()];
    wowDrift: Wander = new Wander();
    flutterDrift: Wander = new Wander();
    jitter: StaticArray<Wander> = [new Wander(), new Wander()];
    dropout: Wander = new Wander();

    // The tape curve's per block numbers.
    level: f32 = 0;
    bias: f32 = 0;
    biasOut: f32 = 0;
    levelOut: f32 = 0;
    fast: f32 = 0;
    slow: f32 = 0;

    setParam(index: i32, value: f32): void {
        this.targets[index] = min(max(value, this.mins[index]), this.maxs[index]);
    }

    value(index: i32): f32 {
        return this.values[index];
    }

    init(rate: f32, maxFrames: i32): void {
        this.rate = rate;
        this.wetL = new StaticArray<f32>(maxFrames);
        this.wetR = new StaticArray<f32>(maxFrames);
        // Three heads at the longest time, with room for wow and the loop's
        // latency.
        let needed = <u64>(<u32>(rate * <f32>kHeads * <f32>1.2 * <f32>1.02)) + kLoopLatency + 8;
        let size: u64 = 1;
        while (size < needed) {
            size <<= 1;
        }
        this.mask = size - 1;
        this.trackL = new StaticArray<f32>(<i32>size);
        this.trackR = new StaticArray<f32>(<i32>size);
        this.position = new StaticArray<f64>(<i32>size);
        for (let k = 0; k < kHeads; k++) {
            this.headDistance[k] = <f64>(k + 1) * <f64>rate;
        }
        designHalfband(this.halfband);
        this.preEmphasis.highShelf(rate, 3000, 6);
        this.deEmphasis.highShelf(rate, 3000, -6);
        this.bump.peak(rate, 100, 2.5, 0.8);
        this.rotor[kWowA].set(0.7, rate);
        this.rotor[kWowB].set(1.77, rate);
        this.wowDrift.set(0.4, 0.6, rate);
        this.rotor[kFlutterA].set(7.3, rate);
        this.rotor[kFlutterB].set(12.7, rate);
        this.flutterDrift.set(0.02, 30, rate);
        this.jitter[0].set(0.015, 40, rate);
        this.jitter[1].set(0.013, 40, rate);
        this.dropout.set(0.02, 10, rate);
        this.rotor[kHum].set(50, rate);
        this.motorUp = <f32>1.0 - Mathf.exp(<f32>-1.0 / (<f32>0.15 * rate));
        this.motorDown = <f32>1.0 - Mathf.exp(<f32>-1.0 / (<f32>0.07 * rate));
        this.rumbleCoef = Mathf.exp(<f32>-2.0 * kPi * <f32>90.0 / rate);
        this.reset();
    }

    reset(): void {
        for (let i = 0; i < 10; i++) {
            this.values[i] = this.targets[i];
        }
        this.trackL.fill(0);
        this.trackR.fill(0);
        // The whole ring is history at the resting speed, so the heads start
        // where the time says.
        this.speed = <f32>1000.0 / this.value(kTapeTime);
        this.speedTarget = this.speed;
        let size = this.mask + 1;
        this.now = size;
        this.tapePos = 0;
        for (let s: u64 = 0; s < size; s++) {
            this.position[<i32>s] = (<f64>s - <f64>size) * <f64>this.speed;
        }
        for (let k = 0; k < kHeads; k++) {
            this.headIndex[k] = this.now - <u64>(this.headDistance[k] / <f64>this.speed) - 1;
        }
        this.preEmphasis.clear();
        this.deEmphasis.clear();
        this.bump.clear();
        this.gapLoss.clear();
        for (let c = 0; c < 2; c++) {
            this.rumble[c] = 0;
            this.rumbleIn[c] = 0;
            this.magnet[c] = 0;
            this.over[c].clear();
            this.hiss[c].seed(<u32>0x3c6ef372 + <u32>0x9e3779b9 * <u32>c);
            this.jitter[c].reset();
        }
        this.pink.fill(0);
        this.noise.seed(0x243f6a88);
        for (let r = 0; r < kRotors; r++) {
            this.rotor[r].reset();
        }
        this.wowDrift.reset();
        this.flutterDrift.reset();
        this.dropout.reset();
    }

    // Writes the echoes of the input into wetL and wetR.
    @unchecked
    process(left: StaticArray<f32>, right: StaticArray<f32>, frames: i32): void {
        let rate = this.rate;
        let blockMs: f32 = <f32>frames * <f32>1000.0 / rate;
        for (let i = 0; i < 10; i++) {
            if (this.values[i] == this.targets[i]) {
                continue;
            }
            let ms = this.smoothing[i];
            let coef: f32 = ms > 0 ? <f32>1.0 - Mathf.exp(-blockMs / ms) : <f32>1.0;
            this.values[i] += (this.targets[i] - this.values[i]) * coef;
        }
        let feedback = this.value(kTapeFeedback);
        let mix = this.value(kTapeMix);
        let drive = this.value(kTapeDrive);
        let tone = this.value(kTapeTone);
        let age = this.value(kTapeAge);
        let flutter = this.value(kTapeFlutter);
        let wowDepth: f32 = this.value(kTapeWow) * <f32>0.004;
        let flutterDepth: f32 = flutter * <f32>0.0006;
        let spread = this.value(kTapeSpread);
        let sendSpread = this.pingPong ? <f32>0 : spread;
        let cross = this.pingPong ? <f32>1 : spread;
        let heads = this.value(kTapeHeads);
        this.speedTarget = <f32>1000.0 / this.value(kTapeTime);

        // Slower tape sees the head gap as a longer wavelength, against the
        // 380 ms rest.
        let speedFactor = Mathf.sqrt(min(max(this.speed * <f32>0.38, <f32>0.5), <f32>2.0));
        let gapHz = min(<f32>1500.0 * Mathf.pow(10, tone) * speedFactor * (<f32>1.0 - <f32>0.5 * age),
            <f32>0.45 * rate);
        this.gapLoss.lowPass(rate, gapHz, 0.6);

        // Record level into the tape curve, unity for small signals so the
        // feedback knob keeps its meaning at any drive.
        this.level = <f32>0.5 + <f32>11.5 * drive * drive;
        this.bias = <f32>0.05 + <f32>0.15 * drive;
        this.biasOut = Mathf.tanh(this.bias);
        this.levelOut = <f32>1.0 / (this.level * (<f32>1.0 - this.biasOut * this.biasOut));
        let magnetHz: f32 = <f32>20000.0 * (<f32>1.0 - <f32>0.6 * age);
        this.fast = <f32>1.0 - Mathf.exp(<f32>-2.0 * kPi * magnetHz / (<f32>2 * rate));
        this.slow = this.fast * (<f32>0.8 - <f32>0.3 * age);
        let outGain: f32 = <f32>1.0 + <f32>1.5 * drive;

        let hissLevel: f32 = age * age * <f32>0.0005;
        let humLevel: f32 = age * <f32>0.0001;
        let dropoutDepth: f32 = <f32>0.6 * age * age;
        let dropoutChance: f32 = <f32>0.01 * age;
        let jitterAmp: f32 = <f32>0.25 * flutter * spread;

        let headGain = this.headGain;
        let headSum: f32 = 0;
        for (let k = 0; k < kHeads; k++) {
            headGain[k] = min(max(heads - <f32>k, <f32>0.0), <f32>1.0);
            headSum += headGain[k];
        }
        let loopGain = feedback / headSum;
        let outNorm = outGain / Mathf.sqrt(headSum);

        let mask = this.mask;
        let position = this.position;
        let pink = this.pink;
        let rotor = this.rotor;
        let noise = this.noise;
        for (let i = 0; i < frames; i++) {
            // Transport.
            this.speed += (this.speedTarget - this.speed) *
                (this.speedTarget > this.speed ? this.motorUp : this.motorDown);
            let wow: f32 = <f32>0.55 * rotor[kWowA].tick() + <f32>0.25 * rotor[kWowB].tick() +
                <f32>0.6 * this.wowDrift.tick(noise);
            let scrape: f32 = <f32>0.4 * rotor[kFlutterA].tick() + <f32>0.25 * rotor[kFlutterB].tick() +
                <f32>0.6 * this.flutterDrift.tick(noise);
            this.tapePos += <f64>(this.speed * (<f32>1.0 + wowDepth * wow + flutterDepth * scrape));
            let now = this.now;
            position[<i32>(now & mask)] = this.tapePos;
            // The loop's own latency is read off the tape as the distance it
            // moved in that many samples.
            let compensation: f64 = this.tapePos - position[<i32>((now - kLoopLatency) & mask)];
            let jitter0: f32 = jitterAmp * this.jitter[0].tick(noise);
            let jitter1: f32 = jitterAmp * this.jitter[1].tick(noise);

            let read0: f32 = 0;
            let read1: f32 = 0;
            for (let k = 0; k < kHeads; k++) {
                let q: f64 = this.tapePos - this.headDistance[k] + compensation;
                let index = this.headIndex[k];
                while (position[<i32>((index + 1) & mask)] <= q && now - index > 3) {
                    index++;
                }
                while (position[<i32>(index & mask)] > q && now - index < mask - 4) {
                    index--;
                }
                this.headIndex[k] = index;
                if (headGain[k] <= 0) {
                    continue;
                }
                let p0 = position[<i32>(index & mask)];
                let p1 = position[<i32>((index + 1) & mask)];
                let fraction = <f32>((q - p0) / (p1 - p0));
                let delay: f32 = <f32>(now - index) - fraction;
                read0 += headGain[k] * this.readTrack(this.trackL, now, delay + jitter0);
                read1 += headGain[k] * this.readTrack(this.trackR, now, delay + jitter1);
            }

            // Playback head.
            let dropout = this.dropout;
            if (dropout.due()) {
                dropout.target = noise.next() * <f32>0.5 + <f32>0.5 < dropoutChance ? <f32>1.0 : <f32>0.0;
            }
            let dropoutGain: f32 = <f32>1.0 - dropoutDepth * dropout.ease();
            let play0 = this.playback(0, read0) * dropoutGain;
            let play1 = this.playback(1, read1) * dropoutGain;

            // Send and feedback, crossing as spread rises.
            let inL = left[i];
            let inR = right[i];
            let send0: f32 = inL * (<f32>1 - sendSpread) + sendSpread * <f32>0.5 * (inL + inR);
            let send1: f32 = inR * (<f32>1 - sendSpread);
            let back0: f32 = (<f32>1 - cross) * play0 + cross * play1;
            let back1: f32 = (<f32>1 - cross) * play1 + cross * play0;
            let hum: f32 = humLevel * rotor[kHum].tick();
            // A trace of noise keeps the loop's filters out of denormals.
            let floor: f32 = hum + <f32>1e-10 * noise.next();

            // Record head.
            for (let c = 0; c < 2; c++) {
                let white = this.hiss[c].next();
                let at = c * 3;
                pink[at] = <f32>0.99765 * pink[at] + white * <f32>0.0990460;
                pink[at + 1] = <f32>0.96300 * pink[at + 1] + white * <f32>0.2965164;
                pink[at + 2] = <f32>0.57000 * pink[at + 2] + white * <f32>1.0526913;
                let hiss: f32 = (pink[at] + pink[at + 1] + pink[at + 2] + white * <f32>0.1848) * hissLevel;
                let rec: f32 = (c == 0 ? send0 : send1) + loopGain * (c == 0 ? back0 : back1) + hiss + floor;
                rec = this.preEmphasis.tick(c, rec);
                let over = this.over[c];
                over.up(this.halfband, rec);
                let a = this.magnetize(c, over.a);
                let b = this.magnetize(c, over.b);
                let track = c == 0 ? this.trackL : this.trackR;
                track[<i32>(now & mask)] = over.down(this.halfband, a, b);
            }
            this.now = now + 1;

            this.wetL[i] = play0 * outNorm * mix;
            this.wetR[i] = play1 * outNorm * mix;
        }
        for (let r = 0; r < kRotors; r++) {
            rotor[r].renormalize();
        }
    }

    @unchecked
    playback(c: i32, read: f32): f32 {
        let p = this.deEmphasis.tick(c, read);
        p = this.bump.tick(c, p);
        p = this.gapLoss.tick(c, p);
        let hp: f32 = p - this.rumbleIn[c] + this.rumbleCoef * this.rumble[c];
        this.rumbleIn[c] = p;
        this.rumble[c] = hp;
        return hp;
    }

    // Hermite read at a fractional delay behind now.
    @unchecked
    readTrack(track: StaticArray<f32>, now: u64, delay: f32): f32 {
        let whole = <u32>delay;
        let u: f32 = <f32>1.0 - (delay - <f32>whole);
        let mask = this.mask;
        let at: u64 = now - <u64>whole - 1;
        let ym1 = track[<i32>((at - 1) & mask)];
        let y0 = track[<i32>(at & mask)];
        let y1 = track[<i32>((at + 1) & mask)];
        let y2 = track[<i32>((at + 2) & mask)];
        let c1: f32 = <f32>0.5 * (y1 - ym1);
        let c2: f32 = ym1 - <f32>2.5 * y0 + <f32>2 * y1 - <f32>0.5 * y2;
        let c3: f32 = <f32>0.5 * (y2 - ym1) + <f32>1.5 * (y0 - y1);
        return ((c3 * u + c2) * u + c1) * u + y0;
    }

    // Soft asymmetric tape curve into a magnetization that follows outward
    // swings faster than the return, a loop standing in for hysteresis.
    @unchecked
    magnetize(c: i32, x: f32): f32 {
        let y = (fastTanh(x * this.level + this.bias) - this.biasOut) * this.levelOut;
        let m = this.magnet[c];
        let d = y - m;
        m += d * (d * m >= 0 ? this.fast : this.slow);
        this.magnet[c] = m;
        return m;
    }
}
