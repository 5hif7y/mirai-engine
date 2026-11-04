package mirai_anim

import "core:testing"
import "core:math/linalg"
import math "mirai:std/math"

@(test)
semantic_chain_retarget_interpolates_different_topologies_without_changing_target_lengths :: proc(t:^testing.T) {
    source_parents:=[3]i32{-1,0,1};source_names:=[3]u64{1,2,3}
    source_rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    target_parents:=[5]i32{-1,0,1,2,3};target_names:=[5]u64{4,5,6,7,8}
    target_rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,{{0,.5,0},1,{1,1,1}},{{0,.5,0},1,{1,1,1}},{{0,.5,0},1,{1,1,1}},{{0,.5,0},1,{1,1,1}}}
    source:=Skeleton{source_parents[:],source_names[:],source_rest[:]};target:=Skeleton{target_parents[:],target_names[:],target_rest[:]}
    source_chain:=[3]i32{0,1,2};target_chain:=[5]i32{0,1,2,3,4}
    source_world:[3]math.Transform;target_world:[5]math.Transform;bindings:[5]Chain_Retarget_Bone
    testing.expect(t,chain_retarget_prepare(source,target,source_chain[:],target_chain[:],source_world[:],target_world[:],bindings[:]))
    testing.expect_value(t,bindings[1].fraction,f32(.5));testing.expect_value(t,bindings[3].fraction,f32(.5))
    source_pose:=source_rest;target_pose:=target_rest
    source_pose[1].rotation=math.quat_axis_angle({0,0,1},.8)
    source_pose[2].rotation=math.quat_axis_angle({0,0,1},.6)
    testing.expect(t,skeleton_world(source,source_pose[:],source_world[:]))
    testing.expect(t,chain_retarget_pose(target,bindings[:],source_world[:],target_pose[:],target_world[:]))
    for value,i in target_pose {testing.expect_value(t,value.position,target_rest[i].position)}
    testing.expect(t,abs(linalg.dot(target_world[4].rotation,source_world[2].rotation))>.9999)
    testing.expect(t,abs(linalg.dot(target_world[1].rotation,math.quat_slerp(source_world[0].rotation,source_world[1].rotation,.5)))>.9999)
    target_pose=target_rest
    testing.expect(t,chain_retarget_pose(target,bindings[:],source_world[:],target_pose[:],target_world[:],0) && target_pose==target_rest)
    bindings[2].source_b=999;testing.expect(t,!chain_retarget_pose(target,bindings[:],source_world[:],target_pose[:],target_world[:]))
}

@(test)
multi_effector_ik_converges_on_branches_respects_fixed_roots_and_joint_limits :: proc(t:^testing.T) {
    parents:=[7]i32{-1,0,1,2,0,4,5};names:=[7]u64{1,2,3,4,5,6,7}
    rest:=[7]math.Transform{math.TRANSFORM_IDENTITY,{{-1,0,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}},{{1,0,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[7]math.Transform
    joint_bones:=[4]i32{1,2,4,5};joints:[4]Multi_IK_Joint;for &joint,i in joints {joint=MULTI_IK_JOINT_DEFAULT;joint.bone=joint_bones[i]}
    effectors:=[2]Multi_IK_Effector{{bone=3,position={-2,1,0},rotation=1,position_weight=1},{bone=6,position={2,1,0},rotation=1,position_weight=1}}
    settings:=MULTI_IK_DEFAULT;settings.iterations=128
    residuals:[2]f32
    result,ok:=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && result.reached && result.residual<.001 && local[0]==rest[0])
    for value,i in local {testing.expect_value(t,value.position,rest[i].position)}
    local=rest
    for &joint in joints {joint.use_limit=true;joint.limit={axis={0,0,1},max_swing=0,min_twist=0,max_twist=0}}
    result,ok=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && !result.reached && result.residual>1 && local==rest)
    settings.root_policy=.Translate;settings.max_root_translation=.5
    for &effector in effectors {effector.position.y+=4}
    result,ok=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && !result.reached && linalg.length(world[0].position)<=.5001 && world[0].position.y>0)
}

@(test)
multi_ik_preferred_rotations_stiffness_and_angular_limits_have_separate_residuals :: proc(t:^testing.T) {
    parents:=[2]i32{-1,0};names:=[2]u64{1,2};rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[2]math.Transform;residuals:[1]f32
    joint:=MULTI_IK_JOINT_DEFAULT;joint.bone=1;joint.preferred=math.quat_axis_angle({0,1,0},.4);joint.preferred_weight=1
    joints:=[1]Multi_IK_Joint{joint};effector:=MULTI_IK_EFFECTOR_DEFAULT;effector.bone=1;effector.position_weight=0
    effectors:=[1]Multi_IK_Effector{effector};settings:=MULTI_IK_DEFAULT;settings.iterations=1;settings.relaxation=1
    result,ok:=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && result.reached && math.quat_angle(local[1].rotation,joint.preferred)<.001)
    local=rest;joints[0].preferred_weight=0;joints[0].stiffness=1
    effectors[0].rotation=math.quat_axis_angle({0,1,0},.8);effectors[0].rotation_weight=1
    result,ok=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && !result.reached && result.residual==0 && abs(result.angular_error-.8)<.001 && local==rest)
    joints[0].stiffness=0;joints[0].use_limit=true;joints[0].limit={axis={0,1,0},max_swing=0,min_twist=-.2,max_twist=.2}
    result,ok=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
    testing.expect(t,ok && !result.reached && abs(result.angular_error-.6)<.001 && math.quat_angle(local[1].rotation,math.quat_axis_angle({0,1,0},.2))<.001)
}

@(test)
multi_ik_root_and_child_effectors_keep_ancestor_corrections_inside_the_selected_subtree :: proc(t:^testing.T) {
    parents:=[5]i32{-1,0,1,2,0};names:=[5]u64{1,2,3,4,5}
    rest:=[5]math.Transform{math.TRANSFORM_IDENTITY,math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}},{{3,0,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]}
    joints:=[2]Multi_IK_Joint{MULTI_IK_JOINT_DEFAULT,MULTI_IK_JOINT_DEFAULT};joints[0].bone,joints[1].bone=1,2
    settings:=MULTI_IK_DEFAULT;settings.root,settings.iterations,settings.relaxation=1,128,1
    for bone in ([?]i32{1,3}) {
        local:=rest;world:[5]math.Transform;residuals:[1]f32
        effectors:=[1]Multi_IK_Effector{{bone=bone,rotation=1}}
        if bone==1 {effectors[0].rotation=math.quat_axis_angle({0,0,1},.3);effectors[0].rotation_weight=1} else {effectors[0].position={1,1,0};effectors[0].position_weight=1}
        result,ok:=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
        testing.expect(t,ok && result.reached && local[0]==rest[0] && local[4]==rest[4])
        testing.expect_value(t,world[4],rest[4])
    }
}

@(test)
spring_chains_replay_snapshots_preserve_lengths_and_reset_after_teleports :: proc(t:^testing.T) {
    points:=[4]math.Vec3{{},{0,1,0},{0,2,0},{0,3,0}};lengths:=[3]f32{1,1,1}
    state:[4]Spring_Joint_State;out:[4]math.Vec3
    settings:=SPRING_CHAIN_DEFAULT;settings.force={3,0,0};settings.gravity={}
    result,ok:=spring_chain_update(points[:],lengths[:],nil,nil,settings,1.0/60,state[:],out[:])
    testing.expect(t,ok && result.reset && result.substeps==2 && out[3].x>0)
    snapshot:=state
    second:[4]math.Vec3
    for _ in 0..<120 {
        _,a:=spring_chain_update(points[:],lengths[:],nil,nil,settings,1.0/60,state[:],out[:])
        _,b:=spring_chain_update(points[:],lengths[:],nil,nil,settings,1.0/60,snapshot[:],second[:])
        testing.expect(t,a && b && out==second)
    }
    for i in 1..<4 {testing.expect(t,abs(linalg.length(out[i]-out[i-1])-1)<.0001)}
    for &point in points {point.x+=10}
    result,ok=spring_chain_update(points[:],lengths[:],nil,nil,settings,0,state[:],out[:])
    testing.expect(t,ok && result.reset && out==points)
    collision:=[1]Spring_Collision{{position={10,1,0},radius=.2}}
    _,ok=spring_chain_update(points[:],lengths[:],nil,collision[:],settings,1.0/60,state[:],out[:])
    testing.expect(t,ok && linalg.length(out[1]-collision[0].position)>=.1999)
}

@(test)
twist_distribution_preserves_source_and_distributes_cumulative_roll :: proc(t:^testing.T) {
    parents:=[4]i32{-1,0,1,0};names:=[4]u64{1,2,3,4}
    rest:=[4]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}},math.TRANSFORM_IDENTITY}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[4]math.Transform
    local[3].rotation=math.quat_axis_angle({0,1,0},.8);source:=local[3]
    bones:=[2]i32{1,2};amounts:=[2]f32{1,1};original:[2]math.Quat
    testing.expect(t,skeleton_twist(skeleton,local[:],world[:],3,bones[:],amounts[:],{0,2,0},1,original[:]))
    testing.expect_value(t,local[3],source)
    testing.expect(t,abs(linalg.dot(world[1].rotation,math.quat_axis_angle({0,1,0},.4)))>.9999 && abs(linalg.dot(world[2].rotation,source.rotation))>.9999)
    for value,i in local {testing.expect_value(t,value.position,rest[i].position)}
}

@(test)
rig_solvers_reject_hostile_indices_nonfinite_values_and_short_buffers :: proc(t:^testing.T) {
    parents:=[2]i32{-1,0};names:=[2]u64{1,2};rest:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[2]math.Transform
    residuals:[1]f32;effector:=[1]Multi_IK_Effector{MULTI_IK_EFFECTOR_DEFAULT};effector[0].bone=1
    settings:=MULTI_IK_DEFAULT
    for value in ([?]f32{transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000),-1}) {
        invalid:=settings;invalid.tolerance=value
        _,ok:=multi_ik(skeleton,local[:],world[:],nil,effector[:],invalid,residuals[:]);testing.expect(t,!ok)
        spring:=SPRING_CHAIN_DEFAULT;spring.max_step=value
        points:=[2]math.Vec3{{},{0,1,0}};lengths:=[1]f32{1};state:[2]Spring_Joint_State;out:[2]math.Vec3
        _,ok=spring_chain_update(points[:],lengths[:],nil,nil,spring,.01,state[:],out[:]);testing.expect(t,!ok)
    }
    _,ok:=multi_ik(skeleton,local[:],world[:],nil,effector[:],settings,nil);testing.expect(t,!ok)
    bones:=[2]i32{0,1};original:[2]math.Quat;amounts:=[2]f32{1,1}
    testing.expect(t,!skeleton_twist(skeleton,local[:],world[:],999,bones[:],amounts[:],{0,1,0},1,original[:]))
    bindings:[2]Chain_Retarget_Bone;bones[1]=999
    testing.expect(t,!chain_retarget_prepare(skeleton,skeleton,bones[:],bones[:],world[:],world[:],bindings[:]))
}

@(test)
multi_ik_validates_reference_and_current_pose_before_iterating_without_joint_corrections :: proc(t:^testing.T) {
    parents:=[2]i32{-1,0};names:=[2]u64{1,2}
    reference:=[2]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}}}
    effects:=[1]Multi_IK_Effector{{bone=1,position={0,1,0},rotation=1,position_weight=1}}
    settings:=MULTI_IK_DEFAULT;world:[2]math.Transform;residuals:[1]f32
    for invalid in 0..<5 {
        rest,local:=reference,reference;actor:=math.TRANSFORM_IDENTITY
        switch invalid {
        case 0:rest[1].rotation=0
        case 1:local[1].rotation=0
        case 2:local[1].position.x=transmute(f32)u32(0x7fc00000)
        case 3:local[1].scale.y=transmute(f32)u32(0x7f800000)
        case 4:actor.rotation=0
        }
        _,ok:=multi_ik({parents[:],names[:],rest[:]},local[:],world[:],nil,effects[:],settings,residuals[:],actor)
        testing.expect(t,!ok)
    }
    local:=reference
    result,ok:=multi_ik({parents[:],names[:],reference[:]},local[:],world[:],nil,effects[:],settings,residuals[:])
    testing.expect(t,ok && result.reached && local==reference && world==reference)
}

@(test)
rig_solvers_return_for_randomized_hostile_settings_without_allocations :: proc(t:^testing.T) {
    rounds:=#config(ANIM_RIG_HOSTILE_ROUNDS,400);random:=math.rng_make(7719)
    parents:=[3]i32{-1,0,1};names:=[3]u64{1,2,3}
    rest:=[3]math.Transform{math.TRANSFORM_IDENTITY,{{0,1,0},1,{1,1,1}},{{0,1,0},1,{1,1,1}}}
    skeleton:=Skeleton{parents[:],names[:],rest[:]};local:=rest;world:[3]math.Transform
    joints:=[1]Multi_IK_Joint{MULTI_IK_JOINT_DEFAULT};effectors:=[1]Multi_IK_Effector{MULTI_IK_EFFECTOR_DEFAULT};effectors[0].bone=2;residuals:[1]f32
    points:=[3]math.Vec3{{},{0,1,0},{0,2,0}};lengths:=[2]f32{1,1};states:[3]Spring_Joint_State;out:[3]math.Vec3
    values:=[8]f32{0,1,-1,1e30,1e-30,transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000),.01}
    for _ in 0..<rounds {
        scalar:=values[math.rng_u32(&random)%8]
        settings:=MULTI_IK_DEFAULT;settings.root=i32(math.rng_u32(&random)%7)-2;settings.tolerance=scalar;settings.iterations=int(math.rng_u32(&random)%260)
        joints[0].bone=i32(math.rng_u32(&random)%7)-2;joints[0].stiffness=scalar
        local=rest;_,_=multi_ik(skeleton,local[:],world[:],joints[:],effectors[:],settings,residuals[:])
        spring:=SPRING_CHAIN_DEFAULT;spring.max_step=scalar;spring.stiffness=scalar
        states={};_,_=spring_chain_update(points[:],lengths[:],nil,nil,spring,.01,states[:],out[:])
    }
    testing.expect(t,true)
}
