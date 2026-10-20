// The colour schemes the swatches in scene.rml choose between, in linear
// light, and the blend that eases from one to the next.

// Per palette: lines, their hot cores, the rim and dust glow, the deep
// backdrop and the bloom haze tint, three channels each.
const STRIDE: i32 = 15;
const TABLE: StaticArray<f32> = [
    // Cobalt
    0.38, 0.52, 1.0, 0.82, 0.88, 1.0, 0.55, 0.7, 1.0, 0.008, 0.014, 0.032, 0.7, 0.88, 1.2,
    // Ember
    1.0, 0.4, 0.1, 1.0, 0.86, 0.66, 1.0, 0.55, 0.22, 0.03, 0.011, 0.005, 1.2, 0.82, 0.55,
    // Aurora
    0.12, 0.95, 0.62, 0.75, 1.0, 0.9, 0.3, 1.0, 0.74, 0.004, 0.022, 0.02, 0.6, 1.15, 0.95,
    // Ultraviolet
    0.74, 0.3, 1.0, 0.96, 0.82, 1.0, 0.8, 0.45, 1.0, 0.02, 0.008, 0.036, 1.05, 0.7, 1.25,
    // Ivory
    0.66, 0.66, 0.7, 1.0, 0.98, 0.94, 0.8, 0.8, 0.84, 0.012, 0.012, 0.015, 1.0, 1.0, 1.0,
];
const NAMES: StaticArray<string> = ["COBALT", "EMBER", "AURORA", "ULTRAVIOLET", "IVORY"];
export const LINE: i32 = 0;
export const HOT: i32 = 3;
export const GLOW: i32 = 6;
export const DEEP: i32 = 9;
export const HAZE: i32 = 12;

export class PaletteMix {
    index: i32 = 0;
    colors: StaticArray<f32> = new StaticArray<f32>(STRIDE);

    constructor() {
        this.ease(0, Infinity);
    }

    get name(): string {
        return NAMES[this.index];
    }

    // Moves toward the palette at index, clamped to the table, over about
    // half a second.
    ease(index: f64, seconds: f64): void {
        this.index = <i32>Math.min(Math.max(Math.round(index), 0), NAMES.length - 1);
        let k = <f32>(1 - Math.exp(-seconds * 8));
        let base = this.index * STRIDE;
        for (let i = 0; i < STRIDE; i++) {
            this.colors[i] += (TABLE[base + i] - this.colors[i]) * k;
        }
    }
}
