package physics_fields

import "core:math/linalg"
import "core:mem"
import "core:testing"
import "mirai:core"
import destruct "plugins:destruct/runtime"
import phys "plugins:physics/runtime"
import mm "mirai:std/math"

@(test)
persistent_fields_transform_filter_and_accumulate_strain_independent_of_force :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    fields:core.Table(Physics_Field);poses:core.Table(core.Transform);parents:core.Table(core.Parent);objects:core.Table(destruct.Destructible)
    defer core.table_destroy(&fields);defer core.table_destroy(&poses);defer core.table_destroy(&parents);defer core.table_destroy(&objects)
    body_requests:phys.Body_Requests;damage:destruct.Destruct_Requests;authority:core.Network
    defer delete(body_requests.queue.items);defer delete(damage.queue.items)
    field:=core.create(&entities);target:=core.create(&entities);filtered:=core.create(&entities)
    config:=PHYSICS_FIELD_DEFAULT;config.shape=.Box;config.direction=.Directional;config.half_extents={1,2,3};config.vector={1,0,0};config.force=10;config.strain=120;config.weakening=true;config.filter.objects=4
    config.filter.ignore_body=17
    core.add(&fields,field,config);core.add(&poses,field,core.Transform{{3,4,5},mm.quat_axis_angle({0,1,0},mm.PI*.5),{2,1,.5}})
    colliders:core.Table(phys.Collider);defer core.table_destroy(&colliders)
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    for category,i in ([2]phys.Collision_Category{2,3}) {
        e:=i==0?target:filtered
        core.add(&objects,e,destruct.destructible())
        collider:=destruct.collider_fracture();phys.collision_custom(&collider,phys.collision_layers(category),phys.COLLISION_LAYERS_ALL);core.add(&colliders,e,collider)
    }
    core.table_settle(&fields,&entities);core.table_settle(&poses,&entities);core.table_settle(&objects,&entities);core.table_settle(&colliders,&entities);core.entities_settle(&entities)
    for _ in 0..<3 {physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&body_requests,&damage,{playing=true,dt=.25},core.ref(&collision))}
    testing.expect_value(t,len(body_requests.queue.items),3);testing.expect_value(t,len(damage.queue.items),3)
    force:=body_requests.queue.items[0]
    testing.expect_value(t,force.kind,phys.Body_Request_Kind.Box_Force);testing.expect_value(t,force.position,mm.Vec3{3,4,5})
    testing.expect_value(t,force.half_extents,mm.Vec3{2,2,1.5});testing.expect(t,abs(force.linear.x)<.001 && abs(abs(force.linear.z)-10)<.001)
    event:=damage.queue.items[0]
    testing.expect_value(t,event.entity,target);testing.expect_value(t,event.kind,destruct.Fracture_Kind.Weaken)
    testing.expect_value(t,event.strain,f32(30));testing.expect_value(t,event.vector,mm.Vec3{})
    testing.expect_value(t,event.ignore_body,config.filter.ignore_body)
    testing.expect_value(t,event.region.half_extents,mm.Vec3{2,2,1.5})
    core.queue_clear(&body_requests.queue);core.queue_clear(&damage.queue)
    authority.role=.Client
    physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&body_requests,&damage,{playing=true,dt=.25},core.ref(&collision))
    testing.expect_value(t,len(body_requests.queue.items),1);testing.expect_value(t,len(damage.queue.items),0)
}

@(test)
steady_persistent_fields_reuse_request_capacity_and_disabled_fields_do_nothing :: proc(t:^testing.T) {
    tracking:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracking,context.allocator);defer mem.tracking_allocator_destroy(&tracking)
    previous:=context.allocator;context.allocator=mem.tracking_allocator(&tracking);defer {context.allocator=previous}
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    fields:core.Table(Physics_Field);poses:core.Table(core.Transform);parents:core.Table(core.Parent);objects:core.Table(destruct.Destructible)
    defer core.table_destroy(&fields);defer core.table_destroy(&poses);defer core.table_destroy(&parents);defer core.table_destroy(&objects)
    requests:phys.Body_Requests;damage:destruct.Destruct_Requests;authority:core.Network
    defer delete(requests.queue.items);defer delete(damage.queue.items)
    colliders:core.Table(phys.Collider);defer core.table_destroy(&colliders)
    e:=core.create(&entities);config:=PHYSICS_FIELD_DEFAULT;config.force=10
    core.add(&fields,e,config);core.add(&poses,e,core.TRANSFORM_DEFAULT)
    core.table_settle(&fields,&entities);core.table_settle(&poses,&entities);core.entities_settle(&entities)
    physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&requests,&damage,{playing=true,dt=.1},{})
    before:=tracking.total_allocation_count
    for _ in 0..<128 {
        core.queue_clear(&requests.queue)
        physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&requests,&damage,{playing=true,dt=.1},{})
    }
    testing.expect_value(t,tracking.total_allocation_count,before)
    core.disable(&fields,e);core.table_settle(&fields,&entities);core.queue_clear(&requests.queue)
    physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&requests,&damage,{playing=true,dt=.1},{})
    testing.expect_value(t,len(requests.queue.items),0)
}

@(test)
plane_and_noise_fields_send_their_region_direction_range_and_noise :: proc(t:^testing.T) {
    entities:core.Entities;core.entities_init(&entities);defer core.entities_destroy(&entities)
    fields:core.Table(Physics_Field);poses:core.Table(core.Transform);parents:core.Table(core.Parent);objects:core.Table(destruct.Destructible)
    defer core.table_destroy(&fields);defer core.table_destroy(&poses);defer core.table_destroy(&parents);defer core.table_destroy(&objects)
    colliders:core.Table(phys.Collider);defer core.table_destroy(&colliders)
    requests:phys.Body_Requests;damage:destruct.Destruct_Requests;authority:core.Network
    defer delete(requests.queue.items);defer delete(damage.queue.items)
    collision:=phys.COLLISION_SETTINGS_DEFAULT
    turn:=mm.quat_axis_angle({0,0,1},mm.PI*.5)
    noise:=phys.Field_Noise{scale=2,seed=5,range={.5,1.5}}
    radial,directional,noisy,target:=core.create(&entities),core.create(&entities),core.create(&entities),core.create(&entities)
    plane:=PHYSICS_FIELD_DEFAULT;plane.shape=.Plane;plane.half_extents={1,2,3};plane.force=40;plane.strain=10;plane.falloff=.Squared;plane.falloff_range={.2,1}
    core.add(&fields,radial,plane)
    plane.direction,plane.vector,plane.strain=.Directional,{0,0,2},0
    core.add(&fields,directional,plane)
    sphere:=PHYSICS_FIELD_DEFAULT;sphere.force=-5;sphere.falloff=.Inverse;sphere.noise=noise
    core.add(&fields,noisy,sphere)
    for e in ([3]core.Entity{radial,directional,noisy}) {core.add(&poses,e,core.Transform{{1,2,3},turn,{1,1,1}})}
    core.add(&objects,target,destruct.destructible());core.add(&colliders,target,destruct.collider_fracture())
    core.table_settle(&fields,&entities);core.table_settle(&poses,&entities);core.table_settle(&objects,&entities);core.table_settle(&colliders,&entities);core.entities_settle(&entities)
    physics_fields_step(core.read(&fields),core.read(&poses),core.read(&parents),core.read(&objects),core.read(&colliders),core.ref(&authority),&requests,&damage,{playing=true,dt=.5},core.ref(&collision))
    testing.expect_value(t,len(requests.queue.items),3)
    first,second,third:=requests.queue.items[0],requests.queue.items[1],requests.queue.items[2]
    // A radial plane pushes along its normal, the local +Y turned by the pose.
    testing.expect_value(t,first.kind,phys.Body_Request_Kind.Plane_Force)
    testing.expect_value(t,first.half_extents,mm.Vec3{1,2,3})
    testing.expect(t,linalg.length(first.linear-mm.Vec3{-40,0,0})<1e-4)
    testing.expect_value(t,first.falloff,phys.Radial_Falloff.Squared)
    testing.expect_value(t,first.falloff_range,phys.Weight_Range{.2,1})
    testing.expect_value(t,second.kind,phys.Body_Request_Kind.Plane_Force)
    testing.expect(t,linalg.length(second.linear-mm.Vec3{0,0,40})<1e-4)
    testing.expect_value(t,third.kind,phys.Body_Request_Kind.Radial_Force)
    testing.expect_value(t,third.noise,noise)
    testing.expect_value(t,third.falloff,phys.Radial_Falloff.Inverse)
    // Strain takes the box of the plane.
    testing.expect_value(t,len(damage.queue.items),1)
    testing.expect_value(t,damage.queue.items[0].region.half_extents,mm.Vec3{1,2,3})
    testing.expect_value(t,damage.queue.items[0].region.falloff,phys.Radial_Falloff.Squared)
    testing.expect_value(t,damage.queue.items[0].strain,f32(5))
}
