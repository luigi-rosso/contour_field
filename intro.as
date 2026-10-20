// The build sequence that opens the piece. Dust implodes into a seed of
// light, the sphere slams out of it on a shockwave that bends the picture,
// a scan sweeps the contours in, the shells slam up off the sphere as the
// dust erupts, and the tracker locks on while the panels snap in. Everything
// is a function of time, so a rebuild just starts the clock again.

export const BUILD_SECONDS: f64 = 4.6;
// The beats, in seconds.
export const IMPACT: f64 = 0.65;
export const SCAN_START: f64 = 1.25;
export const SCAN_END: f64 = 2.25;
export const RAISE: f64 = 2.25;
export const RAISE_SECONDS: f64 = 0.55;
export const TRACK_AT: f64 = 2.9;
// Where the scan front starts and ends, in sphere radii of view y.
const SCAN_FROM: f64 = 1.3;

function clamp01(x: f64): f64 {
    return Math.min(Math.max(x, 0), 1);
}

function smooth(from: f64, to: f64, x: f64): f64 {
    let t = clamp01((x - from) / (to - from));
    return t * t * (3 - 2 * t);
}

// Decays from 1 at the beat, and is 0 before it.
function after(beat: f64, t: f64, rate: f64): f64 {
    return t < beat ? 0 : Math.exp(-(t - beat) * rate);
}

export class Intro {
    time: f64 = 0;
    // The backdrop's fade in, the seed's glow, the sphere's scale, the
    // shockwave's radius in sphere radii, the scan front, how far the shells
    // have risen, the dust burst, and how hard the lens fringes.
    fade: f64 = 0;
    flash: f64 = 0;
    form: f64 = 0;
    shock: f64 = 0;
    front: f64 = SCAN_FROM;
    raise: f64 = 0;
    burst: f64 = 0;
    glitch: f64 = 0;
    // How far the dust has fallen in to the seed, 0 once the sphere forms.
    charge: f64 = 0;
    // Extra exposure in stops, how hard the shockwave bends the picture, and
    // the camera's shake in points.
    punch: f64 = 0;
    ripple: f64 = 0;
    shakeX: f64 = 0;
    shakeY: f64 = 0;
    // The impact's screen glitch: full at the hit, clear in under a second.
    mega: f64 = 0;

    restart(): void {
        this.time = 0;
    }

    get building(): bool {
        return this.time < BUILD_SECONDS;
    }

    get tracking(): bool {
        return this.time >= TRACK_AT;
    }

    get progress(): f64 {
        return clamp01(this.time / BUILD_SECONDS);
    }

    // How far the blob panel has faded in, as Blobs In in scene.rml. Its rows
    // are nested artboards, which the panel's opacity does not reach.
    get panel(): f64 {
        return clamp01((this.time - 3.2) / 0.6);
    }

    // How much of the sphere the scan has drawn, 0 to 1.
    get scanned(): f64 {
        return clamp01((SCAN_FROM - this.front) / (2 * SCAN_FROM));
    }

    get phase(): string {
        let t = this.time;
        if (t < IMPACT) return "CHARGING";
        if (t < SCAN_START) return "IGNITION";
        if (t < SCAN_END) return "SCANNING FIELD";
        if (t < TRACK_AT) return "RAISING CONTOURS";
        return "CALIBRATING TRACKER";
    }

    advance(seconds: f64): void {
        // Held just past the end, so the curves below sit at rest.
        this.time = Math.min(this.time + seconds, BUILD_SECONDS + 1);
        let t = this.time;
        let k = t < IMPACT ? (t / IMPACT) * (t / IMPACT) : 0;
        this.charge = k;
        let hit = after(IMPACT, t, 1);
        let slam = after(RAISE, t, 1);

        this.flash = t < IMPACT ? 0.1 + 0.9 * k * k : 3 * Math.pow(hit, 9);
        this.punch = 2.2 * Math.pow(hit, 10) + 0.8 * Math.pow(slam, 10);
        this.fade = smooth(IMPACT - 0.05, IMPACT + 0.6, t);
        // A stiff spring: out past full size and back, settled in half a
        // second.
        let s = t - IMPACT;
        this.form = s < 0 ? 0 : 1 - Math.exp(-12 * s) * Math.cos(18 * s);

        // One shockwave at the impact, a smaller one as the shells lift.
        let s2 = t - RAISE;
        if (s >= 0 && s < 1.1) {
            this.shock = s * 3.6;
            this.ripple = Math.pow(hit, 3);
        } else if (s2 >= 0 && s2 < 0.85) {
            this.shock = 1 + s2 * 3;
            this.ripple = 0.5 * Math.pow(slam, 3);
        } else {
            this.shock = 0;
            this.ripple = 0;
        }

        this.front = SCAN_FROM - 2 * SCAN_FROM * smooth(SCAN_START, SCAN_END, t);
        this.raise = clamp01(s2 / RAISE_SECONDS);
        this.burst = Math.pow(slam, 2.2);

        let jitter = Math.abs(Math.sin(t * 37) * Math.sin(t * 13));
        // Both end outright rather than decaying forever, so nothing tears or
        // fringes once the piece has settled.
        this.glitch = (0.3 * k * jitter + Math.pow(hit, 6) + 0.6 * Math.pow(slam, 6)) * (1 - smooth(TRACK_AT, BUILD_SECONDS, t));
        this.mega = Math.pow(hit, 4) * (1 - smooth(IMPACT + 0.5, IMPACT + 0.9, t));
        let shake = 2 * k + 16 * Math.pow(hit, 7) + 6 * Math.pow(slam, 8);
        this.shakeX = shake * 0.5 * (Math.sin(t * 83) + Math.sin(t * 47.3));
        this.shakeY = shake * 0.5 * (Math.sin(t * 71.1) + Math.sin(t * 29.7));
    }
}
