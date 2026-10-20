// The piece's sound, cued from the Field view model the visuals write. It is
// its own script, so a host without audio processors loses only the sound.

import { Context, Node } from "rive/host";
import { PropertyNumber, PropertyTrigger } from "rive/data";
import { Audio, AudioHandle } from "rive/audio";
import { BUILD_SECONDS } from "./intro";
import { Cue, Sound, SoundLink, CUE_HOVER_IN, CUE_HOVER_OUT, CUE_INTRO, CUE_KEY, CUE_LOCK, CUE_LOSS, CUE_PALETTE } from "./audio/sound";

// Longer than this without a block from the processor, it looks afresh.
const STALL_SECONDS: f64 = 0.25;

export class Soundtrack extends Node {
    private context: Context? = null;
    private link: SoundLink = new SoundLink();
    private cue: Cue = new Cue();
    // Held, as releasing the handle stops the processor.
    private sound: AudioHandle? = null;
    private pulse: f64 = 0;
    private stalled: f64 = 0;
    private build: PropertyNumber? = null;
    private palette: PropertyNumber? = null;
    private locks: PropertyNumber? = null;
    private losses: PropertyNumber? = null;
    private hoverIn: PropertyTrigger? = null;
    private hoverOut: PropertyTrigger? = null;
    // The first look only takes the values in, so a late start plays no
    // backlog.
    private seen: bool = false;
    private lastBuild: f64 = 0;
    private lastPalette: i32 = 0;
    private lastLocks: i32 = 0;
    private lastLosses: i32 = 0;

    override init(context: Context): bool {
        this.context = context;
        this.sound = Audio.start(() => new Sound(), this.link);
        return true;
    }

    override advance(seconds: f64): bool {
        // Cued only while blocks come, so the score starts where the visuals
        // are, even when audio starts late or stalls.
        let pulse = this.link.pulse.seq;
        if (pulse == this.pulse) {
            this.stalled += seconds;
            return true;
        }
        this.pulse = pulse;
        if (this.stalled > STALL_SECONDS) {
            this.seen = false;
        }
        this.stalled = 0;
        if (!this.bind()) {
            return true;
        }
        let build = this.build!.value;
        let palette = <i32>Math.round(this.palette!.value);
        let locks = <i32>this.locks!.value;
        let losses = <i32>this.losses!.value;
        if (!this.seen || build < this.lastBuild) {
            // The visuals have already advanced this frame, and the processor
            // plays the cue from the frame's start.
            this.send(CUE_INTRO, Math.max(build * BUILD_SECONDS - seconds, 0));
            this.send(CUE_KEY, palette);
        }
        if (this.seen) {
            if (palette != this.lastPalette) {
                this.send(CUE_PALETTE, palette);
            }
            if (locks > this.lastLocks) {
                this.send(CUE_LOCK, locks - this.lastLocks);
            }
            if (losses > this.lastLosses) {
                this.send(CUE_LOSS, losses - this.lastLosses);
            }
        }
        this.seen = true;
        this.lastBuild = build;
        this.lastPalette = palette;
        this.lastLocks = locks;
        this.lastLosses = losses;
        return true;
    }

    // The view model can be missing at init, and asking for it there
    // detaches the script.
    private bind(): bool {
        if (this.build != null) {
            return true;
        }
        let context = this.context;
        let vm = context != null ? context.viewModel() : null;
        if (vm == null) {
            return false;
        }
        let build = vm.getNumber("build");
        let palette = vm.getNumber("palette");
        let locks = vm.getNumber("locks");
        let losses = vm.getNumber("losses");
        if (build == null || palette == null || locks == null || losses == null) {
            return false;
        }
        this.palette = palette;
        this.locks = locks;
        this.losses = losses;
        this.build = build;
        let hoverIn = vm.getTrigger("hoverIn");
        if (hoverIn != null) {
            hoverIn.addListenerWith(this, Soundtrack.onHoverIn);
            this.hoverIn = hoverIn;
        }
        let hoverOut = vm.getTrigger("hoverOut");
        if (hoverOut != null) {
            hoverOut.addListenerWith(this, Soundtrack.onHoverOut);
            this.hoverOut = hoverOut;
        }
        return true;
    }

    // Hovers sound at once, but only while the sound is playing, so a
    // stalled processor is not handed a backlog of them.
    static onHoverIn(self: Soundtrack): void {
        if (self.stalled < STALL_SECONDS) {
            self.send(CUE_HOVER_IN, 0);
        }
    }

    static onHoverOut(self: Soundtrack): void {
        if (self.stalled < STALL_SECONDS) {
            self.send(CUE_HOVER_OUT, 0);
        }
    }

    private send(kind: i32, value: f64): void {
        let cue = this.cue;
        cue.kind = kind;
        cue.value = value;
        this.link.cues.send(cue);
    }
}
