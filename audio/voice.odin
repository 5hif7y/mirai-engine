package mirai_audio

import "mirai:std/base"

// Voices: one playing instance of a sound. The handle is valid from
// voice_play until a mixer_update finds that the voice has ended, or until
// the voice is stolen to make room for another.

Voice :: distinct base.Handle

// Start from VOICE_DEFAULT: a zeroed desc is silent (volume 0).
Voice_Desc :: struct {
    bus:Bus,
    volume:f32, // linear gain
    pitch:f32,  // rate of playback; 1 is the sound as recorded, 0 is taken as 1. Clamped to [PITCH_MIN,PITCH_MAX]
    pan:f32,    // -1 left to 1 right: constant power for a mono sound, balance for a stereo one. Ignored when spatial
    loop:bool,
    paused:bool,  // created paused; voice_set_paused starts it
    priority:u8,  // when no voice is free, the one of lowest priority is stolen, the oldest among equals; never one of higher priority
    fade_in:f32,  // seconds
    offset:f32,   // seconds into the sound where it starts; a loop starts over from the beginning
    // Mixer clock (mixer_clock) of the frame in which the first sample
    // plays. 0, or a frame already rendered, starts as soon as possible.
    start_frame:u64,
    spatial:bool, // placed in the world: panned and attenuated for the listener
    position,velocity:[3]f32,
    attenuation:Attenuation,
    doppler:f32, // 0: none; 1: the physical effect
    lowpass:f32, // Hz, cutoff of a one-pole low-pass on the voice (6 dB per octave); 0: none
    reverb:f32,  // share of the voice sent to the reverb of the mixer, after its gains and its filter
}
VOICE_DEFAULT :: Voice_Desc{volume=1,pitch=1,attenuation=ATTENUATION_DEFAULT}

// Frames of the ramp to silence of a voice that is stopped without a fade
// are those left in the chunk being mixed: at most CHUNK_FRAMES.

@(private)
Voice_Shadow :: struct {
    generation:u32,
    active:bool,
    priority:u8,
    sequence:u64, // order of creation
    stream:i32,   // the stream it plays; -1 for a sound in memory
}

@(private)
voice_shadow :: proc(m:^Mixer,voice:Voice) -> (index:u32,shadow:^Voice_Shadow) {
    index=base.handle_index(base.Handle(voice))
    if voice==0 || int(index)>=len(m.shadows) {return 0,nil}
    shadow=&m.shadows[index]
    if !shadow.active || shadow.generation!=base.handle_generation(base.Handle(voice)) {return 0,nil}
    return index,shadow
}
@(private)
voice_shadow_free :: proc(m:^Mixer,index:u32) {
    shadow:=&m.shadows[index]
    if shadow.stream>=0 && m.streams[shadow.stream].voice==i32(index) {m.streams[shadow.stream].voice=-1}
    shadow.active=false
    shadow.generation+=1
    m.free_voices[m.free_count]=index;m.free_count+=1
}

// Plays a sound. Returns 0 when it cannot: the sound is not valid, a stream
// that is already playing, no voice to use or steal, or a full command queue.
voice_play :: proc(m:^Mixer,sound:Sound,desc:Voice_Desc=VOICE_DEFAULT) -> Voice {
    slot:=sound_slot(m,sound)
    if slot==nil || !bus_valid(m,desc.bus) {return 0}
    if slot.stream>=0 && m.streams[slot.stream].voice>=0 {m.counters.streams_busy+=1;return 0}
    index:u32
    stolen:=false
    if m.free_count>0 {
        m.free_count-=1
        index=m.free_voices[m.free_count]
    } else {
        victim:=-1
        for shadow,i in m.shadows {
            // A voice that plays a stream is not stolen: its stream would have to be handed over too.
            if !shadow.active || shadow.stream>=0 {continue}
            if victim<0 || shadow.priority<m.shadows[victim].priority || (shadow.priority==m.shadows[victim].priority && shadow.sequence<m.shadows[victim].sequence) {victim=i}
        }
        if victim<0 || m.shadows[victim].priority>desc.priority {m.counters.voices_rejected+=1;return 0}
        index=u32(victim)
        stolen=true
    }
    shadow:=&m.shadows[index]
    generation:=shadow.generation+1 if stolen else shadow.generation
    rate:=f64(slot.rate)
    start:=Voice_Start{
        generation=generation,
        sound=base.handle_index(base.Handle(sound)),
        source={samples=raw_data(slot.samples),frames=slot.frames,channels=slot.channels,rate=slot.rate,stream=slot.stream},
        bus=u16(desc.bus),
        volume=max(desc.volume,0),pitch=desc.pitch,pan=desc.pan,
        loop=desc.loop,paused=desc.paused,spatial=desc.spatial,
        fade_in=u32(max(f64(desc.fade_in),0)*f64(m.sample_rate)+0.5),
        start_frame=desc.start_frame,
        position=desc.position,velocity=desc.velocity,
        attenuation=desc.attenuation,doppler=desc.doppler,
        lowpass=max(desc.lowpass,0),reverb=max(desc.reverb,0),
    }
    frames:=slot.frames
    if slot.stream>=0 {frames=u32(min(m.streams[slot.stream].decoder.frames,int(max(u32))))}
    offset:=frames>0?u32(min(max(f64(desc.offset),0)*rate,f64(frames-1))):0
    if slot.stream>=0 {
        // The ring begins at the offset.
        stream_begin(m,&m.streams[slot.stream],desc.loop,int(offset))
    } else {
        start.offset=offset
    }
    if !command_push(m,{kind=.Voice_Play,index=index,start=start}) {
        if !stolen {m.free_voices[m.free_count]=index;m.free_count+=1}
        return 0
    }
    shadow.generation=generation
    shadow.active=true
    shadow.priority=desc.priority
    shadow.sequence=m.sequence;m.sequence+=1
    shadow.stream=slot.stream
    if slot.stream>=0 {m.streams[slot.stream].voice=i32(index)}
    m.counters.voices_played+=1
    if stolen {m.counters.voices_stolen+=1}
    return Voice(base.handle_make(index,generation))
}

// The voice has not ended, as far as the last mixer_update knows.
voice_valid :: proc(m:^Mixer,voice:Voice) -> bool {
    _,shadow:=voice_shadow(m,voice)
    return shadow!=nil
}

@(private)
voice_send :: proc(m:^Mixer,voice:Voice,command:Command) -> bool {
    index,shadow:=voice_shadow(m,voice)
    if shadow==nil {return false}
    command:=command
    command.index=index;command.generation=shadow.generation
    return command_push(m,command)
}

// Ends the voice, at once (ramped to silence over the chunk being mixed) or
// after fading out for fade seconds. The handle stays valid until the voice
// has gone quiet.
voice_stop :: proc(m:^Mixer,voice:Voice,fade:f32=0) -> bool {
    return voice_send(m,voice,{kind=.Voice_Stop,frames=u32(max(f64(fade),0)*f64(m.sample_rate)+0.5)})
}
voice_set_paused :: proc(m:^Mixer,voice:Voice,paused:bool) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pause,flag=paused})
}
voice_set_volume :: proc(m:^Mixer,voice:Voice,volume:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Volume,value=max(volume,0)})
}
voice_set_pitch :: proc(m:^Mixer,voice:Voice,pitch:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pitch,value=pitch})
}
voice_set_pan :: proc(m:^Mixer,voice:Voice,pan:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Pan,value=pan})
}
voice_set_loop :: proc(m:^Mixer,voice:Voice,loop:bool) -> bool {
    _,shadow:=voice_shadow(m,voice)
    if shadow==nil {return false}
    if shadow.stream>=0 {m.streams[shadow.stream].loop=loop}
    return voice_send(m,voice,{kind=.Voice_Loop,flag=loop})
}
// Moves the envelope of the voice to level (1 is its volume, 0 silence) over
// seconds, linearly from where it is. A voice that is fading out to stop
// keeps doing so.
voice_fade :: proc(m:^Mixer,voice:Voice,level:f32,seconds:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Fade,value=max(level,0),frames=u32(max(f64(seconds),0)*f64(m.sample_rate)+0.5)})
}
voice_set_lowpass :: proc(m:^Mixer,voice:Voice,cutoff_hz:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Lowpass,value=max(cutoff_hz,0)})
}
voice_set_reverb :: proc(m:^Mixer,voice:Voice,send:f32) -> bool {
    return voice_send(m,voice,{kind=.Voice_Reverb,value=max(send,0)})
}
// Where a spatial voice is and how fast it moves.
voice_set_position :: proc(m:^Mixer,voice:Voice,position:[3]f32,velocity:[3]f32={}) -> bool {
    return voice_send(m,voice,{kind=.Voice_Place,vectors={position,velocity}})
}
