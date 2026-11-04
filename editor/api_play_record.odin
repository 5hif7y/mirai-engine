package editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:cook/movie"
import "mirai:core"
import "mirai:editor/api"
import "mirai:host"
import "mirai:project"
import render "mirai:render"
import "mirai:std/base"
import "mirai:std/jobs"

Record_Format :: enum u8 {
    Png16, // after the tonemap: what the window shows, 16 bits a channel
    Exr,   // before the tonemap: the exposed linear image, half floats
}

Api_Play_Record_Params :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"optional,text,label=Folder of the sequence; its frames are frame_000000 and on and the sound audio.wav. Under .mirai/recordings when empty"`,
    format:Record_Format `mirai:"optional,label=Png16: after the tonemap as the window shows it; Exr: before it in linear light unclipped"`,
    fps:int `mirai:"optional,min=1,max=240,label=Frames per second of the sequence; each lasts 1/fps of the time of the game"`,
    seconds:f32 `mirai:"optional,min=0.004,max=600,unit=s,label=Time of the game recorded"`,
    width:int `mirai:"optional,min=16,max=4096,label=Pixels of each frame"`,
    height:int `mirai:"optional,min=16,max=4096,label=Pixels of each frame"`,
    audio:bool `mirai:"optional,label=Mixes what the game makes heard into audio.wav as it plays"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Record_Result :: struct {
    path:[API_PATH_BYTES]u8 `mirai:"text,label=The absolute folder of the sequence"`,
    first:[API_PATH_BYTES]u8 `mirai:"text,label=The file of its first frame"`,
    audio:[API_PATH_BYTES]u8 `mirai:"text,label=The WAV of 32-bit floats; empty without sound"`,
    frames:int,
    fps:int,
    width,height:int,
    format:Record_Format,
    tick_from,tick_to:u64 `mirai:"label=The ticks of the game when it began and when it ended"`,
    seconds:f64 `mirai:"label=Time of the game it advanced"`,
    real_seconds:f64 `mirai:"label=What the recording took: drawing, reading back and writing every frame"`,
    sample_rate,channels:int,
    audio_frames:u64,
}

Api_Play_Seek_Params :: struct {
    tick:u64 `mirai:"label=The tick to go to; when no frame ended on it the newest before it"`,
    player:int `mirai:"optional,min=0,max=3,label=The run of that player of a game a turn plays on the network"`,
}

Api_Play_Seek_Result :: struct {
    tick:u64 `mirai:"label=The tick reached"`,
    seconds:f64,
    paused:bool,
    replayed:int `mirai:"label=Frames played again to get there from a keyframe or from where the game was"`,
    matches:bool `mirai:"label=The frames played again left the World as when they played; false: the game does not repeat itself or something outside its frames changed it (an edit or a move of the simulation)"`,
}

Api_Play_History_Result :: struct {
    on:bool `mirai:"label=The run keeps its past"`,
    tick:u64 `mirai:"label=Where the run is"`,
    oldest,newest:u64 `mirai:"label=The ticks play.seek goes to"`,
    oldest_seconds,newest_seconds:f64,
    frames:int `mirai:"label=Frames kept with what they gave the World"`,
    keyframes:int `mirai:"label=Copies of the World kept"`,
    capacity:int `mirai:"label=The copies that fit in the time and the memory of the history"`,
    interval:u64 `mirai:"label=Ticks between two copies: going to a tick plays again at most these"`,
    megabytes:f32 `mirai:"label=What the copies take"`,
    reason:[160]u8 `mirai:"text,label=Why it keeps none, when it does not"`,
}

@(private)
api_play_record_register :: proc(s:^Session,st:^Api_State) {
    record_default:=Api_Play_Record_Params{format=.Png16,fps=30,seconds=2,width=1280,height=720,audio=true}
    api_register(s,st,{name="play.record",summary="Records the game of the caller as a sequence of images and its sound, frame after frame at a fixed rate whatever the clock: it pauses the game, advances it 1/fps each frame and draws it alone through its camera. Ends paused.",params=Api_Play_Record_Params,result=Api_Play_Record_Result,defaults=&record_default,run=api_play_record})
    api_register(s,st,{name="play.seek",summary="Takes the game of the caller to a tick it played, paused, to look at it and play on from there: the copy of the World before it and the frames between played again.",params=Api_Play_Seek_Params,result=Api_Play_Seek_Result,run=api_play_seek})
    api_register(s,st,{name="play.history",summary="The ticks the game of the caller keeps to go back to, and what they take.",params=Api_Play_Player_Params,result=Api_Play_History_Result,flags={.Read_Only},run=api_play_history})
}

// A frame on its way to a file.
@(private)
Record_Write :: struct {
    path:string,
    pixels:[]f32,
    width,height:int,
    format:Record_Format,
    error:movie.Error,
    counter:jobs.Counter,
}

@(private)
record_write :: proc(w:^Record_Write,worker:int) {
    switch w.format {
    case .Png16: w.error=movie.png16_write(w.path,w.pixels,w.width,w.height)
    case .Exr:   w.error=movie.exr_write(w.path,w.pixels,w.width,w.height)
    }
}

@(private)
api_play_record :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Record_Params)
    r,own:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if !own {api_play_refused(call);return}
    if s.app==nil || s.app.renderer==nil {api.call_fail(call,api.SERVER_ERROR,"play.record requires a GPU; start without --no-gpu");return}
    owner,player:=r.owner,r.player
    folder:string
    if path:=strings.trim_space(base.text_get(p.path[:]));path!="" {
        problem:string
        folder,problem=api_output_path(s.project_root,path,context.temp_allocator)
        if problem!="" {api.call_fail(call,api.INVALID_PARAMS,problem);return}
    } else {
        if s.project_root=="" {api.call_fail(call,api.INVALID_PARAMS,"path is required without a project");return}
        tick:u64
        if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {tick=t.tick}
        folder=project.path(s.project_root,".mirai","recordings",fmt.tprintf("play-%d-%d",owner,tick),allocator=context.temp_allocator)
    }
    if os.is_file(folder) {api.call_failf(call,api.INVALID_PARAMS,"%s is a file: path names the folder of the sequence",folder);return}
    if error:=os.make_directory_all(folder);error!=nil && !os.is_dir(folder) {api.call_failf(call,api.SERVER_ERROR,"The folder %s could not be made: %s",folder,os.error_string(error));return}
    // The frames below free the temporary memory.
    folder=strings.clone(folder,s.app.allocator)
    defer delete(folder,s.app.allocator)
    extension:=p.format==.Exr?"exr":"png"
    // What an earlier recording left in the folder goes: a longer one would leave frames past these.
    for ext in ([2]string{"png","exr"}) {
        for n:=0;;n+=1 {
            if os.remove(project.path(folder,fmt.tprintf("frame_%06d.%s",n,ext),allocator=context.temp_allocator))!=nil {break}
        }
    }
    _=os.remove(project.path(folder,"audio.wav",allocator=context.temp_allocator))
    began:=time.tick_now()
    frames:=max(int(f64(p.seconds)*f64(p.fps)+0.5),1)
    width,height:=p.width,p.height

    // Two frames on their way to their files while the next ones are drawn.
    writes:[2]Record_Write
    for &w in writes {
        pixels,error:=make([]f32,width*height*4,s.app.allocator)
        if error!=nil {
            for &other in writes {delete(other.pixels,s.app.allocator)}
            api.call_failf(call,api.SERVER_ERROR,"No memory for frames of %dx%d: record smaller ones",width,height)
            return
        }
        w=Record_Write{pixels=pixels,width=width,height=height,format=p.format}
    }
    defer for &w in writes {
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        delete(w.pixels,s.app.allocator)
        delete(w.path,s.app.allocator)
    }
    wide:=p.format==.Exr?render.View_Wide.Scene:render.View_Wide.Display
    rec:host.World_Recording
    if !host.app_recording_begin(s.app,&rec,{i32(width),i32(height)},wide,p.audio) {
        api.call_failf(call,api.SERVER_ERROR,"The recording could not start: the renderer takes no image of %dx%d, or the audio device could not be paused",width,height)
        return
    }
    defer host.app_recording_end(s.app,&rec)
    rate,channels:=host.app_recording_audio(s.app,&rec)
    wav:movie.Wav_Writer
    audio_path:string
    if p.audio {
        audio_path=project.path(folder,"audio.wav",allocator=s.app.allocator)
        if error:=movie.wav_open(&wav,audio_path,rate,channels);error!=.None {
            delete(audio_path,s.app.allocator)
            api.call_failf(call,api.SERVER_ERROR,"%s: %s",audio_path,movie.error_message(error))
            return
        }
    }
    defer if audio_path!="" {delete(audio_path,s.app.allocator)}
    sound,sound_error:=make([]f32,(rate/p.fps+2)*channels,s.app.allocator)
    if sound_error!=nil {
        if p.audio {movie.wav_close(&wav)}
        api.call_fail(call,api.SERVER_ERROR,"No memory for the sound of a frame")
        return
    }
    defer delete(sound,s.app.allocator)

    if owner==0 && !play_paused(s) {play_pause(s,true)}
    s.recording={i32(width),i32(height)}
    s.viewport.output_size=s.recording
    defer s.recording={}
    start:core.Time
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {start=t^}
    failure:string
    done:=0
    // Each frame ends where the frames so far put it, in ticks, and a hair
    // later: one that ends on a tick reaches it whatever the rounding.
    ticks:=max(int(1/f64(s.app.tick_dt)+0.5),1)
    for frame in 0..<frames {
        dt:=(f64((frame+1)*ticks)/f64(p.fps)-f64(frame*ticks)/f64(p.fps)+1e-9)*f64(s.app.tick_dt)
        // A frame longer than the ticks a frame of the game runs is played in parts, drawn once.
        parts:=max(int(math.ceil(dt/(f64(max(s.app.max_ticks,1))*f64(s.app.tick_dt)))),1)
        for _ in 0..<parts {
            r.step,r.frame_dt=true,dt/f64(parts)
            if api_frames(s,1,0)==0 {failure="the editor was asked to end";break}
            if r=run_player(s,owner,player);r==nil {failure="the game ended";break}
        }
        if failure!="" {break}
        if p.audio {
            // The sound of the frames so far, to the sample, whatever their rate.
            due:=u64(frame+1)*u64(rate)/u64(p.fps)-rec.mixed
            part:=sound[:int(due)*channels]
            host.app_recording_mix(s.app,&rec,part)
            if error:=movie.wav_append(&wav,part);error!=.None {failure=fmt.tprintf("%s: %s",audio_path,movie.error_message(error));break}
        }
        w:=&writes[frame%2]
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        if w.error!=.None {failure=fmt.tprintf("%s: %s",w.path,movie.error_message(w.error));break}
        if !host.app_recording_frame(s.app,&rec,r.world,w.pixels) {failure="the frame could not be drawn";break}
        delete(w.path,s.app.allocator)
        w.path=project.path(folder,fmt.tprintf("frame_%06d.%s",frame,extension),allocator=s.app.allocator)
        jobs.run(&s.app.jobs,jobs.OWNER,record_write,w,&w.counter)
        done+=1
    }
    for &w in writes {
        jobs.wait(&s.app.jobs,jobs.OWNER,&w.counter)
        if w.error!=.None && failure=="" {failure=fmt.tprintf("%s: %s",w.path,movie.error_message(w.error))}
    }
    if p.audio {
        if error:=movie.wav_close(&wav);error!=.None && failure=="" {failure=fmt.tprintf("%s: %s",audio_path,movie.error_message(error))}
    }
    s.view_cut=true
    if failure!="" {
        api.call_failf(call,api.SERVER_ERROR,"The recording stopped after %d of %d frames: %s; %s keeps those",done,frames,failure,folder)
        return
    }
    result:=api.call_result(call,Api_Play_Record_Result)
    api_text_put(result.path[:],folder)
    api_text_put(result.first[:],project.path(folder,fmt.tprintf("frame_%06d.%s",0,extension),allocator=context.temp_allocator))
    api_text_put(result.audio[:],audio_path)
    result.frames,result.fps,result.width,result.height,result.format=done,p.fps,width,height,p.format
    result.tick_from=start.tick
    result.real_seconds=time.duration_seconds(time.tick_since(began))
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {result.tick_to,result.seconds=t.tick,t.seconds-start.seconds}
    if p.audio {result.sample_rate,result.channels,result.audio_frames=rate,channels,wav.frames}
}

@(private)
api_play_seek :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Seek_Params)
    r,own:=api_play_run(s,call,p.player)
    if r==nil {api.call_fail(call,api.SERVER_ERROR,"No game is playing; play.start first");return}
    if !own {api_play_refused(call);return}
    if reason:=history_reason(s,r);reason!="" {api.call_fail(call,api.SERVER_ERROR,reason);return}
    oldest,newest,_,_,_:=history_span(r.history)
    serial:=history_frame_for(r.history,p.tick)
    if serial==0 {
        api.call_failf(call,api.INVALID_PARAMS,"tick %d is older than the history keeps: it goes to ticks %d to %d (play.history); Play_History.seconds and megabytes of the preferences keep more",p.tick,oldest,newest)
        return
    }
    if r.owner==0 && !play_paused(s) {play_pause(s,true)}
    seek:=history_seek(s,r,serial)
    if !seek.ok {api.call_fail(call,api.SERVER_ERROR,"No memory to go back: the game stays where it was");return}
    result:=api.call_result(call,Api_Play_Seek_Result)
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {result.tick,result.seconds=t.tick,t.seconds}
    result.paused=r.owner!=0 || play_paused(s)
    result.replayed,result.matches=seek.replayed,seek.matches
}

@(private)
api_play_history :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Play_Player_Params)
    r,_:=api_play_run(s,call,p.player)
    result:=api.call_result(call,Api_Play_History_Result)
    if r==nil {
        api_text_put(result.reason[:],"No game is playing")
        return
    }
    if t:=core.world_storage_of(run_ref(s,r),core.Time);t!=nil {result.tick=t.tick}
    if reason:=history_reason(s,r);reason!="" {
        api_text_put(result.reason[:],reason)
        return
    }
    h:=r.history
    result.on=true
    result.oldest,result.newest,result.oldest_seconds,result.newest_seconds,_=history_span(h)
    result.frames,result.keyframes,result.capacity,result.interval=h.frame_count,h.count,h.limit,h.interval
    result.megabytes=f32(f64(history_bytes(h))/(1024*1024))
}

// Why a run has no past to go back to; empty when it has one.
@(private)
history_reason :: proc(s:^Session,r:^Run) -> string {
    if r.history!=nil && r.history.count>0 {return ""}
    if s.play_history==nil || !s.play_history.on {return "The history of Play is off: Play_History.on in the preferences of the editor turns it on"}
    if network:=core.world_storage_of(run_ref(s,r),core.Network);network!=nil && network.role!=.Standalone {return "A game on the network keeps no history: its past belongs to its server"}
    if r.history_off {return "This run keeps no history: there was no memory for it"}
    return "The game has not run a tick yet: play.step first"
}
