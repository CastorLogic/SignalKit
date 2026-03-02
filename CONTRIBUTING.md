# Contributing to SignalKit

Thank you for your interest in contributing. SignalKit values correctness, real-time safety, and clean code above all else.

## Getting Started

```bash
git clone https://github.com/AstroLogicStudio/SignalKit.git
cd SignalKit
swift build
swift test
```

## Development Rules

### Real-Time Safety

Any code that runs inside a `process()` method must follow these rules:

- **No heap allocations** — no `Array.append`, no string formatting, no `malloc`
- **No locks** — no `DispatchSemaphore`, no `os_unfair_lock`
- **No Objective-C messaging** — no `objc_msgSend`, no `NSLog`
- **No ARC traffic** — avoid retain/release on the audio thread

If you are unsure whether an operation is real-time safe, it probably is not. See [ARCHITECTURE.md](ARCHITECTURE.md) for details.

### Code Style

- Use `UnsafeMutablePointer<Float>` for audio buffers, not `[Float]`
- Mark processor classes as `public final class`
- Use `@inline(__always)` only on small, hot inner-loop helpers
- Keep comments concise — explain *why*, not *what*
- Reference academic sources where applicable (author, title, venue, year)
- No emoji, no filler text, no first-person language in comments

### Testing

Every processor must have tests covering:

1. **Bypass/passthrough** — flat settings or disabled state should not modify audio
2. **Signal modification** — verify the processor actually changes the signal as expected
3. **Edge cases** — zero-length buffers, single-sample buffers, invalid parameters
4. **Reset** — verify `reset()` clears all internal state
5. **Presets** — round-trip application and snapshot

Run the full suite before submitting:

```bash
swift test
```

### Benchmarks

Run benchmarks in release mode to verify performance:

```bash
swift run -c release Benchmarks
```

Compare against the committed baseline. Regressions greater than 5% should be investigated and documented.

## Pull Request Checklist

- [ ] All existing tests pass (`swift test`)
- [ ] New functionality includes tests
- [ ] Benchmarks show no regression (`swift run -c release Benchmarks`)
- [ ] No warnings from `swift build`
- [ ] Code follows the real-time safety rules above
- [ ] Comments reference academic sources where applicable

## Reporting Issues

When reporting bugs, include:

- Processor name and configuration (preset, sample rate, buffer size)
- Input signal description (frequency, amplitude, duration)
- Expected vs actual behavior
- Platform and Swift version

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
