package terrain_editor

import "core:testing"
import "mirai:core"
import "mirai:editor"
import phys "plugins:physics/runtime"
import sim "plugins:physics/runtime/sim"
import terrain "plugins:terrain/runtime"
import "mirai:std/base"

@(private)
Budget_World :: struct {
    entities:core.Entities,
    terrains:core.Table(terrain.Terrain),
    data:terrain.Terrain_Data,
    settings:terrain.Terrain_Settings,
    physics:phys.Physics_State,
    tables:[1]core.Table_Info,
    storages:[3]core.Storage_Info,
    info:core.World_Info,
}

@(private)
budget_world_init :: proc(w:^Budget_World) {
    core.entities_init(&w.entities);core.table_init(&w.terrains,"Terrain")
    w.tables={{type=terrain.Terrain,info=type_info_of(terrain.Terrain),offset=offset_of(Budget_World,terrains)}}
    w.storages={
        {type=terrain.Terrain_Data,info=type_info_of(terrain.Terrain_Data),offset=offset_of(Budget_World,data)},
        {type=terrain.Terrain_Settings,info=type_info_of(terrain.Terrain_Settings),offset=offset_of(Budget_World,settings)},
        {type=phys.Physics_State,info=type_info_of(phys.Physics_State),offset=offset_of(Budget_World,physics)},
    }
    w.info={entities=offset_of(Budget_World,entities),tables=w.tables[:],storages=w.storages[:]}
    w.data.entries=make([dynamic]terrain.Data_Source)
}

@(private)
budget_world_destroy :: proc(w:^Budget_World) {
    terrain.terrain_data_free(&w.data);phys.state_destroy(&w.physics)
    core.table_destroy(&w.terrains);core.entities_destroy(&w.entities)
}

@(test)
terrain_editor_budget_counts_sources_chunks_and_replacement_without_double_charging :: proc(t:^testing.T) {
    w:Budget_World;budget_world_init(&w);defer budget_world_destroy(&w)
    // A Heightfield costs the samples of its pages that hold their own values.
    w.settings={sources=2,chunks=8,samples=13000}
    ids:=[2]base.Asset_Id{{11,12},{13,14}}
    for id in ids {
        entry:=terrain.Data_Source{id=id,versions=make([]u32,1)}
        testing.expect(t,terrain.source_make(&entry.source,.Heightfield,{5,1,5},1,4))
        testing.expect(t,terrain.source_set(&entry.source,{1,0,1},1))
        append(&w.data.entries,entry)
    }
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,terrain.source_make(&source,.Heightfield,{9,1,9},1,4))
    testing.expect_value(t,terrain.source_cost(&source),0)
    testing.expect(t,terrain.source_set(&source,{1,0,1},1))
    // Each page holds its samples: those of its source of 5 by 5, those of 9 by 9.
    page,cost:=terrain.source_cost(&w.data.entries[0].source),terrain.source_cost(&source)
    testing.expect(t,page==25 && cost==81)
    session:editor.Session
    world:=core.world_ref(&w,&w.info)
    testing.expect_value(t,terrain_vertex_budget(world,{}),13000-2*page)
    testing.expect_value(t,terrain_vertex_budget(world,ids[0]),13000-page)
    testing.expect(t,!terrain_budget(&session,world,&source))
    testing.expect(t,terrain_budget(&session,world,&source,ids[0]))
    w.settings.sources=3
    testing.expect(t,terrain_budget(&session,world,&source))
    w.settings.samples=u32(2*page+cost-1)
    testing.expect(t,!terrain_budget(&session,world,&source))
    testing.expect(t,terrain_budget(&session,world,&source,ids[0]))
    w.data.ready=true;w.data.settings={sources=8,chunks=64,samples=20000}
    testing.expect_value(t,terrain_vertex_budget(world,{}),20000-2*page)
    testing.expect(t,terrain_budget(&session,world,&source))
}

@(test)
terrain_editor_budget_leaves_chunks_and_colliders_of_a_heightfield_to_the_runtime :: proc(t:^testing.T) {
    w:Budget_World;budget_world_init(&w);defer budget_world_destroy(&w)
    testing.expect(t,sim.world_init(&w.physics.world,{body_capacity=4,shape_capacity=4,contact_capacity=4,joint_capacity=1,character_capacity=1,hull_capacity=1,mesh_capacity=1,heightfield_capacity=16}))
    w.physics.ready=true
    w.settings.chunks=64
    source:terrain.Source;defer terrain.source_destroy(&source)
    testing.expect(t,terrain.source_make(&source,.Heightfield,{1025,1,1025},1,64))
    world:=core.world_ref(&w,&w.info)
    session:editor.Session
    testing.expect(t,terrain_budget(&session,world,&source),"256 chunks show as nodes past 64 pieces, and the nearest take the 16 heightfields")
    // A Volume has no nodes to show in place of its chunks.
    volume:terrain.Source;defer terrain.source_destroy(&volume)
    testing.expect(t,terrain.source_make(&volume,.Volume,{65,65,65},1,8))
    testing.expect(t,!terrain_budget(&session,world,&volume),"512 chunks of a Volume pass 64")
    w.settings.resident_distance=100
    testing.expect(t,terrain_budget(&session,world,&volume),"a streamed Volume keeps its nearest")
}
