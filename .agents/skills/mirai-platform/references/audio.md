# Package `audio`

SDL-free mixing library (`std/base`, `core:sync`, `core:math`, `vendor:stb/vorbis`). The output
device is in [`platform`](platform.md#audio-device).

## Mixer

`mixer_create(Mixer_Desc)` sets the sample rate, output channels (1 or 2), capacities and the speed
of sound. `mixer_render(m,out)` replaces `out` with interleaved f32 frames and does not clip: a mix
louder than full scale exceeds 1.

### Two threads

`mixer_render` can run on an audio thread; everything else belongs to a single other thread (the
game thread), with no shared locks:

- The game thread's requests enter a lock-free single-producer single-consumer queue; when full,
  the function returns false or a handle 0 and adds to `commands_dropped`.
- The audio thread drains the queue at the start of each chunk of `CHUNK_FRAMES` (or less, if the
  request is shorter) and ramps across the chunk the changes of volume, pan, position, pause and
  buses.
- What it reports (finished voices, released sounds, clock, underruns) comes back through atomics.
  `mixer_update`, once per frame on the game thread, frees what finished and decodes ahead for
  streams.
- As long as parameters do not change, one call or chunks of any size give the same samples.
- `mixer_destroy` requires that the audio thread is no longer rendering.

## Sounds

Interleaved f32 PCM, mono or stereo, at its own sample rate. `sound_create` copies the samples and
`sound_load` decodes a WAV or an Ogg Vorbis whole, told apart by their first bytes.

- `sound_stream` decodes while playing and does not copy the file: it must stay in memory until
  the sound is destroyed and a later `mixer_update` frees it.
- `sound_destroy` invalidates the handle at once and ends its voices; the memory is freed in a
  later `mixer_update`, when the audio thread confirmed that it let go of it.
- `decode`, `wav_decode` and `vorbis_decode` work without a mixer. WAV is read in Odin (integer and
  float PCM, also `WAVE_FORMAT_EXTENSIBLE`; a truncated file delivers the complete frames); Vorbis
  with `stb_vorbis`, with all its memory in one allocator block. More than two channels give
  `Unsupported_Format`.

### Streams

The game thread decodes in `mixer_update` (and when the voice starts) into a ring that the audio
thread reads, without waits: `mixer_update` must be called more often than the ring's duration.

- A stream plays in one voice at a time: another playback returns 0 (`streams_busy`) until a
  `mixer_update` sees the voice finish, and then it starts from the beginning.
- If the ring empties the voice goes silent (`stream_underruns`) and resumes when there is data.
- `voice_set_loop(false)` applies at the next end of file that has not been decoded yet.
- Its pitch has a cap of source frames per output frame, `offset` does not apply and its voice is
  not stolen.

## Voices

`voice_play(m,sound,desc)`: start from `VOICE_DEFAULT`, because a zeroed desc is silent. The handle
is valid until a `mixer_update` sees the voice finish or until it is stolen; operations on an
invalid one return false.

- **Resampling** linear; with a step of exactly 1 the samples are copied. In a loop, the frame
  after the last is the first, also for interpolating.
- **Pan.** Mono: constant power. Stereo: balance, lowers the side it moves away from.
- **Fades**: an exact linear envelope to the sample. A voice that is leaving to stop does not
  accept another fade.
- **Stop without fade and pause** drop to silence with a ramp in the current chunk and resuming
  rises with another; a paused voice keeps its position, and one that is paused or has not started
  yet is stopped at once.
- **Aligned start.** With `start_frame` (mixer clock) the first sample comes out exactly on that
  frame, even if it falls in the middle of a render.
- **Filter and send.** A voice with a low-pass or a reverb send is mixed apart and goes through its
  one-pole filter, which changes cutoff without clicks; with neither it goes straight to its bus,
  at no extra cost.
- **Stealing.** Without free voices, `voice_play` takes the one with the lowest priority and,
  among equals, the oldest, if its priority does not exceed the new one's; if not, it returns 0.
  The stolen handle stops being valid at once and its sound drops to silence within a chunk.

## Buses

Every voice sounds on a bus and every bus on the master (`BUS_MASTER`), which is what is written;
buses are not nested or destroyed. A game's named buses belong to
[`engine/audio`](../../mirai-gameplay/references/libraries.md#audio).

- Volume and mute are ramped within a chunk; a muted bus keeps its volume.
- `bus_set_duck`: while the peak of the `source` bus, measured after its volume and its filter,
  exceeds `threshold`, the bus drops to `1-amount` in `attack` and returns in `release`. The master
  is not ducked and a bus does not duck itself.

## Reverb

`reverb.odin` follows Freeverb; its memory is reserved when the mixer is created. There are two
kinds:

- **The room's**, one per mixer, to which voices send their signal after their gains and their
  filter: a distant or covered voice sends less. `reverb_set` chooses on which bus what it returns
  sounds (the master by default), after the voices and before processing the buses: the volume,
  filter and ducking of that bus reach it. `wet` 0 turns it off and clears its memory.
- **One per bus** (`bus_set_reverb`): it adds its tail to what the bus plays dry, before its
  filter and its volume; a song sounds in a room without depending on the room.

## Positional audio

Right-handed, Y up, meters: a listener without rotation looks toward -Z with +X to its right.

- Attenuation clamps the distance to [`min_distance`, `max_distance`]: closer than the minimum the
  gain is 1 and farther than the maximum it stops dropping.
- Pan is the component of the direction to the source along the listener's right, with constant
  power: it does not tell front from back.
- Doppler takes the velocities along the source-listener line and multiplies the pitch.
- A stereo sound with a position is heard as one source (average of its channels).
- Gains and pitch of a positional voice are recomputed on the audio thread when its position or
  the listener changes, with the chunk's ramp.

## What it does not do

Resampling better than linear, other per-voice filters, more than one room reverb, reflections
from geometry, HRTF, sounds or output of more than two channels, and seeking or querying the
position of a playing voice.
