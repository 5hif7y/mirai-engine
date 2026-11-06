package mirai_anim

import cmath "core:math"
import "core:math/linalg"
import "core:mem"
import "core:simd"
import math "mirai:std/math"

// Motion matching: every frame of a set of clips is a row of features (where
// the feet are and how they move, how the hips move and where the body goes
// in the next second), normalized per feature so that each kind weighs what
// its weight says. A query with the same features finds the row closest to
// what the body does and is asked to do. The features are in the frame of
// the character: its position on the ground and its facing, +Z forward and Y
// up, so a row does not depend on where or toward where the clip was made.

MATCH_LANES :: 7 // f32x4 per row: 27 features and one of padding
MATCH_TRAJECTORY :: 3
MATCH_HORIZON :: [MATCH_TRAJECTORY]f32{1.0/3,2.0/3,1} // seconds ahead of each trajectory point

Match_Feature :: enum u8 {Foot_Position,Foot_Velocity,Hip_Velocity,Trajectory_Position,Trajectory_Direction}
Match_Weights :: [Match_Feature]f32
MATCH_WEIGHTS_DEFAULT :: Match_Weights{.Foot_Position=.75,.Foot_Velocity=1,.Hip_Velocity=1,.Trajectory_Position=1,.Trajectory_Direction=1.5}
// First and end feature of each kind in a row.
MATCH_FEATURES :: [Match_Feature][2]int{.Foot_Position={0,6},.Foot_Velocity={6,12},.Hip_Velocity={12,15},.Trajectory_Position={15,21},.Trajectory_Direction={21,27}}
// Smallest spread of a kind of feature: a kind every row shares (the facing of clips in place)
// does not turn a small difference of the query into a huge cost.
MATCH_SPREAD_MIN :: .1
// A database of more rows keeps the bounds of runs of rows, small and large, and the search
// skips a run whose bound costs more than the best row found.
MATCH_LINEAR_ROWS :: 1024
MATCH_BOUND_SMALL :: 16
MATCH_BOUND_LARGE :: 64
// Seconds from its start in which an entry clip can be entered.
MATCH_ENTRY_SPAN :: .1

Match_Query :: [MATCH_LANES]simd.f32x4

// A clip in the database. modes is the set of locomotion modes it serves, bit m for mode m; an
// entry clip starts one of them (a jump, a landing): it is searched only from its start, when the
// body enters the mode. speed, when positive, is the m/s the clip travels at instead of the one
// measured: an in-place clip goes that fast along its measured direction, or forward.
Match_Clip :: struct {clip:Clip,modes:u32,entry:bool,speed:f32}
// The rows of a clip. speed is how fast the body goes over the ground in it, m/s: that of its
// root, or for a clip in place the one its feet push at.
Match_Range :: struct {clip:Clip,first,count:i32,modes:u32,loop,entry:bool,speed:f32,travel:math.Vec3}
Match_Database :: struct {
    rate:f32,                      // rows per second of each clip
    features:[]simd.f32x4,         // MATCH_LANES per row, normalized
    mean,scale:[MATCH_LANES*4]f32, // raw = normalized*scale+mean
    ranges:[]Match_Range,
    rows:int,
    small,large:[]simd.f32x4,      // per run of MATCH_BOUND_SMALL or _LARGE rows: MATCH_LANES of its least, then of its greatest features; empty up to MATCH_LINEAR_ROWS rows
    allocator:mem.Allocator,
}
Match_Build_Error :: enum u8 {None,Invalid,Memory_Limit,Out_Of_Memory}
// What the features read of a skeleton: bones of the feet and the hips, the
// body its clips are measured with, and its forward in the space of the rig.
Match_Rig :: struct {skeleton:Skeleton,body:Body_Map,left_foot,right_foot,hips:i32,forward:math.Vec3}

match_database_free :: proc(db:^Match_Database) {
    if db.allocator.procedure!=nil {delete(db.features,db.allocator);delete(db.ranges,db.allocator);delete(db.small,db.allocator);delete(db.large,db.allocator)}
    db^={}
}

// Bytes the database keeps.
match_database_size :: proc "contextless" (db:Match_Database) -> int {return (len(db.features)+len(db.small)+len(db.large))*size_of(simd.f32x4)+len(db.ranges)*size_of(Match_Range)+size_of(Match_Database)}
// Bytes a database of rows over ranges clips keeps.
match_database_bytes :: proc "contextless" (rows,ranges:int) -> int {
    lanes:=rows*MATCH_LANES
    if rows>MATCH_LINEAR_ROWS {lanes+=2*MATCH_LANES*((rows+MATCH_BOUND_SMALL-1)/MATCH_BOUND_SMALL+(rows+MATCH_BOUND_LARGE-1)/MATCH_BOUND_LARGE)}
    return lanes*size_of(simd.f32x4)+ranges*size_of(Match_Range)+size_of(Match_Database)
}

// Samples every clip at about rate rows per second and keeps its features, refusing with
// Memory_Limit a database that would keep more than limit bytes (0: any). A clip that does not
// move the skeleton, lasts a single pose or a rig without feet and hips gives Invalid; db is
// empty after an error.
match_database_build :: proc(db:^Match_Database,lib:^Library,rig:Match_Rig,clips:[]Match_Clip,rate:f32,weights:=MATCH_WEIGHTS_DEFAULT,limit:=0,allocator:=context.allocator) -> (error:Match_Build_Error) {
    match_database_free(db)
    error=.Invalid
    n:=len(rig.skeleton.parents)
    if n==0 || len(clips)==0 || !anim_finite(rate) || rate<=0 || rate>FRAMES_MAX_RATE || !skeleton_validate(rig.skeleton) {return}
    for bone in ([3]i32{rig.left_foot,rig.right_foot,rig.hips}) {if bone<0 || int(bone)>=n {return}}
    forward,unit:=anim_unit(math.Vec3{rig.forward.x,0,rig.forward.z});if !unit {return}
    for weight in weights {if !anim_finite(weight) || weight<0 {return}}
    MAX_FRAMES :: 1<<20
    total,longest:=0,0
    for c in clips {
        if !clip_valid(lib,c.clip) || !anim_finite(c.speed) || c.speed<0 {return}
        count,_:=frames_layout(clip_duration(lib,c.clip),rate,MAX_FRAMES)
        if count<2 {return}
        total+=count;longest=max(longest,count)
    }
    if limit>0 && match_database_bytes(total,len(clips))>limit {return .Memory_Limit}
    context.allocator=allocator
    ok:bool
    raw,e0:=make([][MATCH_LANES*4]f32,total);defer delete(raw)
    tracks,e1:=make([]Bone_Tracks,n);defer delete(tracks)
    local,e2:=make([]math.Transform,longest*n);defer delete(local)
    world,e3:=make([]math.Transform,(longest+1)*n);defer delete(world)
    rest,e4:=make([]math.Transform,n);defer delete(rest)
    ranges,e5:=make([]Match_Range,len(clips))
    defer if !ok {delete(ranges)}
    if e0!=nil || e1!=nil || e2!=nil || e3!=nil || e4!=nil || e5!=nil {return .Out_Of_Memory}
    copy(rest,rig.skeleton.rest)
    skeleton:=rig.skeleton;skeleton.rest=rest
    body_rig:=Body_Rig{parents=skeleton.parents,rest=rest,body=rig.body,root=-1}
    row:=0
    for c,i in clips {
        if !skeleton_bind(lib,c.clip,skeleton,tracks) {return}
        count,exact:=frames_layout(clip_duration(lib,c.clip),rate,MAX_FRAMES)
        frames:=Frames{rate=exact,bones=n,loop=clip_data(lib,c.clip).loop==.Loop,local=local[:count*n]}
        if !frames_sample_clip(lib,c.clip,tracks,rest,nil,frames) {return}
        ground,grounded:=frames_ground(body_rig,frames,world);if !grounded {return}
        rest_world:=world[count*n:][:n]
        root:=int(ground.root)
        travel,speed:=ground.travel,linalg.length(ground.travel)
        if c.speed>0 {
            if ground.in_place {direction,moving:=anim_unit(travel);travel=(direction if moving else forward)*c.speed}
            speed=c.speed
        }
        motion:=Match_Motion{frames=frames,world=world[:count*n],rest=rest_world,root=root,in_place=ground.in_place,travel=travel,forward=forward}
        ranges[i]={clip=c.clip,first=i32(row),count=i32(count),modes=c.modes,loop=frames.loop,entry=c.entry,speed=speed,travel=travel}
        for frame in 0..<count {
            values:=&raw[row+frame]
            at:=f32(frame)
            here:=match_motion_body(motion,at)
            inverse:=math.quat_inverse(match_yaw(match_motion_facing(motion,at)))
            for bone,k in ([2]i32{rig.left_foot,rig.right_foot}) {
                position:=math.quat_rotate(inverse,match_motion_point(motion,int(bone),at)-here)
                velocity:=math.quat_rotate(inverse,match_motion_velocity(motion,int(bone),frame))
                for axis in 0..<3 {values[k*3+axis]=position[axis];values[6+k*3+axis]=velocity[axis]}
            }
            hips:=math.quat_rotate(inverse,match_motion_velocity(motion,int(rig.hips),frame))
            for axis in 0..<3 {values[12+axis]=hips[axis]}
            for horizon,k in MATCH_HORIZON {
                ahead:=at+horizon*exact
                position:=math.quat_rotate(inverse,match_motion_body(motion,ahead)-here)
                direction:=math.quat_rotate(inverse,match_motion_facing(motion,ahead))
                values[15+k*2],values[16+k*2]=position.x,position.z
                values[21+k*2],values[22+k*2]=direction.x,direction.z
            }
        }
        row+=count
    }
    features,e6:=make([]simd.f32x4,total*MATCH_LANES)
    if e6!=nil {return .Out_Of_Memory}
    small,large:[]simd.f32x4
    if total>MATCH_LINEAR_ROWS {
        e7,e8:mem.Allocator_Error
        small,e7=make([]simd.f32x4,2*MATCH_LANES*((total+MATCH_BOUND_SMALL-1)/MATCH_BOUND_SMALL))
        large,e8=make([]simd.f32x4,2*MATCH_LANES*((total+MATCH_BOUND_LARGE-1)/MATCH_BOUND_LARGE))
        if e7!=nil || e8!=nil {delete(features);delete(small);delete(large);return .Out_Of_Memory}
    }
    db^={rate=rate,features=features,ranges=ranges,rows=total,small=small,large=large,allocator=allocator}
    for i in 0..<MATCH_LANES*4 {db.scale[i]=1}
    for span,kind in MATCH_FEATURES {
        spread:f64
        for i in span[0]..<span[1] {
            sum:f64;for values in raw {sum+=f64(values[i])}
            mean:=sum/f64(total);db.mean[i]=f32(mean)
            variance:f64;for values in raw {d:=f64(values[i])-mean;variance+=d*d}
            spread+=cmath.sqrt(variance/f64(total))
        }
        spread=max(spread/f64(span[1]-span[0]),MATCH_SPREAD_MIN)
        for i in span[0]..<span[1] {db.scale[i]=f32(spread)/weights[kind] if weights[kind]>0 else max(f32)}
    }
    for values,r in raw {
        normalized:[MATCH_LANES*4]f32
        for value,i in values {normalized[i]=(value-db.mean[i])/db.scale[i]}
        for lane in 0..<MATCH_LANES {features[r*MATCH_LANES+lane]=match_lane(normalized[lane*4:][:4])}
    }
    for bounds,b in ([2][]simd.f32x4{small,large}) {
        size:=MATCH_BOUND_SMALL if b==0 else MATCH_BOUND_LARGE
        for box in 0..<len(bounds)/(2*MATCH_LANES) {
            least,greatest:=bounds[box*2*MATCH_LANES:][:MATCH_LANES],bounds[box*2*MATCH_LANES+MATCH_LANES:][:MATCH_LANES]
            for lane in 0..<MATCH_LANES {least[lane],greatest[lane]=max(f32),min(f32)}
            for r in box*size..<min((box+1)*size,total) {
                for lane in 0..<MATCH_LANES {v:=features[r*MATCH_LANES+lane];least[lane]=simd.min(least[lane],v);greatest[lane]=simd.max(greatest[lane],v)}
            }
        }
    }
    ok=true
    return .None
}

// The normalized features of the row of a range nearest a time of its clip.
match_row :: proc "contextless" (db:^Match_Database,range:int,time:f32) -> int {
    r:=db.ranges[range]
    frame:=int(cmath.round(time*db.rate)) if anim_finite(time) else 0
    if r.loop && r.count>1 {frame%=int(r.count-1);if frame<0 {frame+=int(r.count-1)}}
    return int(r.first)+clamp(frame,0,int(r.count-1))
}
match_features :: #force_inline proc "contextless" (db:^Match_Database,row:int) -> Match_Query {
    query:Match_Query
    copy(query[:],db.features[row*MATCH_LANES:][:MATCH_LANES])
    return query
}
// The cost of a row against a query, each feature by its weight (match_query gives them).
match_cost :: #force_inline proc "contextless" (db:^Match_Database,row:int,query,weights:Match_Query) -> f32 {
    features:=db.features[row*MATCH_LANES:][:MATCH_LANES]
    sum:simd.f32x4
    #unroll for lane in 0..<MATCH_LANES {d:=features[lane]-query[lane];sum+=d*d*weights[lane]}
    return simd.reduce_add_pairs(sum)
}

// The raw trajectory of a row.
match_row_trajectory :: proc "contextless" (db:^Match_Database,row:int) -> (positions,directions:[MATCH_TRAJECTORY]math.Vec2) {
    values:[MATCH_LANES*4]f32
    for lane in 0..<MATCH_LANES {lanes:=simd.to_array(db.features[row*MATCH_LANES+lane]);copy(values[lane*4:][:4],lanes[:])}
    for k in 0..<MATCH_TRAJECTORY {
        for axis in 0..<2 {
            i,j:=15+k*2+axis,21+k*2+axis
            positions[k][axis]=values[i]*db.scale[i]+db.mean[i]
            directions[k][axis]=values[j]*db.scale[j]+db.mean[j]
        }
    }
    return
}

// Writes the trajectory of the query, raw values in the frame of the character, normalized.
match_query_trajectory :: proc "contextless" (db:^Match_Database,query:^Match_Query,positions,directions:[MATCH_TRAJECTORY]math.Vec2) {
    values:[MATCH_LANES*4]f32
    for lane in 0..<MATCH_LANES {lanes:=simd.to_array(query[lane]);copy(values[lane*4:][:4],lanes[:])}
    for k in 0..<MATCH_TRAJECTORY {
        for axis in 0..<2 {
            i,j:=15+k*2+axis,21+k*2+axis
            values[i]=(positions[k][axis]-db.mean[i])/db.scale[i]
            values[j]=(directions[k][axis]-db.mean[j])/db.scale[j]
        }
    }
    for lane in 0..<MATCH_LANES {query[lane]=match_lane(values[lane*4:][:4])}
}

// What a search looks for: the pose part of query (the trajectory lanes are written per clip),
// the trajectory in the frame of the character, the modes whose clips it searches and the rates
// a clip that travels may play at (1 and 1: as it was made) and the rate the pose of query plays
// at (0: 1). entry searches the starts of the entry clips of the modes alone; otherwise they are
// left out.
Match_Request :: struct {query:Match_Query,positions,directions:[MATCH_TRAJECTORY]math.Vec2,modes:u32,min_rate,max_rate,rate:f32,entry:bool,filter_stationary,moving:bool}

// The query against the rows of a range, its weights and the rate the range plays at to go where
// the trajectory goes: a few clips cover the speeds between theirs by their rate, whose trajectory
// and velocities are theirs scaled by it. The query is taken to the rate of the range (its
// trajectory over it, the velocities of its pose by the rate it plays at over it), and the
// velocities and trajectory positions weigh the square of the rate: costs are of what the body
// does, so a clip slowed down is not dearer than one at its own rate.
match_query :: proc "contextless" (db:^Match_Database,request:Match_Request,range:int) -> (query,weights:Match_Query,rate:f32) {
    query,rate=request.query,1
    for &lane in weights {lane={1,1,1,1}}
    r:=db.ranges[range]
    if r.speed>1e-3 && request.min_rate>0 && request.min_rate<=request.max_rate {
        rate=clamp(linalg.length(request.positions[MATCH_TRAJECTORY-1])/(MATCH_HORIZON[MATCH_TRAJECTORY-1]*r.speed),request.min_rate,request.max_rate)
    }
    positions:=request.positions
    for &p in positions {p/=rate}
    match_query_trajectory(db,&query,positions,request.directions)
    if scale:=(request.rate if request.rate>0 else 1)/rate;scale!=1 {
        values:[MATCH_LANES*4]f32
        for lane in 0..<MATCH_LANES {lanes:=simd.to_array(query[lane]);copy(values[lane*4:][:4],lanes[:])}
        for i in MATCH_FEATURES[.Foot_Velocity][0]..<MATCH_FEATURES[.Hip_Velocity][1] {values[i]=((values[i]*db.scale[i]+db.mean[i])*scale-db.mean[i])/db.scale[i]}
        for lane in 0..<MATCH_LANES {query[lane]=match_lane(values[lane*4:][:4])}
    }
    if rate!=1 {
        scales:[MATCH_LANES*4]f32
        for &value,i in scales {value=rate*rate if i>=MATCH_FEATURES[.Foot_Velocity][0] && i<MATCH_FEATURES[.Trajectory_Position][1] else 1}
        for lane in 0..<MATCH_LANES {weights[lane]=match_lane(scales[lane*4:][:4])}
    }
    return
}

// The least cost a row inside the bounds of a run can have against query.
@(private)
match_bound :: #force_inline proc "contextless" (bounds:[]simd.f32x4,box:int,query,weights:Match_Query) -> f32 {
    least,greatest:=bounds[box*2*MATCH_LANES:][:MATCH_LANES],bounds[box*2*MATCH_LANES+MATCH_LANES:][:MATCH_LANES]
    sum:simd.f32x4
    #unroll for lane in 0..<MATCH_LANES {d:=simd.max(simd.max(least[lane]-query[lane],query[lane]-greatest[lane]),0);sum+=d*d*weights[lane]}
    return simd.reduce_add_pairs(sum)
}

// Whether some clip serves one of modes, entry or not.
match_serves :: proc "contextless" (db:^Match_Database,modes:u32,entry:bool) -> bool {
    for r in db.ranges {if r.modes&modes!=0 && r.entry==entry {return true}}
    return false
}

// The row of least cost among the clips that serve one of the modes of request, and the rate its
// clip plays at. A clip that does not loop keeps out its last horizon, from which playing on would
// end the clip before the trajectory. Rows of range skip within reach rows of its row near are
// left out: a jump that short is a stutter. With bounds, runs that cannot hold a better row are
// skipped whole.
match_search :: proc "contextless" (db:^Match_Database,request:Match_Request,skip:int=-1,near:int=-1,reach:int=0) -> (best:int,cost,rate:f32) {
    best,cost,rate=-1,max(f32),1
    tail:=int(cmath.ceil(MATCH_HORIZON[MATCH_TRAJECTORY-1]*db.rate))
    entry_rows:=int(cmath.ceil(MATCH_ENTRY_SPAN*db.rate))+1
    bounded:=len(db.small)>0
    for r,range in db.ranges {
        if r.modes&request.modes==0 || r.entry!=request.entry {continue}
        if request.filter_stationary && r.loop && (r.speed>.05)!=request.moving {continue}
        query,weights,scaled:=match_query(db,request,range)
        last:=int(r.count) if r.loop || int(r.count)<=tail+1 else int(r.count)-tail
        if request.entry {last=min(int(r.count),entry_rows)}
        row,end:=int(r.first),int(r.first)+last
        for row<end {
            large_end:=min((row/MATCH_BOUND_LARGE+1)*MATCH_BOUND_LARGE,end)
            if bounded && match_bound(db.large,row/MATCH_BOUND_LARGE,query,weights)>=cost {row=large_end;continue}
            for row<large_end {
                small_end:=min((row/MATCH_BOUND_SMALL+1)*MATCH_BOUND_SMALL,large_end)
                if bounded && match_bound(db.small,row/MATCH_BOUND_SMALL,query,weights)>=cost {row=small_end;continue}
                for ;row<small_end;row+=1 {
                    if range==skip && abs(row-near)<=reach {continue}
                    if value:=match_cost(db,row,query,weights);value<cost {best,cost,rate=row,value,scaled}
                }
            }
        }
    }
    return
}

// The range a row belongs to.
match_range_of :: proc "contextless" (db:^Match_Database,row:int) -> int {
    low,high:=0,len(db.ranges)
    for low<high {
        middle:=(low+high)/2
        if row<int(db.ranges[middle].first) {high=middle} else if row>=int(db.ranges[middle].first+db.ranges[middle].count) {low=middle+1} else {return middle}
    }
    return -1
}

// Where the body goes in the next MATCH_HORIZON seconds, in the frame of its facing: its
// horizontal velocity heads toward desired at acceleration m/s² (braking with desired zero),
// as a walk drives it, and its facing turns toward desired_facing at turn_rate rad/s (0: at once;
// a zero desired_facing keeps it). Vectors are in the world, Y up.
match_trajectory :: proc "contextless" (velocity,desired:math.Vec3,acceleration,braking:f32,facing,desired_facing:math.Vec3,turn_rate:f32) -> (positions,directions:[MATCH_TRAJECTORY]math.Vec2) {
    flat :: proc "contextless" (v:math.Vec3) -> math.Vec3 {return {v.x,0,v.z}}
    v,goal:=flat(velocity),flat(desired)
    heading,known:=anim_unit(flat(facing));if !known {heading={0,0,1}}
    rate:=braking if goal=={} else acceleration
    change:=goal-v;distance:=linalg.length(change)
    reach:=distance/rate if rate>0 && anim_finite(rate) else max(f32)
    along:=change/distance if distance>0 else math.Vec3{}
    turn:f32
    if wanted,ok:=anim_unit(flat(desired_facing));ok {turn=cmath.atan2(linalg.dot(linalg.cross(heading,wanted),math.Vec3{0,1,0}),linalg.dot(heading,wanted))}
    inverse:=math.quat_inverse(match_yaw(heading))
    for horizon,k in MATCH_HORIZON {
        position:math.Vec3
        if horizon<=reach {position=v*horizon+along*(.5*rate*horizon*horizon)} else {position=v*reach+along*(.5*rate*reach*reach)+goal*(horizon-reach)}
        angle:=turn if turn_rate<=0 else clamp(turn,-turn_rate*horizon,turn_rate*horizon)
        direction:=math.quat_rotate(math.quat_axis_angle({0,1,0},angle),heading)
        local,toward:=math.quat_rotate(inverse,position),math.quat_rotate(inverse,direction)
        positions[k],directions[k]={local.x,local.z},{toward.x,toward.z}
    }
    return
}

@(private)
match_lane :: #force_inline proc "contextless" (values:[]f32) -> simd.f32x4 {return {values[0],values[1],values[2],values[3]}}

// The rotation about Y that takes +Z to a horizontal direction.
match_yaw :: proc "contextless" (direction:math.Vec3) -> math.Quat {
    return math.quat_axis_angle({0,1,0},cmath.atan2(direction.x,direction.z))
}

@(private)
Match_Motion :: struct {frames:Frames,world,rest:[]math.Transform,root:int,in_place:bool,travel,forward:math.Vec3}

// A frame of the clip, out of its span: a loop goes on into its next passes, carrying what the body
// moved in each one; a clip that does not loop holds its ends.
@(private)
match_motion_frame :: proc "contextless" (m:Match_Motion,frame:int) -> (index:int,passes:f32) {
    count:=frames_count(m.frames)
    if !m.frames.loop || count<2 {return clamp(frame,0,count-1),0}
    span:=count-1
    pass:=frame/span if frame>=0 else -((span-1-frame)/span)
    return frame-pass*span,f32(pass)
}
@(private)
match_motion_loop :: proc "contextless" (m:Match_Motion) -> math.Vec3 {
    count:=frames_count(m.frames)
    if m.in_place {return m.travel*frames_duration(m.frames)}
    a,b:=m.world[m.root].position,m.world[(count-1)*m.frames.bones+m.root].position
    return {b.x-a.x,0,b.z-a.z}
}
// Where a bone is in the world of the clip at a frame, with the travel of a clip in place.
@(private)
match_motion_point_at :: proc "contextless" (m:Match_Motion,bone,frame:int) -> math.Vec3 {
    index,passes:=match_motion_frame(m,frame)
    position:=m.world[index*m.frames.bones+bone].position+match_motion_loop(m)*passes
    if m.in_place {position+=m.travel*(f32(index)/m.frames.rate)}
    return position
}
@(private)
match_motion_point :: proc "contextless" (m:Match_Motion,bone:int,frame:f32) -> math.Vec3 {
    whole:=int(cmath.floor(frame))
    return linalg.lerp(match_motion_point_at(m,bone,whole),match_motion_point_at(m,bone,whole+1),frame-f32(whole))
}
@(private)
match_motion_velocity :: proc "contextless" (m:Match_Motion,bone,frame:int) -> math.Vec3 {
    a,b:=frame-1,frame+1
    if !m.frames.loop {a,b=max(a,0),min(b,frames_count(m.frames)-1)}
    if b<=a {return {}}
    return (match_motion_point_at(m,bone,b)-match_motion_point_at(m,bone,a))*(m.frames.rate/f32(b-a))
}
// The body on the ground: its root, or for a clip in place the origin carried by the travel.
@(private)
match_motion_body :: proc "contextless" (m:Match_Motion,frame:f32) -> math.Vec3 {
    if m.in_place {
        whole:=int(cmath.floor(frame))
        index,passes:=match_motion_frame(m,whole)
        return match_motion_loop(m)*passes+m.travel*((f32(index)+frame-f32(whole))/m.frames.rate)
    }
    p:=match_motion_point(m,m.root,frame)
    return {p.x,0,p.z}
}
@(private)
match_motion_facing :: proc "contextless" (m:Match_Motion,frame:f32) -> math.Vec3 {
    if m.in_place {return m.forward}
    index,_:=match_motion_frame(m,int(cmath.round(frame)))
    turn:=m.world[index*m.frames.bones+m.root].rotation*math.quat_inverse(m.rest[m.root].rotation)
    facing:=math.quat_rotate(turn,m.forward)
    if direction,ok:=anim_unit(math.Vec3{facing.x,0,facing.z});ok {return direction}
    return m.forward
}
