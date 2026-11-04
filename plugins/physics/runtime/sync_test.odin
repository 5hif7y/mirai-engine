package physics

import "core:testing"
import "mirai:core"
import sim "plugins:physics/runtime/sim"
import mm "mirai:std/math"

@(private="file")
Sync_Scene :: struct {holder,free_entity,wall:core.Entity}

// A floor, a stack, a character, and under an entity without a body a wall
// of colliders, a static body, a kinematic one and a dynamic compound.
@(private="file")
sync_scene :: proc(f:^Physics_Test) -> (scene:Sync_Scene) {
    f.settings={bodies=64,shapes=64,contacts=256,characters=2}
    f.gravity={0,-9.81,0}
    physics_test_box(f,{0,-0.5,0},{20,0.5,20},RIGID_BODY_STATIC)
    for i in 0..<4 {physics_test_box(f,{0,0.5+f32(i)*1.01,0},{0.5,0.5,0.5},RIGID_BODY_DYNAMIC)}
    walker:=core.create(&f.entities)
    core.add(&f.transforms,walker,core.Transform{{4,1,0},1,{1,1,1}})
    core.add(&f.colliders,walker,collider_character())
    core.add(&f.characters,walker,character_default())
    scene.free_entity=core.create(&f.entities)
    core.add(&f.transforms,scene.free_entity,core.Transform{{0,9,0},1,{1,1,1}})
    scene.holder=core.create(&f.entities)
    core.add(&f.transforms,scene.holder,core.Transform{{-6,0,0},1,{1,1,1}})
    under :: proc(f:^Physics_Test,holder:core.Entity,position:[3]f32,rigid:Maybe(Rigid_Body)) -> core.Entity {
        e:=physics_test_box(f,position,{0.4,0.4,0.4},rigid)
        core.add(&f.parents,e,core.Parent{holder,0})
        return e
    }
    scene.wall=under(f,scene.holder,{0,0.4,-3},nil)
    under(f,scene.holder,{0,0.4,3},RIGID_BODY_STATIC)
    under(f,scene.holder,{0,3,0},RIGID_BODY_KINEMATIC)
    compound:=under(f,scene.holder,{2,0.4,0},RIGID_BODY_DYNAMIC)
    under(f,compound,{0,0,1},nil)
    physics_test_settle(f)
    return
}

// The sync of the sealed rows gives the simulation and the rows the sync of
// every body gives, while the editor places and while it plays: a parent
// moved and scaled, a Transform without a body, a collider moved by its own
// row. It goes only through what hangs from what was written.
@(test)
a_sync_of_the_sealed_rows_gives_what_a_sync_of_every_body_gives :: proc(t:^testing.T) {
    tests:=new([2]Physics_Test)
    defer free(tests)
    sealed,whole:=&tests[0],&tests[1]
    physics_test_init(sealed)
    defer physics_test_destroy(sealed)
    physics_test_init(whole)
    defer physics_test_destroy(whole)
    whole.whole=true
    scene:=sync_scene(sealed)
    _=sync_scene(whole)
    for tick in 0..<80 {
        for f in ([2]^Physics_Test{sealed,whole}) {
            if tick%2==0 {
                holder:=core.get(&f.transforms,scene.holder)
                holder.position.x+=0.05
                holder.rotation=mm.quat_axis_angle({0,1,0},f32(tick)*0.01)
                if tick==40 {holder.scale={1.5,1,1.5}}
            }
            core.get(&f.transforms,scene.free_entity).position.y=9+f32(tick)*0.1
            if tick==51 {core.get(&f.transforms,scene.wall).position.y=1}
        }
        // A sync of every body leaves its scratch as it was.
        clear(&sealed.state.sealed)
        if cap(sealed.state.sealed)>0 {append(&sealed.state.sealed,Sealed_Body{})}
        dt:=f32(tick<12?0:1.0/60)
        physics_test_step(sealed,dt)
        physics_test_step(whole,dt)
        if !testing.expectf(t,sim.world_hash(&sealed.state.world)==sim.world_hash(&whole.state.world),"the simulations differ at tick %v",tick) {return}
        testing.expect_value(t,sealed.state.stats,whole.state.stats)
        for row in 0..<core.count(&whole.transforms) {
            e:=core.entity_at(&whole.transforms,row)
            pose,_:=core.get(core.read(&sealed.transforms),e)
            if !testing.expectf(t,pose==whole.transforms.values[row],"entity %v differs at tick %v",e,tick) {return}
        }
        if tick>=20 {
            through:=tick%2==0?5:(tick==51?1:0)
            testing.expectf(t,len(sealed.state.sealed)==through,"tick %v went through %v bodies, not %v",tick,len(sealed.state.sealed),through)
        }
    }
    testing.expect(t,sealed.state.stats.teleports>0 && sealed.state.stats.shapes_created>sealed.state.stats.bodies_created)
    testing.expect_value(t,sealed.problems.count,whole.problems.count)
}
