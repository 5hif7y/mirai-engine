# Resident animation storage

`std/anim` keeps the editable document as `Keyframe`. `library_optimize` prepares a shared library,
immutable during a load, without modifying the `.anim`. A prepared library rejects `clip_add` and a
second preparation.

## Configuration

`Optimize_Config` declares the maximum error per property, in its units (scene, radians, Euclidean
distance of the components); `OPTIMIZE_DEFAULT` gives the values and enables reduction and
quantization. Zero demands exactness for that property; a negative or non-finite error is invalid.

## Reduction

- It removes constant tracks down to one key and simplifies linear curves by their maximum deviation
  from the original polyline. The bound between keys results from linearly interpolating that
  difference, with a margin for f32 rounding.
- A varying rotation keeps its keys and `Step` keeps its changes. The time of the retained keys, the
  duration, slots, names, loop and markers stay equal.

## Quantized representation

- `Packed_Key` stores the time in f32 and four u16 components with a minimum and extent per track.
  Rotations use [-1,1], are normalized when decoded and keep the short arc; a pair of neighboring
  keys too close to the hemisphere cut stays raw.
- Tracks with tangents, `Cubic`, `Cubic_Spline`, non-linear easing, insufficient tolerance or a
  quantized size that does not save stay raw. glTF tangents are neither approximated nor replaced by
  squad.
- Quantizing requires strictly increasing times and unit quaternions; repeated times and non-unit
  quaternions that `.anim` admits stay raw.

## Access

- `clip_evaluate` keeps the same contract for `Raw` and `Quantized` with a single search and
  interpolation algorithm, specialized by the key access; it does not decode the whole clip or
  allocate when sampling.
- `track_key` queries a key in any storage (`false` with an invalid quantized index or metadata);
  `track_keys` gives only the raw view and is empty if the track is quantized.

## Errors and statistics

- Preparation validates ranges, enums, values, times and metadata before publishing the new tables;
  each failure, including lack of intermediate memory, leaves the original library intact.
- `library_resident_bytes` counts tables of keys, ranges, tracks, clips and markers, without the
  temporary memory of the transaction or the source files.

## Verification

- `mirai test std/anim` with the `resident_animation_*` cases of `optimize_test.odin` and the
  affected `track_*` and `library_*`.
- `compact_bench_test.odin` measures memory and sampling.
