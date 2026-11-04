package ai

import cmath "core:math"
import "core:testing"
import "mirai:std/base"
import math "mirai:std/math"

field_for :: proc(t:^testing.T,g:^Grid) -> Flow_Field {
    f:Flow_Field
    testing.expect(t,flow_field_init(&f,g.width,g.height))
    return f
}

@(test)
flow_field_integrates_the_cost_to_the_goal :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,6,4))
    defer grid_destroy(&g)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    testing.expect_value(t,flow_field_build(&f,&g,{{0,0}},.Four),Search_Status.Found)
    testing.expect(t,near(flow_field_cost(&f,{0,0}),0) && near(flow_field_cost(&f,{5,3}),8) && near(flow_field_cost(&f,{2,0}),2))
    testing.expect(t,flow_field_direction(&f,{0,0})==math.Vec2{})
    testing.expect(t,near_vec(flow_field_direction(&f,{4,0}),math.Vec2{-1,0}))
    testing.expect_value(t,flow_field_build(&f,&g,{{0,0}},.Eight),Search_Status.Found)
    testing.expect(t,near(flow_field_cost(&f,{3,3}),3*SQRT2) && near(flow_field_cost(&f,{5,1}),SQRT2+4))
    d:=flow_field_direction(&f,{3,3})
    testing.expect(t,near_vec(d,math.Vec2{-0.70710678,-0.70710678}))
}

@(test)
flow_field_follows_the_cheapest_nearest_goal_around_walls :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,7,5))
    defer grid_destroy(&g)
    grid_fill(&g,{3,0},{3,3},0)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    testing.expect_value(t,flow_field_build(&f,&g,{{5,0},{0,4}},.Four),Search_Status.Found)
    testing.expect(t,near(flow_field_cost(&f,{4,0}),1) && near(flow_field_cost(&f,{1,4}),1))
    testing.expect(t,!(flow_field_cost(&f,{3,1})<INFINITY))
    testing.expect(t,flow_field_direction(&f,{3,1})==math.Vec2{})
    testing.expect(t,flow_field_direction(&f,{99,1})==math.Vec2{} && flow_field_cost(&f,{-1,0})>=INFINITY)
}

@(test)
flow_field_agents_reach_a_goal_following_directions :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,20,20))
    defer grid_destroy(&g)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    rng:=base.rng_make(11)
    for hood in Neighborhood {
        for &cost in g.cost {
            roll:=math.random_below(&rng,10)
            cost=0 if roll<2 else u8(1+roll%3)
        }
        grid_set(&g,{10,10},1)
        flow_field_build(&f,&g,{{10,10}},hood)
        for index in 0..<len(g.cost) {
            cell:=grid_cell(&g,index)
            if flow_field_cost(&f,cell)>=INFINITY {continue}
            for _ in 0..<400 {
                if cell==(Cell{10,10}) {break}
                d:=flow_field_direction(&f,cell)
                next:=cell+Cell{i32(cmath.round(d.x)),i32(cmath.round(d.y))}
                testing.expect(t,flow_field_cost(&f,next)<flow_field_cost(&f,cell))
                cell=next
            }
            testing.expectf(t,cell==(Cell{10,10}),"cell %v did not arrive",grid_cell(&g,index))
        }
    }
}

@(test)
flow_field_weighs_cells_and_does_not_cut_corners :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,5,3))
    defer grid_destroy(&g)
    grid_fill(&g,{2,0},{2,1},5)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    flow_field_build(&f,&g,{{4,1}},.Four)
    testing.expect(t,flow_field_direction(&f,{1,1}).y>0.5) // goes around the heavy column through the free row
    grid_set(&g,{1,0},0)
    flow_field_build(&f,&g,{{1,1}},.Eight)
    d:=flow_field_direction(&f,{0,0}) // the diagonal toward (1,1) would graze the wall at (1,0)
    testing.expect(t,near_vec(d,math.Vec2{0,1}))
}

@(test)
flow_field_samples_smoothly_between_cells :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,4,4))
    defer grid_destroy(&g)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    flow_field_build(&f,&g,{{0,0}},.Four)
    at_center:=flow_field_sample(&f,{3,0})
    testing.expect(t,near_vec(at_center,math.Vec2{-1,0}))
    between:=flow_field_sample(&f,{2.5,2})
    testing.expect(t,near(between.x*between.x+between.y*between.y,1,1e-3))
    testing.expect(t,between.x<-0.5)
    diagonal:=flow_field_sample(&f,{0.5,2.5})
    testing.expect(t,diagonal.x<0 && diagonal.y<0 && near(diagonal.x*diagonal.x+diagonal.y*diagonal.y,1,1e-3))
    testing.expect(t,flow_field_sample(&f,{-9,-9})==math.Vec2{})
}

@(test)
flow_field_rejects_bad_goals_and_mismatched_grids :: proc(t:^testing.T) {
    g:Grid
    testing.expect(t,grid_init(&g,4,4))
    defer grid_destroy(&g)
    f:=field_for(t,&g)
    defer flow_field_destroy(&f)
    grid_set(&g,{1,1},0)
    testing.expect_value(t,flow_field_build(&f,&g,{{1,1},{9,9}},.Four),Search_Status.Invalid)
    testing.expect_value(t,flow_field_build(&f,&g,nil,.Four),Search_Status.Invalid)
    testing.expect(t,flow_field_cost(&f,{0,0})>=INFINITY)
    other:Grid
    testing.expect(t,grid_init(&other,5,4))
    defer grid_destroy(&other)
    testing.expect_value(t,flow_field_build(&f,&other,{{0,0}},.Four),Search_Status.Invalid)
    zero:Flow_Field
    testing.expect_value(t,flow_field_build(&zero,&g,{{0,0}},.Four),Search_Status.Invalid)
    testing.expect(t,!flow_field_init(&zero,0,3))
    testing.expect(t,flow_field_direction(&zero,{0,0})==math.Vec2{})
}
