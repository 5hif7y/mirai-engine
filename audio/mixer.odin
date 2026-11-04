package mirai_audio

import "base:runtime"
import "core:sync"

// A mixer of sounds held in memory or streamed, with voices, buses and
// positional audio, that renders interleaved f32 frames into a buffer of the
// caller. It knows no audio device: platform pulls from it.
//
// Two threads at most use a Mixer. mixer_render may run on an audio thread;
// everything else belongs to one other thread (the game thread). They share
// no lock: what the game thread asks for travels in a queue that the audio
// thread empties at the start of every chunk it renders, and what the audio
// thread has to tell comes back in atomics that mixer_update reads.

Error :: enum u8 {
    None,
    Out_Of_Memory,
    Invalid_Desc,
    Capacity_Exhausted,
    Invalid_Data,       // not a WAV or Ogg Vorbis file, or a damaged one
    Unsupported_Format, // a sample format or channel count the mixer does not play
}

Mixer_Desc :: struct {
    sample_rate:int,      // 48000 when zero
    channels:int,         // 1 or 2; 2 when zero
    voice_capacity:int,   // 64 when zero
    bus_capacity:int,     // the master included; 8 when zero
    sound_capacity:int,   // 256 when zero
    stream_capacity:int,  // sounds that are streamed; 4 when zero
    stream_frames:int,    // frames buffered ahead for every stream, rounded up to a power of two; half a second when zero
    command_capacity:int, // commands the game thread can queue between two chunks, rounded up to a power of two; 1024 when zero
    speed_of_sound:f32,   // meters per second, for Doppler; 343 when zero
    allocator:runtime.Allocator, // context.allocator when unset
}

// Frames mixed at a time: commands and parameter changes take effect at the
// start of a chunk and are ramped across it.
CHUNK_FRAMES :: 256
PITCH_MIN :: f32(1.0/64)
PITCH_MAX :: f32(64)

Mixer_Stats :: struct {
    frames_rendered:u64,
    voices_active:int,    // as of the last chunk rendered
    voices_played:u64,
    voices_stolen:u64,    // voices ended to make room for a new one
    voices_rejected:u64,  // voices not started: no room, and nothing of lower or equal priority to steal
    commands_dropped:u64, // requests lost because the command queue was full
    stream_underruns:u64, // chunks in which a stream had no data ready
    streams_busy:u64,     // plays of a stream that was already playing
    sounds:int,
}

@(private) ONE :: u64(1)<<32 // a source frame in the 32.32 fixed point of a voice cursor

@(private)
Command_Kind :: enum u8 {
    Voice_Play,Voice_Stop,Voice_Pause,Voice_Volume,Voice_Pitch,Voice_Pan,Voice_Loop,Voice_Fade,Voice_Place,Voice_Lowpass,Voice_Reverb,
    Bus_Volume,Bus_Mute,Bus_Lowpass,Bus_Duck,Bus_Reverb,
    Reverb,
    Listener,
    Sound_Release,
}
@(private)
Command :: struct {
    kind:Command_Kind,
    flag:bool,
    index:u32,      // voice, bus or sound
    generation:u32, // of the voice
    value:f32,
    frames:u32,
    vectors:[2][3]f32,
    rotation:quaternion128,
    duck:Duck,
    start:Voice_Start,
}
// One producer (the game thread) and one consumer (the audio thread).
@(private)
Command_Queue :: struct {
    items:[]Command,
    head:u64, // next to read; written by the audio thread
    tail:u64, // next to write; written by the game thread
}

Mixer :: struct {
    allocator:runtime.Allocator,
    sample_rate,channels:int,
    speed_of_sound:f32,
    commands:Command_Queue,
    clock:u64, // frames rendered; atomic

    // Game thread.
    sounds:[]Sound_Slot,
    shadows:[]Voice_Shadow,
    free_voices:[]u32,free_count:int,
    sequence:u64,
    bus_count:int,
    bus_shadows:[]Bus_Shadow,
    reverb_shadow:Reverb_Shadow,
    streams:[]Stream,
    counters:Mixer_Stats,

    // Audio thread.
    voices:[]Mix_Voice,
    buses:[]Mix_Bus,
    bus_buffers:[]f32, // CHUNK_FRAMES stereo frames per bus
    voice_scratch:[]f32, // CHUNK_FRAMES stereo frames: a voice before its filter and its send
    reverb_input:[]f32,  // CHUNK_FRAMES stereo frames: what the voices send to the reverb
    reverb:Reverb_Unit,  // the room
    reverb_bus:u16,      // where the room returns
    bus_reverbs:[]Reverb_Unit,
    scratch:[]f32,     // source frames of a stream, laid out in a row
    listener:Listener,
    listener_serial:u32,

    // Written by the audio thread, read by the game thread; atomic.
    finished:[]u32,        // per voice slot: generation of the voice that last ended there
    sound_released:[]u32,  // per sound slot: 1 once no voice plays it any more
    voices_active:i32,
    stream_underruns:u64,
}

mixer_create :: proc(desc:Mixer_Desc) -> (m:^Mixer,error:Error) {
    allocator:=desc.allocator
    if allocator.procedure==nil {allocator=context.allocator}
    channels:=desc.channels if desc.channels!=0 else 2
    if channels<1 || channels>2 || desc.sample_rate<0 || desc.sample_rate>384000 {return nil,.Invalid_Desc}
    if desc.voice_capacity<0 || desc.bus_capacity<0 || desc.bus_capacity>int(max(u16)) || desc.sound_capacity<0 || desc.stream_capacity<0 {return nil,.Invalid_Desc}
    failed:runtime.Allocator_Error
    if m,failed=new(Mixer,allocator);failed!=nil {return nil,.Out_Of_Memory}
    m.allocator=allocator
    m.sample_rate=desc.sample_rate if desc.sample_rate>0 else 48000
    m.channels=channels
    m.speed_of_sound=desc.speed_of_sound if desc.speed_of_sound>0 else 343
    if error=mixer_init(m,desc);error!=.None {
        mixer_destroy(m)
        return nil,error
    }
    return m,.None
}
@(private)
mixer_init :: proc(m:^Mixer,desc:Mixer_Desc) -> Error {
    allocator:=m.allocator
    voices:=desc.voice_capacity if desc.voice_capacity>0 else 64
    buses:=desc.bus_capacity if desc.bus_capacity>0 else 8
    sounds:=desc.sound_capacity if desc.sound_capacity>0 else 256
    streams:=desc.stream_capacity if desc.stream_capacity>0 else 4
    commands:=4
    for commands<(desc.command_capacity if desc.command_capacity>0 else 1024) {commands*=2}
    stream_frames:=CHUNK_FRAMES*4
    for stream_frames<(desc.stream_frames if desc.stream_frames>0 else m.sample_rate/2) {stream_frames*=2}
    failed:runtime.Allocator_Error
    if m.commands.items,failed=make([]Command,commands,allocator);failed!=nil {return .Out_Of_Memory}
    if m.sounds,failed=make([]Sound_Slot,sounds,allocator);failed!=nil {return .Out_Of_Memory}
    if m.sound_released,failed=make([]u32,sounds,allocator);failed!=nil {return .Out_Of_Memory}
    if m.shadows,failed=make([]Voice_Shadow,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.free_voices,failed=make([]u32,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.voices,failed=make([]Mix_Voice,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.finished,failed=make([]u32,voices,allocator);failed!=nil {return .Out_Of_Memory}
    if m.bus_shadows,failed=make([]Bus_Shadow,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.buses,failed=make([]Mix_Bus,buses,allocator);failed!=nil {return .Out_Of_Memory}
    if m.bus_buffers,failed=make([]f32,buses*CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.voice_scratch,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    if m.reverb_input,failed=make([]f32,CHUNK_FRAMES*2,allocator);failed!=nil {return .Out_Of_Memory}
    reverb_init(m,&m.reverb) or_return
    if m.bus_reverbs,failed=make([]Reverb_Unit,buses,allocator);failed!=nil {return .Out_Of_Memory}
    for &unit in m.bus_reverbs {reverb_init(m,&unit) or_return}
    if m.streams,failed=make([]Stream,streams,allocator);failed!=nil {return .Out_Of_Memory}
    // The source frames of a chunk of a stream at its fastest, and the frame after them.
    if m.scratch,failed=make([]f32,(CHUNK_FRAMES*int(STREAM_STEP_MAX>>32)+4)*2,allocator);failed!=nil {return .Out_Of_Memory}
    for &stream in m.streams {
        if stream.ring,failed=make([]f32,stream_frames*2,allocator);failed!=nil {return .Out_Of_Memory}
        stream.voice=-1
    }
    for &slot in m.sounds {slot.generation=1;slot.stream=-1}
    // Slot 0 is handed out first.
    for &shadow,i in m.shadows {
        shadow.generation=1
        m.free_voices[i]=u32(voices-1-i)
    }
    m.free_count=voices
    m.bus_count=1
    for &bus in m.bus_shadows {bus.volume=1}
    for &bus in m.buses {bus.volume=1;bus.gain=1;bus.duck_gain=1;bus.duck_gain_now=1}
    m.listener.rotation=1
    return .None
}

// The audio thread must have stopped rendering before this is called.
mixer_destroy :: proc(m:^Mixer) {
    if m==nil {return}
    allocator:=m.allocator
    for &slot in m.sounds {
        if slot.state!=.Free {sound_slot_free(m,&slot)}
    }
    for stream in m.streams {delete(stream.ring,allocator)}
    delete(m.commands.items,allocator)
    delete(m.sounds,allocator);delete(m.sound_released,allocator)
    delete(m.shadows,allocator);delete(m.free_voices,allocator)
    delete(m.voices,allocator);delete(m.finished,allocator)
    delete(m.bus_shadows,allocator);delete(m.buses,allocator);delete(m.bus_buffers,allocator)
    delete(m.voice_scratch,allocator);delete(m.reverb_input,allocator);delete(m.reverb.memory,allocator)
    for unit in m.bus_reverbs {delete(unit.memory,allocator)}
    delete(m.bus_reverbs,allocator)
    delete(m.streams,allocator);delete(m.scratch,allocator)
    free(m,allocator)
}

// Frames rendered since the mixer was created: the time base of Voice_Desc.start_frame.
mixer_clock :: proc "contextless" (m:^Mixer) -> u64 {
    return sync.atomic_load_explicit(&m.clock,.Acquire)
}
mixer_stats :: proc(m:^Mixer) -> Mixer_Stats {
    stats:=m.counters
    stats.frames_rendered=mixer_clock(m)
    stats.voices_active=int(sync.atomic_load_explicit(&m.voices_active,.Relaxed))
    stats.stream_underruns=sync.atomic_load_explicit(&m.stream_underruns,.Relaxed)
    return stats
}

// Once per frame on the game thread: frees the voices that ended and the
// sounds that were destroyed, and decodes ahead for the streams that play.
mixer_update :: proc(m:^Mixer) {
    for &shadow,i in m.shadows {
        if !shadow.active || sync.atomic_load_explicit(&m.finished[i],.Acquire)!=shadow.generation {continue}
        voice_shadow_free(m,u32(i))
    }
    for &slot,i in m.sounds {
        if slot.state!=.Releasing {continue}
        if !slot.release_sent {
            slot.release_sent=command_push(m,{kind=.Sound_Release,index=u32(i)})
            continue
        }
        if sync.atomic_load_explicit(&m.sound_released[i],.Acquire)!=0 {sound_slot_free(m,&slot)}
    }
    for &stream in m.streams {
        if stream.voice>=0 {stream_fill(m,&stream)}
    }
}

@(private)
command_push :: proc(m:^Mixer,command:Command) -> bool {
    q:=&m.commands
    tail:=q.tail
    head:=sync.atomic_load_explicit(&q.head,.Acquire)
    if tail-head>=u64(len(q.items)) {m.counters.commands_dropped+=1;return false}
    q.items[tail&u64(len(q.items)-1)]=command
    sync.atomic_store_explicit(&q.tail,tail+1,.Release)
    return true
}
@(private)
command_pop :: proc "contextless" (m:^Mixer,command:^Command) -> bool {
    q:=&m.commands
    head:=q.head
    tail:=sync.atomic_load_explicit(&q.tail,.Acquire)
    if head==tail {return false}
    command^=q.items[head&u64(len(q.items)-1)]
    sync.atomic_store_explicit(&q.head,head+1,.Release)
    return true
}

// Renders len(out)/channels frames, interleaved, replacing what out held.
// The samples are not clamped: a mix louder than full scale goes above 1.
// Safe to call from an audio thread: it takes no lock and allocates nothing.
mixer_render :: proc "contextless" (m:^Mixer,out:[]f32) {
    frames:=len(out)/m.channels
    done:=0
    for done<frames {
        n:=min(frames-done,CHUNK_FRAMES)
        commands_apply(m)
        chunk_render(m,out[done*m.channels:][:n*m.channels],n)
        done+=n
        sync.atomic_add_explicit(&m.clock,u64(n),.Release)
    }
}

@(private)
commands_apply :: proc "contextless" (m:^Mixer) {
    command:Command
    for command_pop(m,&command) {
        switch command.kind {
        case .Voice_Play:
            v:=&m.voices[command.index]
            if v.phase==.Free {
                voice_begin(m,v,command.start)
            } else {
                // The slot was stolen: what plays there fades out first.
                v.next=command.start;v.has_next=true
            }
        case .Voice_Stop,.Voice_Pause,.Voice_Volume,.Voice_Pitch,.Voice_Pan,.Voice_Loop,.Voice_Fade,.Voice_Place,.Voice_Lowpass,.Voice_Reverb:
            voice_command(m,&command)
        case .Bus_Volume:m.buses[command.index].volume=command.value
        case .Bus_Mute:m.buses[command.index].muted=command.flag
        case .Bus_Lowpass:bus_lowpass_apply(m,&m.buses[command.index],command.value)
        case .Bus_Duck:
            bus:=&m.buses[command.index]
            bus.duck=command.duck
        case .Reverb:
            m.reverb.params=reverb_command(&command)
            m.reverb_bus=u16(command.index)
        case .Bus_Reverb:m.bus_reverbs[command.index].params=reverb_command(&command)
        case .Listener:
            m.listener={command.vectors[0],command.vectors[1],command.rotation}
            m.listener_serial+=1
        case .Sound_Release:
            for &v,i in m.voices {
                if v.has_next && v.next.sound==command.index {voice_next_cancel(m,u32(i))}
                if v.phase!=.Free && v.sound==command.index {
                    // What takes its place may play the same sound.
                    voice_end(m,u32(i))
                    if v.phase!=.Free && v.sound==command.index {voice_end(m,u32(i))}
                }
            }
            sync.atomic_store_explicit(&m.sound_released[command.index],1,.Release)
        }
    }
}

@(private)
chunk_render :: proc "contextless" (m:^Mixer,out:[]f32,n:int) {
    #no_bounds_check {
        for i in 0..<len(m.buses)*CHUNK_FRAMES*2 {m.bus_buffers[i]=0}
        for i in 0..<CHUNK_FRAMES*2 {m.reverb_input[i]=0}
    }
    clock:=m.clock
    active:=i32(0)
    for &v,i in m.voices {
        if v.phase==.Free {continue}
        voice_mix(m,u32(i),n,clock)
        if v.phase!=.Free {active+=1}
    }
    sync.atomic_store_explicit(&m.voices_active,active,.Relaxed)
    room:=raw_data(m.bus_buffers[int(m.reverb_bus)*CHUNK_FRAMES*2:])
    reverb_run(&m.reverb,raw_data(m.reverb_input),room,n)
    buses_mix(m,out,n)
}
