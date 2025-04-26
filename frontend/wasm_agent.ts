import { Extension, Prec, RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";

export class WasmAgent {
    private memory: WebAssembly.Memory;
    private wasmExports: any;

    constructor(private url: string) {
        this.memory = new WebAssembly.Memory({
            initial: 32,
        });
    }

    async init() {
        const t = this;
        const result = await WebAssembly.instantiateStreaming(fetch(this.url), {
            env: {
                memory: this.memory,
                consoleLog(ptr, len) {
                    t.consoleLog(ptr, len)
                },
            }
        });
        this.wasmExports = result.instance.exports;
    }

    // Imports
    private consoleLog(ptr: number, len: number) {
        console.log(new TextDecoder().decode(this.memory.buffer.slice(ptr, ptr + len)));
    }

    // Exports
    updateDocument(text: string) {
        const encoded = new TextEncoder().encode(text);
        const ptr = this.wasmExports.startDocumentUpdate(encoded.length);
        new Uint8Array(this.memory.buffer).set(encoded, ptr);
        const result = this.wasmExports.endDocumentUpdate();

        const dv = new DataView(this.memory.buffer);

        const highlights: Highlight[] = [];

        const start = dv.getUint32(result, true);
        const highlightSizeInBytes = 1 + 2 * 4;
        const end = start + dv.getUint32(result + 4, true) * highlightSizeInBytes;
    
        for (let ptr = start; ptr < end; ptr += highlightSizeInBytes) {
            highlights.push({
                tag: dv.getUint8(ptr),
                start: dv.getUint32(ptr + 1, true),
                end: dv.getUint32(ptr + 5, true),
            });
        }

        return highlights;
    }
}

enum HighlightTag {
    amogus = 0,
}

interface Highlight {
    tag: HighlightTag,
    start: number,
    end: number,
}

// TODO: Proper storage of WasmAgent per CodeMirror conventions (using a StateField).
class Highlighter {
    public decorations: DecorationSet;
    private markCache: {[n: number]: Decoration} = {
        [HighlightTag.amogus]: Decoration.mark({class: "amogus"}),
    }

    constructor(view: EditorView, private wasmAgent: WasmAgent) {
        this.decorations = this.buildDecorations(view);
    }

    update(update: ViewUpdate) {
        this.decorations = this.buildDecorations(update.view);
    }

    buildDecorations(view: EditorView): DecorationSet {
        const builder = new RangeSetBuilder<Decoration>();

        const highlights = this.wasmAgent.updateDocument(view.state.doc.toString());
        for (const highlight of highlights) {
            builder.add(highlight.start, highlight.end, this.markCache[highlight.tag]);
        }

        return builder.finish();
    }
}

const highlighterTheme = EditorView.theme({
    ".amogus": {
        color: "red",
    },
});

export function codeMirrorWasmAgent(wasmAgent: WasmAgent): Extension {
    const highlighter = Prec.high(ViewPlugin.define(view => new Highlighter(view, wasmAgent), {
        decorations: v => v.decorations,
    }));
 
    return [highlighter, highlighterTheme];
}
  