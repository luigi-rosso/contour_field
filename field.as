// The heightmap field.wgsl renders, mirrored on the CPU so the blob tracker
// finds the same shapes the GPU shows. Keep the constants in step with
// field() and contourValue() there.

function hash3(x: i32, y: i32, z: i32): u32 {
    let h: u32 = (<u32>x * 0x8da6b343) ^ (<u32>y * 0xd8163841) ^ (<u32>z * 0xcb1ab31f);
    h = (h ^ (h >> 16)) * 0x7feb352d;
    h = (h ^ (h >> 15)) * 0x846ca68b;
    return h ^ (h >> 16);
}

function grad(h: u32, x: f32, y: f32, z: f32): f32 {
    let b = h & 15;
    let u = b < 8 ? x : y;
    let v = b < 4 ? y : (b == 12 || b == 14 ? x : z);
    return ((b & 1) == 0 ? u : -u) + ((b & 2) == 0 ? v : -v);
}

function fade(t: f32): f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

export function noise3(x: f32, y: f32, z: f32): f32 {
    let fx = Mathf.floor(x);
    let fy = Mathf.floor(y);
    let fz = Mathf.floor(z);
    let ix = <i32>fx;
    let iy = <i32>fy;
    let iz = <i32>fz;
    let dx = x - fx;
    let dy = y - fy;
    let dz = z - fz;
    let ux = fade(dx);
    let uy = fade(dy);
    let uz = fade(dz);
    let n000 = grad(hash3(ix, iy, iz), dx, dy, dz);
    let n100 = grad(hash3(ix + 1, iy, iz), dx - 1, dy, dz);
    let n010 = grad(hash3(ix, iy + 1, iz), dx, dy - 1, dz);
    let n110 = grad(hash3(ix + 1, iy + 1, iz), dx - 1, dy - 1, dz);
    let n001 = grad(hash3(ix, iy, iz + 1), dx, dy, dz - 1);
    let n101 = grad(hash3(ix + 1, iy, iz + 1), dx - 1, dy, dz - 1);
    let n011 = grad(hash3(ix, iy + 1, iz + 1), dx, dy - 1, dz - 1);
    let n111 = grad(hash3(ix + 1, iy + 1, iz + 1), dx - 1, dy - 1, dz - 1);
    let x00 = n000 + (n100 - n000) * ux;
    let x10 = n010 + (n110 - n010) * ux;
    let x01 = n001 + (n101 - n001) * ux;
    let x11 = n011 + (n111 - n011) * ux;
    let y0 = x00 + (x10 - x00) * uy;
    let y1 = x01 + (x11 - x01) * uy;
    return y0 + (y1 - y0) * uz;
}

// As the constants of the same names in field.wgsl.
const BASE_DRIFT: f32 = 0.15;
const DETAIL_FLOW: f32 = 1.5;
const STIR: f32 = 0.9;
const SEEP: f32 = 0.25;
export const STEP_LINES: f32 = 5;
const TERRACE: f32 = 0.85;
const CLIFF: f32 = 0.3;

function smoothstep(e0: f32, e1: f32, x: f32): f32 {
    let t = Mathf.min(Mathf.max((x - e0) / (e1 - e0), 0), 1);
    return t * t * (3 - 2 * t);
}

export class Field {
    frequency: f32 = 1.2;
    warp: f32 = 0.9;
    lines: f32 = 30;
    // Detail in contour lines per line of the major relief.
    detail: f32 = 0.16;
    time: f32 = 0;

    // Contour value at a point on the unit sphere in object space, as
    // contourValue(field(n)) in field.wgsl.
    contour(nx: f32, ny: f32, nz: f32): f32 {
        let t = this.time;
        let px = nx * this.frequency;
        let py = ny * this.frequency;
        let pz = nz * this.frequency;
        let qx = px * 0.6;
        let qy = py * 0.6;
        let qz = pz * 0.6;
        let drift = t * BASE_DRIFT;
        let wx = noise3(qx, qy, qz + drift);
        let wy = noise3(qx + 5.2, qy + 1.3, qz + 2.8 - drift);
        let wz = noise3(qx - 3.7, qy + 2.9 + drift, qz + 7.1);
        let ux = px + wx * this.warp;
        let uy = py + wy * this.warp;
        let uz = pz + wz * this.warp;

        let sx = ux;
        let sy = uy;
        let sz = uz;
        let base: f32 = 0;
        let amp: f32 = 0.5;
        for (let i = 0; i < 3; i++) {
            base += amp * noise3(sx, sy, sz);
            sx = sx * 2.03 + 1.7;
            sy = sy * 2.03 - 3.1;
            sz = sz * 2.03 + 2.3;
            amp *= 0.45;
        }
        let flow = t * DETAIL_FLOW;
        let sx2 = qx * 1.3;
        let sy2 = qy * 1.3;
        let sz2 = qz * 1.3;
        let stirX = noise3(sx2 + 1.9, sy2 + 7.3, sz2 + flow);
        let stirY = noise3(sx2 + 8.1, sy2 - 2.4, sz2 - flow);
        let stirZ = noise3(sx2 - 5.5, sy2 + flow, sz2 + 4.4);
        let dx = (ux + stirX * STIR) * 1.9;
        let dy = (uy + stirY * STIR) * 1.9;
        let dz = (uz + stirZ * STIR) * 1.9 + flow * SEEP;
        let detail: f32 = 0;
        amp = 0.5;
        for (let i = 0; i < 2; i++) {
            detail += amp * noise3(dx, dy, dz);
            dx = dx * 2.03 - 2.9;
            dy = dy * 2.03 + 1.1;
            dz = dz * 2.03 + 0.7;
            amp *= 0.4;
        }

        let u = base * this.lines;
        let step = u / STEP_LINES;
        let stepped = Mathf.floor(step) + smoothstep(0.5 - CLIFF, 0.5 + CLIFF, step - Mathf.floor(step));
        return u + (stepped * STEP_LINES - u) * TERRACE + detail * this.lines * this.detail;
    }
}

// The sphere's rotation as a unit quaternion taking object space to view
// space, and the view to object matrix the shader and tracker read, by column.
export class Orientation {
    w: f64 = 1;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    m: StaticArray<f32> = new StaticArray<f32>(9);

    // Turns the sphere by angle radians about a view space axis.
    turn(ax: f64, ay: f64, az: f64, angle: f64): void {
        let len = Math.sqrt(ax * ax + ay * ay + az * az);
        if (len < 1e-9 || angle == 0) {
            return;
        }
        let s = Math.sin(angle * 0.5) / len;
        let bw = Math.cos(angle * 0.5);
        let bx = ax * s;
        let by = ay * s;
        let bz = az * s;
        let w = bw * this.w - bx * this.x - by * this.y - bz * this.z;
        let x = bw * this.x + bx * this.w + by * this.z - bz * this.y;
        let y = bw * this.y - bx * this.z + by * this.w + bz * this.x;
        let z = bw * this.z + bx * this.y - by * this.x + bz * this.w;
        let n = 1 / Math.sqrt(w * w + x * x + y * y + z * z);
        this.w = w * n;
        this.x = x * n;
        this.y = y * n;
        this.z = z * n;
        this.update();
    }

    update(): void {
        let w = this.w;
        let x = this.x;
        let y = this.y;
        let z = this.z;
        // Rows of the object to view rotation are the columns of its inverse.
        let m = this.m;
        m[0] = <f32>(1 - 2 * (y * y + z * z));
        m[1] = <f32>(2 * (x * y - w * z));
        m[2] = <f32>(2 * (x * z + w * y));
        m[3] = <f32>(2 * (x * y + w * z));
        m[4] = <f32>(1 - 2 * (x * x + z * z));
        m[5] = <f32>(2 * (y * z - w * x));
        m[6] = <f32>(2 * (x * z - w * y));
        m[7] = <f32>(2 * (y * z + w * x));
        m[8] = <f32>(1 - 2 * (x * x + y * y));
    }

    copyFrom(other: Orientation): void {
        for (let i = 0; i < 9; i++) {
            this.m[i] = other.m[i];
        }
    }
}
