package mirai_anim

import math "mirai:std/math"

// A tween moves one value from `from` to `to` over `duration` seconds after
// `delay`, shaped by an easing curve. It is plain data: advance it with the
// time that passed and read the value. Quaternions are slerped; a Vec4 can
// be interpolated as a color in OKLab.
Tween :: struct($T:typeid) {
    from,to:T,
    duration,delay,elapsed:f32,
    ease:math.Ease,
    loop:Loop,
    oklab:bool,
    done:bool,
}

tween_make :: proc "contextless" (from,to:$T,duration:f32,ease:math.Ease=.Linear,delay:f32=0,loop:Loop=.Once) -> Tween(T) {
    return {from=from,to=to,duration=max(duration,0),delay=max(delay,0),ease=ease,loop=loop,done=duration<=0 && delay<=0 && loop==.Once}
}
// A color tween (linear RGBA) that interpolates in OKLab.
tween_make_color :: proc "contextless" (from,to:math.Vec4,duration:f32,ease:math.Ease=.Linear,delay:f32=0,loop:Loop=.Once) -> Tween(math.Vec4) {
    tween:=tween_make(from,to,duration,ease,delay,loop)
    tween.oklab=true
    return tween
}
tween_reset :: proc "contextless" (tween:^$W/Tween($T)) {tween.elapsed=0;tween.done=tween.duration<=0 && tween.delay<=0 && tween.loop==.Once}

// Moves the tween forward and returns its value. A negative dt rewinds it.
tween_advance :: proc "contextless" (tween:^$W/Tween($T),dt:f32) -> T {
    tween.elapsed+=dt
    local:=tween.elapsed-tween.delay
    switch tween.loop {
    case .Once:
        tween.elapsed=max(tween.elapsed,0)
        tween.done=local>=tween.duration
    case .Loop,.Ping_Pong:
        period:=loop_period(tween.loop,tween.duration)
        if period>0 && local>=period {tween.elapsed=tween.delay+loop_wrap(local,period)}
        tween.done=false
    }
    return tween_value(tween^)
}
// Eased progress from 0 to 1 (back and elastic curves leave that range).
tween_progress :: proc "contextless" (tween:Tween($T)) -> f32 {
    local:=tween.elapsed-tween.delay
    if tween.duration<=0 {return 1 if local>=0 else 0}
    if local<=0 {return 0}
    clip_time,_:=loop_time(tween.loop,tween.duration,local)
    return math.ease_apply(tween.ease,clip_time/tween.duration)
}
tween_value :: proc "contextless" (tween:Tween($T)) -> T {
    t:=tween_progress(tween)
    when T==math.Quat {return math.quat_slerp(tween.from,tween.to,t)}
    else when T==math.Vec4 {
        if tween.oklab {return math.color_mix_oklab(tween.from,tween.to,t)}
        return tween.from+(tween.to-tween.from)*t
    } else {return tween.from+(tween.to-tween.from)*t}
}
