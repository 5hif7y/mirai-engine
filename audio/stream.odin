package mirai_audio

import "base:runtime"
import "core:sync"
import "vendor:stb/vorbis"

// Streaming: a long sound is decoded on the game thread, in mixer_update, a
// little ahead of what the audio thread plays. The two meet in a ring of
// decoded frames: one writes, the other reads, neither waits.

// Source frames a stream voice may consume per output frame: its pitch
// times the ratio of the sample rates is clamped to this.
@(private) STREAM_STEP_MAX :: ONE*8

@(private)
Decoder_Kind :: enum u8 {None,Wav,Vorbis,Lossless}
@(private)
Decoder :: struct {
    kind:Decoder_Kind,
    channels,sample_rate:int,
    frames:int, // total; 0 when the file does not say
    cursor:int,
    wav:Wav,
    vorbis:^vorbis.vorbis,
    lossless:Lossless,
    held:int,    // the lossless block decoded in memory; -1 when none
    memory:[]u8, // everything the Vorbis decoder allocates
    planes:[]i32, // a decoded lossless block, channel after channel
}
@(private)
Stream :: struct {
    used:bool,
    decoder:Decoder,
    ring:[]f32, // len(ring)/2 frames, a power of two; a mono stream uses the first half
    write:u64,  // frames decoded since the stream began; written by the game thread, atomic
    read:u64,   // frames played; written by the audio thread, atomic
    ended:u32,  // the decoder reached the end: what the ring holds is all there is; atomic
    loop:bool,
    voice:i32,  // slot of the voice that plays it; -1 when none
}

@(private)
decoder_open :: proc(file:[]u8,allocator:runtime.Allocator) -> (d:Decoder,error:Error) {
    if len(file)>=12 && string(file[:4])=="RIFF" && string(file[8:12])=="WAVE" {
        d.wav=wav_parse(file) or_return
        d.kind=.Wav
        d.channels=d.wav.channels;d.sample_rate=d.wav.sample_rate;d.frames=d.wav.frames
        return d,.None
    }
    if len(file)>=4 && string(file[:4])=="OggS" {
        d.vorbis,d.memory=vorbis_open(file,allocator) or_return
        info:=vorbis.get_info(d.vorbis)
        d.kind=.Vorbis
        d.channels=int(info.channels);d.sample_rate=int(info.sample_rate)
        d.frames=int(vorbis.stream_length_in_samples(d.vorbis))
        return d,.None
    }
    if len(file)>=4 && string(file[:4])==LOSSLESS_MAGIC {
        d.lossless=lossless_parse(file) or_return
        failed:runtime.Allocator_Error
        if d.planes,failed=make([]i32,d.lossless.block_frames*d.lossless.channels,allocator);failed!=nil {return {},.Out_Of_Memory}
        d.kind=.Lossless
        d.channels=d.lossless.channels;d.sample_rate=d.lossless.sample_rate;d.frames=d.lossless.frames
        d.held=-1
        return d,.None
    }
    return {},.Invalid_Data
}
@(private)
decoder_close :: proc(d:^Decoder,allocator:runtime.Allocator) {
    if d.vorbis!=nil {vorbis.close(d.vorbis)}
    delete(d.memory,allocator)
    delete(d.planes,allocator)
    d^={}
}
// Decodes up to len(out)/channels frames and returns how many; fewer means the end.
@(private)
decoder_read :: proc(d:^Decoder,out:[]f32) -> int {
    count:=0
    switch d.kind {
    case .None:
    case .Wav:count=wav_convert(&d.wav,d.cursor,out)
    case .Vorbis:
        wanted:=len(out)/d.channels
        for count<wanted {
            got:=int(vorbis.get_samples_float_interleaved(d.vorbis,i32(d.channels),raw_data(out[count*d.channels:]),i32((wanted-count)*d.channels)))
            if got<=0 {break}
            count+=got
        }
    case .Lossless:
        l:=&d.lossless
        wanted:=min(len(out)/d.channels,l.frames-d.cursor)
        for count<wanted {
            at:=d.cursor+count
            block:=at/l.block_frames
            if block!=d.held {
                // A damaged block plays as silence.
                lossless_block(l,block,d.planes)
                d.held=block
            }
            frames:=min(l.block_frames,l.frames-block*l.block_frames)
            first:=at-block*l.block_frames
            run:=min(wanted-count,frames-first)
            lossless_convert(d.planes,l.block_frames,d.channels,first,run,out[count*d.channels:])
            count+=run
        }
    }
    d.cursor+=count
    return count
}
// The next frame decoder_read gives is frame; past the end, nothing is left.
@(private)
decoder_seek :: proc(d:^Decoder,frame:int) {
    frame:=max(frame,0)
    switch d.kind {
    case .None,.Lossless:
    case .Wav:frame=min(frame,d.wav.frames)
    case .Vorbis:
        if frame==0 || vorbis.seek(d.vorbis,u32(min(frame,int(max(u32)))))==0 {
            vorbis.seek_start(d.vorbis)
            frame=0
        }
    }
    d.cursor=frame
}

// A sound that is decoded while it plays, for music and long ambiences. The
// file is not copied: it must stay in memory until the sound is destroyed
// and a later mixer_update has freed it. One voice at a time can play it.
sound_stream :: proc(m:^Mixer,file:[]u8) -> (sound:Sound,error:Error) {
    index:=sound_slot_take(m) or_return
    stream:=-1
    for candidate,i in m.streams {
        if !candidate.used {stream=i;break}
    }
    if stream<0 {return 0,.Capacity_Exhausted}
    s:=&m.streams[stream]
    s.decoder=decoder_open(file,m.allocator) or_return
    s.used=true;s.voice=-1
    return sound_slot_fill(m,index,nil,s.decoder.channels,s.decoder.sample_rate,i32(stream)),.None
}
@(private)
stream_close :: proc(m:^Mixer,s:^Stream) {
    decoder_close(&s.decoder,m.allocator)
    s.used=false;s.voice=-1
}

// No voice plays the stream, so the audio thread does not look at it: it
// starts over from frame with a full ring.
@(private)
stream_begin :: proc(m:^Mixer,s:^Stream,loop:bool,frame:int) {
    decoder_seek(&s.decoder,frame)
    s.loop=loop
    sync.atomic_store_explicit(&s.read,0,.Release)
    sync.atomic_store_explicit(&s.write,0,.Release)
    sync.atomic_store_explicit(&s.ended,0,.Release)
    stream_fill(m,s)
}
@(private)
stream_fill :: proc(m:^Mixer,s:^Stream) {
    if sync.atomic_load_explicit(&s.ended,.Relaxed)!=0 {return}
    capacity:=u64(len(s.ring)/2)
    channels:=s.decoder.channels
    write:=s.write
    free:=capacity-(write-sync.atomic_load_explicit(&s.read,.Acquire))
    rewound:=false
    for free>0 {
        at:=write&(capacity-1)
        run:=int(min(free,capacity-at))
        got:=decoder_read(&s.decoder,s.ring[int(at)*channels:][:run*channels])
        write+=u64(got);free-=u64(got)
        sync.atomic_store_explicit(&s.write,write,.Release)
        if got==run {rewound=false;continue}
        // The end of the file: start over for a loop, unless the file is empty.
        if !s.loop || (got==0 && rewound) {
            sync.atomic_store_explicit(&s.ended,1,.Release)
            return
        }
        decoder_seek(&s.decoder,0)
        rewound=true
    }
}

// The audio thread side: lays the frames the chunk needs out in a row, mixes
// them like a sound in memory and gives back to the ring what was played.
@(private)
stream_voice_mix :: proc "contextless" (m:^Mixer,v:^Mix_Voice,out:[^]f32,from,to:int,step:u64,target:[4]f32,span:f32) -> (alive:bool) {
    s:=&m.streams[v.source.stream]
    // In this order: once ended is set, write no longer moves.
    ended:=sync.atomic_load_explicit(&s.ended,.Acquire)!=0
    write:=sync.atomic_load_explicit(&s.write,.Acquire)
    read:=s.read
    capacity:=u64(len(s.ring)/2)
    channels:=u64(v.source.channels)
    available:=write-read
    needed:=(u64(u32(v.cursor))+step*u64(to-from))>>32+2
    count:=min(available,needed)
    #no_bounds_check for i in 0..<count {
        at:=(read+i)&(capacity-1)
        for c in 0..<channels {m.scratch[i*channels+c]=s.ring[at*channels+c]}
    }
    // More of the sound is still to come after these frames, now or later.
    holds:=!ended || count<available
    mixed:int
    alive,mixed=segments_mix(v,raw_data(m.scratch),count,false,holds,out,from,to,max(step,1),target,span)
    sync.atomic_store_explicit(&s.read,read+v.cursor>>32,.Release)
    v.cursor&=ONE-1
    if holds && mixed<to-from && !ended {sync.atomic_add_explicit(&m.stream_underruns,1,.Relaxed)}
    return alive
}
