import { Extension, Prec, RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";
import { DocumentUpdatedOnePtr, Highlight, HighlightTag } from "./wasm_types";

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
    updateDocument(text: string): Highlight[] {
        const encoded = new TextEncoder().encode(text);
        const ptr = this.wasmExports.startDocumentUpdate(encoded.length);
        new Uint8Array(this.memory.buffer).set(encoded, ptr);
        const result = this.wasmExports.endDocumentUpdate();

        if (result == 0) {
            return [];
        }

        const highlights: Highlight[] = [];
        const document_updated = new DocumentUpdatedOnePtr(this.memory.buffer, result).deref();
        for (let index = 0; index < document_updated.highlights_len; index += 1) {
            highlights.push(document_updated.highlights_ptr.deref(index));
        }

        return highlights;
    }
}

// TODO: Proper storage of WasmAgent per CodeMirror conventions (using a StateField).
class Highlighter {
    public decorations: DecorationSet;
    private markCache: {[n: number]: Decoration} = {
        [HighlightTag.chord]: Decoration.mark({class: "chord"}),
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
    ".chord": {
        color: "green",
    },
});

export function codeMirrorWasmAgent(wasmAgent: WasmAgent): Extension {
    const highlighter = Prec.high(ViewPlugin.define(view => new Highlighter(view, wasmAgent), {
        decorations: v => v.decorations,
    }));
 
    return [highlighter, highlighterTheme];
}
  