# zenpaper

Very WIP.

A Zig implementation of [xenpaper](https://github.com/dxinteractive/xenpaper). [Check out the original!](https://dxinteractive.github.io/xenpaper/)

## Installation

No binaries yet, I need to set up CI for that - sorry!

[Install Zig 0.14.0](https://ziglang.org/download/#release-0.14.0), then:

```bash
git clone https://github.com/SuperAuguste/zenpaper
zig build
./zig-out/bin/zenpaper play examples/hello.xp
```

Add zenpaper to your path for ease of invocation.

If you're developing zenpaper and want to build *and* run, you can do the following:
```bash
zig build run -- play examples/hello.xp
```

## Usage

```bash
# Plays your lil tune 
zenpaper play my_tune.xp
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
- [ ] Scales
  - [ ] Equal divisions of the octave
  - [ ] Equal divisions of the equave
  - [x] Individual pitches
  - [ ] Equave size specification
  - [x] Multi-ratios
  - [ ] Modes
- [x] Root frequency
- [ ] Setters
  - [ ] Tempo
  - [ ] Divisions of beat
  - [ ] Divisions of beat shorthand
  - [ ] Sound
  - [ ] ADSR (envelope)
- [ ] Ruler
- [ ] Error reporting
  - [ ] Parsing
  - [ ] AST to spool
- [ ] Editor support
  - [ ] Highlighting
  - [ ] Frequency tooltips
- [ ] Runtime highlighting

### Differences from Xenpaper

- You can equave-shift chords, so something like `'1:2:3` or `"[0 3 5]` is permissible
- Likewise, you can equave-shift scales; this uses the equave from before the new scale
- The default root frequency is `220hz`. This is [actually what Xenpaper's root frequency is](https://github.com/dxinteractive/xenpaper/blob/4684a16be8f2ceaa387406ad5abc67c6862bc341/packages/xenpaper-ui/src/data/process-grammar.ts#L659) despite
the docs saying otherwise, so this is not really a difference
- Descending multi-ratios behave correctly (e.g. 3::1 and 3:2:1 are equivalent)

You'll notice that the above differences are strict *additions*.

It may be wise to consider reworking the language grammar at a point in the future (potentially
breaking backwards compatibility) for simplicity of implementation and usage. Here's an example 
of a slightly awkward ambiguity (in my opinion): `1.2.3` vs `1.2.3hz` where the first statement is
semantically equivalent to `1 . 2 . 3` and the second to `1 . 2.3hz`.

## License

MIT
