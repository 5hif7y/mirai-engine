package animation_editor

import "core:fmt"
import cmath "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import lib "mirai:std/anim"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"

Test_Locomotion_Mode :: distinct u16

// The modes of the physics plugin, as the World of a project with it names them.
test_locomotion_modes :: proc(info:^core.World_Info) {
    types:=make([]core.Named_Type_Info,1,context.temp_allocator);names:=make([]core.Name_Info,4,context.temp_allocator)
    types[0]={type=Test_Locomotion_Mode,name="Locomotion_Mode",path="plugins:physics/runtime",prefix="MODE_",limit=1<<16}
    for name,i in ([4]string{"FALLING","WALKING","FLYING","SWIMMING"}) {names[i]={type=Test_Locomotion_Mode,value=i64(i),name=name}}
    info.named_types,info.names=types,names
}

@(test)
setup_classifies_clips_by_the_words_of_their_name :: proc(t:^testing.T) {
    cases:=[?]struct {name:string,class:Setup_Class,loop:bool}{
        {"Idle",.Walking,true},{"MM_Walk_Fwd",.Walking,true},{"JogStart",.Walking,false},{"Sprint_Turn_180",.Walking,false},{"running",.Walking,true},
        {"Fall_Loop",.Falling,true},{"InAir",.Falling,true},{"Jump_Loop",.Falling,true},{"Jump_Start",.Jumping,false},{"TakeOff",.Jumping,false},
        {"Jump",.Jumping,false},{"Land",.Landing,false},{"Jump_Land",.Landing,false},{"Swim_Idle",.Swimming,true},{"Fly",.Flying,true},
        {"Chair_Sit",.None,false},{"Stairs_Up",.None,false},{"Wave",.None,false},
    }
    for c in cases {
        class,loop:=setup_class(c.name)
        testing.expectf(t,class==c.class && (class==.None || loop==c.loop),"%s: %v loop %v",c.name,class,loop)
    }
}

// The figure with a skinned mesh and a library: idle sways in place, walk
// travels at 1.2 m/s and loops, wave turns an arm without moving.
setup_test_character :: proc(f:^Pose_Bake_Test,t:^testing.T) -> base.Asset_Id {
    a:=&f.authoring
    source_id,skeleton_id,mesh_id:=base.Asset_Id{840,1},base.Asset_Id{840,2},base.Asset_Id{840,3}
    bones:=body_test_figure()
    map_,_:=asset.skeleton_body_detect(bones,lib.body_map_empty())
    body:asset.Skeleton_Body
    rows:[len(lib.Body_Part)]asset.Skeleton_Body_Part
    count,_:=asset.skeleton_body_rows(bones,map_,&body,&rows)
    baton:asset.Skeleton_Socket;base.text_set(baton.name[:],"baton");base.text_set(baton.bone[:],"root/pelvis/spine_01/clavicle_r/upperarm_r/lowerarm_r/hand_r");baton.offset=mm.TRANSFORM_IDENTITY;baton.offset.position={0,.1,0}
    testing.expect_value(t,asset.skeleton_save(fmt.tprintf("%s/figure.skeleton",a.root),&a.assets.types,{id=skeleton_id,bones=bones,sockets={baton},body=&body,body_parts=rows[:count]}),asset.Error.None)
    vertices:=[3]asset.Vertex{{position={0,0,0},color=0xffffffff},{position={1,0,0},color=0xffffffff},{position={0,1,0},color=0xffffffff}}
    skin:[3]asset.Skin_Vertex;for &vertex in skin {vertex.weights[0]=255}
    testing.expect_value(t,source_mesh_save(fmt.tprintf("%s/figure.mesh",a.root),&a.assets.types,{id=mesh_id,skeleton=skeleton_id,joints={{node=0,inverse_bind=1}}},{vertices=vertices[:],skin=skin[:]},{0,1,2}),asset.Error.None)
    frames:=31
    idle,walk_root,walk_pelvis,wave:=make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator),make([]lib.Keyframe,frames,context.temp_allocator)
    for i in 0..<frames {
        time:=f32(i)/30
        idle[i]={time=time,value={0,1+.01*cmath.sin(time*mm.TAU),0,0}}
        walk_root[i]={time=time,value={0,0,1.2*time,0}}
        walk_pelvis[i]={time=time,value={0,1+.03*cmath.sin(time*mm.TAU*2),0,0}}
        wave[i]={time=time,value=lib.quat_vec4(mm.quat_axis_angle({0,0,1},.8*cmath.sin(time*mm.TAU)))}
    }
    root:asset.Animation_Root;base.text_set(root.bone[:],"root");root.translation=true
    clips:=[3]asset.Animation_Clip_Desc{
        {name="Idle",tracks={{target="root/pelvis",property=.Position,keys=idle}}},
        {name="Walk",root=root,tracks={{target="root",property=.Position,keys=walk_root},{target="root/pelvis",property=.Position,keys=walk_pelvis}}},
        {name="Wave",tracks={{target="root/pelvis/spine_01/clavicle_r/upperarm_r",property=.Rotation,keys=wave}}},
    }
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/moves.anim",a.root),&a.assets.types,{id=source_id,clips=clips[:]}),asset.Error.None)
    testing.expect(t,host.assets_scan(&a.assets))
    core.add(&f.world.meshes,f.rig,erender.Mesh_Renderer{mesh=mesh_id})
    pose_bake_test_settle(&f.world,nil,nil)
    return source_id
}

@(test)
character_setup_builds_locomotion_look_feet_hands_and_gestures_from_the_body :: proc(t:^testing.T) {
    f:=new(Pose_Bake_Test);defer free(f);if !pose_bake_test_init(f,t,"setup") {return};defer pose_bake_test_destroy(f)
    library:=setup_test_character(f,t)
    a:=&f.authoring
    // What it played before: a clip, its rate and a parameter of another graph.
    stale:=anim.ANIMATION_DEFAULT;stale.speed=.65;base.text_set(stale.clip[:],"Walk");anim.animation_parameter(&stale,"Grounded",1)
    core.add(&f.world.animations,f.rig,stale);pose_bake_test_settle(&f.world,nil,nil)
    defaults:=Setup_Params{want=SETUP_ALL}
    authoring_test_register(a,t,"setup",Setup_Params,setup,&defaults)
    request:=fmt.tprintf(`{{"id":"11","library":"%s","folder":"characters"}}`,authoring_test_id_text(library))
    // Matching follows the modes of the Character: a project without physics has none.
    result:=authoring_test_execute(a,"setup",request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Missing_Plugin") && strings.contains(result.data,"physics") && !authoring_test_exists(a,"characters/figure.pose"))
    test_locomotion_modes(&f.info)
    result=authoring_test_execute(a,"setup",strings.concatenate({request[:len(request)-1],`,"dry_run":true}`},context.temp_allocator))
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    testing.expect(t,!authoring_test_exists(a,"characters/figure.match"))
    text:=string(serial_bytes(a))
    testing.expectf(t,strings.contains(text,`"clip":"Idle","mode":"WALKING","entry":false,"loop":true`) && strings.contains(text,`"clip":"Walk","mode":"WALKING"`) && strings.contains(text,`"gestures":["Wave"]`),"clips in %s",text)

    result=authoring_test_execute(a,"setup",request)
    if !testing.expectf(t,result.code==0,"%s %s",result.message,result.data) {return}
    text=string(serial_bytes(a))
    for want in ([]string{"Locomotion","Look","Foot_Ik","Hand_Ik","Gestures"}) {testing.expectf(t,strings.contains(text,fmt.tprintf(`"want":"%s","status":"Ready"`,want)),"%s in %s",want,text)}
    testing.expectf(t,strings.contains(text,`"detail":"walking: Idle, Walk"`),"detail in %s",text)
    for extension in ([]string{"pose","match","motion","action"}) {testing.expectf(t,authoring_test_exists(a,fmt.tprintf("characters/figure.%s",extension)),"figure.%s",extension)}
    testing.expect(t,!authoring_test_exists(a,"characters/figure.agraph") && !authoring_test_exists(a,"characters/figure.blend"))
    animation,found:=core.get(core.read(&f.world.animations),f.rig)
    if !testing.expect(t,found) {return}
    testing.expect(t,animation.asset==authoring_test_id(a,"characters/figure.match") && animation.motion==authoring_test_id(a,"characters/figure.motion") && animation.actions==authoring_test_id(a,"characters/figure.action") && animation.root_motion==.In_Place)
    testing.expect(t,base.text_get(animation.clip[:])=="" && animation.speed==1 && animation.parameter_names==[anim.GRAPH_PARAMETERS]u64{})
    modifiers,has:=core.get(core.read(&f.world.modifiers),f.rig)
    testing.expect(t,has && modifiers.profile==authoring_test_id(a,"characters/figure.pose"))

    file:asset.Asset
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.pose",&file),asset.Error.None) {
        profile,error:=anim.pose_profile_view(&file,&a.assets.types)
        testing.expect(t,error==.None && len(profile.look)==1 && len(profile.ik)==2 && len(profile.grounding)==1 && profile.grounding[0].count==2)
        // The skeleton keeps its body: the profile names its parts, not its bones.
        testing.expect(t,base.text_get(profile.look[0].bone.path[:])=="@head" && !profile.look[0].enabled)
        testing.expect(t,base.text_get(profile.ik[0].end.path[:])=="@hand_l" && base.text_get(profile.grounding[0].legs[1].foot.path[:])=="@foot_r")
        asset.asset_close(&file)
    }
    actions:asset.Asset
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.action",&actions),asset.Error.None) {
        profile,error:=anim.action_profile_view(&actions,&a.assets.types)
        testing.expect(t,error==.None && len(profile.actions)==3)
        if len(profile.actions)==3 {
            testing.expect(t,base.text_get(profile.actions[0].over.path[:])=="@upper_body" && base.text_get(profile.actions[1].over.path[:])=="@arm_l" && base.text_get(profile.actions[2].over.path[:])=="@arm_r")
        }
        asset.asset_close(&actions)
    }
    match:asset.Asset
    if testing.expect_value(t,authoring_test_load(a,"characters/figure.match",&match),asset.Error.None) {
        profile,error:=anim.match_view(&match,&a.assets.types)
        // Idle and walk alone make a valid library: rates cover the speeds between them.
        testing.expect(t,error==.None && profile.info.animation==library && len(profile.clips)==2)
        if len(profile.clips)==2 {
            testing.expect(t,base.text_get(profile.clips[0].clip[:])=="Idle" && profile.clips[0].modes==1<<1 && profile.clips[0].loop && !profile.clips[0].entry)
            testing.expect(t,base.text_get(profile.clips[1].clip[:])=="Walk" && profile.clips[1].modes==1<<1)
        }
        testing.expect(t,base.text_get(profile.info.left_foot.path[:])=="@foot_l" && base.text_get(profile.info.hips.path[:])=="@pelvis")
        asset.asset_close(&match)
    }

    result=authoring_test_execute(a,"setup",request)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Already_Exists") && strings.contains(result.data,"replace"))
    result=authoring_test_execute(a,"setup",strings.concatenate({request[:len(request)-1],`,"replace":true,"want":["Look"]}`},context.temp_allocator))
    testing.expectf(t,result.code==0,"%s %s",result.message,result.data)
    // What it plays already names its clips; a plain entity has no skeleton.
    result=authoring_test_execute(a,"setup",`{"id":"11","folder":"characters"}`)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,"Already_Exists"))
    plain:=core.create(&f.world.entities);core.add(&f.world.ids,plain,{value=19});pose_bake_test_settle(&f.world,nil,nil)
    result=authoring_test_execute(a,"setup",`{"id":"13"}`)
    testing.expect(t,result.code!=0 && strings.contains(result.data,"Missing_Skeleton"))
}
