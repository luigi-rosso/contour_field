// Banshee's stereo biquad, the RBJ cookbook shapes the tape echo uses.

const kPi: f32 = 3.14159265358979;
const kSqrt2: f32 = 1.4142135623730951;

export class Biquad {
    b0: f32 = 1;
    b1: f32 = 0;
    b2: f32 = 0;
    a1: f32 = 0;
    a2: f32 = 0;
    z1: StaticArray<f32> = new StaticArray<f32>(2);
    z2: StaticArray<f32> = new StaticArray<f32>(2);

    clear(): void {
        this.z1.fill(0);
        this.z2.fill(0);
    }

    @unchecked
    tick(channel: i32, x: f32): f32 {
        let y = this.b0 * x + this.z1[channel];
        this.z1[channel] = this.b1 * x - this.a1 * y + this.z2[channel];
        this.z2[channel] = this.b2 * x - this.a2 * y;
        return y;
    }

    normalize(a0: f32): void {
        this.b0 /= a0;
        this.b1 /= a0;
        this.b2 /= a0;
        this.a1 /= a0;
        this.a2 /= a0;
    }

    highShelf(rate: f32, freq: f32, db: f32): void {
        let A = Mathf.pow(10, db / 40);
        let w: f32 = <f32>2 * kPi * freq / rate;
        let cs = Mathf.cos(w);
        let sn = Mathf.sin(w);
        let beta = Mathf.sqrt(A) * sn * kSqrt2;
        this.b0 = A * ((A + 1) + (A - 1) * cs + beta);
        this.b1 = <f32>-2 * A * ((A - 1) + (A + 1) * cs);
        this.b2 = A * ((A + 1) + (A - 1) * cs - beta);
        let a0 = (A + 1) - (A - 1) * cs + beta;
        this.a1 = <f32>2 * ((A - 1) - (A + 1) * cs);
        this.a2 = (A + 1) - (A - 1) * cs - beta;
        this.normalize(a0);
    }

    lowPass(rate: f32, freq: f32, q: f32): void {
        let w: f32 = <f32>2 * kPi * freq / rate;
        let alpha = Mathf.sin(w) / (<f32>2 * q);
        let cs = Mathf.cos(w);
        this.b0 = (<f32>1 - cs) / 2;
        this.b1 = <f32>1 - cs;
        this.b2 = (<f32>1 - cs) / 2;
        let a0 = <f32>1 + alpha;
        this.a1 = <f32>-2 * cs;
        this.a2 = <f32>1 - alpha;
        this.normalize(a0);
    }

    peak(rate: f32, freq: f32, db: f32, q: f32): void {
        let A = Mathf.pow(10, db / 40);
        let w: f32 = <f32>2 * kPi * freq / rate;
        let alpha = Mathf.sin(w) / (<f32>2 * q);
        let cs = Mathf.cos(w);
        this.b0 = <f32>1 + alpha * A;
        this.b1 = <f32>-2 * cs;
        this.b2 = <f32>1 - alpha * A;
        let a0 = <f32>1 + alpha / A;
        this.a1 = <f32>-2 * cs;
        this.a2 = <f32>1 - alpha / A;
        this.normalize(a0);
    }
}
