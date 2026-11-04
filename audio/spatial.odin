package mirai_audio

import "core:math"
import mm "mirai:std/math"

// Positional audio. Right-handed, Y up, meters: a listener with no rotation
// looks down -Z and has +X at its right.

Attenuation_Model :: enum u8 {
    None,        // the same level at any distance
    Inverse,     // min/(min+rolloff*(d-min)): halves at twice the minimum distance with rolloff 1
    Linear,      // 1-rolloff*(d-min)/(max-min): silent at the maximum distance with rolloff 1
    Exponential, // (d/min)^-rolloff
}
// The distance is clamped to [min_distance,max_distance] before the model
// is applied: nearer than the minimum the gain is 1, beyond the maximum it
// stops falling.
Attenuation :: struct {
    model:Attenuation_Model,
    min_distance,max_distance:f32,
    rolloff:f32,
}
ATTENUATION_DEFAULT :: Attenuation{model=.Inverse,min_distance=1,max_distance=100,rolloff=1}

@(private)
Listener :: struct {
    position,velocity:[3]f32,
    rotation:quaternion128,
}

attenuation_gain :: proc "contextless" (a:Attenuation,distance:f32) -> f32 {
    low:=max(a.min_distance,1e-4)
    high:=max(a.max_distance,low)
    d:=clamp(distance,low,high)
    switch a.model {
    case .None:return 1
    case .Inverse:return low/(low+a.rolloff*(d-low))
    case .Linear:
        if high<=low {return 1}
        return clamp(1-a.rolloff*(d-low)/(high-low),0,1)
    case .Exponential:return math.pow(d/low,-a.rolloff)
    }
    return 1
}

// Constant power: the two gains always add up to the same energy, so a sound
// is as loud at the center (0.707 on each side) as hard to one side (1 and 0).
pan_gains :: proc "contextless" (pan:f32) -> [2]f32 {
    angle:=(clamp(pan,-1,1)+1)*(math.PI/4)
    return {math.cos(angle),math.sin(angle)}
}
// Balance of a stereo sound: the side it moves away from is turned down, the
// other one stays as it is.
balance_gains :: proc "contextless" (pan:f32) -> [2]f32 {
    p:=clamp(pan,-1,1)
    return {min(1,1-p),min(1,1+p)}
}

// Pan of a source for a listener: -1 at its left, 1 at its right, 0 ahead,
// behind, above, below or in the same place.
listener_pan :: proc "contextless" (listener_position:[3]f32,listener_rotation:quaternion128,source:[3]f32) -> f32 {
    to_source:=source-listener_position
    distance:=math.sqrt(to_source.x*to_source.x+to_source.y*to_source.y+to_source.z*to_source.z)
    if distance<1e-5 {return 0}
    right:=mm.quat_rotate(listener_rotation,{1,0,0})
    return clamp((to_source.x*right.x+to_source.y*right.y+to_source.z*right.z)/distance,-1,1)
}

// Factor on the pitch of a source heard by a listener, both moving. factor
// scales the effect: 0 turns it off, 1 is the physical one.
doppler_pitch :: proc "contextless" (listener_position,listener_velocity,source_position,source_velocity:[3]f32,factor,speed_of_sound:f32) -> f32 {
    if factor<=0 || speed_of_sound<=0 {return 1}
    to_listener:=listener_position-source_position
    distance:=math.sqrt(to_listener.x*to_listener.x+to_listener.y*to_listener.y+to_listener.z*to_listener.z)
    if distance<1e-5 {return 1}
    direction:=to_listener/distance
    // Speeds along the line from the source to the listener; neither reaches the speed of sound.
    limit:=speed_of_sound/factor*0.99
    listener_speed:=clamp(listener_velocity.x*direction.x+listener_velocity.y*direction.y+listener_velocity.z*direction.z,-limit,limit)
    source_speed:=clamp(source_velocity.x*direction.x+source_velocity.y*direction.y+source_velocity.z*direction.z,-limit,limit)
    return clamp((speed_of_sound-factor*listener_speed)/(speed_of_sound-factor*source_speed),0.25,4)
}

// Gains for the two outputs, without the volume of the voice, and pitch factor.
@(private)
spatialize :: proc "contextless" (listener:Listener,position,velocity:[3]f32,attenuation:Attenuation,doppler,speed_of_sound:f32) -> (gains:[2]f32,pitch:f32) {
    offset:=position-listener.position
    distance:=math.sqrt(offset.x*offset.x+offset.y*offset.y+offset.z*offset.z)
    gains=pan_gains(listener_pan(listener.position,listener.rotation,position))*attenuation_gain(attenuation,distance)
    pitch=doppler_pitch(listener.position,listener.velocity,position,velocity,doppler,speed_of_sound)
    return
}

// Where the listener is, how it is turned and how fast it moves.
listener_set :: proc(m:^Mixer,position:[3]f32,rotation:quaternion128,velocity:[3]f32={}) -> bool {
    return command_push(m,{kind=.Listener,vectors={position,velocity},rotation=rotation})
}
