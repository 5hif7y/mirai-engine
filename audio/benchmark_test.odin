package mirai_audio

import "core:fmt"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

AUDIO_BENCHMARK :: #config(AUDIO_BENCHMARK,false)

@(private="file")
Scenario :: enum {Mono_Direct,Mono_Resampled,Stereo_Resampled,Spatial_Moving,Mixed_Buses}

// Time to mix 10 ms of audio (480 frames at 48 kHz) with every voice playing.
@(test)
benchmark_mixing_ten_milliseconds :: proc(t:^testing.T) {
    if !AUDIO_BENCHMARK {return}
    FRAMES :: 480
    RUNS :: 2000
    out:=make([]f32,FRAMES*2)
    defer delete(out)
    times:=make([]f64,RUNS)
    defer delete(times)
    for scenario in Scenario {
        for count in ([?]int{64,256}) {
            m:=test_mixer(t,{voice_capacity=count,command_capacity=4096})
            defer mixer_destroy(m)
            mono:=test_mono(t,m,RATE,proc(i:int) -> f32 {return 0.01*math.sin_f32(f32(i)*0.05)})
            mono_44:=test_mono(t,m,44100,proc(i:int) -> f32 {return 0.01*math.sin_f32(f32(i)*0.05)},44100)
            stereo_44:=test_stereo(t,m,44100,proc(i:int) -> f32 {return 0.01*math.sin_f32(f32(i)*0.05)},44100)
            buses:[3]Bus
            for &bus in buses {bus,_=bus_create(m)}
            if scenario==.Mixed_Buses {
                bus_set_lowpass(m,buses[0],4000)
                bus_set_lowpass(m,buses[1],800)
                bus_set_duck(m,buses[0],{source=buses[2],threshold=0.001,amount=0.5,attack=0.01,release=0.2})
            }
            voices:=make([]Voice,count,context.temp_allocator)
            for &voice,i in voices {
                desc:=VOICE_DEFAULT
                desc.loop=true
                desc.pan=f32(i%9)/4-1
                desc.offset=f32(i)*0.003
                sound:=mono
                switch scenario {
                case .Mono_Direct:
                case .Mono_Resampled:sound=mono_44;desc.pitch=0.8+f32(i%8)*0.05
                case .Stereo_Resampled:sound=stereo_44;desc.pitch=0.8+f32(i%8)*0.05
                case .Spatial_Moving:
                    sound=mono_44;desc.spatial=true;desc.doppler=1
                    desc.position={f32(i%16)-8,0,-f32(i%5)-1}
                case .Mixed_Buses:
                    sound=mono_44 if i%2==0 else stereo_44 if i%4==1 else mono
                    desc.bus=buses[i%3];desc.spatial=i%4==0;desc.position={f32(i%16)-8,0,-2}
                }
                voice=voice_play(m,sound,desc)
            }
            testing.expect_value(t,mixer_stats(m).commands_dropped,u64(0))
            mixer_render(m,out)
            testing.expect_value(t,mixer_stats(m).voices_active,count)
            for &sample,run in times {
                if scenario==.Spatial_Moving {
                    // Every voice and the listener move every 10 ms: all positions are worked out again.
                    for voice,i in voices {voice_set_position(m,voice,{f32(i%16)-8+f32(run%100)*0.01,0,-f32(i%5)-1},{1,0,0})}
                    listener_set(m,{f32(run%50)*0.01,0,0},1)
                }
                start:=time.tick_now()
                mixer_render(m,out)
                sample=f64(time.duration_microseconds(time.tick_since(start)))
            }
            slice.sort(times)
            fmt.printfln("%-17v %3d voices: median %7.1f us, best %7.1f us, 99th percentile %7.1f us (%.2f%% of 10 ms)",scenario,count,times[RUNS/2],times[0],times[RUNS*99/100],times[RUNS/2]/100)
        }
    }
}
