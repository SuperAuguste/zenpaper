import { Extension, Prec, RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";
import { DocumentUpdated, DocumentUpdatedOnePtr, Highlight, HighlightManyPtr, HighlightsUpdated, HighlightsUpdatedOnePtr, HighlightTag } from "./wasm_types";

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
        return new DocumentUpdatedOnePtr(this.memory.buffer, result).deref();
    }

    moveCursor(position: number) {
        const result = this.wasmExports.moveCursor(position);
        return new HighlightsUpdatedOnePtr(this.memory.buffer, result).deref();
    }
}

// TODO: Rename this to indicate it does more than just highlighting
// TODO: Proper storage of WasmAgent per CodeMirror conventions (using a StateField).
class Highlighter {
    public decorations: DecorationSet;
    private markCache: {[n: number]: Decoration} = {
        [HighlightTag.comment]: Decoration.mark({class: "comment"}),
        [HighlightTag.chord]: Decoration.mark({class: "chord"}),
        [HighlightTag.dependencies]: Decoration.mark({class: "dependencies"}),
    }

    constructor(view: EditorView, private wasmAgent: WasmAgent) {
        this.fullUpdate(view);
    }

    update(update: ViewUpdate) {
        if (update.docChanged) {
            this.fullUpdate(update.view);
        }

        if (update.selectionSet) {
            this.decorations = this.buildDecorations(this.wasmAgent.moveCursor(update.state.selection.main.anchor));
        }
    }

    fullUpdate(view: EditorView) {
        const documentUpdated = this.wasmAgent.updateDocument(view.state.doc.toString());
        this.decorations = this.buildDecorations(documentUpdated.highlights_updated);
    }

    buildDecorations(highlightsUpdated: HighlightsUpdated): DecorationSet {
        const builder = new RangeSetBuilder<Decoration>();

        const highlightsPtr = highlightsUpdated.ptr.unwrap();
        if (!highlightsPtr) return builder.finish();
        const highlightsLen = highlightsUpdated.len;

        for (const highlight of highlightsPtr.slice(0, highlightsLen)) {
            builder.add(highlight.start, highlight.end, this.markCache[highlight.tag]);

        }

        return builder.finish();
    }
}

const highlighterTheme = EditorView.theme({
    ".comment": {
        color: "gray",
    },
    ".chord": {
        color: "green",
    },
    ".dependencies": {
        backgroundColor: "var(--background-2)",
    },
});

export function codeMirrorWasmAgent(wasmAgent: WasmAgent): Extension {
    const highlighter = Prec.high(ViewPlugin.define(view => new Highlighter(view, wasmAgent), {
        decorations: v => v.decorations,
    }));
 
    return [highlighter, highlighterTheme];
}
  