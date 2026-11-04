package mirai_anim

import math "mirai:std/math"

Sequence_Interpolation :: enum u8 {Linear,Step}

Transform_Frame :: struct {
    pose:math.Transform,
    duration:f32, // Arrival from the previous frame; ignored on the first frame.
    hold:f32,
    ease:math.Ease,
    interpolation:Sequence_Interpolation,
}

TRANSFORM_FRAME_DEFAULT :: Transform_Frame{pose=math.TRANSFORM_IDENTITY,duration=1}

sequence_duration :: proc "contextless" (frames:[]Transform_Frame) -> (duration:f32,ok:bool) {
    if len(frames)==0 {return}
    total:f64
    for frame,i in frames {
        if !anim_transform_valid(frame.pose) || !anim_finite(frame.duration) || frame.duration<0 || !anim_finite(frame.hold) || frame.hold<0 {return 0,false}
        if frame.ease<.Linear || int(frame.ease)>=len(math.Ease) || frame.interpolation<.Linear || frame.interpolation>.Step {return 0,false}
        total+=f64(frame.hold)
        if i>0 {total+=f64(frame.duration)}
    }
    if total>f64(max(f32))/2 {return 0,false}
    return f32(total),true
}

// The input timeline includes every hold; Ping_Pong reverses that same timeline.
sequence_sample :: proc "contextless" (frames:[]Transform_Frame,time:f32,loop:Loop=.Once) -> (pose:math.Transform,ok:bool) {
    duration,valid:=sequence_duration(frames)
    if !valid || !anim_finite(time) || loop<.Once || loop>.Ping_Pong {return math.TRANSFORM_IDENTITY,false}
    at,_:=loop_time(loop,duration,time)
    if duration<=0 {return frames[len(frames)-1].pose,true}
    end:=frames[0].hold
    if at<end {return frames[0].pose,true}
    for i in 1..<len(frames) {
        frame:=frames[i]
        arrival:=end+frame.duration
        if at<arrival {
            from:=frames[i-1].pose
            keys:=[2]Keyframe{{time=0},{time=frame.duration,ease=frame.ease,interpolation=frame.interpolation==.Step?.Step:.Linear}}
            keys[0].value={from.position.x,from.position.y,from.position.z,0}
            keys[1].value={frame.pose.position.x,frame.pose.position.y,frame.pose.position.z,0}
            p:=track_evaluate(keys[:],.Position,at-end)
            keys[0].value=quat_vec4(from.rotation);keys[1].value=quat_vec4(frame.pose.rotation)
            q:=track_evaluate(keys[:],.Rotation,at-end)
            keys[0].value={from.scale.x,from.scale.y,from.scale.z,0}
            keys[1].value={frame.pose.scale.x,frame.pose.scale.y,frame.pose.scale.z,0}
            s:=track_evaluate(keys[:],.Scale,at-end)
            pose={position={p.x,p.y,p.z},rotation=vec4_quat(q),scale={s.x,s.y,s.z}}
            return pose,anim_transform_valid(pose)
        }
        end=arrival+frame.hold
        if at<end {return frame.pose,true}
    }
    return frames[len(frames)-1].pose,true
}
