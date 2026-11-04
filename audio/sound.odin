package mirai_audio

import "base:runtime"
import "mirai:std/base"

// Sounds: PCM held by the mixer as interleaved f32, mono or stereo, at the
// sample rate they were recorded at. A streamed sound keeps its encoded file
// instead and decodes a little ahead of what plays.

Sound :: distinct base.Handle

// Decoded audio: len(samples)/channels frames, interleaved.
Pcm :: struct {samples:[]f32,channels,sample_rate:int}

pcm_destroy :: proc(pcm:^Pcm,allocator:=context.allocator) {
    delete(pcm.samples,allocator)
    pcm^={}
}

@(private)
Sound_State :: enum u8 {Free,Ready,Releasing}
@(private)
Sound_Slot :: struct {
    generation:u32,
    state:Sound_State,
    release_sent:bool,
    samples:[]f32, // owned
    frames:u32,
    channels,rate:u32,
    stream:i32, // index of its stream; -1 for a sound in memory
}

@(private)
sound_slot :: proc(m:^Mixer,sound:Sound) -> ^Sound_Slot {
    index:=base.handle_index(base.Handle(sound))
    if sound==0 || int(index)>=len(m.sounds) {return nil}
    slot:=&m.sounds[index]
    if slot.state!=.Ready || slot.generation!=base.handle_generation(base.Handle(sound)) {return nil}
    return slot
}
@(private)
sound_slot_take :: proc(m:^Mixer) -> (index:int,error:Error) {
    for slot,i in m.sounds {
        if slot.state==.Free {return i,.None}
    }
    return -1,.Capacity_Exhausted
}
@(private)
sound_slot_free :: proc(m:^Mixer,slot:^Sound_Slot) {
    if slot.stream>=0 {stream_close(m,&m.streams[slot.stream])}
    delete(slot.samples,m.allocator)
    slot^={generation=slot.generation+1,stream=-1}
    m.counters.sounds-=1
}

// Copies interleaved frames into a new sound. channels is 1 or 2.
sound_create :: proc(m:^Mixer,samples:[]f32,channels,sample_rate:int) -> (sound:Sound,error:Error) {
    if channels<1 || channels>2 || sample_rate<=0 || len(samples)%channels!=0 || len(samples)/channels>=int(max(u32)) {return 0,.Invalid_Desc}
    index:=sound_slot_take(m) or_return
    copied,failed:=make([]f32,len(samples),m.allocator)
    if failed!=nil {return 0,.Out_Of_Memory}
    copy(copied,samples)
    return sound_slot_fill(m,index,copied,channels,sample_rate,-1),.None
}
// A new sound of interleaved 16 bit frames, turned to f32 as they are copied.
sound_create_pcm16 :: proc(m:^Mixer,samples:[]i16,channels,sample_rate:int) -> (sound:Sound,error:Error) {
    if channels<1 || channels>2 || sample_rate<=0 || len(samples)%channels!=0 || len(samples)/channels>=int(max(u32)) {return 0,.Invalid_Desc}
    index:=sound_slot_take(m) or_return
    converted,failed:=make([]f32,len(samples),m.allocator)
    if failed!=nil {return 0,.Out_Of_Memory}
    for sample,i in samples {converted[i]=f32(sample)*(1.0/32768)}
    return sound_slot_fill(m,index,converted,channels,sample_rate,-1),.None
}
// Decodes a whole WAV or Ogg Vorbis file into a new sound.
sound_load :: proc(m:^Mixer,file:[]u8) -> (sound:Sound,error:Error) {
    index:=sound_slot_take(m) or_return
    pcm:=decode(file,m.allocator) or_return
    return sound_slot_fill(m,index,pcm.samples,pcm.channels,pcm.sample_rate,-1),.None
}
@(private)
sound_slot_fill :: proc(m:^Mixer,index:int,samples:[]f32,channels,sample_rate:int,stream:i32) -> Sound {
    slot:=&m.sounds[index]
    slot.state=.Ready;slot.release_sent=false
    slot.samples=samples
    slot.frames=u32(len(samples)/channels)
    slot.channels=u32(channels);slot.rate=u32(sample_rate)
    slot.stream=stream
    m.sound_released[index]=0
    m.counters.sounds+=1
    return Sound(base.handle_make(u32(index),slot.generation))
}

// The handle dies now and the voices that play the sound end; its memory is
// freed by a later mixer_update, once the audio thread has let go of it.
sound_destroy :: proc(m:^Mixer,sound:Sound) {
    slot:=sound_slot(m,sound)
    if slot==nil {return}
    slot.state=.Releasing
    slot.release_sent=command_push(m,{kind=.Sound_Release,index=base.handle_index(base.Handle(sound))})
}
sound_valid :: proc(m:^Mixer,sound:Sound) -> bool {return sound_slot(m,sound)!=nil}
// Length in frames at its own sample rate; 0 for a stream of unknown length.
sound_frames :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    if slot==nil {return 0}
    if slot.stream>=0 {return m.streams[slot.stream].decoder.frames}
    return int(slot.frames)
}
sound_sample_rate :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    return int(slot.rate) if slot!=nil else 0
}
sound_channels :: proc(m:^Mixer,sound:Sound) -> int {
    slot:=sound_slot(m,sound)
    return int(slot.channels) if slot!=nil else 0
}
sound_seconds :: proc(m:^Mixer,sound:Sound) -> f32 {
    rate:=sound_sample_rate(m,sound)
    return f32(sound_frames(m,sound))/f32(rate) if rate>0 else 0
}

// WAV or Ogg Vorbis, told apart by the first bytes of the file.
decode :: proc(file:[]u8,allocator:runtime.Allocator) -> (pcm:Pcm,error:Error) {
    if len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE" {return wav_decode(file,allocator)}
    if len(file)>=4 && string(file[:4])=="OggS" {return vorbis_decode(file,allocator)}
    return {},.Invalid_Data
}
