export class DocumentUpdatedOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(): DocumentUpdated {
        return DocumentUpdated.deref(this.buffer, this.address);
    }
}

export class DocumentUpdatedManyPtr {
    public constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(index: number): DocumentUpdated {
        return DocumentUpdated.deref(this.buffer, this.address + index * DocumentUpdated.size);
    }
}

export class DocumentUpdated {
    public static size = 8;
    public highlights_ptr: HighlightManyPtr;
    public highlights_len: number;

    public static deref(buffer: ArrayBuffer, address: number) {
        let result = new DocumentUpdated();
        const dataView = new DataView(buffer);
        result.highlights_ptr = new HighlightManyPtr(buffer, dataView.getUint32(address + 0, true));
        result.highlights_len = dataView.getUint32(address + 4, true);
        return result;
    }
}

export class HighlightOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(): Highlight {
        return Highlight.deref(this.buffer, this.address);
    }
}

export class HighlightManyPtr {
    public constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(index: number): Highlight {
        return Highlight.deref(this.buffer, this.address + index * Highlight.size);
    }
}

export class Highlight {
    public static size = 9;
    public tag: HighlightTag;
    public start: number;
    public end: number;

    public static deref(buffer: ArrayBuffer, address: number) {
        let result = new Highlight();
        const dataView = new DataView(buffer);
        result.tag = dataView.getUint8(address + 0);
        result.start = dataView.getUint32(address + 1, true);
        result.end = dataView.getUint32(address + 5, true);
        return result;
    }
}

export enum HighlightTag {
    amogus = 0,
}

