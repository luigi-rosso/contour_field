// The sound on the audio thread. The score runs on its own sample clock and a
// 112.5 BPM grid whose downbeat is the second hit, so every hit lands on a beat.

import { AudioProcessor } from "rive/audio";
import { Ring, Snapshot } from "rive/shared";
import { BUILD_SECONDS, IMPACT, RAISE, RAISE_SECONDS, SCAN_START, TRACK_AT } from "../intro";
import { Reverb } from "./reverb";
import { Noise, Svf } from "./synth_kernel";
import { Tape, fastTanh, kTapeAge, kTapeFeedback, kTapeMix, kTapeSpread, kTapeTime } from "./tape";
import { Bed, Blip, Crash, Drum, HUMP, Mono, RISE, Scream, Section, Sweep, Voice } from "./voices";

export const CUE_INTRO: i32 = 0;
export const CUE_LOCK: i32 = 1;
export const CUE_LOSS: i32 = 2;
export const CUE_PALETTE: i32 = 3;
export const CUE_KEY: i32 = 4;
export const CUE_HOVER_IN: i32 = 5;
export const CUE_HOVER_OUT: i32 = 6;

// From the main lane. The value is how far into the build sequence it
// restarts in seconds, a count of new locks or losses, or the palette's index
// for a palette change or for the key alone.
export class Cue {
    kind: i32 = 0;
    value: f64 = 0;
}

// Published every block, so the main lane can tell the sound is playing,
// which a browser holds off until a gesture.
export class Pulse {
    frame: f64 = 0;
}

export class SoundLink {
    cues: Ring<Cue> = Ring.create<Cue>();
    pulse: Snapshot<Pulse> = Snapshot.create<Pulse>(64);
}

// The impact falls three beats before the second hit at this tempo.
const BEAT: f64 = 60.0 / 112.5;
const SIXTEENTH: f64 = BEAT / 4;

// Each chord as its bass root, the pad's four notes and the arp's three tones.
const CHORD_SIZE: i32 = 8;
const CHORDS: StaticArray<f32> = [
    38, 50, 53, 57, 62, 62, 65, 69,
    34, 46, 53, 58, 62, 58, 62, 65,
    31, 50, 55, 58, 62, 55, 58, 62,
    41, 48, 53, 57, 60, 60, 65, 69,
    36, 48, 52, 55, 60, 60, 64, 67,
    33, 49, 52, 57, 61, 57, 61, 64,
];
const DM: i32 = 0;
const BB: i32 = 1;
const GM: i32 = 2;
const F: i32 = 3;
const C: i32 = 4;
const A: i32 = 5;
// Where each chord may go next, so the changes wander without a loop.
const NEXT: StaticArray<i32> = [BB, GM, F, DM, C, GM, DM, BB, A, BB, C, DM, DM, BB, F, DM, DM, BB];
// The braaams, octaves and fifths on D for the impact and on Bb for the
// second hit.
const BRAAAM_D: StaticArray<f32> = [26, 38, 45, 50];
const BRAAAM_BB: StaticArray<f32> = [34, 41, 46, 53];
const BRIGHT_D: StaticArray<f32> = [62, 65, 69, 74];
// A bar of sixteenths: the ostinato's notes over the root, which of the arp's
// tones plays counting up through the octaves, and how much each step
// matters, so a thinner arp keeps the strong ones.
// Eighths on the root, an octave only to turn the bar; REST skips a step.
const REST: f32 = -1;
const BASS: StaticArray<f32> = [0, REST, 0, REST, 0, REST, 0, REST, 0, REST, 0, REST, 0, REST, 12, REST];
const ARP: StaticArray<i32> = [0, 1, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 4, 2, 1];
const WEIGHT: StaticArray<f32> = [1, 0.3, 0.6, 0.3, 0.9, 0.3, 0.6, 0.4, 1, 0.3, 0.6, 0.3, 0.9, 0.4, 0.7, 0.5];
// The timpani roll into the impact, in sixteenths before it.
const ROLL: StaticArray<f64> = [4, 3, 2, 1.5, 1, 0.75, 0.5, 0.25];
// D minor pentatonic, in semitones over D4, for the beeps.
const SCALE: StaticArray<f32> = [0, 3, 5, 7, 10];

// How late a hit may still start when a restart lands past it.
const GRACE: f64 = 0.08;
// Idle blips wait this many sixteenths after anything else has played, and
// longer at random.
const IDLE_AFTER: i32 = 48;
const IDLE_SPREAD: f32 = 64;
const BLIPS: i32 = 6;
const DRUMS: i32 = 4;
const VERB_GAIN: f32 = 0.85;
const CEILING: f32 = 0.89;
// What the side above the bass is lifted by, which folds away in mono.
const WIDTH: f32 = 1.3;
// How hard a hit drives the mix into saturation, and how long it takes to
// clear.
const HIT_DRIVE: f32 = 3.5;
const CRUSH_SECONDS: f32 = 0.9;
// A key change warps the whole mix: the delay it reads through swells to
// WARP_DEPTH and back over WARP_SECONDS, so everything drops a little flat,
// overshoots and settles, the two sides a little apart, while a low pass
// closes to WARP_FLOOR and opens again.
const WARP_SECONDS: f64 = 0.5;
const WARP_DEPTH: f32 = 0.0008;
const WARP_FLOOR: f32 = 1000;
const WARP_FRAMES: i32 = 2048;
// How far the pad dips on each beat once the pulse is in.
const PUMP: f32 = 0.5;
const ARP_GAIN: f32 = 0.18;
const BASS_GAIN: f32 = 0.16;
const PAD_GAIN: f32 = 0.06;
// Each palette's key, in semitones from D minor: D, F, C, G and B minor.
const KEYS: StaticArray<f32> = [0, 3, -2, 5, -3];
const SCREAM_GAIN: f32 = 0.55;

// A degree of the scale, counting up through the octaves from D4.
function note(d: i32): f32 {
    return <f32>(62 + 12 * (d / 5)) + SCALE[d % 5];
}

function mix(a: f32, b: f32, t: f32): f32 {
    return a + (b - a) * t;
}

// A slow sine over a period in sixteenths, for the steady state to drift on.
function lfo(step: i32, period: f32): f32 {
    return Mathf.sin(<f32>6.28318530718 * <f32>step / period);
}

const BEAT_CHARGE: i32 = 0;
const BEAT_ROLL: i32 = 1;
const BEAT_IMPACT: i32 = 2;
const BEAT_LIFT: i32 = 3;
const BEAT_RAISE: i32 = 4;
const BEAT_SWELL: i32 = 5;
const BEAT_SETTLE: i32 = 6;

class Beat {
    // In frames from the start of the build sequence.
    at: f64;
    kind: i32;
    index: i32;
    // Frames past its time that it is still worth starting, so a restart
    // partway skips only what has gone by.
    keep: f64;

    constructor(at: f64, kind: i32, index: i32, keep: f64) {
        this.at = at;
        this.kind = kind;
        this.index = index;
        this.keep = keep;
    }
}

// Cued sounds held for the grid and spaced out on it, so a burst plays as a
// run of sixteenths.
class Train {
    left: i32 = 0;
    cap: i32;
    gap: i32;
    at: i32 = 0;

    constructor(cap: i32, gap: i32) {
        this.cap = cap;
        this.gap = gap;
    }

    add(count: i32): void {
        this.left = min(this.left + count, this.cap);
    }

    due(step: i32): bool {
        if (this.left == 0 || step < this.at) {
            return false;
        }
        this.left--;
        this.at = step + this.gap;
        return true;
    }
}

export class Sound extends AudioProcessor<SoundLink> {
    cues: Ring<Cue>? = null;
    cue: Cue = new Cue();
    pulse: Snapshot<Pulse>? = null;
    pulsed: Pulse = new Pulse();
    rate: f64 = 48000;
    channels: i32 = 2;
    frame: f64 = 0;
    // Frames into the build sequence, negative until the first cue.
    intro: f64 = -1;
    beats: Array<Beat> = [];
    next: i32 = 0;
    nextAt: f64 = Infinity;
    // The grid: the next sixteenth, counted from the second hit, and its frame.
    step: i32 = 0;
    stepAt: f64 = Infinity;
    arpFrom: i32 = 0;
    chord: i32 = -1;
    padOn: bool = false;
    voicing: StaticArray<f32> = new StaticArray<f32>(4);

    charge: Sweep = new Sweep(RISE, false, 0, 0x1f123bb5);
    rumble: Sweep = new Sweep(RISE, true, 1.2, 0x5bd1e995);
    whoosh: Sweep = new Sweep(HUMP, false, 0, 0x165667b1);
    boom: Drum = new Drum(0x2d358dcc);
    crash: Crash = new Crash(0x85ebca6b);
    brass: Section = new Section(5, 30, 0xc2b2ae35);
    stab: Section = new Section(6, 20, 0x27d4eb2f);
    pad: Section = new Section(6, 22, 0x9e3779b1);
    bass: Mono = new Mono(9, 0.2);
    arps: StaticArray<Mono> = [new Mono(7, 0.5), new Mono(-7, 0.5)];
    derez: StaticArray<Mono> = [new Mono(14, 0.6), new Mono(-14, 0.6)];
    drums: StaticArray<Drum> = new StaticArray<Drum>(DRUMS);
    blips: StaticArray<Blip> = new StaticArray<Blip>(BLIPS);
    bed: Bed = new Bed();
    scream: Scream = new Scream(0x5bd1e995);
    voices: Array<Voice> = [];

    locks: Train = new Train(8, 1);
    // Losses come in clusters as a sweep lands, so each plays one derez.
    losses: Train = new Train(1, 2);
    idles: Train = new Train(3, 2);
    idleNotes: StaticArray<f32> = new StaticArray<f32>(3);
    idleAt: i32 = IDLE_AFTER;
    stabDue: bool = false;
    // The song's key in semitones from D minor, from the palette.
    key: f32 = 0;
    shifted: StaticArray<f32> = new StaticArray<f32>(4);
    lockDegree: i32 = 8;
    lockSide: f32 = 1;
    lossDegree: i32 = 3;
    noise: Noise = new Noise();

    // The sidechain's dip and where it is heading.
    pump: f32 = 0;
    pumpTarget: f32 = 0;
    pumpAttack: f32 = 1;
    pumpRelease: f32 = 1;

    tape: Tape = new Tape();
    reverb: Reverb = new Reverb();
    // The side below the bass goes, steeply, so the low end stays in the
    // middle.
    side: Svf = new Svf();
    sideLow: Svf = new Svf();
    dryL: StaticArray<f32> = new StaticArray<f32>(0);
    dryR: StaticArray<f32> = new StaticArray<f32>(0);
    verbL: StaticArray<f32> = new StaticArray<f32>(0);
    verbR: StaticArray<f32> = new StaticArray<f32>(0);
    echoL: StaticArray<f32> = new StaticArray<f32>(0);
    echoR: StaticArray<f32> = new StaticArray<f32>(0);
    // The limiter's held peak and its fall per frame.
    peak: f32 = 0;
    fall: f32 = 1;
    // How hard the hits saturate the whole mix, 1 at the impact, and its
    // fall per frame.
    crush: f32 = 0;
    crushFall: f32 = 1;
    // The key change's warp: the frames the master writes, where in the warp
    // it is from 0 to 1, and its step per frame.
    warpL: StaticArray<f32> = new StaticArray<f32>(WARP_FRAMES);
    warpR: StaticArray<f32> = new StaticArray<f32>(WARP_FRAMES);
    warpAt: i32 = 0;
    warp: f32 = 1;
    warpStep: f32 = 0;
    warpLowL: Svf = new Svf();
    warpLowR: Svf = new Svf();

    override init(sampleRate: f64, maxFrames: i32, channels: i32, link: SoundLink): void {
        this.cues = link.cues;
        this.pulse = link.pulse;
        this.rate = sampleRate;
        this.channels = channels;
        let rate = <f32>sampleRate;
        let voices: Array<Voice> = [
            this.charge, this.rumble, this.whoosh, this.boom, this.crash, this.brass, this.stab, this.pad, this.bass,
            this.bed, this.scream,
        ];
        this.charge.verb = 0.3;
        this.rumble.verb = 0.05;
        this.whoosh.verb = 0.4;
        this.boom.verb = 0.1;
        this.crash.verb = 0.45;
        let brass = this.brass;
        brass.verb = 0.35;
        brass.floor = 110;
        brass.span = 2600;
        brass.resonance = 0.2;
        brass.drive = 1.6;
        brass.sub = 0.5;
        brass.gain = 0.3;
        let stab = this.stab;
        stab.verb = 0.5;
        stab.echo = 0.3;
        stab.floor = 400;
        stab.span = 6500;
        stab.resonance = 0.3;
        let pad = this.pad;
        pad.verb = 0.3;
        pad.duck = 1;
        pad.floor = 320;
        pad.span = 2600;
        pad.resonance = 0.15;
        let bass = this.bass;
        bass.verb = 0.08;
        bass.resonance = 0.12;
        this.bed.duck = 0.6;
        let scream = this.scream;
        scream.verb = 0.4;
        scream.echo = 0.15;
        for (let i = 0; i < 2; i++) {
            let arp = this.arps[i];
            arp.verb = 0.2;
            arp.echo = 0.35;
            arp.resonance = 0.18;
            voices.push(arp);
            let derez = this.derez[i];
            derez.verb = 0.45;
            derez.echo = 0.4;
            derez.cutoff = 140;
            derez.amount = 3200;
            derez.resonance = 0.3;
            voices.push(derez);
        }
        for (let i = 0; i < DRUMS; i++) {
            let drum = new Drum(<u32>(0x6a09e667 + 977 * i));
            drum.verb = 0.2;
            this.drums[i] = drum;
            voices.push(drum);
        }
        for (let i = 0; i < BLIPS; i++) {
            let blip = new Blip();
            blip.verb = 0.18;
            blip.echo = 0.85;
            this.blips[i] = blip;
            voices.push(blip);
        }
        for (let i = 0; i < voices.length; i++) {
            voices[i].init(rate);
        }
        this.voices = voices;
        pad.widen(0.014, 0.6);
        stab.widen(0.011, 0.5);
        brass.widen(0.017, 0.8);

        this.beat(0, BEAT_CHARGE, IMPACT);
        for (let i = 0; i < ROLL.length; i++) {
            this.beat(IMPACT - SIXTEENTH * ROLL[i], BEAT_ROLL, GRACE, i);
        }
        this.beat(IMPACT, BEAT_IMPACT, GRACE);
        this.beat(RAISE - BEAT, BEAT_LIFT, BEAT);
        this.beat(RAISE, BEAT_RAISE, GRACE);
        this.beat(TRACK_AT, BEAT_SWELL, BUILD_SECONDS - TRACK_AT);
        this.beat(BUILD_SECONDS, BEAT_SETTLE, Infinity);
        this.arpFrom = <i32>Math.ceil((SCAN_START - RAISE) / SIXTEENTH);
        this.noise.seed(0x7f4a7c15);

        let tape = this.tape;
        tape.pingPong = true;
        tape.setParam(kTapeTime, <f32>(3 * SIXTEENTH * 1000));
        tape.setParam(kTapeFeedback, 0.45);
        tape.setParam(kTapeMix, 0.55);
        tape.setParam(kTapeSpread, 0.6);
        tape.setParam(kTapeAge, 0.25);
        tape.init(rate, maxFrames);
        this.reverb.init(7, rate);
        this.warpLowL.set(18000, 0.1, rate);
        this.warpLowR.set(18000, 0.1, rate);
        this.side.set(120, 0.3, rate);
        this.sideLow.set(120, 0.3, rate);
        this.dryL = new StaticArray<f32>(maxFrames);
        this.dryR = new StaticArray<f32>(maxFrames);
        this.verbL = new StaticArray<f32>(maxFrames);
        this.verbR = new StaticArray<f32>(maxFrames);
        this.echoL = new StaticArray<f32>(maxFrames);
        this.echoR = new StaticArray<f32>(maxFrames);
        this.fall = <f32>Math.exp(-1 / (0.25 * sampleRate));
        this.crushFall = <f32>Math.exp(-1 / (<f64>CRUSH_SECONDS * 0.3 * sampleRate));
        this.pumpAttack = <f32>(1 - Math.exp(-1 / (0.004 * sampleRate)));
        this.pumpRelease = <f32>Math.exp(-1 / (0.13 * sampleRate));
    }

    private beat(seconds: f64, kind: i32, keep: f64, index: i32 = 0): void {
        this.beats.push(new Beat(seconds * this.rate, kind, index, keep * this.rate));
    }

    @unchecked
    override process(out: StaticArray<f32>, frames: i32, startFrame: f64): void {
        this.receive();
        let voices = this.voices;
        let count = voices.length;
        for (let i = 0; i < frames; i++) {
            if (this.intro >= 0) {
                if (this.intro >= this.nextAt) {
                    this.fireDue();
                }
                if (this.intro >= this.stepAt) {
                    this.onStep(this.step);
                    this.step++;
                    this.stepAt = (RAISE + <f64>this.step * SIXTEENTH) * this.rate;
                }
                this.intro += 1;
            }
            this.pump += (this.pumpTarget - this.pump) * this.pumpAttack;
            this.pumpTarget *= this.pumpRelease;
            let pump = this.pump;
            let l: f32 = 0;
            let r: f32 = 0;
            let vl: f32 = 0;
            let vr: f32 = 0;
            let el: f32 = 0;
            let er: f32 = 0;
            for (let v = 0; v < count; v++) {
                let voice = voices[v];
                if (!voice.active) {
                    continue;
                }
                voice.next();
                let g = <f32>1 - voice.duck * pump;
                let a = voice.outL * g;
                let b = voice.outR * g;
                l += a;
                r += b;
                vl += a * voice.verb;
                vr += b * voice.verb;
                el += a * voice.echo;
                er += b * voice.echo;
            }
            this.dryL[i] = l;
            this.dryR[i] = r;
            this.verbL[i] = vl;
            this.verbR[i] = vr;
            this.echoL[i] = el;
            this.echoR[i] = er;
            this.frame += 1;
        }
        let tape = this.tape;
        tape.process(this.echoL, this.echoR, frames);
        let reverb = this.reverb;
        let side = this.side;
        let sideLow = this.sideLow;
        let channels = this.channels;
        for (let i = 0; i < frames; i++) {
            let wl = tape.wetL[i];
            let wr = tape.wetR[i];
            // A trace of noise keeps the reverb's loop out of denormals.
            let floor = <f32>1e-10 * this.noise.next();
            reverb.tick(this.verbL[i] + <f32>0.3 * wl + floor, this.verbR[i] + <f32>0.3 * wr + floor);
            let left = this.dryL[i] + wl + VERB_GAIN * reverb.wetL;
            let right = this.dryR[i] + wr + VERB_GAIN * reverb.wetR;
            let mid = (left + right) * <f32>0.5;
            side.next((left - right) * <f32>0.5);
            sideLow.next(side.hp);
            let wide = sideLow.hp * WIDTH;
            left = mid + wide;
            right = mid - wide;
            let crush = this.crush;
            if (crush > <f32>0.0001) {
                let k = <f32>1 + HIT_DRIVE * crush;
                left += (fastTanh(left * k) - left) * crush;
                right += (fastTanh(right * k) - right) * crush;
                this.crush = crush * this.crushFall;
            }
            let at = this.warpAt;
            this.warpL[at] = left;
            this.warpR[at] = right;
            this.warpAt = (at + 1) & (WARP_FRAMES - 1);
            // The low pass runs wide open between warps, so its state is
            // always the signal's and a warp starts without a click.
            let warping = this.warp < 1;
            let swell: f32 = warping ? Mathf.sin(<f32>3.14159265 * this.warp) : 0;
            if (warping) {
                let lag = swell * swell * WARP_DEPTH * <f32>this.rate;
                left = this.warped(this.warpL, at, lag);
                right = this.warped(this.warpR, at, lag * <f32>1.15);
                this.warp = min(this.warp + this.warpStep, <f32>1);
                if ((i & 3) == 0 || this.warp == 1) {
                    let hz = WARP_FLOOR * Mathf.pow(<f32>18000 / WARP_FLOOR, <f32>1 - swell);
                    this.warpLowL.set(hz, 0.1, <f32>this.rate);
                    this.warpLowR.set(hz, 0.1, <f32>this.rate);
                }
            }
            this.warpLowL.next(left);
            this.warpLowR.next(right);
            if (warping) {
                left = this.warpLowL.lp;
                right = this.warpLowR.lp;
            }
            this.peak = max(max(Mathf.abs(left), Mathf.abs(right)), this.peak * this.fall);
            let gain = this.peak > CEILING ? CEILING / this.peak : <f32>1;
            if (channels == 1) {
                out[i] = mid * gain;
            } else {
                out[i * channels] = left * gain;
                out[i * channels + 1] = right * gain;
            }
        }
        this.pulsed.frame = this.frame;
        this.pulse!.publish(this.pulsed);
    }

    private receive(): void {
        let cues = this.cues;
        if (cues == null) {
            return;
        }
        let cue = this.cue;
        while (cues.receiveInto(cue)) {
            if (cue.kind == CUE_INTRO) {
                this.restart(cue.value);
            } else if (cue.kind == CUE_LOCK) {
                this.locks.add(<i32>cue.value);
            } else if (cue.kind == CUE_LOSS) {
                this.losses.add(<i32>cue.value);
            } else if (cue.kind == CUE_PALETTE) {
                this.setKey(cue.value, true);
                this.stabDue = true;
            } else if (cue.kind == CUE_KEY) {
                this.setKey(cue.value, false);
            } else if (cue.kind == CUE_HOVER_IN) {
                let pitch = this.degree(12 + <i32>(this.noise.unit() * 2.99));
                this.blip(pitch, pitch, 0.05, 0.15, 0.035);
            } else if (cue.kind == CUE_HOVER_OUT) {
                let pitch = this.degree(5 + <i32>(this.noise.unit() * 1.99));
                this.blip(pitch, pitch, 0.12, 0, 0.03);
            }
        }
    }

    // A new key: the pad moves at once, the arp and the bass from their next
    // steps, under the warp when one is asked for.
    private setKey(palette: f64, warp: bool): void {
        let key = KEYS[<i32>Math.min(Math.max(Math.round(palette), 0), KEYS.length - 1)];
        if (key == this.key) {
            return;
        }
        this.key = key;
        if (warp) {
            this.warp = 0;
            this.warpStep = <f32>(1 / (WARP_SECONDS * this.rate));
        }
        if (this.padOn) {
            this.pad.play(this.voiced(0), 0.001);
        }
    }

    // The master's output lag frames behind the one just written at at.
    @inline
    private warped(line: StaticArray<f32>, at: i32, lag: f32): f32 {
        let whole = <i32>lag;
        let part = lag - <f32>whole;
        let a = line[(at - whole) & (WARP_FRAMES - 1)];
        let b = line[(at - whole - 1) & (WARP_FRAMES - 1)];
        return a + (b - a) * part;
    }

    // A degree of the scale in the song's key.
    private degree(d: i32): f32 {
        return note(d) + this.key;
    }

    // Notes moved into the song's key.
    private inKey(notes: StaticArray<f32>): StaticArray<f32> {
        for (let k = 0; k < 4; k++) {
            this.shifted[k] = notes[k] + this.key;
        }
        return this.shifted;
    }

    // A frequency moved into the song's key.
    private hzInKey(hz: f32): f32 {
        return hz * Mathf.exp2(this.key / <f32>12);
    }

    // The build sequence from seconds in. Whatever still rings of the last
    // one carries on, but the pad and the bed make way.
    private restart(seconds: f64): void {
        this.intro = seconds * this.rate;
        this.next = 0;
        this.nextAt = 0;
        this.step = <i32>Math.ceil((seconds - RAISE) / SIXTEENTH);
        this.stepAt = (RAISE + <f64>this.step * SIXTEENTH) * this.rate;
        this.chord = -1;
        this.padOn = false;
        this.pad.release(0.25);
        this.bed.fade(0, 0.5);
        this.locks.at = this.step;
        this.losses.at = this.step;
        this.idles.at = this.step;
        this.idleAt = this.step + IDLE_AFTER;
    }

    private fireDue(): void {
        let beats = this.beats;
        let intro = this.intro;
        while (this.next < beats.length && intro >= beats[this.next].at) {
            let beat = beats[this.next++];
            let late = intro - beat.at;
            if (late <= beat.keep) {
                this.fire(beat, <f32>(late / this.rate));
            }
        }
        this.nextAt = this.next < beats.length ? beats[this.next].at : Infinity;
    }

    private fire(beat: Beat, late: f32): void {
        let kind = beat.kind;
        if (kind == BEAT_CHARGE) {
            this.charge.start(<f32>IMPACT, 250, 9000, 0.55, 0.3, late);
            this.rumble.start(<f32>IMPACT, 38, 75, 0.3, 0.13, late);
        } else if (kind == BEAT_ROLL) {
            let x = <f32>(1 - SIXTEENTH * ROLL[beat.index] / IMPACT);
            this.timpani(this.hzInKey(73.4), <f32>0.03 + <f32>0.12 * x * x, 0.5);
        } else if (kind == BEAT_IMPACT) {
            // Weight under the scream and little air over it.
            this.boom.start(125, this.hzInKey(36), 0.09, 2.4, 3.5, 0.5, 0);
            this.timpani(this.hzInKey(73.4), 0.34, 1.4);
            this.crash.start(2.4, 0.11);
            // Eased under the scream, which carries the hit now.
            this.brass.gain = 0.2;
            this.brass.sub = 0.9;
            this.braaam(this.inKey(BRAAAM_D), 2.5);
            this.scream.play(50 + this.key, 1.8, SCREAM_GAIN);
            this.crush = 0.65;
            let stab = this.stab;
            stab.gain = 0.022;
            stab.env.set(0.004, 1.2, 0, 0.3);
            stab.play(this.inKey(BRIGHT_D), 0.001);
        } else if (kind == BEAT_LIFT) {
            this.charge.start(<f32>BEAT, 400, 7000, 0.5, 0.14, late);
        } else if (kind == BEAT_RAISE) {
            this.boom.start(95, this.hzInKey(38), 0.07, 1.0, 2.5, 0.28, 0);
            this.timpani(this.hzInKey(58.3), 0.28, 1.1);
            this.crash.start(1.2, 0.16);
            this.whoosh.start(<f32>RAISE_SECONDS + <f32>0.35, 260, 6400, 0.45, 0.28, 0);
            this.brass.gain = 0.3;
            this.brass.sub = 0.5;
            this.braaam(this.inKey(BRAAAM_BB), 1.6);
            this.crush = 0.3;
        } else if (kind == BEAT_SWELL) {
            this.pad.env.set(1.1, 0.8, 0.8, 3.5);
            this.padOn = true;
            this.playPad();
        } else if (kind == BEAT_SETTLE) {
            this.bed.fade(0.07, 3);
        }
    }

    private braaam(notes: StaticArray<f32>, drive: f32): void {
        let brass = this.brass;
        brass.drive = drive;
        brass.env.set(0.12, 3.2, 0, 0.6);
        brass.play(notes, 0.001);
    }

    // A timpani hit on the quietest drum, its pitch falling onto hz.
    private timpani(hz: f32, gain: f32, decay: f32): void {
        this.quietestDrum().start(hz * <f32>1.5, hz, 0.035, decay, 1.3, gain, 0.7);
    }

    private quietestDrum(): Drum {
        let drums = this.drums;
        let pick = drums[0];
        for (let i = 1; i < DRUMS; i++) {
            if (drums[i].level < pick.level) {
                pick = drums[i];
            }
        }
        return pick;
    }

    // The playing chord's pad notes, shifted by semitones.
    private voiced(shift: f32): StaticArray<f32> {
        let at = max(this.chord, DM) * CHORD_SIZE + 1;
        for (let k = 0; k < 4; k++) {
            this.voicing[k] = CHORDS[at + k] + shift + this.key;
        }
        return this.voicing;
    }

    private playPad(): void {
        this.pad.play(this.voiced(0), 0.15);
    }

    // The chord for a bar: D minor through the charge and the scan, the bVI
    // on the second hit, back to D minor, then a wander every two bars.
    private harmony(bar: i32): void {
        let chord: i32;
        if (bar == 0) {
            chord = BB;
        } else if (bar < 3 || this.chord < 0) {
            chord = DM;
        } else if ((bar & 1) == 1) {
            chord = NEXT[this.chord * 3 + min(<i32>(this.noise.unit() * 3), 2)];
        } else {
            return;
        }
        if (chord == this.chord) {
            return;
        }
        this.chord = chord;
        if (this.padOn) {
            this.playPad();
        }
    }

    private onStep(n: i32): void {
        let s = n & 15;
        let bar = n >> 4;
        if (s == 0 || this.chord < 0) {
            this.harmony(bar);
        }
        // From the third bar the pulse eases down to the steady state.
        let steady = <f32>min(max(<f64>(n - 32) / 32, 0), 1);
        if (n >= 0 && (s & 3) == 0) {
            this.pumpTarget = PUMP;
        }
        if (n >= this.arpFrom) {
            this.arpStep(n, s, steady);
        }
        if (n >= 0) {
            this.bassStep(n, s, steady);
            this.pad.gain = PAD_GAIN * mix(1, <f32>0.45 + <f32>0.12 * lfo(n, 331), steady);
            this.pad.span = mix(2600, <f32>1400 + <f32>900 * lfo(n, 307), steady);
        }
        if (n == 16) {
            this.timpani(73.4, 0.16, 0.9);
        }
        if (this.locks.due(n)) {
            this.lock();
        }
        if (this.losses.due(n)) {
            this.loss();
        }
        if (this.stabDue) {
            this.stabDue = false;
            this.paletteStab();
        }
        if (this.idles.due(n)) {
            let k = this.idles.left;
            this.blip(this.idleNotes[k], this.idleNotes[k], 0.08, 0.3, 0.03);
        }
        if (n >= this.idleAt) {
            this.idle(n);
        }
    }

    // The arp rises in through the scan and opens up, then drifts once the
    // pulse settles, thinning to its strong steps when its density dips.
    private arpStep(n: i32, s: i32, steady: f32): void {
        let level: f32;
        let cutoff: f32;
        let density: f32 = 1;
        if (n < 0) {
            let rise = <f32>(n - this.arpFrom + 1) / <f32>(1 - this.arpFrom);
            level = rise * rise;
            cutoff = <f32>250 * Mathf.exp2(<f32>4.2 * rise);
        } else {
            level = mix(1, <f32>0.36 + <f32>0.14 * lfo(n, 397), steady);
            cutoff = mix(2600, <f32>900 * Mathf.exp2(<f32>1.1 * lfo(n, 173)), steady);
            density = mix(1, <f32>0.6 + <f32>0.4 * lfo(n, 277), steady);
        }
        if (WEIGHT[s] < 1 - density) {
            return;
        }
        let i = ARP[s];
        let tone = CHORDS[this.chord * CHORD_SIZE + 5 + i % 3] + <f32>(12 * (i / 3)) + this.key;
        let accent: f32 = (s & 3) == 0 ? 1 : 0.7;
        let arp = this.arps[s & 1];
        // The filter holds still under each note; a per note sweep on short
        // saws reads as brass and as a bend.
        arp.cutoff = cutoff * <f32>1.6;
        arp.amount = 0;
        arp.play(tone, tone, 0.001, 0.3, 0.3, ARP_GAIN * level * accent, (s & 1) == 0 ? <f32>-0.8 : <f32>0.8);
    }

    private bassStep(n: i32, s: i32, steady: f32): void {
        if (BASS[s] == REST) {
            return;
        }
        let level = mix(1, <f32>0.5, steady);
        let accent: f32 = (s & 3) == 0 ? 1 : 0.75;
        let bass = this.bass;
        bass.cutoff = mix(380, <f32>240 + <f32>90 * lfo(n, 233), steady);
        bass.amount = 0;
        let root = CHORDS[this.chord * CHORD_SIZE] + BASS[s] + this.key;
        bass.play(root, root, 0.001, 0.22, 0.3, BASS_GAIN * level * accent, 0);
    }

    // A lush stab of the chord playing, an octave over the pad.
    private paletteStab(): void {
        let stab = this.stab;
        stab.gain = 0.045;
        stab.env.set(0.006, 1.5, 0, 0.3);
        stab.play(this.voiced(12), 0.001);
    }

    // A beep on the quietest voice, out to alternate sides.
    private blip(from: f32, to: f32, decay: f32, edge: f32, gain: f32): void {
        let blips = this.blips;
        let pick = blips[0];
        for (let i = 0; i < BLIPS; i++) {
            let b = blips[i];
            if (!b.active) {
                pick = b;
                break;
            }
            if (b.level < pick.level) {
                pick = b;
            }
        }
        this.lockSide = -this.lockSide;
        pick.start(from, to, decay, edge, gain, this.lockSide * (<f32>0.5 + <f32>0.4 * this.noise.unit()));
        this.idleAt = max(this.idleAt, this.step + IDLE_AFTER);
    }

    // A short high beep. A burst of locks climbs the scale and a lone one
    // wanders near the last, an octave apart at most.
    private lock(): void {
        let step = this.locks.left > 0 ? 1 : this.wander();
        let d = this.lockDegree + step;
        this.lockDegree = d > 14 ? d - 5 : d < 9 ? d + 5 : d;
        let pitch = this.degree(this.lockDegree);
        this.blip(pitch, pitch, 0.07, 0.15, 0.06);
    }

    // A derez: a detuned saw note falling an octave as its resonant filter
    // closes, over a soft thump.
    private loss(): void {
        let d = this.lossDegree + this.wander();
        this.lossDegree = d > 5 ? d - 5 : d < 1 ? d + 5 : d;
        let pitch = this.degree(this.lossDegree) - 12;
        let voice = this.derez[0].level <= this.derez[1].level ? this.derez[0] : this.derez[1];
        voice.play(pitch, pitch - 2, 0.3, 0.4, 0.5, 0.05, this.noise.next() * <f32>0.9);
        this.quietestDrum().start(this.hzInKey(60), this.hzInKey(52), 0.03, 0.3, 1.2, 0.035, 0.3);
    }

    // A step of one or two degrees either way.
    private wander(): i32 {
        let step = 1 + <i32>(this.noise.unit() * 1.99);
        return this.noise.next() < 0 ? -step : step;
    }

    // A few soft random notes, once the build sequence is over.
    private idle(n: i32): void {
        let noise = this.noise;
        this.idleAt = n + IDLE_AFTER + <i32>(IDLE_SPREAD * noise.unit());
        if (this.intro < (BUILD_SECONDS + 1) * this.rate) {
            return;
        }
        for (let k = 0; k < 3; k++) {
            this.idleNotes[k] = this.degree(6 + <i32>(noise.unit() * 7.99));
        }
        this.idles.left = 0;
        this.idles.add(1 + <i32>(noise.unit() * 2.99));
    }
}
