// Banshee's synth kernel, trimmed to the filter, envelope and noise the
// sound uses, ported from dsp/src/synth so the C++ stays the reference.

const kPi: f32 = 3.14159265358979;

function clampf(v: f32, lo: f32, hi: f32): f32 {
    return max(lo, min(v, hi));
}

export function noteHz(note: f32): f32 {
    return <f32>440.0 * Mathf.pow(2.0, (note - <f32>69) / <f32>12.0);
}

// xorshift32, uniform in [-1, 1).
export class Noise {
    state: u32 = 0x9e3779b9;

    seed(value: u32): void {
        this.state = value != 0 ? value : 1;
    }

    next(): f32 {
        let s = this.state;
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        this.state = s;
        return <f32><i32>s * (<f32>1.0 / <f32>2147483648.0);
    }

    unit(): f32 {
        return <f32>0.5 + <f32>0.5 * this.next();
    }
}

// Trapezoidal state variable filter: lowpass, bandpass and highpass from one
// pass, stable under any modulation.
export class Svf {
    ic1: f32 = 0;
    ic2: f32 = 0;
    g: f32 = 0;
    k: f32 = 1;
    a1: f32 = 0;
    a2: f32 = 0;
    a3: f32 = 0;
    lp: f32 = 0;
    bp: f32 = 0;
    hp: f32 = 0;

    set(hz: f32, resonance: f32, sampleRate: f32): void {
        hz = clampf(hz, 10, sampleRate * 0.45);
        this.g = Mathf.tan(kPi * hz / sampleRate);
        this.k = <f32>2 - <f32>2 * clampf(resonance, 0, 0.99);
        this.a1 = <f32>1 / (<f32>1 + this.g * (this.g + this.k));
        this.a2 = this.g * this.a1;
        this.a3 = this.g * this.a2;
    }
    clear(): void {
        this.ic1 = 0;
        this.ic2 = 0;
    }
    next(input: f32): void {
        let v3: f32 = input - this.ic2;
        let v1: f32 = this.a1 * this.ic1 + this.a2 * v3;
        let v2: f32 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
        this.ic1 = <f32>2 * v1 - this.ic1;
        this.ic2 = <f32>2 * v2 - this.ic2;
        this.lp = v2;
        this.bp = v1;
        this.hp = input - this.k * v1 - v2;
    }
}

export const kIdle: i32 = 0;
export const kAttack: i32 = 1;
export const kDecay: i32 = 2;
export const kSustain: i32 = 3;
export const kRelease: i32 = 4;

// ADSR with the analog shape: the attack chases past its target so it stays
// convex, decay and release fall exponentially.
export class Adsr {
    stage: i32 = kIdle;
    value: f32 = 0;
    attackCoef: f32 = 1;
    decayCoef: f32 = 1;
    releaseCoef: f32 = 1;
    sustain: f32 = 1;
    sampleRate: f32 = 48000;

    coefFor(seconds: f32): f32 {
        // Reaches within 1% in the time given.
        return seconds > 0 ? <f32>1.0 - Mathf.exp(<f32>-4.6 / (seconds * this.sampleRate)) : <f32>1.0;
    }
    set(attackS: f32, decayS: f32, sustainLevel: f32, releaseS: f32): void {
        // Aiming at 1.3, the curve crosses 1 after ln(1.3 / 0.3) constants.
        this.attackCoef = attackS > 0 ? <f32>1.0 - Mathf.exp(<f32>-1.466 / (attackS * this.sampleRate)) : <f32>1.0;
        this.decayCoef = this.coefFor(decayS);
        this.releaseCoef = this.coefFor(releaseS);
        this.sustain = clampf(sustainLevel, 0, 1);
    }
    gate(on: bool): void {
        if (on) {
            this.stage = kAttack;
        } else if (this.stage != kIdle) {
            this.stage = kRelease;
        }
    }
    next(): f32 {
        let stage = this.stage;
        if (stage == kAttack) {
            // Aiming past 1 keeps the curve convex like a capacitor.
            this.value += (<f32>1.3 - this.value) * this.attackCoef;
            if (this.value >= 1) {
                this.value = 1;
                this.stage = kDecay;
            }
        } else if (stage == kDecay) {
            this.value += (this.sustain - this.value) * this.decayCoef;
            if (this.value - this.sustain < <f32>1e-4) {
                this.value = this.sustain;
                this.stage = kSustain;
            }
        } else if (stage == kSustain) {
            this.value = this.sustain;
        } else if (stage == kRelease) {
            this.value -= this.value * this.releaseCoef;
            if (this.value < <f32>1e-4) {
                this.value = 0;
                this.stage = kIdle;
            }
        }
        return this.value;
    }
}
