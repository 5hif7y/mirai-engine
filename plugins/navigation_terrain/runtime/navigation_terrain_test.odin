package navigation_terrain

import "core:testing"
import "mirai:core"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"
import terrain "plugins:terrain/runtime"

// A heightfield of 4 by 4 chunks of 16 m: the first row has its colliders
// but for one chunk, the second shows one chunk empty, the rest is not loaded.
@(test)
the_chunks_of_a_terrain_without_collider_are_unloaded_for_navigation :: proc(t:^testing.T) {
    entities:core.Entities
    core.entities_init(&entities)
    defer core.entities_destroy(&entities)
    colliders:core.Table(phys.Collider);core.table_init(&colliders,"Collider");defer core.table_destroy(&colliders)
    terrains:core.Table(terrain.Terrain);core.table_init(&terrains,"Terrain");defer core.table_destroy(&terrains)
    worlds:core.Table(core.World_Transform);core.table_init(&worlds,"World_Transform");defer core.table_destroy(&worlds)
    data:terrain.Terrain_Data
    entry:=terrain.Data_Source{id={3,3}}
    testing.expect(t,terrain.source_make(&entry.source,.Heightfield,{65,1,65},1,16))
    append(&data.entries,entry)
    defer {terrain.source_destroy(&data.entries[0].source);delete(data.entries)}
    hill:=core.create(&entities)
    core.add(&terrains,hill,terrain.Terrain{source={3,3},solid=true})
    core.add(&worlds,hill,core.World_Transform{transform={rotation=1,scale={1,1,1}}})
    resident:terrain.Terrain_Resident
    shown:=make([]terrain.Resident_Chunk,16);defer delete(shown)
    chunks:=make([]core.Entity,16);defer delete(chunks)
    append(&resident.sources,terrain.Resident_Source{id={3,3},owner=hill,chunks=shown})
    append(&resident.owners,terrain.Resident_Owner{entity=hill,source={3,3},chunks=chunks,solid=true})
    defer {delete(resident.sources);delete(resident.owners)}
    for x in 0..<4 {
        if x==2 {continue}
        chunks[x]=core.create(&entities)
        core.add(&colliders,chunks[x],phys.Collider{kind=.Heightfield})
        shown[x].shown=true
    }
    shown[5].shown=true
    core.table_settle(&colliders,&entities);core.table_settle(&terrains,&entities);core.table_settle(&worlds,&entities)
    state:Navigation_Terrain
    unloaded:nav.Nav_Unloaded
    defer nav.nav_unloaded_free(&unloaded)
    step :: proc(state:^Navigation_Terrain,unloaded:^nav.Nav_Unloaded,resident:^terrain.Terrain_Resident,data:^terrain.Terrain_Data,terrains:^core.Table(terrain.Terrain),colliders:^core.Table(phys.Collider),worlds:^core.Table(core.World_Transform)) {
        navigation_terrain_unloaded(state,unloaded,core.ref(resident),core.ref(data),core.read(terrains),core.read(colliders),core.read(worlds))
    }
    step(&state,&unloaded,&resident,&data,&terrains,&colliders,&worlds)
    // Row 0: chunk 2. Row 1: chunk 4, and 6 to 7. Rows 2 and 3: one run each.
    testing.expect_value(t,len(unloaded.boxes),5)
    revision:=unloaded.revision
    testing.expect(t,revision>0)
    for box in unloaded.boxes {
        testing.expect(t,box.min.y<=-1e3 && box.max.y>=1e3)
        // The loaded chunks, from -32 to -16 m and -16 to 0 m along x on the first row, are left out.
        testing.expect(t,!(box.max.z<=-16 && box.min.x< -16+1e-3 && box.max.x> -32+1e-3 && box.max.x<= -16+1e-3))
    }
    step(&state,&unloaded,&resident,&data,&terrains,&colliders,&worlds)
    testing.expect_value(t,unloaded.revision,revision)
    // Chunk 2 loads: one box fewer.
    chunks[2]=core.create(&entities)
    core.add(&colliders,chunks[2],phys.Collider{kind=.Heightfield})
    core.table_settle(&colliders,&entities)
    step(&state,&unloaded,&resident,&data,&terrains,&colliders,&worlds)
    testing.expect_value(t,len(unloaded.boxes),4)
    testing.expect(t,unloaded.revision>revision)
}
