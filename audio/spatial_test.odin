package mirai_audio

import "core:math"
import "core:testing"

@(test)
attenuation_models_follow_their_curves :: proc(t:^testing.T) {
    inverse:=Attenuation{model=.Inverse,min_distance=2,max_distance=50,rolloff=1}
    test_near(t,attenuation_gain(inverse,0),1)
    test_near(t,attenuation_gain(inverse,2),1)
    test_near(t,attenuation_gain(inverse,4),0.5)
    test_near(t,attenuation_gain(inverse,8),0.25)
    test_near(t,attenuation_gain(inverse,20),0.1)
    // Beyond the maximum distance the level stops falling.
    test_near(t,attenuation_gain(inverse,50),0.04)
    test_near(t,attenuation_gain(inverse,5000),0.04)
    inverse.rolloff=3
    test_near(t,attenuation_gain(inverse,4),2.0/(2+3*2))
    inverse.rolloff=0
    test_near(t,attenuation_gain(inverse,40),1)

    linear:=Attenuation{model=.Linear,min_distance=10,max_distance=110,rolloff=1}
    test_near(t,attenuation_gain(linear,5),1)
    test_near(t,attenuation_gain(linear,10),1)
    test_near(t,attenuation_gain(linear,35),0.75)
    test_near(t,attenuation_gain(linear,60),0.5)
    test_near(t,attenuation_gain(linear,110),0)
    test_near(t,attenuation_gain(linear,400),0)
    linear.rolloff=0.5
    test_near(t,attenuation_gain(linear,110),0.5)
    linear.rolloff=4
    test_near(t,attenuation_gain(linear,60),0)

    exponential:=Attenuation{model=.Exponential,min_distance=1,max_distance=100,rolloff=2}
    test_near(t,attenuation_gain(exponential,0.5),1)
    test_near(t,attenuation_gain(exponential,2),0.25)
    test_near(t,attenuation_gain(exponential,10),0.01)
    test_near(t,attenuation_gain(exponential,1000),0.0001,1e-7)
    exponential.rolloff=1
    test_near(t,attenuation_gain(exponential,4),0.25)

    test_near(t,attenuation_gain({model=.None,min_distance=1,max_distance=10,rolloff=1},500),1)
    // Distances that make no sense do not divide by zero.
    test_near(t,attenuation_gain({model=.Inverse},3),1e-4/(1e-4+0*3))
    test_near(t,attenuation_gain({model=.Linear,min_distance=5,max_distance=5,rolloff=1},9),1)
    testing.expect(t,!math.is_nan(attenuation_gain({model=.Exponential,rolloff=1},0)))
    // Every model falls or stays as the distance grows.
    for model in Attenuation_Model {
        a:=Attenuation{model=model,min_distance=1,max_distance=80,rolloff=1.5}
        previous:=f32(2)
        for step in 0..<400 {
            gain:=attenuation_gain(a,f32(step)*0.25)
            testing.expect(t,gain<=previous && gain>=0 && gain<=1)
            previous=gain
        }
    }
}

@(test)
listener_orientation_decides_the_side_of_a_source :: proc(t:^testing.T) {
    ahead:=quaternion128(1)
    test_near(t,listener_pan({},ahead,{5,0,0}),1)
    test_near(t,listener_pan({},ahead,{-5,0,0}),-1)
    test_near(t,listener_pan({},ahead,{0,0,-5}),0)
    test_near(t,listener_pan({},ahead,{0,0,5}),0)
    test_near(t,listener_pan({},ahead,{0,7,0}),0)
    test_near(t,listener_pan({1,2,3},ahead,{1,2,3}),0)
    test_near(t,listener_pan({},ahead,{3,0,-3}),math.SQRT_TWO/2)
    // The listener moved: sides are relative to where it is.
    test_near(t,listener_pan({10,0,0},ahead,{5,0,0}),-1)
    // Turned a quarter turn to its left (about +Y): what was ahead is now at its right.
    left:=quaternion(real=math.cos_f32(math.PI/4),imag=0,jmag=math.sin_f32(math.PI/4),kmag=0)
    test_near(t,listener_pan({},left,{0,0,-5}),1,1e-5)
    test_near(t,listener_pan({},left,{-5,0,0}),0,1e-5)
    test_near(t,listener_pan({},left,{0,0,5}),-1,1e-5)
    // Looking straight up, left and right stay where they were.
    up:=quaternion(real=math.cos_f32(math.PI/4),imag=math.sin_f32(math.PI/4),jmag=0,kmag=0)
    test_near(t,listener_pan({},up,{5,0,0}),1,1e-5)
    test_near(t,listener_pan({},up,{0,5,0}),0,1e-5)
}

@(test)
doppler_raises_the_pitch_of_what_approaches :: proc(t:^testing.T) {
    c:=f32(343)
    // A source coming at a tenth of the speed of sound, and going away.
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},1,c),1/0.9,1e-5)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,-34.3},1,c),1/1.1,1e-5)
    // A listener moving toward the source, and away from it.
    test_near(t,doppler_pitch({},{0,0,-34.3},{0,0,-100},{},1,c),1.1,1e-5)
    test_near(t,doppler_pitch({},{0,0,34.3},{0,0,-100},{},1,c),0.9,1e-5)
    // Moving together, or across the line between them, changes nothing.
    test_near(t,doppler_pitch({},{5,0,0},{0,0,-100},{5,0,0},1,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{50,0,0},1,c),1)
    // The factor scales the effect; zero turns it off.
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},0,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,34.3},2,c),1/0.8,1e-5)
    // At the same place, and faster than sound: finite and bounded.
    test_near(t,doppler_pitch({1,1,1},{},{1,1,1},{0,0,900},1,c),1)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,5000},1,c),4)
    test_near(t,doppler_pitch({},{},{0,0,-100},{0,0,-5000},1,c),1/1.99,1e-4)
}

@(test)
spatial_voice_is_panned_and_attenuated_for_the_listener :: proc(t:^testing.T) {
    m:=test_mixer(t)
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.loop=true;desc.spatial=true
    desc.attenuation={model=.Inverse,min_distance=1,max_distance=100,rolloff=1}
    desc.pan=-1 // has no say for a spatial voice
    one:=test_mono(t,m,64,test_one)
    half:=f32(math.SQRT_TWO/2)
    // Four meters to the right: all in the right speaker, a quarter of the level.
    desc.position={4,0,0}
    voice:=voice_play(m,one,desc)
    out:=test_render(m,4)
    test_near(t,out[0],0,1e-6)
    test_near(t,out[1],0.25,1e-6)
    // Two meters ahead: centered, half the level.
    testing.expect(t,voice_set_position(m,voice,{0,0,-2}))
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],0.5*half,1e-6)
    test_near(t,out[1],0.5*half,1e-6)
    // The listener steps to the right of it and looks the same way: now it is at its left.
    testing.expect(t,listener_set(m,{2,0,-2},1))
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],0.5,1e-6)
    test_near(t,out[1],0,1e-6)
    // Turning around puts it at the right.
    around:quaternion128=quaternion(real=0,imag=0,jmag=1,kmag=0)
    listener_set(m,{2,0,-2},around)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[0],0,1e-6)
    test_near(t,out[1],0.5,1e-6)
    // Its volume still applies.
    voice_set_volume(m,voice,3)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[1],1.5,1e-5)
    voice_stop(m,voice)
    test_render(m,CHUNK_FRAMES)
    mixer_update(m)

    // A stereo sound with a place in the world is heard as one source.
    listener_set(m,{},1)
    desc.position={-1,0,0}
    stereo:=make([]f32,128,context.temp_allocator)
    for i in 0..<64 {stereo[i*2]=1;stereo[i*2+1]=0.5}
    sound,_:=sound_create(m,stereo,2,RATE)
    voice_play(m,sound,desc)
    out=test_render(m,4)
    test_near(t,out[0],0.75,1e-6)
    test_near(t,out[1],0,1e-6)
}

@(test)
doppler_changes_the_speed_of_a_spatial_voice :: proc(t:^testing.T) {
    m:=test_mixer(t,{speed_of_sound=300})
    defer mixer_destroy(m)
    desc:=VOICE_DEFAULT
    desc.spatial=true;desc.attenuation={model=.None}
    desc.position={0,0,-50}
    desc.velocity={0,0,60} // toward the listener at a fifth of the speed of sound: 300/(300-60)=1.25
    sound:=test_mono(t,m,100000,test_ramp)
    half:=f32(math.SQRT_TWO/2)
    desc.doppler=1
    voice:=voice_play(m,sound,desc)
    out:=test_render(m,200)
    for i in 0..<200 {
        if !test_near(t,out[i*2],(1+f32(i)*1.25)*half,2e-3) {break}
    }
    // Without the effect the same voice plays as recorded.
    desc.doppler=0
    voice_stop(m,voice)
    plain:=voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[2]-out[0],half,1e-4)
    // The pitch of the voice and the effect multiply: it stops and the listener runs from it.
    voice_set_pitch(m,plain,2)
    voice_stop(m,plain)
    desc.doppler=1;desc.pitch=2;desc.velocity={}
    listener_set(m,{},1,{0,0,150})
    away:=voice_play(m,sound,desc)
    test_render(m,CHUNK_FRAMES)
    out=test_render(m,4)
    test_near(t,out[2]-out[0],2*0.5*half,1e-3)
    testing.expect(t,voice_valid(m,away))
}
