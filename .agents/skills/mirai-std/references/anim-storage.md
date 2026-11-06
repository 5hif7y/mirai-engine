# Resident animation storage

`std/anim` keeps the editable document as `Keyframe`. `library_compress` prepares a shared library,
immutable during a load, as the runtime plays it: the transform, `Float` and `Vector` tracks of each
clip become uniform samples quantized against the error they make on the skeleton (the approach of
[ACL](https://github.com/nfrechette/acl), which Unreal uses by default). A prepared library rejects
`clip_add` and a second preparation. The `.anim` of a project keeps its keys; a
[cooked one](../../mirai-assets/references/kinds.md#animation) keeps the samples. A change that
gives other samples for the same keys and config advances `COMPRESS_VERSION`: the
[project cache](../../mirai-core/references/host.md#content) keys compressions by it.

## Error

- `Compress_Config.precision` is how far a point `shell` away from each bone may move, in the space
  of the entity that plays the clip; `COMPRESS_DEFAULT` is ACL's (0.1 mm at 3 cm).
- The bones are those of the skeleton the clip plays on (`skeletons`, per clip), whose rest pose
  holds what the clip does not move: a scaled root it does not animate puts the error in scene
  units, as Unreal compresses on its `USkeleton`. A transform track outside it hangs from the track
  `parents` names (`asset.animation_parents` derives it from the target paths); without skeleton,
  a bone without a `Position` track is measured at its parent's origin.
- `Float` and `Vector` tracks are measured per component against `float_precision` and
  `vector_precision`.
- The error is measured at the samples and at three points between each two, decoding exactly as
  the runtime does; `Compress_Stats.error` and `curve_error` are the worst measured.

## Sampling

- A clip is sampled from 0 to its duration at the interval most of its keys share (`COMPRESS_RATE`
  when none does), on the grid of the keys: a duration between two samples makes the last interval
  shorter.
- A track keeps its keys when linear between samples does not follow them (cubic slopes, easing,
  steps that change, rotations far apart) or when they take fewer bytes than its samples. A track
  that holds still becomes one sample (`minimum`, a rotation in xyzw).
- Rotations are interpolated by normalized lerp on the short arc; they are stored as x, y and z with
  `w>=0`.

## Quantized representation

- `Sampled_Track` has the track's range, duration, rate and count. Its samples go in segments of
  `SAMPLED_SEGMENT`: a header with the bit rate (0, 3 to `SAMPLED_MAX_BITS`, or `SAMPLED_RAW` for
  the f32) and, per component, the segment's range in 255ths of the track's range, then the samples
  packed from the lowest bit. `samples` ends with `SAMPLED_PADDING` bytes: a component reads 8
  bytes at once.
- Bit rates start at what each track's range allows within its share of the chain and rise, one
  track and segment at a time, where a point moves too far: the track above it that contributes
  most.
- `sampled_walk` validates a header and its bytes and gives where each segment starts; `clip_add`
  takes sampled tracks (`Track_Desc.sampled`) only through it.

## Access

- `clip_evaluate` gives the same contract for keys and samples. A sampled track reads two samples
  and interpolates them: no search and no allocation.

## Errors and statistics

- Compression validates ranges, enums, values, times, parents and configuration before publishing
  the new tables; each failure, including lack of intermediate memory, leaves the library intact.
- `library_resident_bytes` counts keys, sampled headers, segment starts, samples, tracks, clips and
  markers, without the temporary memory of the transaction or the source files.

## Verification

- `mirai test std/anim` with the cases of `compress_test.odin` and the affected `track_*` and
  `library_*`.
- `mirai test asset animation_compression_of_the_demo --release -define:ANIMATION_BENCH=true`
  (`asset/animation_bench_test.odin`) measures bytes, the worst error, sampling per bone and load
  of the demo's animations; `compact_bench_test.odin` measures a synthetic library.
