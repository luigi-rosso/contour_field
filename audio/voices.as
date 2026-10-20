// The voices the sound plays. Each sleeps once it falls quiet, and costs
// nothing until it is started again.

import { Adsr, Noise, Svf, kAttack, kIdle, noteHz } from "./synth_kernel";
import { Line, OnePole } from "./reverb";
import { Oversampler, designHalfband, fastTanh } from "./tape";

const PI: f32 = 3.14159265358979;
const TWO_PI: f32 = 6.28318530718;

@inline
function wrap(phase: f32): f32 {
    return phase >= 1 ? phase - 1 : phase;
}

// The residual of a band limited step, added at each jump of a naive wave so
// it does not alias.
@inline
function blep(t: f32, dt: f32): f32 {
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1;
    }
    if (t > 1 - dt) {
        t = (t - 1) / dt;
        return t * t + t + t + 1;
    }
    return 0;
}

@inline
function saw(t: f32, dt: f32): f32 {
    return <f32>2 * t - 1 - blep(t, dt);
}

@inline
function square(t: f32, dt: f32): f32 {
    return (t < <f32>0.5 ? <f32>1 : <f32>-1) + blep(t, dt) - blep(wrap(t + <f32>0.5), dt);
}

// Equal power gains for a pan from -1, hard left, to 1.
@inline
function leftOf(pan: f32): f32 {
    return Mathf.cos((pan + 1) * PI * <f32>0.25);
}

@inline
function rightOf(pan: f32): f32 {
    return Mathf.sin((pan + 1) * PI * <f32>0.25);
}

// Sets both sides' filters to one cutoff for the cost of one.
function setBoth(l: Svf, r: Svf, hz: f32, resonance: f32, rate: f32): void {
    l.set(hz, resonance, rate);
    r.g = l.g;
    r.k = l.k;
    r.a1 = l.a1;
    r.a2 = l.a2;
    r.a3 = l.a3;
}

// Two unrelated noises through a filter each, for a wide noise voice.
class Hiss {
    noiseL: Noise = new Noise();
    noiseR: Noise = new Noise();
    left: Svf = new Svf();
    right: Svf = new Svf();

    constructor(seed: u32) {
        this.noiseL.seed(seed);
        this.noiseR.seed(seed * 31 + 7);
    }

    next(): void {
        this.left.next(this.noiseL.next());
        this.right.next(this.noiseR.next());
    }
}

export class Voice {
    active: bool = false;
    outL: f32 = 0;
    outR: f32 = 0;
    // How much goes on to the reverb and to the tape echo, and how far the
    // pulse's sidechain pumps it.
    verb: f32 = 0;
    echo: f32 = 0;
    duck: f32 = 0;
    rate: f32 = 48000;
    env: Adsr = new Adsr();
    ticks: i32 = 0;

    init(rate: f32): void {
        this.rate = rate;
        this.env.sampleRate = rate;
    }

    // A one shot envelope with no sustain has played out once it falls 60 dB.
    get spent(): bool {
        let env = this.env;
        return env.stage == kIdle || (env.sustain == 0 && env.stage != kAttack && env.value < <f32>0.001);
    }

    // Filters follow their envelopes every fourth sample, which no ear tells
    // from every one and costs a quarter.
    steer(): bool {
        return (this.ticks++ & 3) == 0;
    }

    // Puts the voice to sleep once its envelope has played out.
    envelope(): f32 {
        let e = this.env.next();
        if (this.spent) {
            this.active = false;
        }
        return e;
    }

    next(): void {}
}

// The cutoff accelerates into the end and the level climbs with it, then cuts
// dead, as the charge does.
export const RISE: i32 = 0;
// Swells and fades while the cutoff eases from one end to the other.
export const HUMP: i32 = 1;

// Noise through a moving filter, with a sine riding the cutoff for a rumble.
export class Sweep extends Voice {
    hiss: Hiss;
    shape: i32 = HUMP;
    lowpass: bool = false;
    from: f32 = 1000;
    octaves: f32 = 0;
    resonance: f32 = 0;
    gain: f32 = 0;
    sub: f32 = 0;
    phase: f32 = 0;
    length: f32 = 1;
    at: f32 = 0;
    // Eased toward the shape's level, so a restart never clicks.
    level: f32 = 0;

    constructor(shape: i32, lowpass: bool, sub: f32, seed: u32) {
        super();
        this.hiss = new Hiss(seed);
        this.shape = shape;
        this.lowpass = lowpass;
        this.sub = sub;
    }

    start(seconds: f32, fromHz: f32, toHz: f32, resonance: f32, gain: f32, late: f32): void {
        this.length = seconds * this.rate;
        this.at = late * this.rate;
        this.from = fromHz;
        this.octaves = Mathf.log2(toHz / fromHz);
        this.resonance = resonance;
        this.gain = gain;
        this.active = true;
    }

    @unchecked
    override next(): void {
        let x = min(this.at / this.length, <f32>1);
        let position: f32;
        let target: f32;
        if (this.shape == RISE) {
            position = x * x;
            target = x < 1 ? position : 0;
        } else {
            position = x * x * (<f32>3 - <f32>2 * x);
            let s = Mathf.sin(PI * x);
            target = s * s;
        }
        this.level += (target * this.gain - this.level) * <f32>0.004;
        this.at += 1;
        if (x >= 1 && this.level < <f32>0.00001) {
            this.active = false;
        }
        let hz = this.from * Mathf.exp2(this.octaves * position);
        let hiss = this.hiss;
        let l = hiss.left;
        let r = hiss.right;
        if (this.steer()) {
            setBoth(l, r, hz, this.resonance, this.rate);
        }
        hiss.next();
        let left = this.lowpass ? l.lp : l.bp * l.k;
        let right = this.lowpass ? r.lp : r.bp * r.k;
        let rumble: f32 = 0;
        if (this.sub > 0) {
            this.phase = wrap(this.phase + hz / this.rate);
            rumble = this.sub * Mathf.sin(TWO_PI * this.phase);
        }
        this.outL = (left + rumble) * this.level;
        this.outR = (right + rumble) * this.level;
    }
}

// A pitched membrane, a driven sine falling onto its pitch under a decay, with
// a burst of noise for the stick. Without noise it is the sub drop.
export class Drum extends Voice {
    hiss: Hiss;
    phase: f32 = 0;
    hz: f32 = 0;
    end: f32 = 0;
    drop: f32 = 0;
    drive: f32 = 1;
    gain: f32 = 0;
    stick: f32 = 0;
    stickFall: f32 = 0;

    constructor(seed: u32) {
        super();
        this.hiss = new Hiss(seed);
    }

    override init(rate: f32): void {
        super.init(rate);
        setBoth(this.hiss.left, this.hiss.right, 700, 0.3, rate);
        this.stickFall = Mathf.exp(<f32>-1 / (<f32>0.025 * rate));
    }

    start(fromHz: f32, toHz: f32, dropSeconds: f32, decaySeconds: f32, drive: f32, gain: f32, stick: f32): void {
        this.hz = fromHz;
        this.end = toHz;
        this.drop = Mathf.exp(<f32>-1 / (dropSeconds * this.rate));
        this.drive = drive;
        this.gain = gain / fastTanh(drive);
        this.stick = stick * gain;
        this.env.set(0.001, decaySeconds, 0, 0.05);
        this.env.gate(true);
        this.active = true;
    }

    get level(): f32 {
        return this.env.value;
    }

    override next(): void {
        let e = this.envelope();
        this.hz = this.end + (this.hz - this.end) * this.drop;
        this.phase = wrap(this.phase + this.hz / this.rate);
        let y = fastTanh(this.drive * Mathf.sin(TWO_PI * this.phase)) * e * this.gain;
        let l = y;
        let r = y;
        if (this.stick > <f32>0.0001) {
            let hiss = this.hiss;
            hiss.next();
            l += hiss.left.bp * this.stick;
            r += hiss.right.bp * this.stick;
            this.stick *= this.stickFall;
        }
        this.outL = l;
        this.outR = r;
    }
}

// A burst of noise that darkens as it decays.
export class Crash extends Voice {
    hiss: Hiss;
    lowL: OnePole = new OnePole();
    lowR: OnePole = new OnePole();
    hz: f32 = 0;
    fall: f32 = 0;
    gain: f32 = 0;

    constructor(seed: u32) {
        super();
        this.hiss = new Hiss(seed);
    }

    override init(rate: f32): void {
        super.init(rate);
        this.lowL.set(350, rate);
        this.lowR.set(350, rate);
    }

    start(decaySeconds: f32, gain: f32): void {
        this.hz = 14000;
        this.fall = Mathf.exp(<f32>-1 / (decaySeconds * <f32>0.3 * this.rate));
        this.gain = gain;
        this.env.set(0.001, decaySeconds, 0, 0.05);
        this.env.gate(true);
        this.active = true;
    }

    override next(): void {
        let e = this.envelope();
        this.hz = <f32>1500 + (this.hz - <f32>1500) * this.fall;
        let hiss = this.hiss;
        if (this.steer()) {
            setBoth(hiss.left, hiss.right, this.hz, 0.1, this.rate);
        }
        hiss.next();
        let g = e * e * this.gain;
        this.outL = this.lowL.hp(hiss.left.lp) * g;
        this.outR = this.lowR.hp(hiss.right.lp) * g;
    }
}

const NOTES: i32 = 6;
const UNISON: i32 = 8;

// A chord of unison saws fanned across the field, each with its own detune so
// the sides never move together, under one envelope and one lowpass that
// opens with it. A new chord glides each note to its new pitch.
export class Section extends Voice {
    unison: i32;
    phase: StaticArray<f32> = new StaticArray<f32>(NOTES * UNISON);
    ratio: StaticArray<f32> = new StaticArray<f32>(UNISON);
    gainL: StaticArray<f32> = new StaticArray<f32>(UNISON);
    gainR: StaticArray<f32> = new StaticArray<f32>(UNISON);
    hz: StaticArray<f32> = new StaticArray<f32>(NOTES);
    target: StaticArray<f32> = new StaticArray<f32>(NOTES);
    // Each saw's phase step, worked out again only while a chord glides.
    inc: StaticArray<f32> = new StaticArray<f32>(NOTES * UNISON);
    gliding: bool = false;
    count: i32 = 0;
    glide: f32 = 1;
    filterL: Svf = new Svf();
    filterR: Svf = new Svf();
    // The cutoff shut and how far the envelope opens it, in Hz.
    floor: f32 = 300;
    span: f32 = 3000;
    resonance: f32 = 0.2;
    drive: f32 = 0;
    gain: f32 = 0;
    // A sine under the lowest note, in the middle.
    sub: f32 = 0;
    subPhase: f32 = 0;
    // The side gets the middle a few milliseconds late, for width that folds
    // away in mono.
    haas: Line = new Line();
    haasFrames: u32 = 0;
    haasGain: f32 = 0;

    constructor(unison: i32, cents: f32, seed: u32) {
        super();
        this.unison = min(unison, UNISON);
        let n = this.unison;
        let noise = new Noise();
        noise.seed(seed);
        for (let i = 0; i < NOTES * UNISON; i++) {
            this.phase[i] = noise.unit();
        }
        // Detunes stepped by the golden ratio, so neighbours across the field
        // are far apart in pitch.
        let mean: f32 = 0;
        for (let u = 0; u < n; u++) {
            let x = <f32>(<f64>u * 0.618034 + 0.31);
            this.ratio[u] = (x - Mathf.floor(x)) * 2 - 1;
            mean += this.ratio[u] / <f32>n;
        }
        for (let u = 0; u < n; u++) {
            this.ratio[u] = Mathf.exp2((this.ratio[u] - mean) * cents / 1200);
            let pan = n > 1 ? <f32>-1 + <f32>2 * <f32>u / <f32>(n - 1) : <f32>0;
            this.gainL[u] = leftOf(pan) / Mathf.sqrt(<f32>n);
            this.gainR[u] = rightOf(pan) / Mathf.sqrt(<f32>n);
        }
    }

    widen(seconds: f32, gain: f32): void {
        this.haas.init(seconds + <f32>0.002, this.rate);
        this.haasFrames = <u32>(seconds * this.rate);
        this.haasGain = gain;
    }

    play(notes: StaticArray<f32>, glideSeconds: f32): void {
        let fresh = this.spent;
        this.count = min(notes.length, NOTES);
        for (let n = 0; n < this.count; n++) {
            this.target[n] = noteHz(notes[n]);
            if (fresh) {
                this.hz[n] = this.target[n];
            }
        }
        this.glide = <f32>1 - Mathf.exp(<f32>-1 / (glideSeconds * this.rate));
        this.gliding = true;
        this.env.gate(true);
        this.active = true;
    }

    release(seconds: f32): void {
        this.env.releaseCoef = this.env.coefFor(seconds);
        this.env.gate(false);
    }

    @unchecked
    override next(): void {
        let e = this.envelope();
        let left: f32 = 0;
        let right: f32 = 0;
        let step = <f32>1 / this.rate;
        let n = this.unison;
        if (this.gliding) {
            let settled = true;
            for (let k = 0; k < this.count; k++) {
                let hz = this.hz[k] + (this.target[k] - this.hz[k]) * this.glide;
                this.hz[k] = hz;
                settled = settled && Mathf.abs(this.target[k] - hz) < <f32>0.001 * hz;
                for (let u = 0; u < n; u++) {
                    this.inc[k * UNISON + u] = hz * this.ratio[u] * step;
                }
            }
            this.gliding = !settled;
        }
        for (let k = 0; k < this.count; k++) {
            let at = k * UNISON;
            for (let u = 0; u < n; u++) {
                let dt = this.inc[at + u];
                let t = wrap(this.phase[at + u] + dt);
                this.phase[at + u] = t;
                let y = saw(t, dt);
                left += y * this.gainL[u];
                right += y * this.gainR[u];
            }
        }
        let l = this.filterL;
        let r = this.filterR;
        if (this.steer()) {
            setBoth(l, r, this.floor + this.span * e * e, this.resonance, this.rate);
        }
        l.next(left);
        r.next(right);
        let a = l.lp;
        let b = r.lp;
        if (this.drive > 0) {
            a = fastTanh(a * this.drive) / this.drive;
            b = fastTanh(b * this.drive) / this.drive;
        }
        if (this.haasFrames > 0) {
            let line = this.haas;
            line.push((a + b) * <f32>0.5);
            let late = line.at(this.haasFrames) * this.haasGain;
            a += late;
            b -= late;
        }
        if (this.sub > 0) {
            this.subPhase = wrap(this.subPhase + this.hz[0] * step);
            let s = this.sub * Mathf.sin(TWO_PI * this.subPhase);
            a += s;
            b += s;
        }
        let g = e * this.gain;
        this.outL = a * g;
        this.outR = b * g;
    }
}

// One note at a time, two detuned saws through a resonant lowpass, with an
// envelope of its own the derez sweeps; the arp and the bass hold it still.
// The arp, the ostinato bass and the derez of a lost lock are each one of
// these.
export class Mono extends Voice {
    phaseA: f32 = 0;
    phaseB: f32 = 0.37;
    step: f32 = 0;
    end: f32 = 0;
    drop: f32 = 1;
    detune: f32 = 1;
    // How far the second saw leans to the right, 0 for one centred voice.
    spread: f32 = 0;
    filterL: Svf = new Svf();
    filterR: Svf = new Svf();
    cutoff: f32 = 400;
    amount: f32 = 2000;
    resonance: f32 = 0.5;
    sweep: f32 = 0;
    fall: f32 = 0;
    gainL: f32 = 0;
    gainR: f32 = 0;

    constructor(cents: f32, spread: f32) {
        super();
        this.detune = Mathf.exp2(cents / 1200);
        this.spread = spread;
    }

    // Glides from one note to the other over glideSeconds, while the filter
    // closes over sweepSeconds.
    play(note: f32, endNote: f32, glideSeconds: f32, sweepSeconds: f32, decaySeconds: f32, gain: f32, pan: f32): void {
        this.step = noteHz(note) / this.rate;
        this.end = noteHz(endNote) / this.rate;
        this.drop = Mathf.exp(<f32>-1 / (glideSeconds * this.rate));
        this.sweep = 1;
        this.fall = Mathf.exp(<f32>-1 / (sweepSeconds * this.rate));
        this.gainL = gain * leftOf(pan);
        this.gainR = gain * rightOf(pan);
        // Soft enough not to click, quick enough to stay a pluck.
        this.env.set(0.005, decaySeconds, 0, 0.03);
        this.env.gate(true);
        this.active = true;
    }

    get level(): f32 {
        return this.env.value;
    }

    @unchecked
    override next(): void {
        let e = this.envelope();
        this.step = this.end + (this.step - this.end) * this.drop;
        let dt = this.step;
        let db = dt * this.detune;
        this.phaseA = wrap(this.phaseA + dt);
        this.phaseB = wrap(this.phaseB + db);
        let a = saw(this.phaseA, dt);
        let b = saw(this.phaseB, db);
        let l = this.filterL;
        let r = this.filterR;
        if (this.steer()) {
            setBoth(l, r, this.cutoff + this.amount * this.sweep, this.resonance, this.rate);
        }
        this.sweep *= this.fall;
        let s = this.spread;
        l.next(a + b * (<f32>1 - s));
        r.next(b + a * (<f32>1 - s));
        this.outL = l.lp * e * this.gainL;
        this.outR = r.lp * e * this.gainR;
    }
}

// A computer beep: a sine edged toward a square, gliding from one pitch to
// another under a short decay.
export class Blip extends Voice {
    phase: f32 = 0;
    step: f32 = 0;
    end: f32 = 0;
    drop: f32 = 0;
    edge: f32 = 0;
    gainL: f32 = 0;
    gainR: f32 = 0;

    start(note: f32, endNote: f32, decaySeconds: f32, edge: f32, gain: f32, pan: f32): void {
        this.step = noteHz(note) / this.rate;
        this.end = noteHz(endNote) / this.rate;
        this.drop = Mathf.exp(<f32>-1 / (decaySeconds * <f32>0.5 * this.rate));
        this.edge = edge;
        this.gainL = gain * leftOf(pan);
        this.gainR = gain * rightOf(pan);
        this.env.set(0.002, decaySeconds, 0, 0.02);
        this.env.gate(true);
        this.active = true;
    }

    get level(): f32 {
        return this.env.value;
    }

    override next(): void {
        let e = this.envelope();
        this.step = this.end + (this.step - this.end) * this.drop;
        let t = wrap(this.phase + this.step);
        this.phase = t;
        let s = Mathf.sin(TWO_PI * t);
        let y = (s + this.edge * (square(t, this.step) - s)) * e;
        this.outL = y * this.gainL;
        this.outR = y * this.gainR;
    }
}

// Wind from noise whose band wanders, each side on its own.
// Lowpassed noise carries far less energy than the band it replaced.
const RUMBLE_GAIN: f32 = 4.5;

export class Bed extends Voice {
    hiss: Hiss = new Hiss(0x2545f491);
    wander: f32 = 0;
    level: f32 = 0;
    target: f32 = 0;
    ease: f32 = 0;
    tick: i32 = 0;

    fade(level: f32, seconds: f32): void {
        this.target = level;
        this.ease = <f32>1 - Mathf.exp(<f32>-1 / (seconds * <f32>0.3 * this.rate));
        this.active = true;
    }

    @unchecked
    override next(): void {
        this.level += (this.target - this.level) * this.ease;
        if (this.target == 0 && this.level < <f32>0.00001) {
            this.level = 0;
            this.active = false;
        }
        // A low rumble whose floor only drifts, so it moves once every 32
        // samples.
        if ((this.tick++ & 31) == 0) {
            this.wander = wrap(this.wander + <f32>32 * <f32>0.021 / this.rate);
            let w = Mathf.sin(TWO_PI * this.wander);
            this.hiss.left.set(<f32>62 * Mathf.exp2(<f32>0.45 * w), 0.3, this.rate);
            this.hiss.right.set(<f32>62 * Mathf.exp2(<f32>-0.45 * w), 0.3, this.rate);
        }
        let hiss = this.hiss;
        hiss.next();
        this.outL = hiss.left.lp * this.level * RUMBLE_GAIN;
        this.outR = hiss.right.lp * this.level * RUMBLE_GAIN;
    }
}

// The formants of ah and ae, with the gains the lead's throat gives them.
const FORMANTS: StaticArray<f32> = [800, 1150, 2900, 400, 1600, 2700];
const FORMANT_GAINS: StaticArray<f32> = [1, 0.5, 0.25];
// Where the throat sits from ah toward ae, and how hard it resonates.
const VOWEL: f32 = 0.4;
const THROAT_Q: f32 = 0.94;
// The lead's fuzz at 0.85: about 43 dB into the first clip, 6 into the second.
const DRIVE_FIRST: f32 = 135;
const DRIVE_SECOND: f32 = 2;

class ScreamTake {
    main: f32 = 0;
    second: f32 = 0.31;
    under: f32 = 0.67;
    step: f32 = 0;
    noise: Noise = new Noise();
    tone: Svf = new Svf();
    over: Oversampler = new Oversampler();
    cabinet: Svf = new Svf();
    throat: StaticArray<Svf> = [new Svf(), new Svf(), new Svf()];
}

// Reach's lead scream as a hit: a saw, a second three cents off and one an
// octave under with breath noise, through a resonant low pass near 1.5 kHz,
// a hard two stage drive at twice the rate, and the throat added back after.
// Two takes, each on its own side through its own drive, bent apart and back.
export class Scream extends Voice {
    takes: StaticArray<ScreamTake> = [new ScreamTake(), new ScreamTake()];
    halfband: StaticArray<f32> = new StaticArray<f32>(8);
    hz: f32 = 0;
    // Semitones under the note the attack scoops up from, and the fall per
    // sample.
    scoop: f32 = 0;
    scoopFall: f32 = 1;
    // How far the filter has opened, falling back after the attack.
    bright: f32 = 0;
    brightFall: f32 = 1;
    lfo: f32 = 0;
    gain: f32 = 0;
    // How far each take sits toward its side.
    pan: f32 = 1;
    // The throat's mix over the driven wave.
    throat: f32 = 0.6;

    constructor(seed: u32) {
        super();
        this.takes[0].noise.seed(seed);
        this.takes[1].noise.seed(seed * 31 + 7);
        // Takes that start in step drive into nearly the same wave.
        let right = this.takes[1];
        right.main = 0.5;
        right.second = 0.83;
        right.under = 0.12;
    }

    override init(rate: f32): void {
        super.init(rate);
        designHalfband(this.halfband);
        let q = THROAT_Q;
        for (let s = 0; s < 2; s++) {
            let take = this.takes[s];
            take.cabinet.set(4200, 0, rate);
            for (let i = 0; i < 3; i++) {
                let from = FORMANTS[i];
                take.throat[i].set(from * Mathf.pow(FORMANTS[3 + i] / from, VOWEL), q, rate);
            }
        }
    }

    play(note: f32, decaySeconds: f32, gain: f32): void {
        this.hz = noteHz(note);
        this.scoop = 1.5;
        this.scoopFall = Mathf.exp(<f32>-1 / (<f32>0.025 * this.rate));
        this.bright = 1;
        this.brightFall = Mathf.exp(<f32>-1 / (<f32>0.35 * this.rate));
        this.gain = gain;
        this.env.set(0.008, decaySeconds, 0, 0.4);
        this.env.gate(true);
        this.active = true;
    }

    @inline
    clip(x: f32): f32 {
        return fastTanh(fastTanh(x * DRIVE_FIRST) * DRIVE_SECOND);
    }

    @unchecked
    override next(): void {
        let e = this.envelope();
        this.scoop *= this.scoopFall;
        this.bright *= this.brightFall;
        let steer = this.steer();
        if (steer) {
            this.lfo = wrap(this.lfo + <f32>4 * <f32>0.6 / this.rate);
        }
        let l: f32 = 0;
        let r: f32 = 0;
        let halfband = this.halfband;
        for (let s = 0; s < 2; s++) {
            let take = this.takes[s];
            if (steer) {
                // The second take seven cents up, and the two bent apart and
                // back.
                let bend = Mathf.sin(TWO_PI * this.lfo) * <f32>0.06 * (s == 0 ? <f32>1 : <f32>-1);
                let cents = (s == 0 ? <f32>0 : <f32>0.07) + bend;
                take.step = this.hz * Mathf.exp2((cents - this.scoop) / <f32>12) / this.rate;
                take.tone.set(<f32>1500 * (<f32>0.6 + <f32>0.9 * this.bright), 0.6, this.rate);
            }
            let dt = take.step;
            let d2 = dt * <f32>1.0017;
            let du = dt * <f32>0.5;
            take.main = wrap(take.main + dt);
            take.second = wrap(take.second + d2);
            take.under = wrap(take.under + du);
            let x = saw(take.main, dt) + <f32>0.7 * saw(take.second, d2) + <f32>0.3 * saw(take.under, du)
                + <f32>0.12 * take.noise.next();
            take.tone.next(x);
            let over = take.over;
            over.up(halfband, take.tone.lp);
            let y = over.down(halfband, this.clip(over.a), this.clip(over.b));
            take.cabinet.next(y);
            y = take.cabinet.lp;
            let mouth: f32 = 0;
            for (let i = 0; i < 3; i++) {
                let band = take.throat[i];
                band.next(y);
                mouth += band.bp * band.k * FORMANT_GAINS[i];
            }
            y = (y + mouth * this.throat) * e * this.gain;
            let pan = s == 0 ? -this.pan : this.pan;
            l += y * leftOf(pan);
            r += y * rightOf(pan);
        }
        this.outL = l;
        this.outR = r;
    }
}
