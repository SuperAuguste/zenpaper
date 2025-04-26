import { EditorState, StateEffect } from "@codemirror/state"
import { drawSelection, dropCursor, EditorView, highlightActiveLineGutter, keymap, lineNumbers, ViewPlugin } from "@codemirror/view"
import { defaultKeymap, history } from "@codemirror/commands"

// @ts-ignore
import wasmAgentUrl from "url:./zenpaper-wasm-agent.wasm";
import { codeMirrorWasmAgent, WasmAgent } from "./wasm_agent";

const foreground = "var(--foreground)";
const background = "var(--background)";
const highlightBackground = "var(--background-2)"
const cursor = "white";

const theme = EditorView.theme({
    "&": {
        color: foreground,
        backgroundColor: background,
    },
    ".cm-content, .cm-gutter": {
        fontFamily: "var(--code-font)",
    },
    ".cm-content": {
        caretColor: cursor,
    },
    ".cm-gutters": {
        backgroundColor: background,
        color: foreground,
        border: "none",
    },
    ".cm-lineNumbers .cm-gutterElement": {
        padding: "0 0.75em",
        marginRight: "0.25em",
    },
    ".cm-activeLineGutter": {
        backgroundColor: highlightBackground,
    },
    ".cm-cursor, .cm-dropCursor": {
        borderLeftColor: cursor,
    },
    "&.cm-focused": {
        outline: "none",
    },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
        backgroundColor: "var(--background-2)",
    },
});

let view = new EditorView({
    state: EditorState.create({
        doc: "0 1 2 3 4 5 6 7 8 9 10 11\n",
        extensions: [
            lineNumbers(),
            highlightActiveLineGutter(),
            history(),
            drawSelection(),
            dropCursor(),
            keymap.of(defaultKeymap),
            theme,
            EditorView.lineWrapping,
        ]
    }),
    parent: document.body,
});

const wasmAgent = new WasmAgent(wasmAgentUrl);
wasmAgent.init().then(() => {
    view.dispatch({
        effects: [StateEffect.appendConfig.of(codeMirrorWasmAgent(wasmAgent))]
    })
});
