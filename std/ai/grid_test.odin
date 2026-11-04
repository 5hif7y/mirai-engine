package ai

import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

grid_and_search :: proc(t:^testing.T,width,height:int) -> (Grid,Search) {
    g:Grid
    s:Search
    testing.expect(t,grid_init(&g,width,height))
    testing.expect(t,search_init(&s,{nodes=width*height,max_edges=8}))
    return g,s
}
grid_free :: proc(g:^Grid,s:^Search) {
    grid_destroy(g)
    search_destroy(s)
}

@(test)
grid_stores_costs_and_clips_to_its_bounds :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,4,3,2))
    defer grid_destroy(&g)
    testing.expect_value(t,grid_cost(&g,{3,2}),u8(2))
    testing.expect(t,grid_set(&g,{1,1},0) && !grid_passable(&g,{1,1}))
    testing.expect(t,!grid_set(&g,{4,0},1) && !grid_set(&g,{0,-1},1))
    testing.expect(t,grid_cost(&g,{-1,0})==0 && grid_cost(&g,{0,3})==0)
    grid_fill(&g,{-5,-5},{1,0},7)
    testing.expect(t,grid_cost(&g,{0,0})==7 && grid_cost(&g,{1,0})==7 && grid_cost(&g,{2,0})==2)
    grid_fill(&g,{2,1},{50,50},0)
    testing.expect(t,!grid_passable(&g,{3,2}) && grid_passable(&g,{1,2}))
    testing.expect_value(t,grid_cell(&g,grid_index(&g,{3,1})),Cell{3,1})
    bad:Grid
    testing.expect(t,!grid_init(&bad,0,3) && !grid_init(&bad,3,-1))
}

@(test)
grid_path_with_four_neighbors_walks_the_manhattan_distance :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,8,8)
    defer grid_free(&g,&s)
    path:[64]Cell
    count,status:=grid_find_path(&s,&g,{0,0},{5,3},.Four,path[:])
    testing.expect(t,status==.Found && count==9 && near(search_cost(&s),8))
    testing.expect(t,path[0]==Cell{0,0} && path[count-1]==Cell{5,3})
    for i in 1..<count {
        d:=path[i]-path[i-1]
        testing.expect(t,abs(d.x)+abs(d.y)==1)
    }
}

@(test)
grid_path_goes_around_walls_and_reports_unreachable_goals :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,6,5)
    defer grid_free(&g,&s)
    grid_fill(&g,{2,0},{2,3},0)
    path:[30]Cell
    count,status:=grid_find_path(&s,&g,{0,0},{4,0},.Four,path[:])
    testing.expect(t,status==.Found && count==13)
    for cell in path[:count] {testing.expect(t,grid_passable(&g,cell))}
    grid_fill(&g,{2,0},{2,4},0)
    count,status=grid_find_path(&s,&g,{0,0},{4,0},.Four,path[:])
    testing.expect(t,status==.No_Path && count==0)
}

@(test)
grid_path_prefers_cheap_cells_over_a_shorter_expensive_route :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,5,3)
    defer grid_free(&g,&s)
    grid_fill(&g,{1,1},{3,1},9)
    path:[15]Cell
    count,status:=grid_find_path(&s,&g,{0,1},{4,1},.Four,path[:])
    testing.expect(t,status==.Found && near(search_cost(&s),6))
    for cell in path[:count] {testing.expect(t,cell.y!=1 || cell.x==0 || cell.x==4)}
}

@(test)
grid_path_with_eight_neighbors_cuts_diagonals_but_not_corners :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,5,5)
    defer grid_free(&g,&s)
    path:[25]Cell
    count,status:=grid_find_path(&s,&g,{0,0},{4,4},.Eight,path[:])
    testing.expect(t,status==.Found && count==5 && near(search_cost(&s),4*SQRT2))
    grid_set(&g,{1,0},0)
    count,status=grid_find_path(&s,&g,{0,0},{1,1},.Eight,path[:])
    testing.expect(t,status==.Found && count==3 && path[1]==Cell{0,1}) // the diagonal would graze the wall
    grid_set(&g,{0,1},0)
    _,status=grid_find_path(&s,&g,{0,0},{1,1},.Eight,path[:])
    testing.expect_value(t,status,Search_Status.No_Path)
}

@(test)
grid_path_rejects_walls_bounds_small_searches_and_short_outputs :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,4,4)
    defer grid_free(&g,&s)
    grid_set(&g,{3,3},0)
    path:[2]Cell
    _,status:=grid_find_path(&s,&g,{0,0},{3,3},.Four,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    _,status=grid_find_path(&s,&g,{0,0},{4,0},.Four,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    _,status=grid_find_path(&s,&g,{-1,0},{1,1},.Four,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    count,out_status:=grid_find_path(&s,&g,{0,0},{2,2},.Four,path[:])
    testing.expect(t,out_status==.Output_Full && count==0)
    small:Search
    testing.expect(t,search_init(&small,{nodes=8}))
    defer search_destroy(&small)
    _,status=grid_find_path(&small,&g,{0,0},{1,1},.Four,path[:])
    testing.expect_value(t,status,Search_Status.Invalid)
    tiny:Search
    testing.expect(t,search_init(&tiny,{nodes=16,open=2}))
    defer search_destroy(&tiny)
    big:[16]Cell
    _,status=grid_find_path(&tiny,&g,{0,0},{2,3},.Eight,big[:])
    testing.expect_value(t,status,Search_Status.Open_Full)
}

Grid_Graph :: struct {grid:^Grid,hood:Neighborhood}
grid_graph_edges :: proc(user:rawptr,node:u64,list:^Edge_List) {
    graph:=cast(^Grid_Graph)user
    steps:[8]Cell
    lengths:[8]f32
    n:=grid_steps(graph.grid,grid_cell(graph.grid,int(node)),graph.hood,&steps,&lengths)
    for i in 0..<n {edge_add(list,u64(grid_index(graph.grid,steps[i])),f32(grid_cost(graph.grid,steps[i]))*lengths[i])}
}

@(test)
grid_a_star_matches_a_search_without_heuristic_on_random_grids :: proc(t:^testing.T) {
    g,s:=grid_and_search(t,24,24)
    defer grid_free(&g,&s)
    rng:=base.rng_make(7)
    path:[24*24]Cell
    ids:[24*24]u64
    for round in 0..<30 {
        for &cost in g.cost {
            roll:=math.random_below(&rng,10)
            cost=0 if roll<2 else u8(1+roll%4)
        }
        start,goal:=Cell{i32(math.random_below(&rng,24)),i32(math.random_below(&rng,24))},Cell{i32(math.random_below(&rng,24)),i32(math.random_below(&rng,24))}
        grid_set(&g,start,1);grid_set(&g,goal,1)
        for hood in Neighborhood {
            count,status:=grid_find_path(&s,&g,start,goal,hood,path[:])
            fast:=search_cost(&s)
            graph:=Grid_Graph{&g,hood}
            _,reference:=graph_find_path(&s,{user=&graph,neighbors=grid_graph_edges},u64(grid_index(&g,start)),u64(grid_index(&g,goal)),ids[:])
            testing.expectf(t,status==reference,"round %d: %v vs %v",round,status,reference)
            if status==.Found {
                testing.expectf(t,near(fast,search_cost(&s),1e-3),"round %d: cost %f vs %f",round,fast,search_cost(&s))
                testing.expect(t,path[0]==start && path[count-1]==goal)
            }
        }
    }
}
