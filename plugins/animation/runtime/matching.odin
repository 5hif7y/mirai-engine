package anim

import cmath "core:math"
import "core:mem"
import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import lib "mirai:std/anim"
import mm "mirai:std/math"

// A .match plays locomotion by motion matching over its clips: every interval it looks for the
// frame whose feet, hips and trajectory are closest to what the body does and is asked to do,
// and jumps there with an inertial blend. Animation.asset names it like an .agraph. The body is
// told each tick by match_goal (the animation_physics plugin tells it from the Character); the
// locomotion mode of the goal picks the clips that serve it, and entering a mode searches the
// starts of its entry clips (a jump, a landing). match_play plays a clip of the library at once
// (a vault, a hit, a death) until a share of it or one of its markers, and matching goes on from
// there.

MATCH_KIND :: asset.Fourcc(u32('A')|u32('M')<<8|u32('T')<<16|u32('C')<<24)
MATCH_VERSION :: 2
MATCH_CLIPS :: 64
MATCH_GOAL_CAPACITY :: 4096 // rigs told in one tick

Match_Info :: struct {
    animation:base.Asset_Id,           // .anim of its clips
    rate:f32 `mirai:"unit=1/s"`,       // rows of the database per second of clip
    interval:f32 `mirai:"unit=s"`,     // between searches
    blend:f32 `mirai:"unit=s"`,        // of the inertial blend of a jump
    bias:f32,                          // of cost a jump has to save over playing on
    min_rate,max_rate:f32,             // of the speed a clip that travels plays at to follow the body
    memory:u32 `mirai:"unit=KiB"`,     // most the database of one skeleton keeps
    left_foot,right_foot,hips:Bone_Ref,
    foot_position,foot_velocity,hip_velocity,trajectory_position,trajectory_direction:f32, // weights
    keep_loop_phase:bool,              // do not seek within the current looping clip
    stationary_speed:f32,              // if positive, separate stationary and moving loops at this speed
}
MATCH_INFO_DEFAULT :: Match_Info{
    rate=30,interval=0,blend=.2,bias=.5,min_rate=.5,max_rate=1,memory=16384,
    left_foot={path={0='@',1='f',2='o',3='o',4='t',5='_',6='l'}},right_foot={path={0='@',1='f',2='o',3='o',4='t',5='_',6='r'}},hips={path={0='@',1='p',2='e',3='l',4='v',5='i',6='s'}},
    foot_position=.75,foot_velocity=1,hip_velocity=1,trajectory_position=2,trajectory_direction=1.5,
}
// A clip the search can pick. modes: bit m for each locomotion mode m it serves; entry: it starts
// one of them, searched from its start when the body enters the mode.
// speed, when positive, is the m/s the clip travels at instead of the one measured from its feet.
Match_Source :: struct {clip:[64]u8 `mirai:"text"`,animation:base.Asset_Id,modes:u32,loop,entry:bool,speed:f32 `mirai:"unit=m/s"`}
Match_Profile :: struct {info:Match_Info,clips:[]Match_Source}

match_check :: proc(profile:Match_Profile) -> bool {
    info:=profile.info
    if info.animation=={} || len(profile.clips)==0 || len(profile.clips)>MATCH_CLIPS || info.memory==0 {return false}
    for value in ([10]f32{info.rate,info.interval,info.blend,info.bias,info.min_rate,info.max_rate,info.foot_position,info.foot_velocity,info.hip_velocity,info.trajectory_position}) {if !finite(value) || value<0 {return false}}
    if !finite(info.trajectory_direction) || info.trajectory_direction<0 || !finite(info.stationary_speed) || info.stationary_speed<0 || info.rate<=0 || info.rate>lib.FRAMES_MAX_RATE || info.min_rate<=0 || info.min_rate>info.max_rate {return false}
    for bone in ([3]Bone_Ref{info.left_foot,info.right_foot,info.hips}) {if !profile_bone(bone) || bone.path[0]==0 {return false}}
    for &clip,i in profile.clips {
        if !blend_text_valid(clip.clip[:],false) || clip.modes==0 || clip.entry && clip.loop || !finite(clip.speed) || clip.speed<0 {return false}
        for other in profile.clips[:i] {if other.clip==clip.clip && other.animation==clip.animation {return false}}
    }
    return true
}
match_document :: proc(doc:^asset.Document,types:^asset.Types,id:base.Asset_Id,profile:Match_Profile,allocator:=context.allocator) -> asset.Error {
    if !match_check(profile) {return .Invalid}
    asset.document_init(doc,MATCH_KIND,id,allocator);doc.kind_version=MATCH_VERSION
    error:=match_tables(doc,types,profile)
    if error!=.None {asset.document_destroy(doc)}
    return error
}
@(private)
match_tables :: proc(doc:^asset.Document,types:^asset.Types,profile:Match_Profile) -> asset.Error {
    info:=profile.info
    asset.document_put_row(doc,types,"match",&info) or_return
    asset.document_put(doc,types,"clips",profile.clips) or_return
    return .None
}
match_save :: proc(path:string,types:^asset.Types,id:base.Asset_Id,profile:Match_Profile,allocator:=context.allocator) -> asset.Error {
    doc:asset.Document
    match_document(&doc,types,id,profile,allocator) or_return
    defer asset.document_destroy(&doc)
    return asset.document_save(&doc,path)
}
match_view :: proc(file:^asset.Asset,types:^asset.Types) -> (profile:Match_Profile,error:asset.Error) {
    asset.kind_check(file,MATCH_KIND,MATCH_VERSION) or_return
    info:=asset.asset_row(file,types,"match",Match_Info) or_return
    profile.info=info^
    profile.clips=asset.asset_rows(file,types,"clips","",Match_Source) or_return
    if !match_check(profile) {return {},.Corrupt}
    return profile,.None
}
match_profile_free :: proc(profile:^Match_Profile,allocator:=context.allocator) {delete(profile.clips,allocator);profile^={}}

// A database built for a library and a skeleton.
@(private)
Match_Built :: struct {key:[7]u64,database:lib.Match_Database,error:lib.Match_Build_Error}
Match_Content :: struct {
    id:base.Asset_Id,checked,revision:u64,stamp:[2]i64,profile:Match_Profile,valid:bool,error:asset.Error,
    databases:[dynamic]Match_Built,
}
@(private)
match_content_free :: proc(content:^Match_Content) {
    delete(content.profile.clips)
    for &built in content.databases {lib.match_database_free(&built.database)}
    delete(content.databases)
    content^={}
}

match_content :: proc(cache:^Graph_Assets,app:^host.App,id:base.Asset_Id) -> ^Match_Content {
    if cache==nil || app==nil || app.assets==nil || id=={} {return nil}
    context.allocator=app.allocator;cache.allocator=app.allocator
    row:=-1
    for content,i in cache.matches {if content.id==id {row=i;break}}
    if row<0 {row=len(cache.matches);if append(&cache.matches,Match_Content{id=id})!=1 {return nil}}
    content:=&cache.matches[row]
    if content.checked==assets_stamp(app) {return content if content.valid else nil}
    record,found:=asset.registry_find(&app.assets.registry,id)
    stamp:=[2]i64{}
    if found {stamp={record.size,record.time}}
    if content.checked!=0 && stamp==content.stamp {content.checked=assets_stamp(app);return content if content.valid else nil}
    profile:Match_Profile;error:=asset.Error.Not_Found
    if found {
        file:asset.Asset
        error=host.assets_file(app.assets,id,MATCH_KIND,&file)
        if error==.None {
            view,read:=match_view(&file,&app.assets.types);error=read
            if read==.None {
                profile.info=view.info
                clips,ok:=graph_clone(view.clips,app.allocator)
                if ok {profile.clips=clips} else {error=.Out_Of_Memory}
            }
            asset.asset_close(&file)
        }
    }
    if error==.Out_Of_Memory {content.error=error;content.checked=0;return nil}
    revision:=content.revision
    match_content_free(content)
    content^={id=id,profile=profile,valid=error==.None,error=error,stamp=stamp,checked=assets_stamp(app),revision=revision+1}
    return content if content.valid else nil
}

// What the body does and is asked to do in this tick, for a rig that plays a .match: mode is its
// locomotion mode; velocity, where it goes; desired, the velocity its walk heads to at
// acceleration (braking toward zero); facing, where it turns to at turn_rate rad/s (0: at once).
// World axes, m/s. The rig faces the +Z of its transform.
Match_Goal :: struct {rig:core.Entity,mode:u16,velocity,desired,facing:mm.Vec3,acceleration,braking,turn_rate:f32}

// How a clip played by match_play enters and when matching takes over again. A play enters at the
// start of its clip, at the time the clip playing is at (keep_time) or at the phase of its markers
// (match_phase); it holds until phase of its duration (1: its end; a clip that does not loop holds
// its last pose there until matching picks another) or until it crosses its marker. A play of
// lower priority than the one playing is refused; with wait, one that comes while a blend runs
// starts when the blend ends, unless a later play replaces it first.
Match_Entry :: enum u8 {Start,Keep_Time,Match_Phase}
Match_Play_Options :: struct {fade:f32,entry:Match_Entry,phase:f32,marker:string,priority:i16,wait:bool}
MATCH_PLAY_OPTIONS_DEFAULT :: Match_Play_Options{fade=.15,phase=1}
Match_Play :: struct {rig:core.Entity,clip,marker:u64,mode:u16,fade,phase:f32,entry:Match_Entry,priority:i16,wait:bool}

// Tells the matching of a rig what its body does in this tick. False, with nothing queued, for a
// value that is not finite, a mode past 31 or a full queue.
match_goal :: proc(requests:^Animation_Requests,goal:Match_Goal) -> bool {
    if requests==nil || goal.rig==core.NONE || goal.mode>31 {return false}
    for v in ([3]mm.Vec3{goal.velocity,goal.desired,goal.facing}) {if !finite(v.x) || !finite(v.y) || !finite(v.z) {return false}}
    if !finite(goal.acceleration) || !finite(goal.braking) || !finite(goal.turn_rate) || goal.acceleration<0 || goal.braking<0 || goal.turn_rate<0 {return false}
    if !program_array_reserve(&requests.match_goals.items,MATCH_GOAL_CAPACITY) || len(requests.match_goals.items)>=MATCH_GOAL_CAPACITY {return false}
    core.push(&requests.match_goals,goal);return true
}
// Plays a clip of the library of the .match of a rig with an inertial blend of options.fade
// seconds, as the clip of mode, until matching takes over (Match_Play_Options says how). It plays
// while the body stays in mode: leaving it hands the rig back to matching. False, with nothing
// queued, for an empty or too long name or marker, an option out of range or a full queue.
match_play :: proc(requests:^Animation_Requests,rig:core.Entity,clip:string,mode:u16,options:=MATCH_PLAY_OPTIONS_DEFAULT) -> bool {
    if requests==nil || rig==core.NONE || len(clip)==0 || len(clip)>=64 || len(options.marker)>=64 || mode>31 || !finite(options.fade) || options.fade<0 || !finite(options.phase) || options.phase<0 || options.phase>1 || options.entry>max(Match_Entry) {return false}
    for byte in clip {if byte==0 {return false}}
    for byte in options.marker {if byte==0 {return false}}
    if !program_array_reserve(&requests.match_plays.items,REQUEST_CAPACITY) || len(requests.match_plays.items)>=REQUEST_CAPACITY {return false}
    core.push(&requests.match_plays,Match_Play{rig=rig,clip=base.name_hash(clip),marker=base.name_hash(options.marker) if len(options.marker)>0 else 0,mode=mode,fade=options.fade,phase=options.phase,entry=options.entry,priority=options.priority,wait=options.wait})
    return true
}

// What the matching of a rig plays. clip is base.name_hash of its name; speed, m/s the pose
// walks forward at (that of the clip by its rate); mode, the locomotion mode of that clip; forced,
// a clip of match_play plays.
Animation_Match :: struct {clip:u64,time,rate,speed,cost:f32,mode:u16,forced:bool,searches,jumps:u32}

// False for an entity that does not play a .match.
animation_match :: proc(playback:^Playback,entity:core.Entity) -> (value:Animation_Match,ok:bool) {
    state:=constraint_playing(playback,entity) if playback!=nil else nil
    if state==nil || state.program.kind!=MATCH_KIND || !state.program.ready {return}
    m:=state.program.match
    return {clip=m.clip,time=state.time,rate=m.rate,speed=m.speed*m.rate,cost=m.cost,mode=m.mode,forced=m.forced,searches=m.searches,jumps=m.jumps},true
}

// The matching of a rig between ticks.
Match_Playing :: struct {
    range:i32,     // of the database its clip is; -1: one match_play asked for, or none
    clip:u64,      // name in the library of the clip it plays; 0: none yet
    loop,forced:bool,
    mode:u16,      // the one its clip serves
    play,pending:Match_Play, // the one playing while forced, and one that waits for the blend
    waiting,finished:bool,   // pending holds a play; Finished was reported for play
    last:f32,      // time of the clip of play in the last tick
    timer:f32,     // seconds to the next search
    rate,speed,cost:f32,
    searches,jumps:u32,
}
MATCH_PLAYING_DEFAULT :: Match_Playing{range=-1,rate=1}

// The database of a library for the skeleton of a rig, built the first time a rig of that
// skeleton loads it.
@(private)
match_database :: proc(content:^Match_Content,library:^host.Content_Animation,state:^Playing,source:base.Asset_Id,allocator:mem.Allocator) -> (^lib.Match_Database,lib.Match_Build_Error) {
    if library==nil || len(state.parents)<2 || len(state.rest)!=len(state.parents) {return nil,.Invalid}
    shape:=state.skeleton
    if shape=={} {for target in state.targets {shape[0]=base.hash_combine(shape[0],target)}}
    key:=[7]u64{library.id[0],library.id[1],u64(library.generation),shape[0],shape[1],state.skeleton_revision,source[0]~source[1]}
    for &built in content.databases {if built.key==key {return &built.database if built.error==.None else nil,built.error}}
    context.allocator=allocator
    info:=content.profile.info
    bones:=[3]int{bone_resolve(state,info.left_foot),bone_resolve(state,info.right_foot),bone_resolve(state,info.hips)}
    clips,clips_error:=make([]lib.Match_Clip,len(content.profile.clips));defer delete(clips)
    found:=bones[0]>0 && bones[1]>0 && bones[2]>0 && clips_error==nil
    for clip,i in content.profile.clips {
        if !found {break}
        clip:=clip
        handle:=lib.clip_find(&library.lib,source_clip_name(source,source_effective(clip.animation,info.animation,source),base.name_hash(base.text_get(clip.clip[:]))))
        if handle==0 || int(handle)>library.clip_count {found=false;break}
        clips[i]={clip=handle+lib.Clip(library.clip_count if clip.loop else 0),modes=clip.modes,entry=clip.entry,speed=clip.speed}
    }
    built:=Match_Built{key=key,error=.Invalid}
    if found {
        rest,rest_error:=make([]mm.Transform,len(state.rest));defer delete(rest)
        if rest_error!=nil {built.error=.Out_Of_Memory} else {
            copy(rest,state.rest[:]);rest[0]=mm.TRANSFORM_IDENTITY
            body:=lib.body_map_empty();body.forward,body.up={0,0,1},{0,1,0}
            for bone,part in state.body {if bone>0 {body.bones[part]=bone}}
            for part,i in ([3]lib.Body_Part{.Foot_L,.Foot_R,.Pelvis}) {
                if body.bones[part]>=0 {continue}
                taken:=false;for other in body.bones {if int(other)==bones[i] {taken=true}}
                if !taken {body.bones[part]=i32(bones[i])}
            }
            rig:=lib.Match_Rig{skeleton={parents=state.parents[:],names=state.targets[:],rest=rest},body=body,left_foot=i32(bones[0]),right_foot=i32(bones[1]),hips=i32(bones[2]),forward={0,0,1}}
            weights:=lib.Match_Weights{.Foot_Position=info.foot_position,.Foot_Velocity=info.foot_velocity,.Hip_Velocity=info.hip_velocity,.Trajectory_Position=info.trajectory_position,.Trajectory_Direction=info.trajectory_direction}
            built.error=lib.match_database_build(&built.database,&library.lib,rig,clips,info.rate,weights,int(info.memory)*1024,allocator)
        }
    }
    if append(&content.databases,built)!=1 {lib.match_database_free(&built.database);return nil,.Out_Of_Memory}
    last:=&content.databases[len(content.databases)-1]
    return &last.database if last.error==.None else nil,last.error
}

@(private)
match_play_emit :: proc(state:^Playing,events:^Animation_Events,playback:^Playback,kind:Animation_Play_Event_Kind,clip,other:u64,problems:^core.Problems) {
    if events==nil || playback==nil {return}
    if !program_array_reserve(&events.plays.items,max(len(playback.states)*PLAY_EVENT_BATCH,PLAY_EVENT_BATCH)) || len(events.plays.items)>=cap(events.plays.items) {
        core.report(problems,state.entity,"animation.play_events","an %v event of a clip played by match_play on this entity was lost: memory ran out, or the rigs of the world gave more play events in this tick than fit; free memory, or play fewer clips per tick",kind)
        return
    }
    append(&events.plays.items,Animation_Play_Event{state.entity,kind,clip,other})
}

// Whether a marker named name of a clip that does not loop lies in (from,to].
@(private)
match_marker_crossed :: proc(library:^host.Content_Animation,clip:lib.Clip,name:u64,from,to:f32) -> bool {
    for marker in lib.clip_markers(&library.lib,clip) {
        if int(marker.id)<len(library.markers) && library.markers[marker.id]==name && marker.time>from && marker.time<=to {return true}
    }
    return false
}

// Chooses the clip and time the rig plays in this tick and writes them as a program of one clip.
// facing is the +Z of the rig in the world.
@(private)
match_output :: proc(state:^Playing,output:^Program_Output,content:^Match_Content,library:^host.Content_Animation,source:base.Asset_Id,dt:f32,goals:[]Match_Goal,plays:[]Match_Play,facing:mm.Vec3,app:^host.App,events:^Animation_Events,playback:^Playback,problems:^core.Problems) -> bool {
    runtime:=&state.program;m:=&runtime.match;info:=content.profile.info
    goal:Match_Goal;has_goal:=false
    for value in goals {if value.rig==state.entity {goal,has_goal=value,true}}
    mode:=goal.mode if has_goal else m.mode
    db,built:=match_database(content,library,state,source,app.allocator)
    // A rig binds its skeleton after its first program: until then it plays the first clip.
    if db==nil && len(state.parents)>=2 {
        name:[base.ASSET_ID_TEXT]u8;path:=host.assets_name(app.assets,content.id,&name)
        #partial switch built {
        case .Memory_Limit: core.report(problems,state.entity,"animation.match_memory","the motion matching database of %s for this skeleton keeps more than its memory of %d KiB; lower its rate, give it fewer or shorter clips, or raise its memory",path,info.memory)
        case .Out_Of_Memory: memory_problem(problems,state.entity,"its motion matching database")
        case: core.report(problems,state.entity,"animation.match_database","%s cannot match on this rig: its left_foot, right_foot or hips is not a bone of this skeleton, or a clip of it is missing, lasts a single pose or does not move the skeleton; name bones of the skeleton (animation.asset.inspect lists them), and give it clips of the library that move",path)
        }
    }
    library_name :: proc(source:base.Asset_Id,info:Match_Info,name:u64) -> u64 {return source_clip_name(source,source_effective({},info.animation,source),name)}
    previous:=m.clip
    start:=f32(-1);fade:=info.blend
    begin :: proc(m:^Match_Playing,state:^Playing,library:^host.Content_Animation,play:Match_Play,clip:u64,runtime:^Program_Playing) -> f32 {
        start:f32
        handle:=lib.clip_find(&library.lib,clip)
        duration:=lib.clip_duration(&library.lib,handle)
        switch play.entry {
        case .Start:
        case .Keep_Time: start=clamp(state.time,0,duration)
        case .Match_Phase: if time,ok:=lib.sync_time(&library.lib,handle,runtime.current_phase);ok {start=clamp(time,0,duration)}
        }
        m.forced,m.clip,m.range,m.loop,m.mode,m.play,m.finished,m.last=true,clip,-1,false,play.mode,play,false,start
        return start
    }
    for play in plays {
        if play.rig!=state.entity {continue}
        clip:=library_name(source,info,play.clip)
        if lib.clip_find(&library.lib,clip)==0 {
            core.report(problems,state.entity,"animation.match_clip","match_play asked this rig for a clip the library of its .match does not have; name a clip of its library (animation.inspect lists them)")
            continue
        }
        if m.forced && play.priority<m.play.priority {
            core.report(problems,state.entity,"animation.match_busy","match_play asked this rig for a clip of priority %d while one of priority %d plays; raise its priority, or wait for the Exited event of the one playing",play.priority,m.play.priority)
            continue
        }
        if play.wait && runtime.elapsed<runtime.fade {m.pending,m.waiting=play,true;continue}
        if m.forced {match_play_emit(state,events,playback,.Exited,m.clip,clip,problems)}
        match_play_emit(state,events,playback,.Entered,clip,m.clip if m.forced else 0,problems)
        start=begin(m,state,library,play,clip,runtime);fade=play.fade;m.waiting=false
    }
    if start<0 && m.waiting && runtime.elapsed>=runtime.fade {
        clip:=library_name(source,info,m.pending.clip)
        if m.forced {match_play_emit(state,events,playback,.Exited,m.clip,clip,problems)}
        match_play_emit(state,events,playback,.Entered,clip,m.clip if m.forced else 0,problems)
        start=begin(m,state,library,m.pending,clip,runtime);fade=m.pending.fade;m.waiting=false
    }
    released:=false
    if start<0 && m.forced {
        if state.ended && !m.finished {m.finished=true;match_play_emit(state,events,playback,.Finished,m.clip,0,problems)}
        reached:=match_marker_crossed(library,lib.clip_find(&library.lib,m.clip),m.play.marker,m.last,state.time) if m.play.marker!=0 else state.ended || state.duration>0 && state.time>=m.play.phase*state.duration
        m.last=state.time
        if reached || has_goal && mode!=m.play.mode {m.forced=false;released=true;match_play_emit(state,events,playback,.Exited,m.clip,0,problems)}
    }
    if start<0 && !m.forced && db!=nil {
        m.timer-=dt
        bit:=u32(1)<<mode
        entering:=has_goal && mode!=m.mode && m.clip!=0 && lib.match_serves(db,bit,true)
        current:=int(m.range) if m.range>=0 && int(m.range)<len(db.ranges) && db.ranges[m.range].modes&bit!=0 else -1
        row:=lib.match_row(db,current,state.time) if current>=0 else -1
        // A clip that does not loop is left once it ends or nears its end, before the trajectory runs
        // past it: its own pose would win every search from there, frozen.
        ending:=false
        if current>=0 && !db.ranges[current].loop {
            r:=db.ranges[current];tail:=int(cmath.ceil(lib.MATCH_HORIZON[lib.MATCH_TRAJECTORY-1]*db.rate))
            ending=state.ended || int(r.count)>tail+1 && row>=int(r.first+r.count)-tail
        }
        filter_stationary,moving:=false,false
        if info.stationary_speed>0 && has_goal && !entering {
            stationary,walks:=false,false
            for range in db.ranges {
                if range.modes&bit==0 || !range.loop || range.entry {continue}
                if range.speed>.05 {walks=true} else {stationary=true}
            }
            filter_stationary=stationary && walks
            moving=linalg.length(mm.Vec3{goal.velocity.x,0,goal.velocity.z})>info.stationary_speed
        }
        // A body that starts or stops searches in that tick instead of waiting for the interval: a
        // loop that does not move as the body does would hold its legs still, or walk in place.
        incompatible:=filter_stationary && current>=0 && db.ranges[current].loop && (db.ranges[current].speed>.05)!=moving
        if m.timer<=0 || current<0 || released || entering || ending || incompatible {
            m.timer=info.interval
            request:=lib.Match_Request{query=lib.match_features(db,row) if row>=0 else {},modes=bit,min_rate=info.min_rate,max_rate=info.max_rate,rate=m.rate,entry=entering}
            request.filter_stationary,request.moving=filter_stationary,moving
            request.positions,request.directions=lib.match_trajectory(goal.velocity,goal.desired,goal.acceleration,goal.braking,facing,goal.facing,goal.turn_rate)
            playing_on:=max(f32)
            if row>=0 && !entering && !ending {query,weights,_:=lib.match_query(db,request,current);playing_on=lib.match_cost(db,row,query,weights)}
            reach:=int(info.interval*db.rate)+1
            if info.keep_loop_phase && current>=0 && db.ranges[current].loop {reach=int(db.ranges[current].count)}
            // A clip that ends is left: a row of it a little earlier would play its tail again.
            if ending {reach=int(db.ranges[current].count)}
            best,cost,_:=lib.match_search(db,request,current,row,reach)
            m.searches+=1;m.cost=min(cost,playing_on)
            if best>=0 && (entering || ending || incompatible || playing_on==max(f32) || cost<playing_on-info.bias) {
                range:=lib.match_range_of(db,best)
                m.range,m.mode,m.loop=i32(range),mode,db.ranges[range].loop
                m.clip=lib.clip_data(&library.lib,db.ranges[range].clip).name
                m.speed=db.ranges[range].speed
                start=f32(best-int(db.ranges[range].first))/db.rate
                m.jumps+=1
            }
        }
    }
    if m.clip==0 {
        if len(content.profile.clips)==0 {return false}
        first:=content.profile.clips[0]
        m.clip,m.loop,m.mode,m.range=source_clip_name(source,source_effective(first.animation,info.animation,source),base.name_hash(base.text_get(first.clip[:]))),first.loop,mode,-1
        start=0
    }
    m.rate=1
    // A loop follows the speed of the body; a clip that plays once (a jump, a landing) keeps its
    // own rate, or a body standing still would hold it, frozen, at min_rate.
    if !m.forced && m.range>=0 && m.loop && m.speed>.05 && has_goal {
        speed:=linalg.length(mm.Vec3{goal.velocity.x,0,goal.velocity.z})
        m.rate=clamp(speed/m.speed,info.min_rate,info.max_rate)
    }
    if m.forced || m.range<0 {m.speed=0}
    if !program_output_prepare(output,1,1) {runtime.error=.Out_Of_Memory;return false}
    program_output_reset(output)
    output.asset=source;output.count=1
    group:=&output.groups[0];group^={}
    group.weight,group.root_weight,group.mode,group.key=1,1,.Independent,1
    group.count=1;group.leaves[0]={clip=m.clip,weight=1,speed=m.rate,loop=m.loop,start=max(start,0)}
    output.instruction_count=1;output.instructions[0]={kind=.Clip,group=0,root_weight=1}
    if start>=0 {
        runtime.epoch+=1
        if previous!=0 && fade>0 && len(state.local)>0 {
            if len(runtime.from)!=len(state.local) && resize(&runtime.from,len(state.local))!=nil {runtime.error=.Out_Of_Memory;return false}
            copy(runtime.from[:],runtime.current[:] if len(runtime.current)==len(state.local) && runtime.history_dt>0 else state.local[:])
            if !program_curves_prepare(runtime,len(state.curves)) {runtime.error=.Out_Of_Memory;return false}
            copy(runtime.from_curves[:],runtime.prior_curves[:] if len(runtime.prior_curves)==len(state.curves) else state.curves[:])
            runtime.elapsed,runtime.fade=0,fade
            runtime.capture=true
        }
    }
    return true
}
