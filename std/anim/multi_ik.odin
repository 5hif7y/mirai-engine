package mirai_anim

import "core:math/linalg"
import math "mirai:std/math"

Multi_IK_Root_Policy :: enum u8 {Fixed,Translate}
Multi_IK_Joint :: struct {bone:i32,stiffness:f32,preferred:math.Quat,preferred_weight:f32,limit:Rotation_Limit,use_limit:bool}
MULTI_IK_JOINT_DEFAULT :: Multi_IK_Joint{preferred=1,limit={axis={0,1,0},max_swing=math.PI,min_twist=-math.PI,max_twist=math.PI}}
Multi_IK_Effector :: struct {bone:i32,position:math.Vec3,rotation:math.Quat,position_weight,rotation_weight:f32}
MULTI_IK_EFFECTOR_DEFAULT :: Multi_IK_Effector{rotation=1,position_weight=1}
Multi_IK :: struct {
    root:i32 `mirai:"transient"`,
    root_policy:Multi_IK_Root_Policy `mirai:"optional"`,
    root_stiffness:f32 `mirai:"optional,min=0,max=1"`,
    max_root_translation:f32 `mirai:"optional,min=0"`,
    relaxation:f32 `mirai:"optional,min=0,max=1"`,
    iterations:int `mirai:"optional,min=1,max=256"`,
    tolerance:f32 `mirai:"optional,min=0"`,
    angular_tolerance:f32 `mirai:"optional,min=0,unit=rad"`,
}
MULTI_IK_DEFAULT :: Multi_IK{iterations=32,tolerance=.001,angular_tolerance=.001,relaxation=.7,max_root_translation=1}
Multi_IK_Result :: struct {residual,angular_error:f32,iterations:int,reached:bool}

@(private)
multi_ik_descendant :: proc "contextless" (skeleton:Skeleton,bone,root:i32) -> bool {
    bone:=bone
    for bone>=0 {if bone==root {return true};bone=skeleton.parents[bone]}
    return false
}

multi_ik :: proc "contextless" (skeleton:Skeleton,local,world:[]math.Transform,joints:[]Multi_IK_Joint,effectors:[]Multi_IK_Effector,settings:Multi_IK,residuals:[]f32,root_transform:math.Transform=math.TRANSFORM_IDENTITY) -> (result:Multi_IK_Result,ok:bool) {
    if !skeleton_validate(skeleton) || len(local)!=len(skeleton.rest) || len(world)!=len(local) || settings.root<0 || int(settings.root)>=len(local) || settings.root_policy>max(Multi_IK_Root_Policy) || settings.iterations<1 || settings.iterations>256 || !anim_finite(settings.tolerance) || settings.tolerance<0 || !anim_finite(settings.relaxation) || settings.relaxation<=0 || settings.relaxation>1 || !anim_finite(settings.root_stiffness) || settings.root_stiffness<0 || settings.root_stiffness>1 || !anim_finite(settings.max_root_translation) || settings.max_root_translation<0 || len(effectors)==0 || len(residuals)!=len(effectors) {return}
    if !anim_finite(settings.angular_tolerance) || settings.angular_tolerance<0 {return}
    for joint,i in joints {
        if joint.bone<0 || int(joint.bone)>=len(local) || !multi_ik_descendant(skeleton,joint.bone,settings.root) || !anim_finite(joint.stiffness) || joint.stiffness<0 || joint.stiffness>1 || !anim_rotation_valid(joint.preferred) || !anim_finite(joint.preferred_weight) || joint.preferred_weight<0 || joint.preferred_weight>1 {return}
        for other in joints[:i] {if other.bone==joint.bone {return}}
        if joint.use_limit {_,valid:=rotation_limit(joint.preferred,skeleton.rest[joint.bone].rotation,joint.limit);if !valid {return}}
    }
    for effector in effectors {if effector.bone<0 || int(effector.bone)>=len(local) || !multi_ik_descendant(skeleton,effector.bone,settings.root) || !anim_vec3_valid(effector.position) || !anim_rotation_valid(effector.rotation) || !anim_finite(effector.position_weight) || effector.position_weight<0 || effector.position_weight>1 || !anim_finite(effector.rotation_weight) || effector.rotation_weight<0 || effector.rotation_weight>1 {return}}
    if !pose_world(skeleton.parents,local,world,root_transform) {return}
    root_position:=world[settings.root].position
    for iteration in 0..<settings.iterations {
        for joint in joints {
            if joint.preferred_weight<=0 {continue}
            local[joint.bone].rotation=math.quat_slerp(local[joint.bone].rotation,joint.preferred,joint.preferred_weight*settings.relaxation/f32(settings.iterations))
        }
        if !pose_world(skeleton.parents,local,world,root_transform) {return}
        if settings.root_policy==.Translate {
            correction:math.Vec3;total:f32
            for effector in effectors {correction+=(effector.position-world[effector.bone].position)*effector.position_weight;total+=effector.position_weight}
            if total>0 {
                desired:=world[settings.root].position+correction/total*settings.relaxation*(1-settings.root_stiffness)
                offset:=desired-root_position;distance:=linalg.length(offset)
                if distance>settings.max_root_translation {offset*=settings.max_root_translation/distance}
                parent:=skeleton.parents[settings.root]
                parent_pose:=world[parent] if parent>=0 else root_transform
                local[settings.root].position+=math.transform_inverse_vector(parent_pose,root_position+offset-world[settings.root].position)
                if !pose_world(skeleton.parents,local,world,root_transform) {return}
            }
        }
        for effector in effectors {
            bone:=skeleton.parents[effector.bone] if effector.bone!=settings.root else i32(-1)
            for bone>=0 {
                for joint in joints {
                    if joint.bone!=bone {continue}
                    from,from_ok:=anim_unit(world[effector.bone].position-world[bone].position)
                    to,to_ok:=anim_unit(effector.position-world[bone].position)
                    if from_ok && to_ok {
                        change:=math.quat_slerp(1,anim_between(from,to),settings.relaxation*effector.position_weight*(1-joint.stiffness))
                        parent:=skeleton.parents[bone]
                        desired:=linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*change*world[bone].rotation)
                        if joint.use_limit {desired,ok=rotation_limit(desired,skeleton.rest[bone].rotation,joint.limit);if !ok {return result,false}}
                        local[bone].rotation=desired
                        if !pose_world(skeleton.parents,local,world,root_transform) {return result,false}
                    }
                    break
                }
                if bone==settings.root {break};bone=skeleton.parents[bone]
            }
            if effector.rotation_weight>0 {
                parent:=skeleton.parents[effector.bone]
                desired:=linalg.normalize0(conj(world[parent].rotation if parent>=0 else root_transform.rotation)*effector.rotation)
                stiffness:f32
                for joint in joints {if joint.bone==effector.bone {stiffness=joint.stiffness;if joint.use_limit {desired,ok=rotation_limit(desired,skeleton.rest[effector.bone].rotation,joint.limit);if !ok {return result,false}};break}}
                local[effector.bone].rotation=math.quat_slerp(local[effector.bone].rotation,desired,effector.rotation_weight*settings.relaxation*(1-stiffness))
                if !pose_world(skeleton.parents,local,world,root_transform) {return result,false}
            }
        }
        result.residual,result.angular_error=0,0
        for effector,i in effectors {
            positional:=linalg.length(world[effector.bone].position-effector.position)*effector.position_weight
            rotational:=math.quat_angle(world[effector.bone].rotation,effector.rotation)
            residuals[i]=positional
            if !anim_finite(residuals[i]) {return result,false}
            result.residual=max(result.residual,residuals[i])
            result.angular_error=max(result.angular_error,rotational*effector.rotation_weight)
        }
        result.iterations=iteration+1;result.reached=result.residual<=settings.tolerance && result.angular_error<=settings.angular_tolerance
        if result.reached {break}
    }
    return result,true
}
