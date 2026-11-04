package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

// Hips over two feet and a head; idle stands, walk pushes the ground back at 1.5 m/s in place,
// fall (another mode) lifts both feet.
@(private="file")
match_test_rig :: proc(library:^Library) -> (rig:Match_Rig,clips:[3]Match_Clip,ok:bool) {
    @(static) parents:=[5]i32{-1,0,1,1,1}
    @(static) names:[5]u64
    @(static) rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{.1,-.95,0},1,{1,1,1}},{{-.1,-.95,0},1,{1,1,1}},{{0,.7,0},1,{1,1,1}}}
    for name,i in ([5]string{"root","hips","foot_l","foot_r","head"}) {names[i]=base.name_hash(name)}
    body:=body_map_empty();body.forward,body.up={0,0,1},{0,1,0}
    body.bones[.Pelvis],body.bones[.Foot_L],body.bones[.Foot_R],body.bones[.Head]=1,2,3,4
    rig={skeleton={parents[:],names[:],rest[:]},body=body,left_foot=2,right_foot=3,hips=1,forward={0,0,1}}
    if !library_init(library,{max_keys=64,max_tracks=16,max_clips=8}) {return}
    still:=[2]Keyframe{{time=0,value={.1,-.95,0,0}},{time=1,value={.1,-.95,0,0}}}
    other:=[2]Keyframe{{time=0,value={-.1,-.95,0,0}},{time=1,value={-.1,-.95,0,0}}}
    left:=[4]Keyframe{{time=0,value={.1,-.95,.375,0}},{time=.5,value={.1,-.95,-.375,0}},{time=.75,value={.1,-.8,0,0}},{time=1,value={.1,-.95,.375,0}}}
    right:=[4]Keyframe{{time=0,value={-.1,-.95,-.375,0}},{time=.25,value={-.1,-.8,0,0}},{time=.5,value={-.1,-.95,.375,0}},{time=1,value={-.1,-.95,-.375,0}}}
    up:=[2]Keyframe{{time=0,value={.1,-.6,.1,0}},{time=1,value={.1,-.6,.1,0}}}
    descs:=[3]Clip_Desc{
        {name=base.name_hash("idle"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=still[:]},{target=names[3],property=.Position,keys=other[:]}}},
        {name=base.name_hash("walk"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=left[:]},{target=names[3],property=.Position,keys=right[:]}}},
        {name=base.name_hash("fall"),loop=.Loop,tracks={{target=names[2],property=.Position,keys=up[:]},{target=names[3],property=.Position,keys=other[:]}}},
    }
    for desc,i in descs {
        clip,error:=clip_add(library,desc)
        if error!=.None {return}
        clips[i]={clip=clip,modes=1<<1 if i<2 else 1<<0}
    }
    return rig,clips,true
}

@(test)
match_database_finds_each_frame_by_its_features_and_the_clip_a_trajectory_asks_for :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    rig,clips,ok:=match_test_rig(&library)
    if !testing.expect(t,ok) {return}
    db:Match_Database;defer match_database_free(&db)
    // Without frames that start or stop the walk, the trajectory has to outweigh the pose.
    weights:=MATCH_WEIGHTS_DEFAULT;weights[.Trajectory_Position]=3
    if !testing.expect(t,match_database_build(&db,&library,rig,clips[:],30,weights)==.None) {return}
    testing.expect(t,len(db.ranges)==3 && db.ranges[0].speed<.05 && abs(db.ranges[1].speed-1.5)<.1 && db.ranges[1].travel.z>0,"the walk in place travels forward at the speed its feet push")
    for row in 0..<db.rows {
        request:=Match_Request{query=match_features(&db,row),modes=~u32(0)}
        request.positions,request.directions=match_row_trajectory(&db,row)
        best,cost,_:=match_search(&db,request)
        query,weights,_:=match_query(&db,request,match_range_of(&db,row))
        testing.expect(t,cost<1e-6 && match_cost(&db,best,query,weights)<1e-6,"every row is its own best match")
    }
    // From standing to a walk, at its own speed and at a half and a third of it by its rate: a
    // slowed walk costs what the body does, not more than one at its own rate; then back.
    for speed in ([3]f32{1.5,.75,.5}) {
        for facing in ([2]math.Vec3{{0,0,1},{1,0,0}}) {
            request:=Match_Request{query=match_features(&db,int(db.ranges[0].first)),modes=1<<1,min_rate=.3,max_rate=1}
            request.positions,request.directions=match_trajectory(facing*speed,facing*speed,20,20,facing,facing,0)
            testing.expect(t,abs(request.positions[2].y-speed)<1e-4 && abs(request.positions[2].x)<1e-4 && abs(request.directions[0].y-1)<1e-4,"the trajectory is in the frame of the facing")
            best,_,rate:=match_search(&db,request)
            testing.expect(t,match_range_of(&db,best)==1 && abs(rate*db.ranges[1].speed-speed)<.05,"the walk plays at the rate that covers the speed")
        }
    }
    standing:=Match_Request{query=match_features(&db,int(db.ranges[1].first)+7),modes=1<<1,min_rate=.5,max_rate=1}
    standing.positions,standing.directions=match_trajectory({},{},20,20,{0,0,1},{},0)
    best,_,_:=match_search(&db,standing)
    testing.expect_value(t,match_range_of(&db,best),0)
    standing.modes=1<<0
    best,_,_=match_search(&db,standing)
    testing.expect_value(t,match_range_of(&db,best),2)
    near:=int(db.ranges[0].first)+5
    request:=Match_Request{query=match_features(&db,near),modes=1<<1}
    request.positions,request.directions=match_row_trajectory(&db,near)
    best,_,_=match_search(&db,request,0,near,3)
    testing.expect(t,abs(best-near)>3,"rows near the one playing are left out")
    // A pose that plays at half its rate moves its feet at half their speed: the walk at its own
    // rate, with the trajectory of that frame, is no longer the same frame.
    walking:=int(db.ranges[1].first)+7
    costs:[2]f32
    for rate,i in ([2]f32{1,.5}) {
        request:=Match_Request{query=match_features(&db,walking),modes=1<<1,min_rate=.5,max_rate=1,rate=rate}
        request.positions,request.directions=match_row_trajectory(&db,walking)
        query,weights,scaled:=match_query(&db,request,1)
        costs[i]=match_cost(&db,walking,query,weights)
        testing.expect(t,abs(scaled-1)<.05)
    }
    testing.expectf(t,costs[0]<.05 && costs[1]>costs[0]+1,"a pose at half its rate is not its own frame: %v",costs)
    testing.expect(t,match_database_size(db)==match_database_bytes(db.rows,len(db.ranges)))
    testing.expect_value(t,match_database_build(&db,&library,rig,clips[:],30,weights,match_database_bytes(db.rows,3)-1),Match_Build_Error.Memory_Limit)
}

@(test)
match_search_skips_runs_by_their_bounds_and_enters_a_mode_by_its_entry_clips :: proc(t:^testing.T) {
    library:Library;defer library_destroy(&library)
    rig,clips,ok:=match_test_rig(&library)
    if !testing.expect(t,ok) {return}
    // Every clip three times at 120 rows a second: past MATCH_LINEAR_ROWS, so the database keeps bounds.
    many:[9]Match_Clip
    for &clip,i in many {clip=clips[i%3];clip.entry=i%3==2}
    db:Match_Database;defer match_database_free(&db)
    if !testing.expect(t,match_database_build(&db,&library,rig,many[:],120)==.None) || !testing.expect(t,db.rows>MATCH_LINEAR_ROWS && len(db.small)>0 && len(db.large)>0) {return}
    for row in 0..<db.rows {
        if db.ranges[match_range_of(&db,row)].entry {continue}
        request:=Match_Request{query=match_features(&db,(row*7919)%db.rows),modes=~u32(0),min_rate=.5,max_rate=1}
        request.positions,request.directions=match_row_trajectory(&db,row)
        best,cost,_:=match_search(&db,request,1,row,5)
        least:=max(f32)
        for r,range in db.ranges {
            if r.entry {continue}
            query,weights,_:=match_query(&db,request,range)
            last:=int(r.count) if r.loop else int(r.count)-int(cmath.ceil(MATCH_HORIZON[MATCH_TRAJECTORY-1]*db.rate))
            for frame in 0..<last {if candidate:=int(r.first)+frame;range!=1 || abs(candidate-row)>5 {least=min(least,match_cost(&db,candidate,query,weights))}}
        }
        testing.expect(t,best>=0 && cost==least,"the bounded search finds the row the whole scan finds")
    }
    falling:=Match_Request{query=match_features(&db,0),modes=1<<0}
    best,_,_:=match_search(&db,falling)
    testing.expect(t,best<0 && !match_serves(&db,1<<0,false) && match_serves(&db,1<<0,true),"an entry clip is left out of the steady search")
    falling.entry=true
    best,_,_=match_search(&db,falling)
    range:=match_range_of(&db,best)
    testing.expect(t,range>=0 && db.ranges[range].entry && f32(best-int(db.ranges[range].first))<=MATCH_ENTRY_SPAN*db.rate+1,"entering a mode searches the starts of its entry clips")
}

@(test)
match_trajectory_follows_a_walk_that_accelerates_brakes_and_turns_at_its_rates :: proc(t:^testing.T) {
    Case :: struct {velocity,desired,facing,wanted:math.Vec3,acceleration,braking,turn:f32}
    cases:=[]Case{
        {velocity={},desired={0,0,3},facing={0,0,1},wanted={0,0,1},acceleration=20,braking=20},
        {velocity={0,0,3},desired={},facing={0,0,1},acceleration=8,braking=4},
        {velocity={2,0,0},desired={0,0,-2.5},facing={1,0,0},wanted={0,0,-1},acceleration=6,braking=10,turn=cmath.PI},
        {velocity={1,5,0},desired={1,0,0},facing={0,0,1},wanted={1,0,0},acceleration=0,braking=0},
    }
    for c in cases {
        positions,directions:=match_trajectory(c.velocity,c.desired,c.acceleration,c.braking,c.facing,c.wanted,c.turn)
        STEPS :: 600
        velocity:=math.Vec3{c.velocity.x,0,c.velocity.z};position,facing:math.Vec3
        rate:=c.braking if c.desired=={} else c.acceleration
        inverse:=math.quat_inverse(match_yaw(c.facing))
        step:=0
        for horizon,k in MATCH_HORIZON {
            for ;step<int(cmath.round(horizon*STEPS));step+=1 {
                change:=c.desired-velocity
                if length:=linalg.length(change);length>rate/STEPS {velocity+=change*(rate/STEPS/length)} else {velocity=c.desired}
                position+=velocity/STEPS
            }
            local:=math.quat_rotate(inverse,position)
            testing.expect(t,linalg.length(math.Vec2{local.x,local.z}-positions[k])<.01,"positions follow the velocity of a walk")
            facing=c.facing
            if c.wanted!={} {
                angle:=cmath.atan2(linalg.dot(linalg.cross(c.facing,c.wanted),math.Vec3{0,1,0}),linalg.dot(c.facing,c.wanted))
                turned:=angle if c.turn<=0 else clamp(angle,-c.turn*horizon,c.turn*horizon)
                facing=math.quat_rotate(math.quat_axis_angle({0,1,0},turned),c.facing)
            }
            toward:=math.quat_rotate(inverse,facing)
            testing.expect(t,linalg.length(math.Vec2{toward.x,toward.z}-directions[k])<1e-4,"the facing turns at its rate")
        }
    }
}
