package fracture

import "core:testing"
import sim "plugins:physics/runtime/sim"
import math "mirai:std/math"
import "mirai:std/geom"

@(private="file")
test_authored_destructible :: proc(w:^World,hierarchy:=true,settings:=Destructible_Desc{}) -> (Destructible_Handle,Destructible_Error) {
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube)
    geom.cube_build(&cube)
    for part in 0..<4 {
        first_vertex,first_index:=u32(len(f.mesh.positions)),u32(len(f.mesh.indices))
        center:=Vec3{f32(part)*1.1-1.65,3,0}
        for point in cube.positions {append(&f.mesh.positions,point+center)}
        append(&f.mesh.indices,..cube.indices[:])
        for _ in 0..<len(cube.indices)/3 {append(&f.mesh.materials,0)}
        append(&f.pieces,geom.Fracture_Piece{site=u32(part),first_vertex=first_vertex,vertex_count=u32(len(cube.positions)),first_index=first_index,index_count=u32(len(cube.indices)),volume=1,center=center})
    }
    append(&f.connections,geom.Fracture_Connection{0,1,1},geom.Fracture_Connection{1,2,1},geom.Fracture_Connection{2,3,1})
    clusters:=[3]Cluster_Desc{{parent=-1,strength=100},{parent=0,strength=50},{parent=0,strength=50}}
    membership:=[4]i32{1,1,2,2}
    desc:=settings
    if desc.density==0 {desc=DESTRUCTIBLE_DESC_DEFAULT}
    desc.fracture=&f
    if hierarchy {desc.clusters,desc.piece_clusters=clusters[:],membership[:]}
    return destructible_create(&w.fracture,&w.sim,desc)
}

@(private="file")
destruct_group_count :: proc(w:^World,h:Destructible_Handle) -> int {
    pieces:[16]Piece_Info
    count:=min(destructible_pieces(&w.fracture,&w.sim,h,pieces[:]),len(pieces))
    groups:=0
    for piece,at in pieces[:count] {
        if piece.body=={} {continue}
        seen:=false
        for prior in pieces[:at] {seen=seen || prior.body==piece.body}
        if !seen {groups+=1}
    }
    return groups
}

@(test)
authored_clusters_release_root_then_children_then_leaves_and_replay :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,true,settings)
    if !testing.expect_value(t,error,Destructible_Error.None) {return}
    testing.expect_value(t,destruct_group_count(&w,h),1)
    snapshot:=make([]u8,world_snapshot_size(&w));defer delete(snapshot)
    _,saved:=world_snapshot(&w,snapshot)
    testing.expect(t,saved)
    events:[3]Fracture_Event
    events[0],_=destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,1000)
    testing.expect_value(t,destruct_group_count(&w,h),2)
    clusters:[3]Cluster_Info
    testing.expect_value(t,destructible_clusters(&w.fracture,h,clusters[:]),3)
    testing.expect(t,clusters[0].broken && !clusters[1].broken && !clusters[2].broken)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    events[1],_,_=destructible_strain_body(&w.fracture,&w.sim,h,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,destruct_group_count(&w,h),3)
    events[2],_,_=destructible_strain_body(&w.fracture,&w.sim,h,pieces[3].id,{1.1,3,0},100,1000)
    testing.expect_value(t,destruct_group_count(&w,h),4)
    final:=world_hash(&w)
    testing.expect(t,world_restore(&w,snapshot))
    for event in events {testing.expect(t,fracture_event_apply(&w.fracture,&w.sim,event))}
    testing.expect_value(t,world_hash(&w),final)
}

@(test)
strain_breaks_without_launching_and_weakening_waits_for_external_damage :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    h,_:=test_authored_destructible(&w,false,settings)
    event,strained:=destructible_weaken(&w.fracture,&w.sim,h,{0,3,0},100,10000)
    testing.expect(t,strained && event.kind==.Weaken)
    testing.expect_value(t,destruct_group_count(&w,h),1)
    testing.expect_value(t,destructible_revision(&w.fracture,h),u32(0))
    _,broke:=destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,1)
    testing.expect(t,broke)
    testing.expect_value(t,destruct_group_count(&w,h),4)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    for piece in pieces {testing.expect_value(t,sim.body_linear_velocity(&w.sim,piece.body),Vec3{})}
}

@(test)
authored_cluster_state_preserves_level_and_connection_strength_on_late_join :: proc(t:^testing.T) {
    a,b:World
    testing.expect(t,test_destruct_world(&a));defer world_destroy(&a)
    testing.expect(t,test_destruct_world(&b));defer world_destroy(&b)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    first,_:=test_authored_destructible(&a,true,settings)
    second,_:=test_authored_destructible(&b,true,settings)
    destructible_strain(&a.fracture,&a.sim,first,{0,3,0},100,1000)
    state:=make([]u8,destructible_state_size(&a.fracture,first));defer delete(state)
    testing.expect_value(t,destructible_state_write(&a.fracture,&a.sim,first,state),len(state))
    testing.expect_value(t,sim.world_stats(&b.sim).shapes,1)
    testing.expect(t,destructible_state_apply(&b.fracture,&b.sim,second,state))
    testing.expect_value(t,destructible_check(&b.fracture,second),destructible_check(&a.fracture,first))
    testing.expect_value(t,destruct_group_count(&b,second),2)
    testing.expect_value(t,sim.world_stats(&b.sim).shapes,sim.world_stats(&a.sim).shapes)
    pieces:[4]Piece_Info;destructible_pieces(&b.fracture,&b.sim,second,pieces[:])
    destructible_strain_body(&b.fracture,&b.sim,second,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,destruct_group_count(&b,second),3)
}

@(test)
detached_groups_keep_gravity_surface_and_filter_take_a_new_filter_and_expire_by_timer :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT
    settings.gravity_scale,settings.friction,settings.restitution=0,0.25,0.7
    settings.filter={layers=4,block=8,overlap=16,group=2}
    settings.removal_ticks=2
    h,error:=test_authored_destructible(&w,false,settings)
    testing.expect_value(t,error,Destructible_Error.None)
    destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    for piece in pieces {
        _,restitution:=sim.shape_material(&w.sim,piece.shape)
        testing.expect_value(t,restitution,f32(0.7))
        testing.expect_value(t,sim.shape_filter(&w.sim,piece.shape),settings.filter)
        testing.expect_value(t,sim.body_gravity_scale(&w.sim,piece.body),f32(0))
    }
    moved:=Filter{layers=2,block=2}
    destructible_set_filter(&w.fracture,&w.sim,h,moved)
    for piece in pieces {testing.expect_value(t,sim.shape_filter(&w.sim,piece.shape),moved)}
    test_steps(&w,2)
    testing.expect_value(t,destruct_group_count(&w,h),4)
    world_step(&w,1.0/60)
    testing.expect_value(t,destruct_group_count(&w,h),1)
    testing.expect_value(t,len(fracture_events(&w.fracture)),3)
    for event in fracture_events(&w.fracture) {testing.expect_value(t,event.kind,Fracture_Kind.Remove)}
}

@(test)
detached_groups_can_be_removed_when_they_sleep :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0;settings.remove_on_sleep=true
    h,_:=test_authored_destructible(&w,false,settings)
    destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    for piece in pieces {
        if piece.group==0 {continue}
        pose:=sim.body_transform(&w.sim,piece.body)
        sim.body_rest(&w.sim,piece.body,pose.p,pose.q)
    }
    world_step(&w,1.0/60)
    testing.expect_value(t,destruct_group_count(&w,h),1)
}

@(test)
passive_fragment_deadlines_survive_expiry_restore_and_explicit_removal_replay :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=3;settings.remove_on_sleep=true;settings.passive_removal=true
    h,_:=test_authored_destructible(&w,false,settings)
    destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,10000)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    representative:i32=-1
    body:Body_Handle
    for piece in pieces {
        ticks,expires:=destructible_body_remaining_ticks(&w.fracture,&w.sim,h,piece.body)
        if piece.group==0 {
            testing.expect(t,!expires)
            _,removed:=destructible_remove_body(&w.fracture,&w.sim,h,piece.id)
            testing.expect(t,!removed)
            testing.expect(t,!fracture_event_apply(&w.fracture,&w.sim,{destructible=h,piece=piece.id,kind=.Remove}))
            continue
        }
        testing.expect(t,expires)
        testing.expect_value(t,ticks,u32(3))
        representative,body=piece.id,piece.body
        pose:=sim.body_transform(&w.sim,piece.body);sim.body_rest(&w.sim,piece.body,pose.p,pose.q)
    }
    snapshot:=make([]u8,world_snapshot_size(&w));defer delete(snapshot)
    _,saved:=world_snapshot(&w,snapshot);testing.expect(t,saved)
    test_steps(&w,5)
    ticks,expires:=destructible_body_remaining_ticks(&w.fracture,&w.sim,h,body)
    testing.expect(t,expires)
    testing.expect_value(t,ticks,u32(0))
    testing.expect_value(t,destruct_group_count(&w,h),4)
    event,removed:=destructible_remove_body(&w.fracture,&w.sim,h,representative)
    testing.expect(t,removed && event.kind==.Remove)
    testing.expect_value(t,destruct_group_count(&w,h),3)
    final:=world_hash(&w)
    testing.expect(t,world_restore(&w,snapshot))
    test_steps(&w,5)
    testing.expect(t,fracture_event_apply(&w.fracture,&w.sim,event))
    testing.expect_value(t,world_hash(&w),final)
}

@(test)
fragment_state_preserves_finite_and_unlimited_lifetimes_for_passive_worlds :: proc(t:^testing.T) {
    for lifetime in ([2]u32{0,4}) {
        a,b:World;testing.expect(t,test_destruct_world(&a));testing.expect(t,test_destruct_world(&b))
        settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=lifetime;settings.passive_removal=true
        first,_:=test_authored_destructible(&a,false,settings)
        second,_:=test_authored_destructible(&b,false,settings)
        destructible_strain(&a.fracture,&a.sim,first,{0,3,0},100,10000)
        test_steps(&a,2)
        state:=make([]u8,destructible_state_size(&a.fracture,first))
        testing.expect_value(t,destructible_state_write(&a.fracture,&a.sim,first,state),len(state))
        testing.expect(t,destructible_state_apply(&b.fracture,&b.sim,second,state))
        pieces:[4]Piece_Info;destructible_pieces(&b.fracture,&b.sim,second,pieces[:])
        for piece in pieces {
            ticks,expires:=destructible_body_remaining_ticks(&b.fracture,&b.sim,second,piece.body)
            testing.expect_value(t,expires,piece.group!=0 && lifetime!=0)
            if expires {testing.expect_value(t,ticks,u32(2))}
        }
        testing.expect_value(t,destructible_check(&b.fracture,second),destructible_check(&a.fracture,first))
        delete(state);world_destroy(&a);world_destroy(&b)
    }
}

@(test)
cutting_a_detached_group_preserves_its_deadline_mass_and_replay :: proc(t:^testing.T) {
    for lifetime in ([2]u32{0,20}) {
        w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
        settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0;settings.removal_ticks=lifetime
        h,_:=test_authored_destructible(&w,false,settings)
        destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,10000)
        test_steps(&w,2)
        pieces:[16]Piece_Info
        count:=min(destructible_pieces(&w.fracture,&w.sim,h,pieces[:]),len(pieces))
        target:Piece_Info
        for piece in pieces[:count] {if piece.group!=0 {target=piece;break}}
        if !testing.expect(t,target.body!=0) {return}
        remaining,expires:=destructible_body_remaining_ticks(&w.fracture,&w.sim,h,target.body)
        mass:=destructible_mass(&w.fracture,h)
        snapshot:=make([]u8,world_snapshot_size(&w));defer delete(snapshot)
        _,saved:=world_snapshot(&w,snapshot);testing.expect(t,saved)
        pose:=sim.body_transform(&w.sim,target.body)
        event,cut:=destructible_slice_body(&w.fracture,&w.sim,h,target.id,xf_point(pose,target.center),{0,1,0})
        if !testing.expect(t,cut) {return}
        ticks,scheduled:=destructible_body_remaining_ticks(&w.fracture,&w.sim,h,target.body)
        testing.expect_value(t,scheduled,expires)
        testing.expect_value(t,ticks,remaining)
        test_steps(&w,2)
        testing.expect(t,sim.body_valid(&w.sim,target.body),"the retained half of a detached group stays alive")
        testing.expect_value(t,destruct_group_count(&w,h),5)
        testing.expect(t,abs(destructible_mass(&w.fracture,h)-mass)<0.01)
        final:=world_hash(&w)
        testing.expect(t,world_restore(&w,snapshot))
        testing.expect(t,fracture_event_apply(&w.fracture,&w.sim,event))
        test_steps(&w,2)
        testing.expect_value(t,world_hash(&w),final)
        state:=make([]u8,destructible_state_size(&w.fracture,h));defer delete(state)
        testing.expect_value(t,destructible_state_write(&w.fracture,&w.sim,h,state),len(state))
        b:World;testing.expect(t,test_destruct_world(&b));defer world_destroy(&b)
        other,_:=test_authored_destructible(&b,false,settings)
        testing.expect(t,destructible_state_apply(&b.fracture,&b.sim,other,state))
        testing.expect_value(t,destructible_check(&b.fracture,other),destructible_check(&w.fracture,h))
        count=min(destructible_pieces(&b.fracture,&b.sim,other,pieces[:]),len(pieces))
        for piece in pieces[:count] {
            if piece.body==0 || piece.group!=target.group {continue}
            ticks,scheduled=destructible_body_remaining_ticks(&b.fracture,&b.sim,other,piece.body)
            testing.expect_value(t,scheduled,expires)
            testing.expect_value(t,ticks,expires?remaining-2:u32(0))
        }
        if expires {
            test_steps(&w,int(remaining)-2)
            testing.expect(t,sim.body_valid(&w.sim,target.body))
            world_step(&w,1.0/60)
            testing.expect(t,!sim.body_valid(&w.sim,target.body),"the cut keeps the original removal deadline")
        }
    }
}

@(test)
invalid_authored_cluster_membership_is_rejected_before_allocating_bodies :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    cube:geom.Mesh_Buffer;geom.mesh_buffer_init(&cube);defer geom.mesh_buffer_destroy(&cube);geom.cube_build(&cube)
    f:geom.Fracture;geom.fracture_init(&f);defer geom.fracture_destroy(&f)
    geom.mesh_fracture(&f,geom.mesh_buffer_view(&cube),([]Vec3{{}}))
    cluster:=[1]Cluster_Desc{{parent=0,strength=10}}
    membership:=[1]i32{0}
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.fracture=&f;settings.clusters=cluster[:];settings.piece_clusters=membership[:]
    _,error:=destructible_create(&w.fracture,&w.sim,settings)
    testing.expect_value(t,error,Destructible_Error.Invalid_Desc)
    testing.expect_value(t,sim.world_stats(&w.sim).bodies,0)
}

@(test)
authored_piece_cluster_bond_and_hull_capacity_failures_leave_no_live_destructible :: proc(t:^testing.T) {
    for failure in 0..<4 {
        desc:=sim.world_desc_default();desc.body_capacity,desc.shape_capacity,desc.contact_capacity,desc.joint_capacity=8,8,16,0
        desc.hull_capacity=8
        capacities:=Desc{destructibles=1,pieces=8,connections=8}
        if failure==0 {capacities.pieces=3}
        if failure==1 {capacities.connections=5}
        if failure==2 {desc.hull_capacity=3}
        if failure==3 {desc.shape_capacity=3}
        w:World;testing.expect(t,world_init(&w,desc,capacities))
        h,error:=test_authored_destructible(&w)
        testing.expect_value(t,error,Destructible_Error.Capacity)
        testing.expect_value(t,h,Destructible_Handle(0))
        testing.expect_value(t,w.sim.body_count,i32(0));testing.expect_value(t,w.sim.shape_count,i32(0))
        testing.expect_value(t,w.fracture.destructible_count,i32(0));testing.expect_value(t,w.fracture.piece_count,i32(0));testing.expect_value(t,w.fracture.connection_count,i32(0))
        world_destroy(&w)
    }
}

@(test)
destructive_box_fields_use_oriented_common_falloff_without_impulse :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    h,_:=test_authored_destructible(&w,false,settings)
    region:=Region{point={0,3,0},half_extents={.2,3,.3},rotation=math.quat_axis_angle({0,0,1},sim.PI*.5),falloff=.Constant}
    event,broke,strained:=destructible_field_body(&w.fracture,&w.sim,h,-1,region,10000)
    testing.expect(t,broke && strained)
    testing.expect_value(t,event.vector,Vec3{})
    testing.expect_value(t,destruct_group_count(&w,h),4)
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    for piece in pieces {testing.expect_value(t,sim.body_linear_velocity(&w.sim,piece.body),Vec3{})}
}

@(test)
a_whole_cluster_collides_as_one_hull_with_the_mass_of_its_pieces_until_it_breaks :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,true,settings)
    if !testing.expect_value(t,error,Destructible_Error.None) {return}
    pieces:[4]Piece_Info;destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    for piece in pieces {testing.expect(t,piece.shape==pieces[0].shape && piece.body==pieces[0].body && piece.shape!={})}
    testing.expect_value(t,sim.world_stats(&w.sim).shapes,1)
    body:=pieces[0].body
    testing.expectf(t,abs(sim.body_mass(&w.sim,body)-4*2000)<0.05,"the hull weighs %v, its pieces 8000",sim.body_mass(&w.sim,body))
    testing.expect(t,length(sim.body_center(&w.sim,body)-Vec3{0,3,0})<1e-4)
    // The hull fills the gaps between its pieces while the cluster stands.
    hit,_:=sim.ray_cast_closest(&w.sim,{0,5,0},{0,-4,0})
    testing.expect_value(t,hit.body,body)
    destructible_strain(&w.fracture,&w.sim,h,{0,3,0},100,1000)
    testing.expect_value(t,sim.world_stats(&w.sim).shapes,2)
    destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    testing.expect(t,pieces[0].shape==pieces[1].shape && pieces[2].shape==pieces[3].shape && pieces[0].shape!=pieces[2].shape)
    hit,_=sim.ray_cast_closest(&w.sim,{0,5,0},{0,-4,0})
    testing.expect_value(t,hit.body,Body_Handle{})
    moved:=Filter{layers=2,block=2}
    destructible_set_filter(&w.fracture,&w.sim,h,moved)
    testing.expect(t,sim.shape_filter(&w.sim,pieces[0].shape)==moved && sim.shape_filter(&w.sim,pieces[2].shape)==moved)
    destructible_strain_body(&w.fracture,&w.sim,h,pieces[0].id,{-1.1,3,0},100,1000)
    testing.expect_value(t,sim.world_stats(&w.sim).shapes,3)
    destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
    testing.expect(t,pieces[0].shape!=pieces[1].shape && pieces[2].shape==pieces[3].shape)
    total:f32
    for piece,at in pieces {
        seen:=false
        for prior in pieces[:at] {seen||=prior.body==piece.body}
        if !seen {total+=sim.body_mass(&w.sim,piece.body)}
        testing.expect_value(t,sim.shape_filter(&w.sim,piece.shape),moved)
    }
    testing.expectf(t,abs(total-4*2000)<0.05,"the bodies weigh %v",total)
}

@(test)
an_impact_on_a_whole_cluster_names_one_of_its_pieces_and_breaks_it :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0;settings.damage_threshold=10;settings.damage_radius=3
    h,_:=test_authored_destructible(&w,true,settings)
    test_cannonball(&w,{0.55,6,0},{0,-30,0})
    found:=false
    for _ in 0..<30 {
        world_step(&w,1.0/60)
        for event in fracture_events(&w.fracture) {
            pieces:[4]Piece_Info
            count:=destructible_pieces(&w.fracture,&w.sim,h,pieces[:])
            named:=false
            for piece in pieces[:count] {named||=piece.id==event.piece}
            testing.expect(t,event.kind==.Impact && named)
            found=true
        }
        if found {break}
    }
    testing.expect(t,found)
    testing.expect(t,destructible_revision(&w.fracture,h)>0 && destruct_group_count(&w,h)>1)
}

@(test)
a_cut_without_hulls_for_its_halves_is_refused_and_says_so :: proc(t:^testing.T) {
    w:World;testing.expect(t,test_destruct_world(&w,512,5));defer world_destroy(&w)
    settings:=DESTRUCTIBLE_DESC_DEFAULT;settings.gravity_scale=0
    h,error:=test_authored_destructible(&w,false,settings)
    if !testing.expect_value(t,error,Destructible_Error.None) {return}
    _,cut:=destructible_slice(&w.fracture,&w.sim,h,{0.6,3,0},{1,0,0})
    testing.expect(t,!cut,"a cut without hulls for its halves does not happen")
    testing.expect_value(t,destructible_pieces(&w.fracture,&w.sim,h,nil),4)
    testing.expect_value(t,destruct_group_count(&w,h),1)
    _,refused:=destructible_shortfall(&w.fracture,h)
    testing.expect_value(t,refused,Capacities{.Hulls})
    world_step(&w,1.0/60)
    _,refused=destructible_shortfall(&w.fracture,h)
    testing.expect_value(t,refused,Capacities{})
}

@(test)
destruction_fields_accept_every_falloff_curve :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_destruct_world(&w))
    defer world_destroy(&w)
    h:=test_wall(&w)
    for falloff in Radial_Falloff {
        _,_,strained:=destructible_field_body(&w.fracture,&w.sim,h,-1,{point={0,1,0},radius=3,falloff=falloff},1,weaken=true)
        testing.expectf(t,strained,"%v strains nothing",falloff)
    }
    _,_,strained:=destructible_field_body(&w.fracture,&w.sim,h,-1,{point={0,1,0},radius=3,falloff=Radial_Falloff(5)},1,weaken=true)
    testing.expect(t,!strained)
}
