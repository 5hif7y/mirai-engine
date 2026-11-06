package mirai_audio

import "core:testing"

@(private="file") TONE_LONG :: #load("testdata/tone_long.ogg") // 2 s of 330 Hz at 32 kHz, mono

// A xorshift: numbers that repeat from run to run.
@(private="file")
next :: proc(state:^u64,n:int) -> int {
    state^~=state^<<13;state^~=state^>>7;state^~=state^<<17
    return int(state^%u64(n))
}

// Music-like: a few tones, some noise and a channel that follows the other.
@(private="file")
lossless_music :: proc(frames,channels:int,r:^u64) -> []i16 {
    samples:=make([]i16,frames*channels,context.temp_allocator)
    phase:=[3]f32{}
    for i in 0..<frames {
        phase+={0.031,0.0731,0.0113}
        value:=9000*sin(phase[0])+5000*sin(phase[1])+3000*sin(phase[2])+f32(next(r,801)-400)
        samples[i*channels]=i16(value)
        if channels==2 {samples[i*2+1]=i16(value*0.7+f32(next(r,201)-100))}
    }
    return samples
}
@(private="file")
sin :: proc(x:f32) -> f32 {
    // Bhaskara's approximation is enough for a test signal and needs no tables.
    x:=x-6.2831855*f32(int(x/6.2831855))
    sign:=f32(1)
    if x>3.1415927 {x-=3.1415927;sign=-1}
    return sign*16*x*(3.1415927-x)/(5*3.1415927*3.1415927-4*x*(3.1415927-x))
}

@(test)
lossless_decodes_bit_for_bit_what_was_encoded :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    r:=u64(0x9E3779B97F4A7C15+7)
    Case :: struct {name:string,channels:int,samples:[]i16}
    cases:=make([dynamic]Case,context.temp_allocator)
    append(&cases,Case{"mono",1,lossless_music(LOSSLESS_BLOCK_FRAMES*3+517,1,&r)})
    append(&cases,Case{"stereo",2,lossless_music(LOSSLESS_BLOCK_FRAMES*2+1,2,&r)})
    append(&cases,Case{"silence",2,make([]i16,2*10000,context.temp_allocator)})
    noise:=make([]i16,2*9000,context.temp_allocator)
    for &sample in noise {sample=i16(next(&r,65536)-32768)}
    noise[0],noise[1],noise[2],noise[3]=32767,-32768,-32768,32767
    append(&cases,Case{"full-scale noise",2,noise})
    append(&cases,Case{"short",2,[]i16{-32768,32767,5,-5,0,1}})
    append(&cases,Case{"one frame",1,[]i16{-1234}})
    // A source of 8 bits: the low byte of every sample is zero.
    eight:=make([]i16,6000,context.temp_allocator)
    for &sample,i in eight {sample=i16((i*7)%256-128)<<8}
    append(&cases,Case{"eight bits",1,eight})
    // Left and right at opposite extremes: a side channel of 17 bits.
    extremes:=make([]i16,2*5000,context.temp_allocator)
    for i in 0..<5000 {extremes[i*2],extremes[i*2+1]=(i%2==0?32767:-32768),(i%2==0?-32768:32767)}
    append(&cases,Case{"opposite extremes",2,extremes})

    for c in cases {
        file,error:=lossless_encode(c.samples,c.channels,44100,context.temp_allocator)
        if !testing.expectf(t,error==.None,"%s: %v",c.name,error) {continue}
        pcm,decode_error:=decode(file,context.temp_allocator)
        if !testing.expectf(t,decode_error==.None && pcm.channels==c.channels && pcm.sample_rate==44100 && len(pcm.samples)==len(c.samples),"%s: decoded as %v, %d channels, %d samples",c.name,decode_error,pcm.channels,len(pcm.samples)) {continue}
        for sample,i in c.samples {
            // What plays is what a WAV of the samples plays.
            if pcm.samples[i]!=f32(sample)*(1.0/32768) {
                testing.expectf(t,false,"%s: sample %d is %v, not %d",c.name,i,pcm.samples[i]*32768,sample)
                break
            }
        }
        if c.name!="full-scale noise" && c.name!="short" && c.name!="one frame" {
            testing.expectf(t,len(file)<len(c.samples)*2,"%s: %d bytes for %d of samples",c.name,len(file),len(c.samples)*2)
        }
    }
}

@(test)
lossless_refuses_what_it_does_not_code_and_survives_damage :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    samples:=[]i16{1,2,3,4,5,6}
    _,error:=lossless_encode(samples,3,48000,context.temp_allocator)
    testing.expect_value(t,error,Error.Invalid_Desc)
    _,error=lossless_encode(samples[:5],2,48000,context.temp_allocator)
    testing.expect_value(t,error,Error.Invalid_Desc)
    _,error=lossless_encode(samples,1,0,context.temp_allocator)
    testing.expect_value(t,error,Error.Invalid_Desc)

    r:=u64(0x9E3779B97F4A7C15+11)
    music:=lossless_music(LOSSLESS_BLOCK_FRAMES*2+100,2,&r)
    file,_:=lossless_encode(music,2,48000,context.temp_allocator)
    // Every cut and damaged byte decodes or is refused, without reading outside the file.
    damaged:=make([]u8,len(file),context.temp_allocator)
    for length:=0;length<len(file);length+=max(len(file)/300,1) {
        if pcm,decode_error:=decode(file[:length],context.temp_allocator);decode_error==.None {testing.expect(t,len(pcm.samples)<=len(music))}
        copy(damaged,file)
        damaged[length]~=u8(next(&r,255)+1)
        decode(damaged,context.temp_allocator)
        m:=test_mixer(t,{stream_frames=1024})
        if sound,stream_error:=sound_stream(m,damaged);stream_error==.None {
            voice_play(m,sound)
            for _ in 0..<12 {
                test_render(m,1000)
                mixer_update(m)
            }
        }
        mixer_destroy(m)
    }
}

// Streamed, from the beginning or from an offset and looping, a lossless
// sound plays the frames of its whole decode.
@(test)
lossless_stream_and_its_offsets_play_the_whole_decode :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    r:=u64(0x9E3779B97F4A7C15+3)
    FRAMES :: LOSSLESS_BLOCK_FRAMES*7+1234
    music:=lossless_music(FRAMES,2,&r)
    file,_:=lossless_encode(music,2,RATE,context.temp_allocator)
    whole,_:=decode(file,context.temp_allocator)

    m:=test_mixer(t,{stream_frames=1024})
    defer mixer_destroy(m)
    sound,error:=sound_stream(m,file)
    testing.expect_value(t,error,Error.None)
    testing.expect(t,sound_frames(m,sound)==FRAMES && sound_channels(m,sound)==2 && sound_sample_rate(m,sound)==RATE)
    play :: proc(m:^Mixer,frames:int) -> []f32 {
        out:=make([]f32,frames*2,context.temp_allocator)
        for done:=0;done<frames;done+=173 {
            n:=min(173,frames-done)
            mixer_render(m,out[done*2:][:n*2])
            mixer_update(m)
        }
        return out
    }
    same :: proc(t:^testing.T,what:string,got:[]f32,whole:[]f32,first,frames:int) {
        for i in 0..<len(got)/2 {
            frame:=(first+i)%frames
            if got[i*2]!=whole[frame*2] || got[i*2+1]!=whole[frame*2+1] {
                testing.expectf(t,false,"%s: frame %d of the output is not frame %d of the sound",what,i,frame)
                return
            }
        }
    }
    voice:=voice_play(m,sound)
    same(t,"from the beginning",play(m,FRAMES),whole.samples,0,FRAMES)
    play(m,CHUNK_FRAMES*2)
    testing.expect(t,!voice_valid(m,voice))

    // An offset inside a block, looping back to the beginning at the end.
    desc:=VOICE_DEFAULT
    desc.offset=0.3125 // 15000 frames
    desc.loop=true
    voice=voice_play(m,sound,desc)
    same(t,"from an offset, looping",play(m,FRAMES+20000),whole.samples,15000,FRAMES)
    testing.expect(t,voice_stop(m,voice))
    play(m,CHUNK_FRAMES*2)
    testing.expect_value(t,mixer_stats(m).stream_underruns,u64(0))
}

// A Vorbis stream starts at an offset as the same file played from memory does.
@(test)
ogg_stream_starts_at_an_offset :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    memory:=test_mixer(t)
    defer mixer_destroy(memory)
    streamed:=test_mixer(t,{stream_frames=2048})
    defer mixer_destroy(streamed)
    loaded,_:=sound_load(memory,TONE_LONG)
    stream,_:=sound_stream(streamed,TONE_LONG)
    desc:=VOICE_DEFAULT
    desc.offset=1.25 // 40000 frames at 32 kHz
    voice_play(memory,loaded,desc)
    voice_play(streamed,stream,desc)
    worst:=f32(0)
    for _ in 0..<60 {
        want:=test_render(memory,480)
        got:=test_render(streamed,480)
        mixer_update(memory);mixer_update(streamed)
        for i in 0..<len(want) {worst=max(worst,abs(want[i]-got[i]))}
    }
    testing.expectf(t,worst<1e-5,"the stream differs from the sound in memory by %v",worst)
}
