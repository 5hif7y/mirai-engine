package terrain_editor

import "core:testing"
import "mirai:core"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(test)
a_preview_shows_the_level_of_its_chunk_and_a_hole_joins_its_neighbors_at_level_0 :: proc(t:^testing.T) {
    world:Create_Test_World
    create_test_world_init(&world);defer create_test_world_destroy(&world)
    chunks:core.Table(terrain.Terrain_Chunk);core.table_init(&chunks,"Terrain_Chunk");defer core.table_destroy(&chunks)
    tool:Terrain_Tool;defer terrain_tool_free(&tool)
    stroke:=&tool.stroke
    s:=&stroke.source
    if !testing.expect(t,terrain.source_make(s,.Heightfield,{69,1,69},0.5,16)) {return}
    stroke.id=base.Asset_Id{7,8}
    counts:=terrain.chunk_counts(s)
    total:=counts.x*counts.y*counts.z
    resize(&stroke.preview_at,total)
    for &slot in stroke.preview_at {slot=-1}
    owner:=core.create(&world.entities)
    core.add(&world.terrains,owner,terrain.Terrain{source=stroke.id,revision=1})
    // What the runtime shows: the middle chunk and the one east of it at level 2, the one west at 0, the rest at 1.
    levels:=make([]u8,total,context.temp_allocator)
    for &level in levels {level=1}
    levels[terrain.chunk_index(s,{2,0,2})]=2
    levels[terrain.chunk_index(s,{3,0,2})]=2
    levels[terrain.chunk_index(s,{1,0,2})]=0
    shown:=make([]terrain.Chunk_Lod,total,context.temp_allocator)
    for index in 0..<total {
        coord:=terrain.chunk_coord(s,index)
        shown[index]=terrain.chunk_lod_sides(s,levels,coord)
        e:=core.create(&world.entities)
        core.add(&chunks,e,terrain.Terrain_Chunk{owner=owner,coord=coord,revision=1,lod=shown[index]})
    }
    core.table_settle(&world.terrains,&world.entities);core.table_settle(&chunks,&world.entities)
    preview_of :: proc(stroke:^Stroke,coord:[3]i32) -> (Preview,bool) {
        at:=preview_find(stroke,coord)
        if at<0 {return {},false}
        return stroke.previews[at],true
    }

    // A stroke on a chunk at level 2 previews it at level 2, with the sides its neighbors show.
    raise:=terrain.source_edit(s,{kind=.Raise,center={11,0,3},radius=1,amount=0.5})
    if !testing.expect(t,raise.changed) {return}
    stroke_changed(stroke,raise)
    preview_levels(stroke,core.read(&world.terrains),core.read(&chunks))
    east,found:=preview_of(stroke,{3,0,2})
    testing.expect(t,found && east.dirty)
    testing.expect_value(t,east.lod,shown[terrain.chunk_index(s,{3,0,2})])
    testing.expect_value(t,east.lod.level,u8(2))
    testing.expect_value(t,len(stroke.previews),1)

    // A hole puts its chunk at level 0, and each neighbor whose side toward it was coarser is previewed with that side at 0.
    hole:=terrain.source_edit(s,{kind=.Hole,center={3,0,3},radius=1})
    if !testing.expect(t,hole.changed) {return}
    stroke_changed(stroke,hole)
    preview_levels(stroke,core.read(&world.terrains),core.read(&chunks))
    middle,has_middle:=preview_of(stroke,{2,0,2})
    testing.expect(t,has_middle)
    testing.expect_value(t,middle.lod,terrain.Chunk_Lod{})
    east,_=preview_of(stroke,{3,0,2})
    testing.expect_value(t,east.lod.level,u8(2))
    testing.expect_value(t,east.lod.faces[0],u8(0))
    north,has_north:=preview_of(stroke,{2,0,1})
    testing.expect(t,has_north && north.dirty)
    testing.expect_value(t,north.lod.level,u8(1))
    testing.expect_value(t,north.lod.faces[5],u8(0))
    south,has_south:=preview_of(stroke,{2,0,3})
    testing.expect(t,has_south && south.lod.faces[4]==0)
    // The chunk west of it was at level 0 already: its side does not change.
    _,has_west:=preview_of(stroke,{1,0,2})
    testing.expect(t,!has_west)
    _,far:=preview_of(stroke,{0,0,0})
    testing.expect(t,!far)
}
