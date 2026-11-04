package physics_editor

import "mirai:editor"
import "core:testing"
import "mirai:core"
import phys "plugins:physics/runtime"
import erender "mirai:engine/render"
import "mirai:host"
import sim "plugins:physics/runtime/sim"
import "mirai:std/base"
import "mirai:std/geom"

@(private)
Collider_Hierarchy_Test_World :: struct {
    entities:core.Entities,
    state:phys.Physics_State,
    colliders:core.Table(phys.Collider),
    parents:core.Table(core.Parent),
    ids:core.Table(core.Id),
}

@(test)
selected_colliders_show_their_physics_shape_even_with_the_grid_hidden :: proc(t:^testing.T) {
    state:phys.Physics_State
    desc:=sim.world_desc_default()
    desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=8,8,16,0
    desc.hull_capacity,desc.mesh_capacity,desc.heightfield_capacity,desc.event_capacity=0,0,0,0
    desc.character_capacity=0
    testing.expect(t,sim.world_init(&state.world,desc))
    state.ready=true
    defer phys.state_destroy(&state)
    entities:core.Entities
    core.entities_init(&entities)
    defer core.entities_destroy(&entities)
    transforms:core.Table(core.Transform)
    colliders:core.Table(phys.Collider)
    parents:core.Table(core.Parent)
    rigids:core.Table(phys.Rigid_Body)
    core.table_init(&transforms,"Transform")
    core.table_init(&colliders,"Collider")
    core.table_init(&parents,"Parent")
    core.table_init(&rigids,"Rigid_Body")
    defer core.table_destroy(&transforms)
    defer core.table_destroy(&colliders)
    defer core.table_destroy(&parents)
    defer core.table_destroy(&rigids)
    owner,selected,other:=core.create(&entities),core.create(&entities),core.create(&entities)
    core.add(&rigids,owner,phys.RIGID_BODY_STATIC)
    core.add(&transforms,owner,core.Transform{position={5,0,0},rotation=1,scale={2,2,2}})
    core.add(&transforms,selected,core.Transform{position={1,2,3},rotation=1,scale={1,1,1}})
    core.add(&transforms,other,core.TRANSFORM_IDENTITY)
    core.add(&colliders,selected,phys.COLLIDER_DEFAULT)
    core.add(&colliders,other,phys.collider_sphere(2))
    core.add(&parents,selected,core.Parent{entity=owner})
    core.table_settle(&transforms,&entities)
    core.table_settle(&colliders,&entities)
    core.table_settle(&parents,&entities)
    core.table_settle(&rigids,&entities)
    characters:core.Table(phys.Character)
    moves:core.Table(phys.Character_Move)
    joints:core.Table(phys.Joint)
    statics:core.Table(erender.Mesh_Renderer)
    names:core.Table(core.Name)
    body_states:core.Table(core.Motion)
    replicas:core.Table(core.Pose_Target)
    character_states:core.Table(phys.Character_State)
    joint_states:core.Table(phys.Joint_State)
    settings:phys.Physics_Settings
    requests:phys.Body_Requests
    events:phys.Physics_Events
    defer core.value_free(&events,type_info_of(phys.Physics_Events))
    meshes:phys.Collider_Meshes
    app:host.App
    problems:core.Problems
    phys.physics_step(&state,{&settings},&requests,&events,&meshes,&app,{},
        {&rigids},{&colliders},{&characters},{&moves},&joints,{&statics},{&parents},{&names},
        &transforms,&body_states,core.read(&replicas),&character_states,&joint_states,{},nil,{},{},nil,nil,&problems,{},{},{},{},{},{})
    testing.expect_value(t,problems.count,0)
    testing.expect(t,phys.body_of({&state},selected)==phys.body_of({&state},owner))
    preview:=new(Collider_Preview)
    defer free(preview)
    storages:=[2]core.Storage_Info{
        {type=phys.Physics_State,place=.World},
        {type=Collider_Preview,place=.Editor},
    }
    info:=core.World_Info{storages=storages[:]}
    selection:editor.Selection
    defer delete(selection.entities)
    editor.selection_set(&selection,{selected})
    session:=editor.Session{app=&app,info=&info,editor_world=preview,selection=&selection}
    collider_lines_draw(&session,core.world_ref(&state,&info))
    testing.expect_value(t,app.extras.debug_count,2)
    lines:=app.extras.debug[0]
    faint:=app.extras.debug[1]
    testing.expect(t,lines.depth_test && lines.count==24 && lines.dropped==0,"in sight: hidden behind what is in front")
    testing.expect(t,!faint.depth_test && faint.count==24 && faint.vertices[0].position==lines.vertices[0].position && faint.vertices[0].color>>24==lines.vertices[0].color>>24/4,"the same lines at a quarter of their opacity, through everything")
    for vertex in lines.vertices[:lines.count] {
        testing.expect(t,abs(vertex.position.x-7)==1 && abs(vertex.position.y-4)==1 && abs(vertex.position.z-6)==1)
    }
    app.extras.debug_count=0
    core.get(&transforms,selected).position.x=2
    phys.physics_step(&state,{&settings},&requests,&events,&meshes,&app,{},
        {&rigids},{&colliders},{&characters},{&moves},&joints,{&statics},{&parents},{&names},
        &transforms,&body_states,core.read(&replicas),&character_states,&joint_states,{},nil,{},{},nil,nil,&problems,{},{},{},{},{},{})
    collider_lines_draw(&session,core.world_ref(&state,&info))
    testing.expect_value(t,app.extras.debug_count,2)
    for vertex in app.extras.debug[0].vertices[:app.extras.debug[0].count] {
        testing.expect(t,abs(vertex.position.x-9)==1 && abs(vertex.position.y-4)==1 && abs(vertex.position.z-6)==1)
    }
    app.extras.debug_count=0
    editor.selection_clear(&selection)
    collider_lines_draw(&session,core.world_ref(&state,&info))
    testing.expect_value(t,app.extras.debug_count,0)
    editor.selection_set(&selection,{selected})
    session.mode=.Play
    collider_lines_draw(&session,core.world_ref(&state,&info))
    testing.expect_value(t,app.extras.debug_count,0)
    session.mode=.Paused
    collider_lines_draw(&session,core.world_ref(&state,&info))
    testing.expect_value(t,app.extras.debug_count,0)
}

@(test)
selected_author_colliders_exclude_derived_geometry_and_never_draw_partial_shapes :: proc(t:^testing.T) {
    world:Collider_Hierarchy_Test_World
    core.entities_init(&world.entities)
    core.table_init(&world.colliders,"Collider");core.table_init(&world.parents,"Parent")
    core.table_init(&world.ids,"Id")
    defer {
        phys.state_destroy(&world.state)
        core.table_destroy(&world.colliders);core.table_destroy(&world.parents)
        core.table_destroy(&world.ids)
        core.entities_destroy(&world.entities)
    }
    transforms:core.Table(core.Transform)
    core.table_init(&transforms,"Transform")
    defer core.table_destroy(&transforms)
    owner:=core.create(&world.entities)
    core.add(&world.ids,owner,{value=1})
    core.add(&transforms,owner,core.TRANSFORM_IDENTITY)
    first:=core.NONE
    children:=editor.LINE_CAPACITY/24+2
    for index in 0..<children {
        e:=core.create(&world.entities)
        if index==0 {first=e}
        core.add(&world.ids,e,{value=base.Entity_Id(index+2)})
        core.add(&world.parents,e,core.Parent{entity=owner})
        core.add(&world.colliders,e,phys.COLLIDER_DEFAULT)
        core.add(&transforms,e,core.Transform{position={f32(index)*2,0,0},rotation=1,scale={1,1,1}})
    }
    unrelated:=core.create(&world.entities)
    core.add(&world.colliders,unrelated,phys.COLLIDER_DEFAULT)
    core.add(&transforms,unrelated,core.Transform{position={9000,0,0},rotation=1,scale={1,1,1}})
    core.table_settle(&world.colliders,&world.entities);core.table_settle(&world.parents,&world.entities)
    core.table_settle(&transforms,&world.entities)
    core.table_settle(&world.ids,&world.entities)
    rigids:core.Table(phys.Rigid_Body)
    characters:core.Table(phys.Character)
    moves:core.Table(phys.Character_Move)
    joints:core.Table(phys.Joint)
    statics:core.Table(erender.Mesh_Renderer)
    defer core.table_destroy(&statics)
    names:core.Table(core.Name)
    body_states:core.Table(core.Motion)
    replicas:core.Table(core.Pose_Target)
    character_states:core.Table(phys.Character_State)
    joint_states:core.Table(phys.Joint_State)
    settings:=phys.Physics_Settings{bodies=i32(children+1),shapes=i32(children+1),contacts=16,joints=1,characters=1,hulls=1,meshes=1,heightfields=1}
    requests:phys.Body_Requests
    events:phys.Physics_Events
    defer core.value_free(&events,type_info_of(phys.Physics_Events))
    meshes:phys.Collider_Meshes
    defer phys.collider_meshes_destroy(&meshes)
    app:host.App
    problems:core.Problems
    phys.physics_step(&world.state,{&settings},&requests,&events,&meshes,&app,{},
        {&rigids},{&world.colliders},{&characters},{&moves},&joints,{&statics},{&world.parents},{&names},
        &transforms,&body_states,core.read(&replicas),&character_states,&joint_states,{},nil,{},{},nil,nil,&problems,{},{},{},{},{},{})
    testing.expect_value(t,problems.count,0)
    preview:=new(Collider_Preview)
    defer free(preview)
    storages:=[2]core.Storage_Info{
        {type=phys.Physics_State,offset=offset_of(Collider_Hierarchy_Test_World,state),place=.World},
        {type=Collider_Preview,place=.Editor},
    }
    tables:=[3]core.Table_Info{
        {type=phys.Collider,offset=offset_of(Collider_Hierarchy_Test_World,colliders),place=.World},
        {type=core.Parent,offset=offset_of(Collider_Hierarchy_Test_World,parents),place=.World},
        {type=core.Id,offset=offset_of(Collider_Hierarchy_Test_World,ids),place=.World},
    }
    info:=core.World_Info{entities=offset_of(Collider_Hierarchy_Test_World,entities),storages=storages[:],tables=tables[:]}
    selection:editor.Selection
    defer delete(selection.entities)
    session:=editor.Session{app=&app,info=&info,editor_world=preview,selection=&selection}
    editor.selection_set(&selection,{first})
    collider_lines_draw(&session,core.world_ref(&world,&info))
    testing.expect_value(t,app.extras.debug_count,2)
    testing.expect_value(t,app.extras.debug[0].count,24)
    for vertex in app.extras.debug[0].vertices[:24] {testing.expect(t,abs(vertex.position.x)==0.5)}
    app.extras.debug_count=0
    editor.selection_set(&selection,{owner,first})
    collider_lines_draw(&session,core.world_ref(&world,&info))
    testing.expect_value(t,app.extras.debug_count,2)
    testing.expect_value(t,app.extras.debug[0].count,editor.LINE_CAPACITY/24*24)
    testing.expect(t,app.extras.debug[0].dropped>0)
    for vertex in app.extras.debug[0].vertices[:app.extras.debug[0].count] {testing.expect(t,vertex.position.x<1000)}
    app.extras.debug_count=0
    for e in world.colliders.entities {core.remove(&world.ids,e)}
    core.table_settle(&world.ids,&world.entities)
    collider_lines_draw(&session,core.world_ref(&world,&info))
    testing.expect_value(t,app.extras.debug_count,0)
    physical:=sim.Debug_Draw{lines=preview.scratch[:]}
    testing.expect(t,phys.collider_debug_draw({&world.state},first,&physical))
    testing.expect_value(t,physical.line_count,12)
    core.add(&world.ids,first,{value=2});core.table_settle(&world.ids,&world.entities)
    collider_lines_draw(&session,core.world_ref(&world,&info))
    testing.expect_value(t,app.extras.debug_count,2)
    testing.expect_value(t,app.extras.debug[0].count,24)
    app.extras.debug_count=0

    assets:host.Assets
    if !testing.expect(t,host.assets_init(&assets,{root="assets",capacity=8})) {return}
    defer host.assets_destroy(&assets)
    app.assets=&assets
    geometry:geom.Mesh_Buffer;geom.mesh_buffer_init(&geometry);defer geom.mesh_buffer_destroy(&geometry)
    geom.plane_build(&geometry,{32,32},32,32)
    mesh,generated:=host.assets_mesh_generate(&assets,geom.mesh_buffer_view(&geometry),options={no_lods=true,collision=true})
    if !testing.expect(t,generated) {return}
    core.add(&statics,first,erender.Mesh_Renderer{mesh=mesh});core.table_settle(&statics,&world.entities)
    core.get(&world.colliders,first)^=phys.collider_mesh()
    phys.physics_step(&world.state,{&settings},&requests,&events,&meshes,&app,{},
        {&rigids},{&world.colliders},{&characters},{&moves},&joints,{&statics},{&world.parents},{&names},
        &transforms,&body_states,core.read(&replicas),&character_states,&joint_states,{},nil,{},{},nil,nil,&problems,{},{},{},{},{},{})
    collider_lines_draw(&session,core.world_ref(&world,&info))
    if !testing.expect_value(t,app.extras.debug_count,2) {return}
    testing.expect_value(t,app.extras.debug[0].count,24)
    testing.expect(t,app.extras.debug[0].dropped>0)
    bounds,bounded:=phys.collider_bounds({&world.state},first)
    testing.expect(t,bounded)
    testing.expect_value(t,bounds.min,[3]f32{-16,0,-16});testing.expect_value(t,bounds.max,[3]f32{16,0,16})
    for vertex in app.extras.debug[0].vertices[:app.extras.debug[0].count] {
        for axis in 0..<3 {testing.expect(t,vertex.position[axis]==bounds.min[axis] || vertex.position[axis]==bounds.max[axis])}
    }
    _,invalid:=phys.collider_bounds({&world.state},core.NONE);testing.expect(t,!invalid)
    app.extras.debug_count=0
    editor.selection_clear(&selection)
    collider_lines_draw(&session,core.world_ref(&world,&info))
    testing.expect_value(t,app.extras.debug_count,0)
}
