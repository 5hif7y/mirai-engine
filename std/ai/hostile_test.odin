package ai

import "base:runtime"
import "core:testing"
import math "mirai:std/math"

// Every public procedure takes whatever it is given and returns: cells, nodes,
// triangles and states out of range, sizes that overflow, graphs with edges to
// nowhere, NaN, infinities and huge coordinates and buffers of any length.
// The minds have theirs in mind_test.odin.

@(private="file") HOSTILE_ROUNDS :: #config(AI_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc "contextless" (h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc "contextless" (h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc "contextless" (h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_vec2 :: proc "contextless" (h:^Hostile,wild:bool) -> math.Vec2 {
    if !wild {return {f32(hostile_int(h,201)-100)/20,f32(hostile_int(h,201)-100)/20}}
    return {hostile_f32(h),hostile_f32(h)}
}

@(private="file")
hostile_vec3 :: proc "contextless" (h:^Hostile,wild:bool) -> math.Vec3 {
    if !wild {return {f32(hostile_int(h,201)-100)/20,f32(hostile_int(h,201)-100)/20,f32(hostile_int(h,201)-100)/20}}
    return {hostile_f32(h),hostile_f32(h),hostile_f32(h)}
}

@(private="file")
hostile_cell :: proc "contextless" (h:^Hostile,size:int) -> Cell {
    switch hostile_int(h,10) {
    case 0: return {-1,-1}
    case 1: return {max(i32),max(i32)}
    case 2: return {min(i32),min(i32)}
    case 3: return {i32(size),i32(size)}
    case 4: return {0,i32(size)}
    }
    return {i32(hostile_int(h,max(size,1))),i32(hostile_int(h,max(size,1)))}
}

@(private="file")
hostile_count :: proc "contextless" (h:^Hostile) -> int {
    switch hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<16
    case 3: return 1
    }
    return 1+hostile_int(h,40)
}

@(private="file")
hostile_extent :: proc "contextless" (h:^Hostile) -> int {
    switch hostile_int(h,10) {
    case 0: return -1
    case 1: return 0
    case 2: return 1<<10
    case 3: return 1
    }
    return 1+hostile_int(h,40)
}

@(private="file")
hostile_grid :: proc(h:^Hostile,g:^Grid) -> bool {
    w,height:=1+hostile_int(h,12),1+hostile_int(h,12)
    if !grid_init(g,w,height,u8(hostile_int(h,3)==0?hostile_int(h,256):1)) {return false}
    for _ in 0..<hostile_int(h,10) {
        low:=hostile_cell(h,w)
        grid_fill(g,low,low+Cell{i32(hostile_int(h,5)),i32(hostile_int(h,5))},u8(hostile_int(h,3)==0?hostile_int(h,256):0))
        _=grid_set(g,hostile_cell(h,w),u8(hostile_int(h,256)))
    }
    return true
}

@(test)
hostile_cells_through_the_grid_search :: proc(t:^testing.T) {
    h:=Hostile{1}
    path:[dynamic]Cell
    defer delete(path)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !hostile_grid(&h,&g) {continue}
        s:Search
        nodes:=len(g.cost)+hostile_int(&h,3)-1
        if !search_init(&s,{nodes=nodes,open=hostile_int(&h,3)==0?hostile_int(&h,6):0,max_edges=hostile_int(&h,3)==0?hostile_int(&h,10)-2:0}) {
            grid_destroy(&g)
            continue
        }
        for _ in 0..<8 {
            resize(&path,hostile_int(&h,4)==0?hostile_int(&h,5):len(g.cost))
            start,goal:=hostile_cell(&h,g.width),hostile_cell(&h,g.height)
            if hostile_int(&h,6)==0 {goal=start}
            hood:=Neighborhood(hostile_int(&h,2))
            count,status:=grid_find_path(&s,&g,start,goal,hood,path[:])
            if status==.Found {
                testing.expect(t,count>=1&&count<=len(path),"path does not fit")
                if count>=1&&count<=len(path) {
                    testing.expect(t,path[0]==start&&path[count-1]==goal,"path does not join the ends")
                }
            }
            steps:[8]Cell
            lengths:[8]f32
            _=grid_steps(&g,hostile_cell(&h,g.width),hood,&steps,&lengths)
            _=grid_cost(&g,hostile_cell(&h,g.width))
            _=grid_passable(&g,hostile_cell(&h,g.width))
            _=grid_in_bounds(&g,hostile_cell(&h,g.width))
            _=grid_index(&g,hostile_cell(&h,g.width))
            _=grid_cell(&g,hostile_int(&h,len(g.cost)))
            _=search_cost(&s)
            _=search_nodes(&s)
            out:[8]u64
            _,_=search_path(&s,out[:hostile_int(&h,9)])
        }
        search_destroy(&s)
        grid_destroy(&g)
    }
}

@(test)
hostile_calls_through_empty_grids :: proc(t:^testing.T) {
    h:=Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        g:Grid
        s:Search
        f:Flow_Field
        out:[4]Cell
        _,_=grid_find_path(&s,&g,hostile_cell(&h,3),hostile_cell(&h,3),.Eight,out[:])
        _=grid_cost(&g,hostile_cell(&h,3))
        _=grid_passable(&g,hostile_cell(&h,3))
        _=grid_set(&g,hostile_cell(&h,3),1)
        grid_fill(&g,hostile_cell(&h,3),hostile_cell(&h,3),1)
        steps:[8]Cell
        lengths:[8]f32
        _=grid_steps(&g,hostile_cell(&h,3),.Eight,&steps,&lengths)
        _=flow_field_build(&f,&g,out[:],.Eight)
        _=flow_field_cost(&f,hostile_cell(&h,3))
        _=flow_field_direction(&f,hostile_cell(&h,3))
        _=flow_field_sample(&f,hostile_vec2(&h,true))
        _=search_run(&s,0,0,&g,proc(g:^Grid,n:u64,e:^Edge_List){},proc(g:^Grid,n,goal:u64) -> f32 {return 0})
        _,_=search_path(&s,nil)
        _=search_cost(&s)
        _=open_contains(&s.open,0)
        _=open_push(&s.open,0,1)
        _,_,_=open_pop(&s.open)
        open_clear(&s.open)
        grid_destroy(&g);search_destroy(&s);flow_field_destroy(&f)
    }
}

@(test)
hostile_cell_of_a_zero_grid :: proc(t:^testing.T) {
    g:Grid
    _=grid_cell(&g,0)
}

@(test)
hostile_sizes_through_the_grid_init :: proc(t:^testing.T) {
    h:=Hostile{3}
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        w,height:=hostile_extent(&h),hostile_extent(&h)
        if grid_init(&g,w,height) {
            _=grid_cost(&g,{0,0})
            _=grid_set(&g,{i32(hostile_int(&h,100)),i32(hostile_int(&h,100))},3)
            grid_fill(&g,{0,0},{1<<20,1<<20},2)
        }
        grid_destroy(&g)
    }
}

@(test)
hostile_overflowing_sizes_through_the_grid_init :: proc(t:^testing.T) {
    for size in ([?][2]int{{1<<32,1<<32},{1<<62,3},{max(int),2},{1<<44,max(int)},{(1<<32)+1,(1<<32)+1}}) {
        g:Grid
        if grid_init(&g,size.x,size.y) {
            testing.expectf(t,len(g.cost)==g.width*g.height,"grid of %d by %d has %d cells",g.width,g.height,len(g.cost))
            _=grid_cost(&g,{0,0})
        }
        grid_destroy(&g)
    }
}

@(test)
hostile_overflowing_sizes_through_the_flow_field_init :: proc(t:^testing.T) {
    for size in ([?][2]int{{1<<32,1<<32},{1<<62,3},{max(int),2},{1<<44,max(int)},{(1<<32)+1,(1<<32)+1}}) {
        f:Flow_Field
        if flow_field_init(&f,size.x,size.y) {_=flow_field_cost(&f,{0,0})}
        flow_field_destroy(&f)
    }
}

@(test)
hostile_overflowing_nodes_through_the_search_init :: proc(t:^testing.T) {
    for nodes in ([?]int{1<<61,1<<62,max(int)}) {
        s:Search
        if search_init(&s,{nodes=nodes}) {testing.expectf(t,search_nodes(&s)==nodes,"search of %d nodes holds %d",nodes,search_nodes(&s))}
        search_destroy(&s)
    }
}

@(test)
hostile_overflowing_edges_through_the_search_init :: proc(t:^testing.T) {
    for edges in ([?]int{1<<61,1<<62,max(int)}) {
        s:Search
        _=search_init(&s,{nodes=4,max_edges=edges})
        search_destroy(&s)
    }
}

@(test)
hostile_overflowing_open_through_the_search_init :: proc(t:^testing.T) {
    for open in ([?]int{1<<61,1<<62,max(int)}) {
        s:Search
        _=search_init(&s,{nodes=4,open=open})
        search_destroy(&s)
    }
}

@(test)
hostile_overflowing_sizes_through_the_open_init :: proc(t:^testing.T) {
    for size in ([?]int{1<<61,1<<62,max(int)}) {
        o:Open_Set
        _=open_init(&o,size,4)
        open_destroy(&o)
        _=open_init(&o,4,size)
        open_destroy(&o)
    }
}

@(test)
hostile_overflowing_sizes_through_the_utility_init :: proc(t:^testing.T) {
    for size in ([?]int{1<<59,1<<61,1<<62,max(int)}) {
        u:Utility
        _=utility_init(&u,{max_actions=size})
        utility_destroy(&u)
        _=utility_init(&u,{max_actions=1,max_considerations=size})
        utility_destroy(&u)
    }
}

@(test)
hostile_sizes_through_the_flow_field_init :: proc(t:^testing.T) {
    h:=Hostile{4}
    for _ in 0..<HOSTILE_ROUNDS {
        f:Flow_Field
        w,height:=hostile_extent(&h),hostile_extent(&h)
        if flow_field_init(&f,w,height) {
            _=flow_field_cost(&f,{0,0})
            _=flow_field_direction(&f,{0,0})
        }
        flow_field_destroy(&f)
    }
}

@(test)
hostile_sizes_through_the_search_init :: proc(t:^testing.T) {
    h:=Hostile{5}
    for _ in 0..<HOSTILE_ROUNDS {
        s:Search
        if search_init(&s,{nodes=hostile_count(&h),open=hostile_count(&h),max_edges=hostile_count(&h)}) {
            graph:=Hostile_Graph{nodes=search_nodes(&s)}
            _=search_run(&s,0,0,&graph,hostile_graph_neighbors,hostile_graph_heuristic)
        }
        search_destroy(&s)
        o:Open_Set
        if open_init(&o,hostile_count(&h),hostile_count(&h)) {
            _=open_push(&o,0,1)
        }
        open_destroy(&o)
    }
}

@(private="file")
Hostile_Graph :: struct {h:Hostile, nodes:int, mode:int}

@(private="file")
hostile_graph_neighbors :: proc(graph:^Hostile_Graph,node:u64,edges:^Edge_List) {
    local:=Hostile{node*7919+u64(graph.mode)}
    for _ in 0..<hostile_int(&local,12) {
        to:=u64(hostile_int(&local,graph.nodes+(graph.mode%3==0?4:0)))
        switch hostile_int(&local,12) {
        case 0: to=node
        case 1: to=max(u64)
        }
        cost:=f32(1+hostile_int(&local,5))
        if graph.mode%2==0 {cost=hostile_f32(&local)}
        edge_add(edges,to,cost)
    }
}

@(private="file")
hostile_graph_heuristic :: proc(graph:^Hostile_Graph,node,goal:u64) -> f32 {
    if graph.mode%4==0 {return f32(hostile_next(&graph.h)>>40)-8e6}
    return 0
}

@(private="file")
hostile_user_neighbors :: proc(user:rawptr,node:u64,edges:^Edge_List) {hostile_graph_neighbors((^Hostile_Graph)(user),node,edges)}

@(private="file")
hostile_user_heuristic :: proc(user:rawptr,node,goal:u64) -> f32 {return hostile_graph_heuristic((^Hostile_Graph)(user),node,goal)}

@(test)
hostile_graphs_through_the_search :: proc(t:^testing.T) {
    h:=Hostile{6}
    out:[dynamic]u64
    defer delete(out)
    for round in 0..<HOSTILE_ROUNDS {
        graph:=Hostile_Graph{h={u64(round)},nodes=1+hostile_int(&h,30),mode=hostile_int(&h,8)}
        s:Search
        nodes:=graph.nodes+hostile_int(&h,3)-1
        if !search_init(&s,{nodes=nodes,keyed=hostile_int(&h,3)==0,open=hostile_int(&h,3)==0?hostile_int(&h,8):0,max_edges=hostile_int(&h,3)==0?hostile_int(&h,6)-1:0}) {continue}
        for _ in 0..<6 {
            resize(&out,hostile_int(&h,4)==0?hostile_int(&h,4):graph.nodes)
            start,goal:=u64(hostile_int(&h,graph.nodes+2)),u64(hostile_int(&h,graph.nodes+2))
            if hostile_int(&h,8)==0 {goal=start}
            if hostile_int(&h,10)==0 {start=max(u64)}
            api:=Graph{user=&graph,neighbors=hostile_user_neighbors,heuristic=hostile_int(&h,3)==0?nil:hostile_user_heuristic}
            if hostile_int(&h,12)==0 {api.neighbors=nil}
            count,status:=graph_find_path(&s,api,start,goal,out[:])
            if status==.Found {
                testing.expect(t,count>=1&&count<=len(out),"path does not fit")
                if count>=1&&count<=len(out) {testing.expect(t,out[0]==start&&out[count-1]==goal,"path does not join the ends")}
            }
            _=search_cost(&s)
            _,_=search_path(&s,out[:])
            _,_=search_path(&s,out[:hostile_int(&h,len(out)+1)])
        }
        search_destroy(&s)
    }
}

@(test)
hostile_keys_through_the_open_set :: proc(t:^testing.T) {
    h:=Hostile{7}
    for _ in 0..<HOSTILE_ROUNDS {
        o:Open_Set
        nodes,capacity:=1+hostile_int(&h,20),1+hostile_int(&h,20)
        if !open_init(&o,nodes,capacity) {continue}
        for _ in 0..<60 {
            switch hostile_int(&h,5) {
            case 0,1: _=open_push(&o,u32(hostile_int(&h,nodes+3)),hostile_f32(&h))
            case 2: _,_,_=open_pop(&o)
            case 3: _=open_contains(&o,u32(hostile_next(&h)))
            case 4: open_clear(&o)
            }
        }
        for {
            _,_,ok:=open_pop(&o)
            if !ok {break}
        }
        open_destroy(&o)
    }
}

@(test)
hostile_goals_through_the_flow_field :: proc(t:^testing.T) {
    h:=Hostile{8}
    goals:[dynamic]Cell
    defer delete(goals)
    for _ in 0..<HOSTILE_ROUNDS {
        g:Grid
        if !hostile_grid(&h,&g) {continue}
        f:Flow_Field
        w,height:=g.width,g.height
        if hostile_int(&h,6)==0 {w+=hostile_int(&h,3)-1}
        if !flow_field_init(&f,max(w,1),height) {grid_destroy(&g);continue}
        clear(&goals)
        for _ in 0..<hostile_int(&h,5) {append(&goals,hostile_cell(&h,g.width))}
        _=flow_field_build(&f,&g,goals[:],Neighborhood(hostile_int(&h,2)))
        for _ in 0..<10 {
            c:=hostile_cell(&h,g.width)
            _=flow_field_cost(&f,c)
            _=flow_field_direction(&f,c)
            _=flow_field_sample(&f,hostile_vec2(&h,hostile_int(&h,2)==0))
        }
        flow_field_destroy(&f)
        grid_destroy(&g)
    }
}

@(private="file")
hostile_finite_vec3 :: proc "contextless" (h:^Hostile) -> math.Vec3 {
    v:=hostile_vec3(h,true)
    for &x in v {
        if x!=x {x=0} else if x>1e30 {x=1e30} else if x< -1e30 {x=-1e30}
    }
    return v
}

@(private="file")
hostile_navmesh_input :: proc(h:^Hostile,vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,finite:bool) -> (scale:f32) {
    clear(vertices);clear(indices)
    scale=1
    if hostile_int(h,3)==0 {
        n:=hostile_int(h,16)
        for _ in 0..<n {append(vertices,finite?hostile_finite_vec3(h):hostile_vec3(h,true))}
        count:=hostile_int(h,30)
        if hostile_int(h,4)!=0 {count-=count%3}
        for _ in 0..<count {append(indices,u32(hostile_int(h,max(n,1)+(hostile_int(h,6)==0?3:0))))}
        return
    }
    switch hostile_int(h,6) {
    case 0: scale=1e-3
    case 1: scale=1e4
    case 2: scale=1e12
    }
    w,height:=1+hostile_int(h,6),1+hostile_int(h,6)
    for z in 0..=height {
        for x in 0..=w {
            jitter:=hostile_int(h,4)==0?f32(0.4):0
            append(vertices,math.Vec3{(f32(x)+jitter*f32(hostile_int(h,11)-5)/5)*scale,f32(hostile_int(h,3))*scale*0.1,(f32(z)+jitter*f32(hostile_int(h,11)-5)/5)*scale})
        }
    }
    stride:=u32(w+1)
    for z in 0..<height {
        for x in 0..<w {
            a:=u32(z)*stride+u32(x)
            b,c,d:=a+1,a+stride,a+stride+1
            if hostile_int(h,6)==0 {continue}
            if hostile_int(h,2)==0 {
                append(indices,a,c,b,b,c,d)
            } else {
                append(indices,a,c,d,a,d,b)
            }
            if hostile_int(h,12)==0 {append(indices,a,c,b)}
            if hostile_int(h,12)==0 {append(indices,a,a,b)}
        }
    }
    return
}

@(private="file")
hostile_nav_point :: proc(h:^Hostile,scale:f32) -> math.Vec3 {
    if hostile_int(h,5)==0 {return hostile_vec3(h,true)}
    p:=hostile_vec3(h,false)
    return {p.x*scale/4,p.y*scale/20,p.z*scale/4}
}

@(private="file")
nav_rounds :: proc(t:^testing.T,seed:u64,finite:bool) {
    h:=Hostile{seed}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    for _ in 0..<HOSTILE_ROUNDS {
        scale:=hostile_navmesh_input(&h,&vertices,&indices,finite)
        mesh:Nav_Mesh
        width:=scale*f32(1+hostile_int(&h,8))/2
        if hostile_int(&h,8)==0 {width=hostile_f32(&h)}
        climb:=hostile_int(&h,4)==0?hostile_f32(&h):0.3*scale
        if !nav_mesh_init(&mesh,{tile_width=width,climb=climb,max_tiles=1+hostile_int(&h,4),max_links=hostile_int(&h,5),max_connections=hostile_int(&h,3)==0?hostile_int(&h,4):0}) {continue}
        for _ in 0..<1+hostile_int(&h,3) {
            coord:=[2]i32{i32(hostile_int(&h,3)-1),i32(hostile_int(&h,3)-1)}
            rect:=math.Aabb{{f32(coord.x)*width,-1e6,f32(coord.y)*width},{f32(coord.x+1)*width,1e6,f32(coord.y+1)*width}}
            if hostile_int(&h,6)==0 {rect={hostile_vec3(&h,true),hostile_vec3(&h,true)}}
            data,ok:=nav_tile_from_triangles(coord,rect,vertices[:],indices[:],u8(1+hostile_int(&h,3)))
            if !ok {continue}
            if hostile_int(&h,8)==0 {data.polys[0].neighbor[hostile_int(&h,6)]=u16(hostile_next(&h))}
            if !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
        }
        q:Nav_Query
        _=nav_query_init(&q,1+hostile_int(&h,64))
        filter:=Nav_Filter{excluded=hostile_int(&h,4)==0?hostile_next(&h):0,can=hostile_int(&h,2)==0?NAV_CAN_ALL:{}}
        if hostile_int(&h,5)==0 {filter.costs[hostile_int(&h,64)]=hostile_f32(&h)}
        rng:=math.rng_make(hostile_next(&h))
        path:[16]Nav_Ref
        corners:[8]Nav_Corner
        coarse:Nav_Coarse
        defer nav_coarse_destroy(&coarse)
        coarse_search:Search
        _=search_init(&coarse_search,{nodes=1+hostile_int(&h,80),max_edges=hostile_int(&h,40)})
        defer search_destroy(&coarse_search)
        for _ in 0..<12 {
            a,b:=hostile_nav_point(&h,scale),hostile_nav_point(&h,scale)
            extents:=hostile_int(&h,4)==0?hostile_vec3(&h,true):math.Vec3{scale,scale,scale}
            from,_,_:=nav_find_nearest(&mesh,a,extents,&filter)
            to,_,_:=nav_find_nearest_any(&mesh,b,extents)
            if hostile_int(&h,6)==0 {from=Nav_Ref(hostile_next(&h))}
            switch hostile_int(&h,9) {
            case 0,1:
                count,_,_:=nav_find_path(&q,&mesh,from,to,a,b,&filter,path[:hostile_int(&h,17)])
                _,_=nav_straight_path(&mesh,a,b,path[:count],corners[:hostile_int(&h,9)])
            case 2:
                status:=nav_path_begin(&q,&mesh,from,to,a,b,&filter)
                for i:=0;status==.Running && i<64;i+=1 {status=nav_path_step(&q,hostile_int(&h,4))}
                if hostile_int(&h,3)==0 {_=nav_mesh_remove_tile(&mesh,{i32(hostile_int(&h,3)-1),i32(hostile_int(&h,3)-1)})}
                _,_,_=nav_path_finish(&q,path[:])
            case 3:
                _,_=nav_move_along_surface(&mesh,from,a,b,&filter,path[:hostile_int(&h,17)])
                _,_,_=nav_raycast(&mesh,from,a,b,&filter,path[:hostile_int(&h,17)])
            case 4:
                _,_,_=nav_random_point(&mesh,&filter,&rng)
                _,_,_=nav_random_point_around(&q,&mesh,from,a,hostile_f32(&h),&filter,&rng)
                _,_,_,_=nav_distance_to_wall(&q,&mesh,from,a,hostile_f32(&h),&filter)
                targets:=[2]Nav_Ref{to,Nav_Ref(hostile_next(&h))}
                _=nav_costs(&q,&mesh,from,a,&filter,targets[:hostile_int(&h,3)])
                if hostile_int(&h,3)==0 {_=nav_mesh_remove_tile(&mesh,{i32(hostile_int(&h,3)-1),i32(hostile_int(&h,3)-1)})}
                _,_=nav_cost_to(&q,&mesh,targets[hostile_int(&h,2)],b)
            case 5:
                link:=nav_mesh_add_link(&mesh,{start=a,end=b,radius=hostile_f32(&h),two_way=hostile_int(&h,2)==0,area=u8(hostile_int(&h,70)),cost=hostile_f32(&h),need={up=hostile_f32(&h)},owner=u64(hostile_int(&h,3))})
                if hostile_int(&h,3)==0 {_=nav_mesh_remove_link(&mesh,link)}
                if hostile_int(&h,4)==0 {_=nav_mesh_remove_links_of(&mesh,u64(hostile_int(&h,3)))}
                _=nav_mesh_remove_link(&mesh,Nav_Ref(hostile_next(&h)))
            case 6:
                _,_=nav_poly_height(&mesh,from,a)
                _,_=nav_closest_point_on_poly(&mesh,from,a)
                _,_,_=nav_portal_points(&mesh,from,to)
                _=nav_ref_valid(&mesh,Nav_Ref(hostile_next(&h)))
                jumps:[8]Nav_Jump_Link
                jump:=Nav_Jump{up=hostile_f32(&h),across=hostile_f32(&h),down=hostile_f32(&h),radius=hostile_f32(&h),climb=hostile_f32(&h),step=hostile_int(&h,3)==0?hostile_f32(&h):scale*0.25}
                _,_=nav_jump_links(&mesh,{i32(hostile_int(&h,3)-1),i32(hostile_int(&h,3)-1)},jump,jumps[:hostile_int(&h,9)])
                _=nav_jump_point({start=a,end=b,kind=Nav_Jump_Kind(hostile_int(&h,2))},hostile_f32(&h))
            case 7:
                _=nav_mesh_remove_tile(&mesh,{i32(hostile_int(&h,3)-1),i32(hostile_int(&h,3)-1)})
            case 8:
                region_of :: proc(user:rawptr,point:math.Vec3) -> u64 {return u64(point.x>0)+u64(point.z>0)*2}
                box:=math.Aabb{a,b}
                if hostile_int(&h,3)==0 {box={math.vec3_min(a,b),math.vec3_max(a,b)}}
                _,_,_=nav_coarse_build_region(&coarse,&mesh,&q,&filter,u64(hostile_int(&h,4)),hostile_next(&h),box,region_of,nil)
                out:[8]math.Vec3
                _,_=nav_coarse_route(&coarse,&coarse_search,a,u64(hostile_int(&h,5)),b,u64(hostile_int(&h,5)),out[:hostile_int(&h,9)])
                if hostile_int(&h,4)==0 {_=nav_coarse_remove(&coarse,u64(hostile_int(&h,4)))}
                if hostile_int(&h,4)==0 && len(coarse.portals)>0 {
                    // A graph scribbled over, as a damaged file gives.
                    coarse.portals[hostile_int(&h,len(coarse.portals))].edge_first=u32(hostile_next(&h))
                    _,_=nav_coarse_route(&coarse,&coarse_search,a,1,b,2,out[:])
                    copied:Nav_Coarse
                    _=nav_coarse_merge(&copied,&coarse)
                    nav_coarse_destroy(&copied)
                    nav_coarse_destroy(&coarse)
                }
            }
        }
        nav_query_destroy(&q)
        nav_mesh_destroy(&mesh)
    }
}

@(test)
hostile_meshes_through_the_navmesh :: proc(t:^testing.T) {nav_rounds(t,9,false)}

@(test)
hostile_finite_meshes_through_the_navmesh :: proc(t:^testing.T) {nav_rounds(t,19,true)}

@(test)
hostile_calls_through_an_empty_navmesh :: proc(t:^testing.T) {
    h:=Hostile{11}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        mesh:Nav_Mesh
        q:Nav_Query
        filter:Nav_Filter
        path:[4]Nav_Ref
        corners:[4]Nav_Corner
        rng:=math.rng_make(1)
        a,b:=hostile_vec3(&h,true),hostile_vec3(&h,true)
        r:=Nav_Ref(hostile_next(&h))
        _,_,_=nav_find_path(&q,&mesh,r,r,a,b,&filter,path[:])
        _,_,_=nav_find_nearest_any(&mesh,a,b)
        _,_=nav_straight_path(&mesh,a,b,path[:],corners[:])
        _,_=nav_move_along_surface(&mesh,r,a,b,&filter,path[:])
        _,_,_=nav_raycast(&mesh,r,a,b,&filter,path[:])
        _,_,_=nav_random_point(&mesh,&filter,&rng)
        _,_,_=nav_random_point_around(&q,&mesh,r,a,hostile_f32(&h),&filter,&rng)
        _,_,_,_=nav_distance_to_wall(&q,&mesh,r,a,hostile_f32(&h),&filter)
        _=nav_costs(&q,&mesh,r,a,&filter,path[:])
        _,_=nav_cost_to(&q,&mesh,r,b)
        _=nav_mesh_add_link(&mesh,{start=a,end=b})
        _=nav_mesh_remove_tile(&mesh,{})
        _=nav_mesh_add_tile(&mesh,{})
        _=nav_mesh_coord(&mesh,a)
        _,_=nav_tile_from_triangles({},{},nil,nil)
        _,_=nav_tile_from_triangles({},{},[]math.Vec3{{0,0,0}},[]u32{0,0,0})
        _,_=nav_tile_from_triangles({},{},[]math.Vec3{{0,0,0},{1,0,0},{0,0,1}},[]u32{0,1,2,0})
        data,made:=nav_tile_data_alloc(hostile_int(&h,40)-8,hostile_int(&h,40)-8,hostile_int(&h,9)-2,hostile_int(&h,9)-2,hostile_int(&h,9)-2)
        if made {
            clone,cloned:=nav_tile_data_clone(&data)
            if cloned {nav_tile_data_free(&clone)}
            if !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
        }
        copied:Nav_Mesh
        _=nav_mesh_copy(&copied,&mesh)
        nav_mesh_destroy(&copied)
        coarse:Nav_Coarse
        search:Search
        out:[4]math.Vec3
        _,_,_=nav_coarse_build_region(&coarse,&mesh,&q,&filter,1,0,{a,b},nil,nil)
        _,_=nav_coarse_route(&coarse,&search,a,0,b,0,out[:])
        _=nav_coarse_remove(&coarse,0)
        _=nav_coarse_merge(&coarse,&coarse)
        nav_coarse_destroy(&coarse)
        nav_query_destroy(&q)
        nav_mesh_destroy(&mesh)
    }
}

@(test)
hostile_corridors_forged_and_followed :: proc(t:^testing.T) {
    h:=Hostile{24}
    mesh:Nav_Mesh
    _=nav_mesh_init(&mesh,{tile_width=2,climb=0.3,max_tiles=4,max_links=2})
    defer nav_mesh_destroy(&mesh)
    vertices:=[]math.Vec3{{0,0,0},{2,0,0},{2,0,2},{0,0,2}}
    for x in 0..<2 {
        moved:[4]math.Vec3
        for v,i in vertices {moved[i]=v+{f32(x)*2,0,0}}
        data,ok:=nav_tile_from_triangles({i32(x),0},{moved[0]+{0,-1,0},moved[2]+{0,1,0}},moved[:],[]u32{0,1,2,0,2,3})
        if ok && !nav_mesh_add_tile(&mesh,data) {nav_tile_data_free(&data)}
    }
    _=nav_mesh_add_link(&mesh,{start={1,0,1},end={3,0,1},radius=0.5})
    refs:[8]Nav_Ref
    n:=0
    for &tile in mesh.tiles {
        if !tile.used {continue}
        for i in 0..<len(tile.data.polys) {if n<len(refs) {refs[n]=nav_tile_ref(&mesh,&tile,i);n+=1}}
    }
    if n<len(refs) {refs[n]=nav_ref_link(mesh.links[0].salt,0,hostile_int(&h,2)==0);n+=1}
    filter:=Nav_Filter{can=hostile_int(&h,2)==0?NAV_CAN_ALL:{}}
    for _ in 0..<HOSTILE_ROUNDS {
        c:Nav_Corridor
        c.count=i32(hostile_int(&h,NAV_CORRIDOR_CAPACITY+4))-2
        if hostile_int(&h,8)==0 {c.count=i32(hostile_next(&h))}
        for &r in c.path[:hostile_int(&h,NAV_CORRIDOR_CAPACITY)] {r=refs[hostile_int(&h,max(n,1))] if hostile_int(&h,6)!=0 else Nav_Ref(hostile_next(&h))}
        c.position,c.target=hostile_nav_point(&h,2),hostile_nav_point(&h,2)
        corners:[4]Nav_Corner
        for _ in 0..<6 {
            switch hostile_int(&h,7) {
            case 0: _=nav_corridor_corners(&c,&mesh,corners[:hostile_int(&h,5)],hostile_f32(&h))
            case 1: _=nav_corridor_move(&c,&mesh,&filter,hostile_nav_point(&h,2))
            case 2: c.count=i32(nav_path_straighten(&mesh,&filter,hostile_nav_point(&h,2),hostile_nav_point(&h,2),c.path[:],int(c.count)))
            case 3: _,_,_,_=nav_corridor_cross(&c,&mesh)
            case 4: _=nav_corridor_valid(&c,&mesh,&filter,hostile_int(&h,80)-4)
            case 5: _=nav_corridor_set(&c,&mesh,&filter,hostile_nav_point(&h,2),refs[:hostile_int(&h,n+1)])
            case 6: nav_corridor_reset(&c,refs[hostile_int(&h,max(n,1))],hostile_nav_point(&h,2))
            }
            _=nav_corridor_first(&c)
            _=nav_corridor_last(&c)
        }
    }
}

@(private="file")
hostile_steer_vec2 :: proc(t:^testing.T,h:^Hostile) {
    p,v,o:=hostile_vec2(h,true),hostile_vec2(h,true),hostile_vec2(h,true)
    ms,mf:=hostile_f32(h),hostile_f32(h)
    _=seek(p,v,o,ms,mf)
    _=flee(p,v,o,ms,mf)
    _=arrive(p,v,o,ms,mf,hostile_f32(h))
    _=pursue(p,v,o,hostile_vec2(h,true),ms,mf,hostile_f32(h))
    _=evade(p,v,o,hostile_vec2(h,true),ms,mf,hostile_f32(h))
    displacement:=hostile_vec2(h,true)
    rng:=math.rng_make(hostile_next(h))
    _=wander(&displacement,v,hostile_f32(h),hostile_f32(h),hostile_f32(h),mf,&rng)
    boids:[6]Boid(math.Vec2)
    for &b in boids {b={hostile_vec2(h,true),hostile_vec2(h,true)}}
    n:=boids[:hostile_int(h,7)]
    _=separation(p,n,hostile_f32(h),mf)
    _=alignment(p,v,n,hostile_f32(h),ms,mf)
    _=cohesion(p,v,n,hostile_f32(h),ms,mf)
    obstacles:[4]Obstacle(math.Vec2)
    for &ob in obstacles {ob={hostile_vec2(h,true),hostile_f32(h)}}
    _=avoid_obstacles(p,v,obstacles[:hostile_int(h,5)],hostile_f32(h),hostile_f32(h),mf)
    _,_=steering_integrate(p,v,o,ms,hostile_f32(h))
    _=limit_length(p,ms)
}

@(private="file")
hostile_steer_vec3 :: proc(t:^testing.T,h:^Hostile) {
    p,v,o:=hostile_vec3(h,true),hostile_vec3(h,true),hostile_vec3(h,true)
    ms,mf:=hostile_f32(h),hostile_f32(h)
    _=seek(p,v,o,ms,mf)
    _=flee(p,v,o,ms,mf)
    _=arrive(p,v,o,ms,mf,hostile_f32(h))
    _=pursue(p,v,o,hostile_vec3(h,true),ms,mf,hostile_f32(h))
    _=evade(p,v,o,hostile_vec3(h,true),ms,mf,hostile_f32(h))
    displacement:=hostile_vec3(h,true)
    rng:=math.rng_make(hostile_next(h))
    _=wander(&displacement,v,hostile_f32(h),hostile_f32(h),hostile_f32(h),mf,&rng)
    boids:[6]Boid(math.Vec3)
    for &b in boids {b={hostile_vec3(h,true),hostile_vec3(h,true)}}
    n:=boids[:hostile_int(h,7)]
    _=separation(p,n,hostile_f32(h),mf)
    _=alignment(p,v,n,hostile_f32(h),ms,mf)
    _=cohesion(p,v,n,hostile_f32(h),ms,mf)
    obstacles:[4]Obstacle(math.Vec3)
    for &ob in obstacles {ob={hostile_vec3(h,true),hostile_f32(h)}}
    _=avoid_obstacles(p,v,obstacles[:hostile_int(h,5)],hostile_f32(h),hostile_f32(h),mf)
    _,_=steering_integrate(p,v,o,ms,hostile_f32(h))
    _=limit_length(p,ms)
}

@(test)
hostile_values_through_the_steering :: proc(t:^testing.T) {
    h:=Hostile{12}
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_steer_vec2(t,&h)
        hostile_steer_vec3(t,&h)
    }
}

@(test)
hostile_neighbors_through_the_avoidance :: proc(t:^testing.T) {
    h:=Hostile{13}
    neighbors:[dynamic]Avoid_Agent(2)
    flying:[dynamic]Avoid_Agent(3)
    defer {delete(neighbors);delete(flying)}
    for round in 0..<HOSTILE_ROUNDS {
        clear(&neighbors)
        wild:=round%3==0
        for _ in 0..<hostile_int(&h,40) {append(&neighbors,Avoid_Agent(2){hostile_vec2(&h,wild),hostile_vec2(&h,wild),wild?hostile_f32(&h):f32(hostile_int(&h,20))/10})}
        if hostile_int(&h,4)==0 && len(neighbors)>0 {
            for &n in neighbors {n.position=neighbors[0].position}
        }
        self:=Avoid_Agent(2){hostile_vec2(&h,wild),hostile_vec2(&h,wild),wild?hostile_f32(&h):f32(hostile_int(&h,20))/10}
        _=avoid_velocity(self,hostile_vec2(&h,wild),hostile_f32(&h),neighbors[:],hostile_f32(&h),hostile_f32(&h))
        _=avoid_velocity(self,hostile_vec2(&h,false),f32(1+hostile_int(&h,5)),neighbors[:],f32(1+hostile_int(&h,5)),0.1)
        clear(&flying)
        for _ in 0..<hostile_int(&h,40) {append(&flying,Avoid_Agent(3){hostile_vec3(&h,wild),hostile_vec3(&h,wild),wild?hostile_f32(&h):f32(hostile_int(&h,20))/10})}
        if hostile_int(&h,4)==0 && len(flying)>0 {
            for &n in flying {n.position=flying[0].position}
        }
        bird:=Avoid_Agent(3){hostile_vec3(&h,wild),hostile_vec3(&h,wild),wild?hostile_f32(&h):f32(hostile_int(&h,20))/10}
        _=avoid_velocity(bird,hostile_vec3(&h,wild),hostile_f32(&h),flying[:],hostile_f32(&h),hostile_f32(&h))
        _=avoid_velocity(bird,hostile_vec3(&h,false),f32(1+hostile_int(&h,5)),flying[:],f32(1+hostile_int(&h,5)),0.1)
    }
}

@(private="file")
hostile_response :: proc(h:^Hostile) -> Response {
    return {kind=Response_Kind(hostile_int(h,hostile_int(h,10)==0?256:4)),degree=u8(hostile_int(h,hostile_int(h,10)==0?256:5)),slope=hostile_f32(h),shift_x=hostile_f32(h),shift_y=hostile_f32(h),invert=hostile_int(h,2)==0}
}

@(test)
hostile_considerations_through_the_utility :: proc(t:^testing.T) {
    h:=Hostile{22}
    considerations:[dynamic]Consideration
    inputs,scores:[dynamic]f32
    defer {delete(considerations);delete(inputs);delete(scores)}
    for _ in 0..<HOSTILE_ROUNDS {
        u:Utility
        if !utility_init(&u,{max_actions=hostile_int(&h,3)==0?hostile_count(&h):1+hostile_int(&h,8),max_considerations=hostile_int(&h,3)==0?hostile_count(&h):hostile_int(&h,20)}) {
            utility_destroy(&u)
            continue
        }
        rng:=math.rng_make(hostile_next(&h))
        for _ in 0..<20 {
            clear(&considerations)
            for _ in 0..<hostile_int(&h,5) {append(&considerations,Consideration{input=u16(hostile_int(&h,hostile_int(&h,8)==0?70000:6)),min=hostile_f32(&h),max=hostile_f32(&h),response=hostile_response(&h)})}
            _=utility_add_action(&u,u32(hostile_next(&h)),hostile_f32(&h),considerations[:])
            resize(&inputs,hostile_int(&h,6))
            for &x in inputs {x=hostile_f32(&h)}
            resize(&scores,hostile_int(&h,10))
            _=utility_score(&u,hostile_int(&h,12)-2,inputs[:])
            _=utility_scores(&u,inputs[:],scores[:])
            _,_,_=utility_select(&u,inputs[:])
            _,_=utility_pick(&u,inputs[:],scores[:],&rng)
            _=response_evaluate(hostile_response(&h),hostile_f32(&h))
        }
        utility_destroy(&u)
    }
}

@(test)
hostile_calls_through_an_empty_utility :: proc(t:^testing.T) {
    h:=Hostile{23}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        u:Utility
        rng:=math.rng_make(1)
        scores:[4]f32
        inputs:[3]f32
        _=utility_add_action(&u,1,1,nil)
        _=utility_add_action(&u,1,1,[]Consideration{{}})
        _=utility_score(&u,hostile_int(&h,5)-2,inputs[:])
        _=utility_scores(&u,inputs[:],scores[:])
        _,_,_=utility_select(&u,inputs[:])
        _,_=utility_pick(&u,inputs[:],scores[:],&rng)
        utility_destroy(&u)
        _=utility_init(&u,{max_actions=0})
        _=utility_init(&u,{max_actions=1,max_considerations=-1})
        utility_destroy(&u)
    }
}

@(test)
hostile_nil_rng_through_the_wander :: proc(t:^testing.T) {
    displacement:math.Vec3
    _=wander(&displacement,math.Vec3{1,0,0},1,1,1,1,nil)
}

@(test)
hostile_nil_rng_through_the_utility_pick :: proc(t:^testing.T) {
    u:Utility
    _=utility_init(&u,{max_actions=2})
    defer utility_destroy(&u)
    _=utility_add_action(&u,1,1,nil)
    scores:[2]f32
    _,_=utility_pick(&u,nil,scores[:],nil)
}

@(test)
hostile_unallocatable_sizes_through_the_inits :: proc(t:^testing.T) {
    size:=1<<44
    s:Search
    testing.expect(t,!search_init(&s,{nodes=size}))
    testing.expect(t,!search_init(&s,{nodes=4,open=size}))
    testing.expect(t,!search_init(&s,{nodes=4,max_edges=size}))
    o:Open_Set
    testing.expect(t,!open_init(&o,size,4))
    testing.expect(t,!open_init(&o,4,size))
    g:Grid
    testing.expect(t,!grid_init(&g,size,1))
    f:Flow_Field
    testing.expect(t,!flow_field_init(&f,size,1))
    u:Utility
    testing.expect(t,!utility_init(&u,{max_actions=size}))
    testing.expect(t,!utility_init(&u,{max_actions=1,max_considerations=size}))
    m:Nav_Mesh
    testing.expect(t,!nav_mesh_init(&m,{tile_width=1,max_tiles=size}))
    q:Nav_Query
    testing.expect(t,!nav_query_init(&q,size))
}

// Mostly small valid configs, now and then a wild value.
@(private="file")
hostile_nav_config :: proc "contextless" (h:^Hostile) -> Nav_Build_Config {
    pick :: proc "contextless" (h:^Hostile,tame:f32) -> f32 {return hostile_f32(h) if hostile_int(h,64)==0 else tame}
    count :: proc "contextless" (h:^Hostile,tame:int) -> i32 {return i32(hostile_int(h,1<<20)-(1<<19)) if hostile_int(h,64)==0 else i32(tame)}
    sizes:=[6]i32{-1,0,NAV_BUILD_MAX_CELLS,max(i32),min(i32),150}
    return {
        origin={pick(h,f32(hostile_int(h,9)-4)),pick(h,0),pick(h,f32(hostile_int(h,9)-4))},
        tile_size=sizes[hostile_int(h,6)] if hostile_int(h,32)==0 else i32(1+hostile_int(h,40)),
        cell_size=pick(h,0.1+f32(hostile_int(h,10))*0.05),
        cell_height=pick(h,0.05+f32(hostile_int(h,6))*0.05),
        agent_radius=pick(h,f32(hostile_int(h,8))*0.1),
        agent_height=pick(h,0.25+f32(hostile_int(h,8))*0.25),
        agent_climb=pick(h,f32(hostile_int(h,6))*0.1),
        agent_max_slope=pick(h,f32(hostile_int(h,16))*0.1),
        min_region_area=count(h,hostile_int(h,20)),
        merge_region_area=count(h,hostile_int(h,40)),
        max_edge_length=pick(h,f32(hostile_int(h,8))*0.5),
        max_edge_error=pick(h,f32(hostile_int(h,8))*0.1),
        detail_sample_distance=pick(h,f32(hostile_int(h,8))*0.25),
        detail_max_error=pick(h,f32(hostile_int(h,6))*0.05),
    }
}

@(private="file")
hostile_nav_quad :: proc(vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,a,b,c,d:math.Vec3) {
    first:=u32(len(vertices))
    append(vertices,a,b,c,d)
    append(indices,first,first+1,first+2,first,first+2,first+3)
}

// Boxes, floors, ramps and loose triangles over the tile, with coordinates
// that are sometimes wild, indices that are sometimes broken, areas of any
// length and volumes of any shape.
@(private="file")
hostile_nav_input :: proc(h:^Hostile,vertices:^[dynamic]math.Vec3,indices:^[dynamic]u32,areas:^[dynamic]u8,volumes:^[dynamic]Nav_Area_Volume) -> Nav_Build_Input {
    clear(vertices);clear(indices);clear(areas);clear(volumes)
    wild:=hostile_int(h,6)==0
    point :: proc "contextless" (h:^Hostile,wild:bool) -> math.Vec3 {
        if wild && hostile_int(h,4)==0 {return hostile_vec3(h,true)}
        p:=hostile_vec3(h,false)
        return {p.x+3,p.y*0.3,p.z+3}
    }
    count:=hostile_int(h,200) if hostile_int(h,8)==0 else hostile_int(h,16)
    for _ in 0..<count {
        p,q:=point(h,wild),point(h,wild)
        low,high:=math.vec3_min(p,q),math.vec3_max(p,q)
        switch hostile_int(h,4) {
        case 0:
            first:=u32(len(vertices))
            append(vertices,p,q,point(h,wild))
            append(indices,first,first+1,first+2)
        case 1:
            hostile_nav_quad(vertices,indices,{low.x,high.y,low.z},{low.x,high.y,high.z},{high.x,high.y,high.z},{high.x,high.y,low.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,low.z},{low.x,high.y,low.z},{high.x,high.y,low.z},{high.x,low.y,low.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,high.z},{high.x,low.y,high.z},{high.x,high.y,high.z},{low.x,high.y,high.z})
            hostile_nav_quad(vertices,indices,{low.x,low.y,low.z},{low.x,low.y,high.z},{low.x,high.y,high.z},{low.x,high.y,low.z})
            hostile_nav_quad(vertices,indices,{high.x,low.y,low.z},{high.x,high.y,low.z},{high.x,high.y,high.z},{high.x,low.y,high.z})
        case 2:
            hostile_nav_quad(vertices,indices,{p.x-4,p.y,p.z-4},{p.x-4,p.y,p.z+4},{p.x+4,p.y,p.z+4},{p.x+4,p.y,p.z-4})
        case 3:
            hostile_nav_quad(vertices,indices,{p.x,p.y,p.z},{p.x,p.y,q.z},{q.x,q.y,q.z},{q.x,q.y,p.z})
        }
    }
    if hostile_int(h,4)==0 {
        for _ in 0..<len(indices)/3 {append(areas,u8(hostile_int(h,4)))}
    }
    ring_x:=[8]f32{1,0.7,0,-0.7,-1,-0.7,0,0.7}
    ring_z:=[8]f32{0,0.7,1,0.7,0,-0.7,-1,-0.7}
    for _ in 0..<hostile_int(h,4) {
        v:Nav_Area_Volume
        v.count=u8(hostile_int(h,9))
        center:=hostile_vec2(h,false)+{3,3}
        for k in 0..<8 {
            radius:=f32(hostile_int(h,5)+1)
            v.points[k]=hostile_vec2(h,true) if wild && hostile_int(h,6)==0 else center+{ring_x[k],ring_z[k]}*radius
        }
        v.area=u8(hostile_int(h,4))
        v.min_y=hostile_f32(h) if wild else f32(hostile_int(h,5))-2
        v.max_y=hostile_f32(h) if wild else v.min_y+f32(hostile_int(h,4))
        append(volumes,v)
    }
    // One broken value now and then.
    switch hostile_int(h,48) {
    case 0: if len(indices)>0 {pop(indices)}
    case 1: append(indices,u32(len(vertices)+hostile_int(h,3)))
    case 2: if len(areas)>0 {pop(areas)} else {append(areas,1)}
    case 3: if len(areas)>0 {areas[hostile_int(h,len(areas))]=NAV_AREA_MAX+1}
    case 4: if len(volumes)>0 {volumes[0].count=9+u8(hostile_int(h,200))}
    case 5: if len(volumes)>0 {volumes[0].area=NAV_AREA_MAX+1+u8(hostile_int(h,100))}
    }
    return {vertices=vertices[:],indices=indices[:],triangle_areas=areas[:],volumes=volumes[:]}
}

@(private="file")
hostile_nav_tile_holds :: proc(t:^testing.T,data:^Nav_Tile_Data) {
    for p,i in data.polys {
        if !testing.expect(t,p.count>=3 && int(p.count)<=NAV_VERTS_PER_POLY,"polygon size") {return}
        for k in 0..<int(p.count) {
            testing.expect(t,int(p.vertices[k])<len(data.vertices),"vertex out of range")
            n:=p.neighbor[k]
            testing.expect(t,n==NAV_EDGE_WALL || n&NAV_EDGE_PORTAL!=0 && n&~NAV_EDGE_PORTAL<4 || int(n)-1<len(data.polys),"neighbor out of range")
        }
        d:=data.details[i]
        if !testing.expect(t,int(d.triangle_first)+int(d.triangle_count)<=len(data.detail_triangles) && int(d.vertex_first)+int(d.vertex_count)<=len(data.detail_vertices),"detail out of range") {return}
        for tri in data.detail_triangles[d.triangle_first:][:d.triangle_count] {
            testing.expect(t,int(max(tri[0],tri[1],tri[2]))<int(p.count)+int(d.vertex_count),"detail triangle out of range")
        }
    }
    testing.expect(t,len(data.bv)==2*len(data.polys)-1,"tree size")
}

@(test)
hostile_triangles_through_the_tile_build :: proc(t:^testing.T) {
    h:=Hostile{24}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    areas:[dynamic]u8
    volumes:[dynamic]Nav_Area_Volume
    defer {delete(vertices);delete(indices);delete(areas);delete(volumes)}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    coords:=[5][2]i32{{0,0},{1,0},{-1,-1},{max(i32),min(i32)},{min(i32),3}}
    for _ in 0..<HOSTILE_ROUNDS {
        config:=hostile_nav_config(&h)
        input:=hostile_nav_input(&h,&vertices,&indices,&areas,&volumes)
        coord:=coords[hostile_int(&h,5)] if hostile_int(&h,8)==0 else [2]i32{}
        data:Nav_Tile_Data
        if nav_build_tile(config,coord,input,&scratch,&data)==.Built {hostile_nav_tile_holds(t,&data)}
        nav_tile_data_free(&data)
        _=nav_tile_rect(config,coord)
        _=nav_build_margin(config)
    }
}

// More floors in a column than a link names, heights beyond the span range
// and the largest heightfield.
@(test)
hostile_extreme_tiles_through_the_tile_build :: proc(t:^testing.T) {
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    defer {delete(vertices);delete(indices)}
    scratch:Nav_Build_Scratch
    nav_build_scratch_init(&scratch)
    defer nav_build_scratch_destroy(&scratch)
    config:=Nav_Build_Config{tile_size=24,cell_size=0.25,cell_height=0.05,agent_radius=0.25,agent_height=0.2,agent_climb=0.1,agent_max_slope=0.7,min_region_area=4,merge_region_area=10,max_edge_length=2,max_edge_error=0.3,detail_sample_distance=1,detail_max_error=0.05}
    for k in 0..<100 {hostile_nav_quad(&vertices,&indices,{-2,f32(k)*0.3,-2},{-2,f32(k)*0.3,8},{8,f32(k)*0.3,8},{8,f32(k)*0.3,-2})}
    hostile_nav_quad(&vertices,&indices,{-2,1e4,-2},{-2,1e4,8},{8,1e4,8},{8,1e4,-2})
    hostile_nav_quad(&vertices,&indices,{-2,-3e4,-2},{-2,-3e4,8},{8,-3e4,8},{8,-3e4,-2})
    data:Nav_Tile_Data
    if nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data)==.Built {hostile_nav_tile_holds(t,&data)}
    nav_tile_data_free(&data)
    clear(&vertices);clear(&indices)
    hostile_nav_quad(&vertices,&indices,{1,0,1},{1,0,9},{9,0,9},{9,0,1})
    config.cell_size=1
    config.tile_size=NAV_BUILD_MAX_CELLS-2*(1+3)
    if testing.expect_value(t,nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data),Nav_Build_Status.Built) {
        hostile_nav_tile_holds(t,&data)
    }
    nav_tile_data_free(&data)
    config.tile_size+=1
    testing.expect_value(t,nav_build_tile(config,{},{vertices=vertices[:],indices=indices[:]},&scratch,&data),Nav_Build_Status.Invalid)
}

@(test)
hostile_scratch_and_tiles_through_the_tile_build :: proc(t:^testing.T) {
    h:=Hostile{25}
    vertices:[dynamic]math.Vec3
    indices:[dynamic]u32
    areas:[dynamic]u8
    volumes:[dynamic]Nav_Area_Volume
    defer {delete(vertices);delete(indices);delete(areas);delete(volumes)}
    for _ in 0..<HOSTILE_ROUNDS/8 {
        input:=hostile_nav_input(&h,&vertices,&indices,&areas,&volumes)
        scratch:Nav_Build_Scratch
        data:Nav_Tile_Data
        _=nav_build_tile(hostile_nav_config(&h),{},input,&scratch,&data)
        _=nav_build_tile(hostile_nav_config(&h),{},input,nil,&data)
        _=nav_build_tile(hostile_nav_config(&h),{},input,&scratch,nil)
        nav_build_scratch_init(&scratch,runtime.nil_allocator() if hostile_int(&h,2)==0 else context.allocator)
        failing:=runtime.nil_allocator() if hostile_int(&h,3)==0 else context.allocator
        _=nav_build_tile(hostile_nav_config(&h),{},input,&scratch,&data,failing)
        nav_tile_data_free(&data)
        nav_build_scratch_destroy(&scratch)
        nav_build_scratch_destroy(&scratch)
        nav_tile_data_free(&data)
    }
}

@(test)
hostile_memories_and_places :: proc(t:^testing.T) {
    h:=Hostile{31}
    for _ in 0..<HOSTILE_ROUNDS {
        m:Perception_Memory
        if hostile_int(&h,6)==0 {m.count=i32(hostile_next(&h))}
        gone:[4]u64
        for _ in 0..<24 {
            switch hostile_int(&h,4) {
            case 0,1: _=memory_perceive(&m,u64(hostile_int(&h,20)),hostile_vec3(&h,true),Sense(hostile_int(&h,3)),hostile_f32(&h),f64(hostile_f32(&h)))
            case 2: _=memory_forget(&m,f64(hostile_f32(&h)),hostile_f32(&h),gone[:hostile_int(&h,5)])
            case 3:
                _=memory_find(&m,u64(hostile_int(&h,20)))
                _,_=memory_best(&m,hostile_vec3(&h,true))
            }
        }
        _=sight_in_cone(hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_vec3(&h,true),hostile_f32(&h),hostile_f32(&h))
        points:[32]math.Vec3
        _=places_rings(hostile_vec3(&h,true),hostile_f32(&h),hostile_f32(&h),hostile_int(&h,6)-1,hostile_int(&h,40)-1,points[:hostile_int(&h,33)])
        _=places_grid(hostile_vec3(&h,true),hostile_f32(&h),hostile_f32(&h),points[:hostile_int(&h,33)])
        inputs:[12]f32
        for &x in inputs {x=hostile_f32(&h)}
        considerations:=[2]Consideration{{input=u16(hostile_int(&h,20)),min=hostile_f32(&h),max=hostile_f32(&h),response={kind=Response_Kind(hostile_int(&h,4)),slope=hostile_f32(&h)}},{}}
        best:[4]Place_Score
        _=places_best(considerations[:hostile_int(&h,3)],inputs[:hostile_int(&h,13)],hostile_int(&h,5)-1,best[:hostile_int(&h,5)])
    }
}
