package ragdoll

import "core:mem"
import "core:math/linalg"
import "core:strings"
import "core:testing"
import "mirai:core"
import "mirai:host"
import phys "plugins:physics/runtime"
import render "mirai:engine/render"
import volume "mirai:engine/volume"
import mm "mirai:std/math"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(test)
physical_animation_rejects_a_stale_parent_binding_and_invalid_parent_offsets :: proc(t:^testing.T) {
    f:Ragdoll_Fixture;ragdoll_fixture_init(&f);defer ragdoll_fixture_free(&f)
    core.get(&f.configs,f.rig).mode=.Driven
    ragdoll_fixture_step(&f)
    child,_:=core.get(core.read(&f.states),f.lower)
    testing.expect(t,child.active && child.error==.None)
    core.get(&f.bones,f.upper).bone=anim.bone_ref("missing")
    ragdoll_fixture_step(&f)
    child,_=core.get(core.read(&f.states),f.lower)
    driven,_:=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,!child.active && child.error==.Missing_Bone && .Disabled in driven.angular[2].drive)
    core.get(&f.bones,f.upper).bone=anim.bone_ref("upper")
    ragdoll_fixture_step(&f)
    child,_=core.get(core.read(&f.states),f.lower)
    testing.expect(t,child.active && child.error==.None)
    core.get(&f.bones,f.upper).offset.rotation=0
    ragdoll_fixture_step(&f)
    child,_=core.get(core.read(&f.states),f.lower)
    driven,_=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,!child.active && child.error==.Invalid_Settings && .Disabled in driven.angular[2].drive)
}

@(private)
Ragdoll_Fixture :: struct {
    entities:core.Entities,
    transforms:core.Table(core.Transform),parents:core.Table(core.Parent),names:core.Table(core.Name),
    rigids:core.Table(phys.Rigid_Body),colliders:core.Table(phys.Collider),body_states:core.Table(core.Motion),replicas:core.Table(core.Pose_Target),
    characters:core.Table(phys.Character),moves:core.Table(phys.Character_Move),character_states:core.Table(phys.Character_State),
    joints:core.Table(phys.Joint),joint_states:core.Table(phys.Joint_State),meshes:core.Table(render.Mesh_Renderer),
    configs:core.Table(Ragdoll),bones:core.Table(Ragdoll_Bone),states:core.Table(Ragdoll_State),
    physics:phys.Physics_State,settings:phys.Physics_Settings,requests:phys.Body_Requests,joint_requests:phys.Joint_Requests,problems:core.Problems,
    events:phys.Physics_Events,geometry:phys.Collider_Meshes,app:host.App,
    playback:anim.Playback,poses:anim.Animation_Requests,ragdoll:Ragdoll_Runtime,
    gravities:core.Table(volume.Gravity),gravity_places:core.Table(volume.Volume),worlds:core.Table(core.World_Transform), // a world without gravity
    rig,upper,lower:core.Entity,
}

@(private)
ragdoll_fixture_settle :: proc(f:^Ragdoll_Fixture) {
    core.table_settle(&f.transforms,&f.entities);core.table_settle(&f.parents,&f.entities);core.table_settle(&f.names,&f.entities)
    core.table_settle(&f.rigids,&f.entities);core.table_settle(&f.colliders,&f.entities);core.table_settle(&f.body_states,&f.entities)
    core.table_settle(&f.characters,&f.entities);core.table_settle(&f.moves,&f.entities);core.table_settle(&f.character_states,&f.entities)
    core.table_settle(&f.joints,&f.entities);core.table_settle(&f.joint_states,&f.entities);core.table_settle(&f.meshes,&f.entities)
    core.table_settle(&f.configs,&f.entities);core.table_settle(&f.bones,&f.entities);core.table_settle(&f.states,&f.entities)
    core.entities_settle(&f.entities)
}

@(private)
ragdoll_fixture_init :: proc(f:^Ragdoll_Fixture) {
    core.entities_init(&f.entities)
    core.add(&f.gravities,core.create(&f.entities),volume.Gravity{})
    core.table_settle(&f.gravities,&f.entities)
    f.rig,f.upper,f.lower=core.create(&f.entities),core.create(&f.entities),core.create(&f.entities)
    core.add(&f.transforms,f.rig,core.from_math(mm.TRANSFORM_IDENTITY))
    for entity,i in ([2]core.Entity{f.upper,f.lower}) {
        core.add(&f.transforms,entity,{{0,2-f32(i),0},1,{1,1,1}})
        core.add(&f.rigids,entity,phys.RIGID_BODY_DYNAMIC)
        collider:=phys.collider_box({.1,.4,.1});collider.group=f.rig
        core.add(&f.colliders,entity,collider)
        binding:=RAGDOLL_BONE_DEFAULT;binding.rig=f.rig;binding.bone=anim.bone_ref("upper" if i==0 else "lower")
        core.add(&f.bones,entity,binding)
    }
    joint:=phys.joint_sixdof(f.upper,{0,.5,0});joint.auto_target=false;joint.target_anchor={0,-.5,0}
    for &axis in joint.angular {axis.motion=.Limited;axis.lower=-1;axis.upper=1}
    core.add(&f.joints,f.lower,joint)
    config:=RAGDOLL_DEFAULT;config.mode=.Animated;config.max_torque=1000
    core.add(&f.configs,f.rig,config)
    f.settings={bodies=32,shapes=32,contacts=128,joints=8,characters=1}
    f.playback.frame=1
    state:=anim.Playing{entity=f.rig,bound=1,seen=1,pose_ready=true}
    append(&state.parents,-1,0,1)
    append(&state.targets,base.name_hash("actor"),base.name_hash("upper"),base.name_hash("lower"))
    append(&state.aliases,base.name_hash("actor"),base.name_hash("upper"),base.name_hash("lower"))
    append(&state.rest,mm.TRANSFORM_IDENTITY,mm.Transform{{0,2,0},1,{1,1,1}},mm.Transform{{0,-1,0},1,{1,1,1}})
    append(&state.local,..state.rest[:]);append(&state.sampled,..state.rest[:]);resize(&state.world,3)
    append(&f.playback.states,state)
    resize(&f.playback.rows,core.entity_index(f.rig)+1);f.playback.rows[core.entity_index(f.rig)]=1
    ragdoll_fixture_settle(f)
}

@(private)
ragdoll_fixture_free :: proc(f:^Ragdoll_Fixture) {
    phys.state_destroy(&f.physics);phys.collider_meshes_destroy(&f.geometry);anim.playback_free(&f.playback)
    core.value_free(f,type_info_of(Ragdoll_Fixture))
}

@(private)
ragdoll_fixture_step :: proc(f:^Ragdoll_Fixture) {
    settings:=RAGDOLL_SETTINGS_DEFAULT
    time:=core.Time{dt=1.0/60,playing=true}
    ragdoll_prepare(core.read(&f.configs),core.read(&f.bones),&f.states,core.read(&f.rigids),core.read(&f.joints),core.read(&f.transforms),core.read(&f.parents),core.ref(&f.playback),&f.ragdoll,core.ref(&settings),&f.requests,&f.joint_requests,time,&f.poses,&f.problems)
    ragdoll_fixture_settle(f)
    phys.physics_step(&f.physics,core.ref(&f.settings),&f.requests,&f.events,&f.geometry,&f.app,time,
        core.read(&f.rigids),core.read(&f.colliders),core.read(&f.characters),core.read(&f.moves),&f.joints,core.read(&f.meshes),core.read(&f.parents),core.read(&f.names),&f.transforms,&f.body_states,core.read(&f.replicas),&f.character_states,&f.joint_states,{},&f.joint_requests,{},{},nil,nil,&f.problems,
        core.read(&f.gravities),core.read(&f.gravity_places),core.read(&f.worlds),{},{},{})
    ragdoll_fixture_settle(f)
    ragdoll_pose(core.read(&f.configs),core.read(&f.bones),core.read(&f.states),core.read(&f.transforms),core.read(&f.parents),&f.poses,time,&f.problems)
}

@(test)
ragdolls_follow_current_animation_preserve_handoff_velocity_and_drive_real_joints :: proc(t:^testing.T) {
    f:Ragdoll_Fixture;ragdoll_fixture_init(&f);defer ragdoll_fixture_free(&f)
    ragdoll_fixture_step(&f)
    f.playback.states[0].sampled[1].position.x=.1
    ragdoll_fixture_step(&f)
    upper,_:=core.get(core.read(&f.transforms),f.upper)
    testing.expect(t,abs(upper.position.x-.1)<.001)
    velocity,_:=core.get(core.read(&f.body_states),f.upper)
    testing.expect(t,velocity.linear.x>5)
    core.get(&f.configs,f.rig).mode=.Simulated
    ragdoll_fixture_step(&f)
    upper,_=core.get(core.read(&f.transforms),f.upper)
    testing.expect(t,upper.position.x>.15)
    testing.expect_value(t,len(f.poses.final_poses.items),2)
    for pose in f.poses.final_poses.items {testing.expect(t,pose.binding.revision==1 && pose.binding.index>=1)}
    clear(&f.poses.final_poses.items)
    core.get(&f.configs,f.rig).mode=.Driven
    f.playback.states[0].sampled[2].rotation=mm.quat_axis_angle({0,0,1},.4)
    for tick in 0..<120 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    child,_:=core.get(core.read(&f.transforms),f.lower)
    upper,_=core.get(core.read(&f.transforms),f.upper)
    relative:=mm.quat_inverse(upper.rotation)*child.rotation
    testing.expect(t,mm.quat_angle(relative,f.playback.states[0].sampled[2].rotation)<.08)
    driven,_:=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,.Position in driven.angular[2].drive && driven.angular[2].motion==.Limited)
    core.get(&f.configs,f.rig).hertz=0
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,.Disabled in driven.angular[2].drive)
    core.get(&f.configs,f.rig).hertz=5
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,.Disabled not_in driven.angular[2].drive)
    core.get(&f.configs,f.rig).mode=.Simulated
    clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)
    driven,_=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,.Disabled in driven.angular[2].drive)
    testing.expect_value(t,f.problems.count,0)
}

@(test)
invalid_bindings_and_removed_configuration_release_kinematic_bodies :: proc(t:^testing.T) {
    f:Ragdoll_Fixture;ragdoll_fixture_init(&f);defer ragdoll_fixture_free(&f)
    ragdoll_fixture_step(&f)
    core.get(&f.bones,f.lower).bone=anim.bone_ref("missing")
    ragdoll_fixture_step(&f)
    state,_:=core.get(core.read(&f.states),f.lower)
    testing.expect(t,state.error==.Missing_Bone && !state.active)
    missing:=core.problem_find(&f.problems,f.lower,"ragdoll.bone")
    testing.expect(t,missing!=nil && strings.contains(core.problem_text(missing),"bone 'missing' of this Ragdoll_Bone"),"the body names the bone it could not find")
    core.remove(&f.configs,f.rig);ragdoll_fixture_settle(&f)
    ragdoll_fixture_step(&f)
    testing.expect_value(t,core.count(core.read(&f.states)),0)
    testing.expect(t,!ragdoll_valid(Ragdoll{weight=2}))
    bone:=RAGDOLL_BONE_DEFAULT;bone.rig=f.rig;bone.bone=anim.bone_ref("upper");bone.offset.rotation=0
    testing.expect(t,!ragdoll_bone_valid(bone))
}

@(test)
physical_animation_uses_current_auto_frames_and_reuses_world_buffers :: proc(t:^testing.T) {
    track:mem.Tracking_Allocator
    mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
    previous_context:=context;context.allocator=mem.tracking_allocator(&track);context.temp_allocator=context.allocator
    defer context=previous_context
    f:Ragdoll_Fixture;ragdoll_fixture_init(&f);defer ragdoll_fixture_free(&f)
    core.get(&f.configs,f.rig).mode=.Driven
    core.get(&f.joints,f.lower).auto_target=true
    turn:=mm.quat_axis_angle({0,1,0},.4)
    core.get(&f.transforms,f.lower).rotation=turn
    f.playback.states[0].sampled[2].rotation=turn
    ragdoll_fixture_step(&f)
    joint,_:=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,.Position in joint.angular[0].drive && abs(joint.angular[1].position)<.001)
    for tick in 0..<10 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    joint,_=core.get(core.read(&f.joints),f.lower)
    testing.expect(t,abs(joint.angular[0].position)<.001 && abs(joint.angular[1].position)<.001 && abs(joint.angular[2].position)<.001)
    allocations:=track.total_allocation_count
    for tick in 0..<60 {clear(&f.poses.final_poses.items);ragdoll_fixture_step(&f)}
    testing.expect_value(t,track.total_allocation_count,allocations)
    testing.expect_value(t,f.problems.count,0)
}
