export class DocumentUpdatedOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(): DocumentUpdated {
        return DocumentUpdated.read(this.buffer, this.address);
    }
}

export class DocumentUpdatedOptionalOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): DocumentUpdatedOnePtr | null {
        return this.address == 0 ? null : new DocumentUpdatedOnePtr(this.buffer, this.address);
    }
}

export class DocumentUpdatedManyPtr {
    public constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(index: number): DocumentUpdated {
        return DocumentUpdated.read(this.buffer, this.address + index * DocumentUpdated.size);
    }

    public* slice(start: number, end: number) {
        for (let index = start; index < end; index += 1) {
            yield this.deref(index);
        }
    }
}

export class DocumentUpdatedOptionalManyPtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): DocumentUpdatedManyPtr | null {
        return this.address == 0 ? null : new DocumentUpdatedManyPtr(this.buffer, this.address);
    }
}
export class DocumentUpdated {
    public static size = 8;
    public highlights_updated: HighlightsUpdated;

    public static read(buffer: ArrayBuffer, address: number) {
        let result = new DocumentUpdated();
        const dataView = new DataView(buffer);
        result.highlights_updated = HighlightsUpdated.read(buffer, address + 0);
        return result;
    }
}

export class HighlightOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(): Highlight {
        return Highlight.read(this.buffer, this.address);
    }
}

export class HighlightOptionalOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): HighlightOnePtr | null {
        return this.address == 0 ? null : new HighlightOnePtr(this.buffer, this.address);
    }
}

export class HighlightManyPtr {
    public constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(index: number): Highlight {
        return Highlight.read(this.buffer, this.address + index * Highlight.size);
    }

    public* slice(start: number, end: number) {
        for (let index = start; index < end; index += 1) {
            yield this.deref(index);
        }
    }
}

export class HighlightOptionalManyPtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): HighlightManyPtr | null {
        return this.address == 0 ? null : new HighlightManyPtr(this.buffer, this.address);
    }
}
export class Highlight {
    public static size = 9;
    public tag: HighlightTag;
    public start: number;
    public end: number;

    public static read(buffer: ArrayBuffer, address: number) {
        let result = new Highlight();
        const dataView = new DataView(buffer);
        result.tag = dataView.getUint8(address + 0);
        result.start = dataView.getUint32(address + 1, true);
        result.end = dataView.getUint32(address + 5, true);
        return result;
    }
}

export enum HighlightTag {
    comment = 0,
    chord = 1,
    dependencies = 2,
}

export class HighlightsUpdatedOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(): HighlightsUpdated {
        return HighlightsUpdated.read(this.buffer, this.address);
    }
}

export class HighlightsUpdatedOptionalOnePtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): HighlightsUpdatedOnePtr | null {
        return this.address == 0 ? null : new HighlightsUpdatedOnePtr(this.buffer, this.address);
    }
}

export class HighlightsUpdatedManyPtr {
    public constructor(public buffer: ArrayBuffer, public address: number) {}

    public deref(index: number): HighlightsUpdated {
        return HighlightsUpdated.read(this.buffer, this.address + index * HighlightsUpdated.size);
    }

    public* slice(start: number, end: number) {
        for (let index = start; index < end; index += 1) {
            yield this.deref(index);
        }
    }
}

export class HighlightsUpdatedOptionalManyPtr {
    constructor(public buffer: ArrayBuffer, public address: number) {}

    public unwrap(): HighlightsUpdatedManyPtr | null {
        return this.address == 0 ? null : new HighlightsUpdatedManyPtr(this.buffer, this.address);
    }
}
export class HighlightsUpdated {
    public static size = 8;
    public ptr: HighlightOptionalManyPtr;
    public len: number;

    public static read(buffer: ArrayBuffer, address: number) {
        let result = new HighlightsUpdated();
        const dataView = new DataView(buffer);
        result.ptr = new HighlightOptionalManyPtr(buffer, dataView.getUint32(address + 0, true));
        result.len = dataView.getUint32(address + 4, true);
        return result;
    }
}

