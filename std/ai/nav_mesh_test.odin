package ai

import "core:math/linalg"
import "core:testing"
import math "mirai:std/math"

TEST_TILE :: f32(4)

// A tile of unit squares (two triangles each) over the walkable cells of a
// width x height grid starting at the corner of the tile, at height y (or the
// heights of the grid points).
cell_tile :: proc(t:^testing.T,coord:[2]i32,width,height:int,walkable:[]bool={},y:f32=0,heights:[]f32={},area:=NAV_AREA_WALKABLE,size:=TEST_TILE) -> Nav_Tile_Data {
    vertices:[dynamic]math.Vec3
    defer delete(vertices)
    origin:=math.Vec3{f32(coord.x)*size,0,f32(coord.y)*size}
    for z in 0..=height {
        for x in 0..=width {
            h:=y
            if len(heights)>0 {h=heights[z*(width+1)+x]}
            append(&vertices,origin+math.Vec3{f32(x),h,f32(z)})
        }
    }
    indices:[dynamic]u32
    defer delete(indices)
    at :: proc(width,x,z:int) -> u32 {return u32(z*(width+1)+x)}
    for z in 0..<height {
        for x in 0..<width {
            if len(walkable)>0 && !walkable[z*width+x] {continue}
            a,b,c,d:=at(width,x,z),at(width,x+1,z),at(width,x+1,z+1),at(width,x,z+1)
            append(&indices,a,b,c,a,c,d)
        }
    }
    rect:=math.Aabb{origin+{0,-1e6,0},origin+{size,1e6,size}}
    data,ok:=nav_tile_from_triangles(coord,rect,vertices[:],indices[:],area)
    testing.expect(t,ok)
    return data
}

test_mesh :: proc(t:^testing.T,mesh:^Nav_Mesh,tiles:=16,links:=16) {
    testing.expect(t,nav_mesh_init(mesh,{tile_width=TEST_TILE,climb=0.3,max_tiles=tiles,max_links=links}))
}

test_filter :: proc() -> Nav_Filter {return {can=NAV_CAN_ALL}}

free_connections :: proc(mesh:^Nav_Mesh) -> int {
    count:=0
    for at:=mesh.free_connection;at!=0;at=mesh.connections[at-1].next {count+=1}
    return count
}

nearest :: proc(t:^testing.T,mesh:^Nav_Mesh,p:math.Vec3) -> Nav_Ref {
    ref,_,ok:=nav_find_nearest_any(mesh,p,{0.5,1,0.5})
    testing.expect(t,ok)
    return ref
}

@(test)
tiles_join_across_their_border_and_part_when_one_is_removed :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    free:=free_connections(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{1,0},4,4)))
    testing.expect(t,free_connections(&mesh)<free)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    a,b:=math.Vec3{0.5,0,2},math.Vec3{7.5,0,2}
    path:[64]Nav_Ref
    count,status,partial:=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,path[:])
    testing.expect(t,status==.Found && !partial && count>=2)
    testing.expect(t,nav_ref_slot(path[0])!=nav_ref_slot(path[count-1]))
    testing.expect(t,abs(search_cost(&q.search)-7)<1e-3)
    corners:[16]Nav_Corner
    n,complete:=nav_straight_path(&mesh,a,b,path[:count],corners[:])
    testing.expect(t,complete && n==2 && .Start in corners[0].flags && .End in corners[1].flags)
    testing.expect(t,nav_mesh_remove_tile(&mesh,{1,0}))
    testing.expect_value(t,free_connections(&mesh),free)
    testing.expect(t,!nav_ref_valid(&mesh,path[count-1]))
    _,_,found:=nav_find_nearest_any(&mesh,b,{0.5,1,0.5})
    testing.expect(t,!found)
}

@(test)
a_replaced_tile_invalidates_old_references :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    old:=nearest(t,&mesh,{1,0,1})
    revision:=mesh.revision
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    testing.expect(t,!nav_ref_valid(&mesh,old))
    testing.expect(t,nav_ref_valid(&mesh,nearest(t,&mesh,{1,0,1})))
    testing.expect(t,mesh.revision>revision)
}

@(test)
a_path_goes_around_a_wall_and_turns_at_its_corners :: proc(t:^testing.T) {
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
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{6.5,0,1.5}
    path:[128]Nav_Ref
    count,status,_:=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,path[:])
    testing.expect_value(t,status,Search_Status.Found)
    corners:[16]Nav_Corner
    n,complete:=nav_straight_path(&mesh,a,b,path[:count],corners[:])
    // A* picks a channel by where it enters each polygon, which may not hold
    // the shortest line: the path is near the shortest, around the same corners.
    testing.expect(t,complete && n>=4)
    length:f32
    around:=0
    for i in 1..<n {
        length+=linalg.distance(corners[i].position,corners[i-1].position)
        if linalg.distance(corners[i].position,math.Vec3{4,0,6})<1e-4 || linalg.distance(corners[i].position,math.Vec3{5,0,6})<1e-4 {around+=1}
    }
    shortest:=linalg.distance(a,math.Vec3{4,0,6})+1+linalg.distance(math.Vec3{5,0,6},b)
    testing.expect(t,around==2 && length>=shortest-1e-3 && length<shortest*1.02)
}

// Two platforms of one tile with a gap between x=3 and x=5, the second 1.5 m higher.
gap_mesh :: proc(t:^testing.T,mesh:^Nav_Mesh) {
    testing.expect(t,nav_mesh_init(mesh,{tile_width=8,climb=0.3,max_tiles=4,max_links=8}))
    heights:[9*3]f32
    for &h,i in heights {h=1.5 if i%9>=5 else 0}
    walkable:[16]bool
    for &w,i in walkable {w=i%8<3 || i%8>=5}
    testing.expect(t,nav_mesh_add_tile(mesh,cell_tile(t,{0,0},8,2,walkable[:],heights=heights[:],size=8)))
}

@(test)
a_link_joins_two_platforms_only_for_agents_that_can_cross_it :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    link:=nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,kind=1,area=NAV_AREA_WALKABLE,need={up=1.5,across=2.2}})
    testing.expect(t,link!=0)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    from,to:=nearest(t,&mesh,a),nearest(t,&mesh,b)
    path:[64]Nav_Ref
    weak:=Nav_Filter{can={up=1,across=3}}
    count,status,partial:=nav_find_path(&q,&mesh,from,to,a,b,&weak,path[:])
    testing.expect(t,status==.No_Path && partial && count>=1)
    able:=Nav_Filter{can={up=2,across=3}}
    count,status,partial=nav_find_path(&q,&mesh,from,to,a,b,&able,path[:])
    testing.expect(t,status==.Found && !partial)
    corners:[16]Nav_Corner
    n,complete:=nav_straight_path(&mesh,a,b,path[:count],corners[:])
    testing.expect(t,complete && n==3)
    testing.expect(t,.Link in corners[1].flags && corners[1].ref==link)
    testing.expect(t,linalg.distance(corners[1].position,math.Vec3{2.9,0,1})<1e-3)
    // One way: no path back.
    count,status,partial=nav_find_path(&q,&mesh,to,from,b,a,&able,path[:])
    testing.expect(t,status==.No_Path)
}

@(test)
a_two_way_link_is_crossed_back :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    link:=nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,two_way=true,area=NAV_AREA_WALKABLE})
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    filter:=test_filter()
    path:[64]Nav_Ref
    count,status,_:=nav_find_path(&q,&mesh,nearest(t,&mesh,b),nearest(t,&mesh,a),b,a,&filter,path[:])
    testing.expect_value(t,status,Search_Status.Found)
    crossed:=false
    for ref in path[:count] {if nav_ref_is_link(ref) {crossed=nav_ref_reverse(ref) && nav_ref_flip(ref)==link}}
    testing.expect(t,crossed)
    testing.expect(t,nav_mesh_remove_link(&mesh,link))
    _,status,_=nav_find_path(&q,&mesh,nearest(t,&mesh,b),nearest(t,&mesh,a),b,a,&filter,path[:])
    testing.expect_value(t,status,Search_Status.No_Path)
}

@(test)
a_link_rests_when_its_tiles_arrive_and_lifts_when_they_leave :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    ref:=nav_mesh_add_link(&mesh,{start={3.5,0,2},end={10,0,2},radius=0.5,area=NAV_AREA_WALKABLE,owner=7})
    link:=nav_link_of(&mesh,ref)
    testing.expect(t,link!=nil && link.start_poly!=0 && link.end_poly==0)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{2,0},4,4)))
    testing.expect(t,link.start_poly!=0 && link.end_poly!=0)
    testing.expect(t,abs(link.end_point.x-10)<1e-4)
    testing.expect(t,nav_mesh_remove_tile(&mesh,{2,0}))
    testing.expect(t,link.start_poly==0 && link.end_poly==0)
    testing.expect_value(t,nav_mesh_remove_links_of(&mesh,7),1)
    testing.expect(t,nav_link_of(&mesh,ref)==nil)
}

@(test)
a_search_in_slices_finds_the_path_of_a_whole_one :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    for x in 0..<3 {testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{i32(x),0},4,4)))}
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,512))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    a,b:=math.Vec3{0.2,0,0.3},math.Vec3{11.6,0,3.5}
    whole:[128]Nav_Ref
    count,status,_:=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,whole[:])
    testing.expect_value(t,status,Search_Status.Found)
    cost:=search_cost(&q.search)
    status=nav_path_begin(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter)
    slices:=0
    for status==.Running {status=nav_path_step(&q,4);slices+=1}
    sliced:[128]Nav_Ref
    n,final,_:=nav_path_finish(&q,sliced[:])
    testing.expect(t,final==.Found && n==count && slices>2)
    testing.expect(t,abs(search_cost(&q.search)-cost)<1e-4)
    for i in 0..<n {testing.expect(t,sliced[i]==whole[i])}
}

@(test)
area_costs_and_exclusions_change_the_path :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=8,climb=0.3,max_tiles=4}))
    defer nav_mesh_destroy(&mesh)
    // A band of area 2 across the middle with a gap of plain ground at the top.
    mixed:=cell_tile(t,{0,0},8,8,size=8)
    for &p,i in mixed.polys {
        cell:=i/2
        if cell%8==4 && cell/8<6 {p.area=2}
    }
    testing.expect(t,nav_mesh_add_tile(&mesh,mixed))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,512))
    defer nav_query_destroy(&q)
    a,b:=math.Vec3{1.5,0,1.5},math.Vec3{6.5,0,1.5}
    path:[128]Nav_Ref
    filter:=test_filter()
    _,status,_:=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,path[:])
    testing.expect(t,status==.Found && abs(search_cost(&q.search)-5)<1e-3)
    filter.costs[2]=10
    _,status,_=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,path[:])
    testing.expect(t,status==.Found && search_cost(&q.search)>9 && search_cost(&q.search)<20)
    filter.costs[2]=0
    filter.excluded=1<<2
    _,status,_=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,path[:])
    testing.expect(t,status==.Found && search_cost(&q.search)>9)
}

@(test)
one_search_measures_the_ways_to_many_ends_as_path_searches_do :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    testing.expect(t,nav_mesh_init(&mesh,{tile_width=8,climb=0.3,max_tiles=4}))
    defer nav_mesh_destroy(&mesh)
    // A band of dear ground across the middle, open at the top, and a hole at its foot.
    walkable:[64]bool
    for &w,i in walkable {w=i!=2}
    mixed:=cell_tile(t,{0,0},8,8,walkable[:],size=8)
    for &p in mixed.polys {
        center:math.Vec3
        for k in 0..<int(p.count) {center+=mixed.vertices[p.vertices[k]]/f32(p.count)}
        if int(center.x)==4 && center.z<6 {p.area=2}
    }
    testing.expect(t,nav_mesh_add_tile(&mesh,mixed))
    q,each:Nav_Query
    testing.expect(t,nav_query_init(&q,512) && nav_query_init(&each,512))
    defer {nav_query_destroy(&q);nav_query_destroy(&each)}
    filter:=test_filter()
    filter.costs[2]=10
    a:=math.Vec3{1.5,0,1.5}
    from:=nearest(t,&mesh,a)
    ends:=[?]math.Vec3{{6.5,0,1.5},{7.5,0,7.5},{0.5,0,6.5},{3.5,0,0.5},{1.8,0,1.2}}
    refs:[len(ends)]Nav_Ref
    for end,i in ends {refs[i]=nearest(t,&mesh,end)}
    testing.expect(t,nav_costs(&q,&mesh,from,a,&filter,refs[:]))
    path:[128]Nav_Ref
    for end,i in ends {
        cost,ok:=nav_cost_to(&q,&mesh,refs[i],end)
        if refs[i]==from {
            testing.expect(t,ok && abs(cost-linalg.distance(a,end))<1e-4)
            continue
        }
        // The polygons it went through may not be those a search toward that end picks: near its cost, never below the line.
        _,status,_:=nav_find_path(&each,&mesh,from,refs[i],a,end,&filter,path[:])
        own:=search_cost(&each.search)
        testing.expectf(t,ok && status==.Found && cost>=linalg.distance(a,end)-1e-4 && abs(cost-own)<=own*0.05,"to %v: %v by one search, %v by its own",end,cost,own)
    }
    // Excluded ground is not crossed, and what lies beyond the hole is reached around it.
    filter.excluded=1<<2
    testing.expect(t,nav_costs(&q,&mesh,from,a,&filter,refs[:]))
    cost,ok:=nav_cost_to(&q,&mesh,refs[0],ends[0])
    testing.expect(t,ok && cost>9)
    _,ok=nav_cost_to(&q,&mesh,0,ends[0])
    testing.expect(t,!ok)
    testing.expect(t,!nav_costs(&q,&mesh,0,a,&filter,refs[:]))
}

@(test)
moving_along_the_surface_stops_at_walls :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    filter:=test_filter()
    start:=math.Vec3{1,0,1}
    visited:[16]Nav_Ref
    result,count:=nav_move_along_surface(&mesh,nearest(t,&mesh,start),start,{1.5,0,1.2},&filter,visited[:])
    testing.expect(t,linalg.distance(result,math.Vec3{1.5,0,1.2})<1e-5 && count>=1 && visited[0]==nearest(t,&mesh,start))
    result,count=nav_move_along_surface(&mesh,nearest(t,&mesh,start),start,{-1,0,1},&filter,visited[:])
    testing.expect(t,abs(result.x)<1e-4 && abs(result.z-1)<1e-4)
}

@(test)
a_ray_over_the_surface_stops_at_a_wall_and_reaches_an_open_end :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{1,0},4,4)))
    filter:=test_filter()
    start:=math.Vec3{1,0,1}
    visited:[32]Nav_Ref
    tt,_,count:=nav_raycast(&mesh,nearest(t,&mesh,start),start,{7,0,3},&filter,visited[:])
    testing.expect(t,tt==max(f32) && count>2)
    tt2,normal,_:=nav_raycast(&mesh,nearest(t,&mesh,start),start,{1,0,9},&filter,visited[:])
    testing.expect(t,abs(tt2-3.0/8)<1e-4)
    testing.expect(t,linalg.distance(normal,math.Vec3{0,0,-1})<1e-4)
}

@(test)
random_points_and_wall_distances_stay_on_the_mesh :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,nav_mesh_add_tile(&mesh,cell_tile(t,{0,0},4,4)))
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,128))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    rng:=math.rng_make(5)
    for _ in 0..<50 {
        ref,p,ok:=nav_random_point(&mesh,&filter,&rng)
        testing.expect(t,ok && p.x>=0 && p.x<=4 && p.z>=0 && p.z<=4 && nav_ref_valid(&mesh,ref))
    }
    center:=math.Vec3{2,0,2}
    for _ in 0..<50 {
        _,p,ok:=nav_random_point_around(&q,&mesh,nearest(t,&mesh,center),center,1,&filter,&rng)
        testing.expect(t,ok && linalg.distance(p,center)<2.5)
    }
    d,point,normal,ok:=nav_distance_to_wall(&q,&mesh,nearest(t,&mesh,{1,0,2}),{1,0,2},3,&filter)
    testing.expect(t,ok && abs(d-1)<1e-4 && abs(point.x)<1e-4 && linalg.distance(normal,math.Vec3{1,0,0})<1e-4)
    _,_,_,ok=nav_distance_to_wall(&q,&mesh,nearest(t,&mesh,{2,0,2}),{2,0,2},0.5,&filter)
    testing.expect(t,!ok)
}

@(test)
the_nearest_polygon_is_the_floor_under_the_point :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    // Two floors in one tile: ground, and a slab 3 m up over half of it.
    vertices:=[]math.Vec3{{0,0,0},{4,0,0},{4,0,4},{0,0,4},{0,3,0},{2,3,0},{2,3.5,4},{0,3.5,4}}
    indices:=[]u32{0,1,2,0,2,3,4,5,6,4,6,7}
    data,ok:=nav_tile_from_triangles({0,0},{{0,-10,0},{4,10,4}},vertices,indices)
    testing.expect(t,ok && nav_mesh_add_tile(&mesh,data))
    low,_,_:=nav_find_nearest_any(&mesh,{1,0.2,2},{1,4,1})
    high,_,_:=nav_find_nearest_any(&mesh,{1,3.4,2},{1,4,1})
    testing.expect(t,low!=0 && high!=0 && low!=high)
    y,over:=nav_poly_height(&mesh,high,{1,9,2})
    testing.expect(t,over && abs(y-3.25)<1e-4)
    _,over=nav_poly_height(&mesh,high,{3,0,2})
    testing.expect(t,!over)
}

@(test)
zero_and_invalid_inputs_are_safe :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    q:Nav_Query
    filter:=test_filter()
    path:[4]Nav_Ref
    corners:[4]Nav_Corner
    _,status,_:=nav_find_path(&q,&mesh,1,2,{},{},&filter,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    _,_,ok:=nav_find_nearest_any(&mesh,{},{1,1,1})
    testing.expect(t,!ok)
    testing.expect(t,!nav_mesh_remove_tile(&mesh,{0,0}))
    testing.expect(t,nav_mesh_add_link(&mesh,{})==0)
    n,_:=nav_straight_path(&mesh,{},{},path[:],corners[:])
    testing.expect_value(t,n,0)
    testing.expect(t,!nav_mesh_init(&mesh,{tile_width=0,max_tiles=1}))
    testing.expect(t,!nav_mesh_init(&mesh,{tile_width=1,max_tiles=0}))
    test_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    testing.expect(t,!nav_mesh_add_tile(&mesh,{}))
    nan:=f32(0)
    nan=nan/nan
    _,_,ok=nav_find_nearest_any(&mesh,{nan,0,0},{1,1,1})
    testing.expect(t,!ok)
    testing.expect(t,nav_mesh_add_link(&mesh,{start={nan,0,0}})==0)
    _,ok=nav_tile_from_triangles({0,0},{},{{0,0,0},{1,0,0},{0,0,1}},{0,1,5})
    testing.expect(t,!ok)
}

@(test)
a_copied_mesh_answers_with_the_same_references :: proc(t:^testing.T) {
    mesh:Nav_Mesh
    gap_mesh(t,&mesh)
    defer nav_mesh_destroy(&mesh)
    link:=nav_mesh_add_link(&mesh,{start={2.9,0,1},end={5.1,1.5,1},radius=0.3,area=NAV_AREA_WALKABLE})
    other:Nav_Mesh
    testing.expect(t,nav_mesh_copy(&other,&mesh))
    defer nav_mesh_destroy(&other)
    q:Nav_Query
    testing.expect(t,nav_query_init(&q,256))
    defer nav_query_destroy(&q)
    filter:=test_filter()
    a,b:=math.Vec3{0.5,0,1},math.Vec3{7.5,1.5,1}
    first,second:[64]Nav_Ref
    n,status,_:=nav_find_path(&q,&mesh,nearest(t,&mesh,a),nearest(t,&mesh,b),a,b,&filter,first[:])
    m,status2,_:=nav_find_path(&q,&other,nearest(t,&other,a),nearest(t,&other,b),a,b,&filter,second[:])
    testing.expect(t,status==.Found && status2==.Found && n==m)
    for i in 0..<n {testing.expect(t,first[i]==second[i])}
    // The copy owns its tiles: removing one from the source leaves it whole.
    nav_mesh_remove_tile(&mesh,{0,0})
    testing.expect(t,nav_link_of(&other,link)!=nil && nav_ref_valid(&other,second[0]))
}
