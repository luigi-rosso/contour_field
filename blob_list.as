// Mirrors the tracker's locks into the blobs list that the scroll panel in
// scene.rml repeats, one Blob view model per track.

import { PropertyList, PropertyNumber, PropertyString, ViewModel } from "rive/data";
import { formatInt } from "rive/format";
import { Track } from "./tracker";

class Row {
    id: i32;
    vm: ViewModel;
    alpha: PropertyNumber?;
    kind: PropertyString?;
    elevation: PropertyString?;
    coords: PropertyString?;
    // Seconds since its lock was lost, 0 while it holds.
    lost: f64 = 0;
    private shownAlpha: f64 = -1;
    private shownKind: string = "";

    constructor(t: Track) {
        this.id = t.id;
        let vm = ViewModel.create("Blob");
        this.vm = vm;
        let ident = vm.getString("ident");
        if (ident != null) {
            ident.value = formatInt(<f64>t.id);
        }
        this.alpha = vm.getNumber("alpha");
        this.kind = vm.getString("kind");
        this.elevation = vm.getString("elevation");
        this.coords = vm.getString("coords");
    }

    show(alpha: f64, kind: string): void {
        let a = this.alpha;
        if (a != null && Math.abs(alpha - this.shownAlpha) > 0.004) {
            this.shownAlpha = alpha;
            a.value = alpha;
        }
        let k = this.kind;
        if (k != null && kind != this.shownKind) {
            this.shownKind = kind;
            k.value = kind;
        }
    }
}

// How long a row stays after its lock is lost, fading as it goes.
const DECAY: f64 = 4;

function find(tracks: Array<Track>, id: i32): Track? {
    for (let i = 0; i < tracks.length; i++) {
        if (tracks[i].id == id) {
            return tracks[i];
        }
    }
    return null;
}

export class BlobList {
    list: PropertyList? = null;
    // In id order: new locks append, and a lost one keeps its slot until it
    // decays, so rows never reshuffle.
    private rows: Array<Row> = [];
    private sweeps: i32 = -1;

    // Fade scales every row, for the panel around them fading in.
    sync(tracks: Array<Track>, sweeps: i32, seconds: f64, cx: f64, cy: f64, r: f64, fade: f64): void {
        let list = this.list;
        if (list == null) {
            return;
        }
        let rows = this.rows;
        let newest = rows.length > 0 ? rows[rows.length - 1].id : -1;
        for (let i = 0; i < tracks.length; i++) {
            if (tracks[i].id > newest) {
                let row = new Row(tracks[i]);
                rows.push(row);
                list.push(row.vm);
            }
        }
        let relabel = sweeps != this.sweeps;
        this.sweeps = sweeps;
        for (let i = rows.length - 1; i >= 0; i--) {
            let row = rows[i];
            let t = find(tracks, row.id);
            if (t == null || t.lost >= 0) {
                row.lost += seconds;
                if (row.lost >= DECAY) {
                    list.remove(row.vm);
                    rows.splice(i, 1);
                } else {
                    row.show(0.5 * (1 - row.lost / DECAY) * fade, "LOST");
                }
                continue;
            }
            row.lost = 0;
            row.show(t.alpha * fade, t.peak ? "PEAK" : "HOLLOW");
            if (!relabel) {
                continue;
            }
            let elevation = row.elevation;
            if (elevation != null) {
                elevation.value = formatInt(Math.round(t.height * 100)) + "%";
            }
            let coords = row.coords;
            if (coords != null) {
                coords.value = formatInt(t.pointX(cx, r)) + ", " + formatInt(t.pointY(cy, r));
            }
        }
    }

    clear(): void {
        let list = this.list;
        if (list != null) {
            list.clear();
        }
        this.rows = [];
    }
}
