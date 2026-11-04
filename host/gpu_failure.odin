package host

import "core:fmt"
import "core:log"
import "mirai:core"
import "mirai:rhi"

// A GPU that stops working (rhi.device_failure) does not end the application
// by itself: the frames go on without drawing, the worlds keep running, and
// the failure is reported once with its likely cause. Whoever runs the
// application decides what follows: the player ends with PLAYER_GPU_LOST, the
// editor starts again with its documents.

// Frames after the shaders of the project were replaced in which a failure
// names them as its likely cause.
GPU_FAILURE_SHADER_FRAMES :: 600
GPU_FAILURE_TEXT :: 1024

// The failure of the GPU of the application and what it says of its likely
// cause; None and "" while it works or without one.
app_gpu_failure :: proc(app:^App) -> (failure:rhi.Device_Failure,text:string) {
    if app.device==nil {return}
    failure,_=rhi.device_failure(app.device)
    if failure==.None {return}
    app_gpu_failure_check(app)
    return failure,string(app.gpu_failure[:app.gpu_failure_length])
}

// The first frame that sees the failure reports it: in the log, and as a
// problem of the world of the player.
@(private)
app_gpu_failure_check :: proc(app:^App) {
    if app.gpu_failure_length>0 || app.device==nil {return}
    failure,text:=rhi.device_failure(app.device)
    if failure==.None {return}
    sh:=&app.shaders
    likely:string
    switch {
    case sh.reloads>0 && app.stats.frames-sh.published_frame<GPU_FAILURE_SHADER_FRAMES:
        likely=fmt.tprintf("the shaders of the project were replaced %d frames before: one of their stages is the likely cause",app.stats.frames-sh.published_frame)
    case failure==.Hung:
        likely="a shader that does not end, of the project or of a plugin, is the likely cause"
    case sh.state==.Loaded:
        likely="a stage of the shaders of the project or of a plugin that reads or writes out of bounds or does not end is the likely cause; otherwise the driver"
    case:
        likely="a shader that reads or writes out of bounds or does not end, or the driver, is the likely cause"
    }
    message:=fmt.bprintf(app.gpu_failure[:],"the GPU device stopped working (%v): %s; %s",failure,text,likely)
    app.gpu_failure_length=len(message)
    log.error(message)
    if app.world!=nil {core.report(app_world_storage(app,app.world,core.Problems),core.NONE,"gpu.failure","%s. Nothing is drawn any more: start the application again",message)}
}
