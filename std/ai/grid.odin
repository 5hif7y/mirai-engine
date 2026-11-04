package ai

import "base:runtime"

Cell :: [2]i32

Neighborhood :: enum u8 {Four,Eight}

// A rectangle of cells with a cost to enter each: 0 is a wall, 1 to 255 is
// the weight of walking onto it.
Grid :: struct {
    width,height:int,
    cost:[]u8,
    allocator:runtime.Allocator,
}

// False for a side that is not positive or more than max(i32) cells in all.
grid_init :: proc(g:^Grid,width,height:int,cost:u8=1,allocator:=context.allocator) -> bool {
    g^={allocator=allocator}
    if width<=0 || height<=0 || width>int(max(i32))/height {return false}
    cells,error:=make([]u8,width*height,allocator)
    if error!=nil {return false}
    for &c in cells {c=cost}
    g.width=width;g.height=height;g.cost=cells
    return true
}
grid_destroy :: proc(g:^Grid) {
    if g.allocator.procedure!=nil {delete(g.cost,g.allocator)}
    g^={}
}
grid_in_bounds :: #force_inline proc "contextless" (g:^Grid,c:Cell) -> bool {return c.x>=0 && c.y>=0 && int(c.x)<g.width && int(c.y)<g.height}
grid_index :: #force_inline proc "contextless" (g:^Grid,c:Cell) -> int {return int(c.y)*g.width+int(c.x)}
grid_cell :: #force_inline proc "contextless" (g:^Grid,index:int) -> Cell {
    if g.width<=0 {return {}}
    return {i32(index%g.width),i32(index/g.width)}
}
// The cost of a cell; walls and cells outside the grid are 0.
grid_cost :: #force_inline proc "contextless" (g:^Grid,c:Cell) -> u8 {return g.cost[grid_index(g,c)] if grid_in_bounds(g,c) else 0}
grid_passable :: #force_inline proc "contextless" (g:^Grid,c:Cell) -> bool {return grid_cost(g,c)>0}
grid_set :: proc "contextless" (g:^Grid,c:Cell,cost:u8) -> bool {
    if !grid_in_bounds(g,c) {return false}
    g.cost[grid_index(g,c)]=cost
    return true
}
// Sets every cell of the rectangle [min, max] that is inside the grid.
grid_fill :: proc "contextless" (g:^Grid,low,high:Cell,cost:u8) {
    for y in max(low.y,0)..=min(high.y,i32(g.height)-1) {
        for x in max(low.x,0)..=min(high.x,i32(g.width)-1) {g.cost[int(y)*g.width+int(x)]=cost}
    }
}

NEIGHBORS_8 :: [8]Cell{{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1}}

// The cells reachable from `c` in one step and how long each step is: 1, or
// the square root of 2 for a diagonal. The cost of a step is its length times
// the cost of the cell entered. Diagonals do not cut corners: both cells they
// pass beside must be passable.
grid_steps :: proc "contextless" (g:^Grid,c:Cell,hood:Neighborhood,steps:^[8]Cell,lengths:^[8]f32) -> int {
    count:=0
    offsets:=NEIGHBORS_8
    limit:=4 if hood==.Four else 8
    for i in 0..<limit {
        offset:=offsets[i]
        next:=c+offset
        if !grid_passable(g,next) {continue}
        length:f32=1
        if i>=4 {
            if !grid_passable(g,{c.x+offset.x,c.y}) || !grid_passable(g,{c.x,c.y+offset.y}) {continue}
            length=SQRT2
        }
        steps[count]=next;lengths[count]=length
        count+=1
    }
    return count
}

@(private)
Grid_Space :: struct {
    grid:^Grid,
    hood:Neighborhood,
}
@(private)
grid_neighbors :: proc(space:Grid_Space,node:u64,edges:^Edge_List) {
    steps:[8]Cell
    lengths:[8]f32
    n:=grid_steps(space.grid,grid_cell(space.grid,int(node)),space.hood,&steps,&lengths)
    for i in 0..<n {edge_add(edges,u64(grid_index(space.grid,steps[i])),f32(grid_cost(space.grid,steps[i]))*lengths[i])}
}
// Manhattan distance for four neighbors, octile for eight: neither exceeds the true cost, as every step costs at least 1.
@(private)
grid_heuristic :: proc(space:Grid_Space,node,goal:u64) -> f32 {
    a,b:=grid_cell(space.grid,int(node)),grid_cell(space.grid,int(goal))
    dx,dy:=f32(abs(a.x-b.x)),f32(abs(a.y-b.y))
    if space.hood==.Four {return dx+dy}
    return (dx+dy)+(SQRT2-2)*min(dx,dy)
}

// The cheapest path from start to goal over the grid, written to `out` as
// cells in order, both ends included. `s` must have at least as many nodes as
// the grid has cells and be dense. A wall or out-of-range start or goal is Invalid.
grid_find_path :: proc(s:^Search,g:^Grid,start,goal:Cell,hood:Neighborhood,out:[]Cell) -> (count:int,status:Search_Status) {
    if len(g.cost)==0 || search_keyed(s) || len(s.g)<len(g.cost) || !grid_passable(g,start) || !grid_passable(g,goal) {return 0,.Invalid}
    space:=Grid_Space{g,hood}
    status=search_run(s,u64(grid_index(g,start)),u64(grid_index(g,goal)),space,grid_neighbors,grid_heuristic)
    if status!=.Found {return 0,status}
    length,path_status:=search_path(s,s.channel)
    if path_status!=.Found || length>len(out) {return 0,.Output_Full}
    for node,i in s.channel[:length] {out[i]=grid_cell(g,int(node))}
    return length,.Found
}
