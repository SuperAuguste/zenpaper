<!-- omit in toc -->
# zenpaper

A work-in-progress CLI implementation of [xenpaper](https://github.com/dxinteractive/xenpaper) written in Zig.

[Check out the original!](https://dxinteractive.github.io/xenpaper/)

<!-- omit in toc -->
## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [Features](#features)
  - [Differences from Xenpaper](#differences-from-xenpaper)
- [License](#license)

## Installation

No binaries yet, I need to set up CI for that - sorry!

[Install Zig 0.14.0](https://ziglang.org/download/#release-0.14.0), then:

```bash
git clone https://github.com/SuperAuguste/zenpaper
zig build
./zig-out/bin/zenpaper play examples/hello.zp
```

Add zenpaper to your path for ease of invocation.

If you're developing zenpaper and want to build *and* run, you can do the following:
```bash
zig build run -- play examples/hello.zp
```

## Usage

```bash
# Plays your lil tune 
zenpaper play my_tune.zp
```

## Features

- [x] Comments
- [x] Notes
  - [x] Scale degrees
  - [x] Ratios
  - [x] Cents
  - [x] Equal divisions of an octave
  - [x] Equal divisions of an equave
  - [x] Hertz
  - [x] Equave shifts
  - [x] Holds
- [x] Rests
- [x] Chords
  - [x] Bracketed
  - [x] Multi-ratios
- [x] Scales
  - [x] Equal divisions of the octave
  - [x] Equal divisions of the equave
  - [x] Individual pitches
  - [x] Equave specification
  - [x] Multi-ratios
  - [x] Modes
- [x] Root frequency
- [ ] Setters
  - [ ] Tempo
  - [ ] Divisions of beat
  - [ ] Divisions of beat shorthand
  - [ ] Sound
  - [ ] ADSR (envelope)
- [ ] Ruler
- [ ] Error reporting
  - [x] Parsing
  - [ ] AST to spool
- [ ] Editor support
  - [ ] Highlighting
  - [ ] Frequency tooltips
- [ ] Runtime highlighting

### Differences from Xenpaper

- You can equave-shift chords, so something like `'1:2:3` or `"[0 3 5]` is permissible
- Likewise, you can equave-shift scales; this uses the equave from before the new scale and is also
  applied to the new equave
  - This also works on the `{...edo}` and `{...ed...}` shorthands, though these preserve their original unshifted equaves
  - TODO: this behavior is sort of buggy and weird and I'm not sure it's desirable - maybe we should preserve equave shifts on chords and ban it for scales?
- Like in xenpaper, you cannot equave shift root frequencies (shift the note rather than the root frequency expression)
- The default root frequency is `220hz`. This is [actually what Xenpaper's root frequency is](https://github.com/dxinteractive/xenpaper/blob/4684a16be8f2ceaa387406ad5abc67c6862bc341/packages/xenpaper-ui/src/data/process-grammar.ts#L659) despite
the docs saying otherwise, so this is not really a difference
- Descending multi-ratios behave correctly (e.g. 3::1 and 3:2:1 are equivalent)
- My ADSR is really questionable and does not match xenpaper's - I'll have to look at 
  tonejs' ADSR and replicate that

You'll notice that the most of the above differences are strict *additions*.
 
It may be wise to consider reworking the language grammar at a point in the future (potentially
breaking backwards compatibility) for simplicity of implementation and usage. Here's an example 
of a slightly awkward ambiguity (in my opinion): `1.2.3` vs `1.2.3hz` where the first statement is
semantically equivalent to `1 . 2 . 3` and the second to `1 . 2.3hz`. Other ambiguous
statements only works in root and are disallowed in chords and scales in both xenpaper and zenpaper,
e.g. `123hz10`.

## License

MIT
