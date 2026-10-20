// The blob tracking overlay, drawn crisp over the post processed image:
// corner brackets, a crosshair at each centroid, links between locks in the
// order they were acquired, and an id with coordinates above each box.

import { Renderer } from "rive/renderer";
import { Paint, PaintStyle } from "rive/paint";
import { Path } from "rive/path";
import { Font, TextRunStyle } from "rive/text";
import { Mat2D } from "rive/mat2d";
import { Vector } from "rive/vector";
import { formatInt } from "rive/format";
import { Track } from "./tracker";

export class Hud {
    private style: TextRunStyle? = null;
    private line: Paint = new Paint();
    private link: Paint = new Paint();
    private ink: Paint = new Paint();
    private path: Path = new Path();
    private sweeps: i32 = -1;

    constructor(font: Font?) {
        this.line.style = PaintStyle.stroke;
        this.line.thickness = 1.25;
        this.line.color = 0xE6FFFFFF;
        this.link.style = PaintStyle.stroke;
        this.link.thickness = 1;
        this.link.color = 0xB3FFFFFF;
        this.ink.color = 0xEBFFFFFF;
        if (font != null) {
            let style = new TextRunStyle(font);
            style.size = 14;
            style.letterSpacing = 0.4;
            style.paint = this.ink;
            this.style = style;
        }
    }

    draw(renderer: Renderer, tracks: Array<Track>, sweeps: i32, cx: f64, cy: f64, r: f64): void {
        let path = this.path;
        path.reset();
        let first = true;
        for (let i = 0; i < tracks.length; i++) {
            let t = tracks[i];
            if (t.alpha < 0.5) {
                continue;
            }
            let s = r * t.lift;
            let p = Vector.xy(<f32>(cx + t.x * s), <f32>(cy + t.y * s));
            if (first) {
                path.moveTo(p);
                first = false;
            } else {
                path.lineTo(p);
            }
        }
        renderer.drawPath(path, this.link);

        let relabel = sweeps != this.sweeps;
        this.sweeps = sweeps;
        for (let i = 0; i < tracks.length; i++) {
            let t = tracks[i];
            if (relabel) {
                this.label(t, cx, cy, r);
            }
            if (t.alpha <= 0) {
                continue;
            }
            // Boxes sit on the shell of the contour that bounds them.
            let s = r * t.lift;
            let x0 = <f32>(cx + t.x0 * s);
            let y0 = <f32>(cy + t.y0 * s);
            let x1 = <f32>(cx + t.x1 * s);
            let y1 = <f32>(cy + t.y1 * s);
            let x = <f32>(cx + t.x * s);
            let y = <f32>(cy + t.y * s);
            path.reset();
            if (t.framed) {
                path.moveTo(Vector.xy(x0, y0));
                path.lineTo(Vector.xy(x1, y0));
                path.lineTo(Vector.xy(x1, y1));
                path.lineTo(Vector.xy(x0, y1));
                path.close();
            } else {
                let c = Mathf.min(Mathf.max(Mathf.min(x1 - x0, y1 - y0) * 0.25, 6), 22);
                this.corner(x0, y0, c, c);
                this.corner(x1, y0, -c, c);
                this.corner(x0, y1, c, -c);
                this.corner(x1, y1, -c, -c);
            }
            path.moveTo(Vector.xy(x - 6, y));
            path.lineTo(Vector.xy(x + 6, y));
            path.moveTo(Vector.xy(x, y - 6));
            path.lineTo(Vector.xy(x, y + 6));
            renderer.save();
            renderer.modulateOpacity(t.alpha);
            renderer.drawPath(path, this.line);
            if (this.style != null) {
                renderer.transform(Mat2D.withTranslation(x0, y0 - 19));
                t.text.draw(renderer);
            }
            renderer.restore();
        }
    }

    private corner(x: f32, y: f32, dx: f32, dy: f32): void {
        let path = this.path;
        path.moveTo(Vector.xy(x + dx, y));
        path.lineTo(Vector.xy(x, y));
        path.lineTo(Vector.xy(x, y + dy));
    }

    private label(t: Track, cx: f64, cy: f64, r: f64): void {
        let style = this.style;
        if (style == null) {
            return;
        }
        let label = formatInt(<f64>t.id) + "  " + formatInt(t.pointX(cx, r)) + ", " + formatInt(t.pointY(cy, r));
        if (label == t.label) {
            return;
        }
        t.label = label;
        t.text.clear();
        t.text.append(label, style);
    }
}
