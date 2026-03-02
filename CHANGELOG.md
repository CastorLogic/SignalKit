# Changelog

All notable changes to SignalKit are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0 — 2026-03-02

First public release.

### Added

- 10-band parametric EQ with ISO 31 center frequencies (`EQProcessor`)
- 3-band multiband compressor with Linkwitz-Riley crossover (`CompressorProcessor`)
- Look-ahead limiter with true-peak ceiling enforcement (`LimiterProcessor`)
- LUFS loudness meter with optional auto-gain correction (`LoudnessMeter`)
- Mid/side stereo widener (`StereoWidener`)
- Crossfeed processor for headphone spatialization (`CrossfeedProcessor`)
- Lock-free single-producer/single-consumer ring buffer (`SPSCRingBuffer`)
- CLI WAV processor example (`SignalKitCLI`)
- Benchmark suite with Apple Silicon baselines (37.79 µs full pipeline)
- 60 tests including DFT frequency validation and ITU-R BS.1770 calibration
- GitHub Actions CI (build, test, benchmark)
