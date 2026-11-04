package ai

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

corridor_plan :: proc(t:^testing.T,c:^Nav_Corridor,q:^Nav_Query,mesh:^Nav_Mesh,filter:^Nav_Filter,a,b:math.Vec3) {
    path:[256]Nav_Ref
    from:=nearest(t,mesh,a)
    count,status,_:=nav_find_path(q,mesh,from,nearest(t,mesh,b),a,b,filter,path[:])
    testing.expect_value(t,status,Search_Status.Found)
    nav_corridor_reset(c,from,a)
    testing.expect(t,nav_corridor_set(c,mesh,b,path[:count]))
}

@(test)
a_corridor_follows_the_agent_and_gives_its_next_corner :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=8,climb=0.3,max_tiles=4}))
    defer nav_mesh_destroy(&mesh)
    walkable:[64]bool
    for &w,i in walkable {w=!(i%8==4 && i/8<6)}
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},8,8,walkable[:],size=8)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{6.5,0,1.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    corners:[4]Nav_Corner
    // Walk toward each next corner in steps of 0.25 m, as an agent would.
    position:=a
    arrived:=false
    for _ in 0..<200 {
        n:=nav_corridor_corners(&c,&mesh,corners[:])
        testing.expect(t,n>=1)
        if n==0 {break}
        next:=corners[0].position
        if .End in corners[0].flags && linalg.distance(position,next)<0.05 {arrived=true;break}
        step:=next-position
        length:=linalg.length(step)
        if length>0.25 {step*=0.25/length}
        testing.expect(t,nav_corridor_move(&c,&mesh,&filter,position+step))
        position=c.position
        nav_corridor_shortcut(&c,&mesh,&filter,next,4)
        // Never through the wall.
        testing.expect(t,!(position.x>4.01 && position.x<4.99 && position.z<5.99))
    }
    testing.expect(t,arrived)
    testing.expect(t,c.count==1 && c.path[0]==nearest(t,&mesh,b))
}

@(test)
a_corridor_stops_at_a_link_and_goes_on_from_its_end :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    link:=nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,area=NAV_AREA_WALKABLE})
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    corners:[4]Nav_Corner
    n:=nav_corridor_corners(&c,&mesh,corners[:])
    testing.expect(t,n==1 && .Link in corners[0].flags && corners[0].ref==link)
    testing.expect(t,nav_corridor_move(&c,&mesh,&filter,{2.9,0,1}))
    from,to,crossed,ok:=nav_corridor_cross(&c,&mesh)
    testing.expect(t,ok && crossed==link && linalg.distance(from,math.Vec3{2.9,0,1})<1e-3 && linalg.distance(to,math.Vec3{5.1,1.5,1})<1e-3)
    testing.expect(t,!nav_ref_is_link(c.path[0]) && linalg.distance(c.position,to)<1e-3)
    n=nav_corridor_corners(&c,&mesh,corners[:])
    testing.expect(t,n==1 && .End in corners[0].flags && linalg.distance(corners[0].position,b)<1e-3)
    _,_,_,ok=nav_corridor_cross(&c,&mesh)
    testing.expect(t,!ok)
}

@(test)
a_corridor_takes_back_the_polygons_walked_off_it :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{3.5,0,1.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    count:=c.count
    // Pushed back and away from the path: the corridor grows at its front and still ends at the target.
    testing.expect(t,nav_corridor_move(&c,&mesh,&filter,{0.5,0,3.5}))
    testing.expect(t,c.count>count && c.path[0]==nearest(t,&mesh,{0.5,0,3.5}) && nav_corridor_last(&c)==nearest(t,&mesh,b))
    for i in 1..<int(c.count) {
        _,_,ok:=nav_portal_points(&mesh,c.path[i-1],c.path[i])
        testing.expect(t,ok)
    }
}

@(test)
a_long_path_keeps_its_first_part_and_a_target_on_it :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=64,climb=0.3,max_tiles=1}))
    defer nav_mesh_destroy(&mesh)
    // A corridor one cell wide and 60 long: two triangles per cell.
    walkable:[64*2]bool
    for &w,i in walkable {w=i<60}
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},64,2,walkable[:],size=64)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,512))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    c:Nav_Corridor
    a,b:=math.Vec3{0.5,0,0.5},math.Vec3{59.5,0,0.5}
    corridor_plan(t,&c,&q,&mesh,&filter,a,b)
    testing.expect_value(t,c.count,i32(NAV_CORRIDOR_CAPACITY))
    testing.expect(t,c.target.x<59 && c.target.x>20)
    testing.expect(t,nav_corridor_valid(&c,&mesh,&filter,8))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},64,2,walkable[:],size=64)))
    testing.expect(t,!nav_corridor_valid(&c,&mesh,&filter,8))
    testing.expect(t,!nav_corridor_move(&c,&mesh,&filter,a))
}

@(test)
following_a_path_and_querying_the_mesh_do_not_allocate :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,area=NAV_AREA_WALKABLE,two_way=true})
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    from,to:=nearest(t,&mesh,a),nearest(t,&mesh,b)
    rng:=math.rng_make(3)
    counter:Alloc_Counter
    saved:=context
    context.allocator=counting_allocator(&counter)
    context.temp_allocator=context.allocator
    path:[64]Nav_Ref
    corners:[8]Nav_Corner
    visited:[16]Nav_Ref
    c:Nav_Corridor
    for round in 0..<20 {
        count,status,_:=nav_find_path(&q,&mesh,from,to,a,b,&filter,path[:])
        if status!=.Found {break}
        nav_straight_path(&mesh,a,b,path[:count],corners[:])
        nav_corridor_reset(&c,from,a)
        nav_corridor_set(&c,&mesh,b,path[:count])
        nav_corridor_move(&c,&mesh,&filter,a+{0.1*f32(round),0,0})
        nav_corridor_corners(&c,&mesh,corners[:])
        nav_corridor_shortcut(&c,&mesh,&filter,{2.9,0,1},4)
        nav_raycast(&mesh,from,a,{2.5,0,1.5},&filter,visited[:])
        nav_random_point(&mesh,&filter,&rng)
        nav_random_point_around(&q,&mesh,from,a,2,&filter,&rng)
        nav_distance_to_wall(&q,&mesh,from,a,2,&filter)
        nav_find_nearest(&mesh,b,{1,2,1},&filter)
    }
    context=saved
    testing.expect_value(t,counter.calls,0)
}
