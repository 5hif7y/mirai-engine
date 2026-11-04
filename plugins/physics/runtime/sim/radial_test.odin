package mirai_physics

import "core:testing"

@(test)
radial_impulses_launch_a_grounded_character_in_the_same_tick :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_character_world(&w))
    defer world_destroy(&w)
    test_ground(&w)
    character:=character_create(&w,CHARACTER_DESC_DEFAULT,{})
    test_steps(&w,60)
    testing.expect(t,.Standing in character_state(&w,character).ground)
    count,ok:=world_apply_radial(&w,{0,-1,0},5,800,.Constant,true)
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,.Standing not_in character_state(&w,character).ground)
    testing.expect(t,character_velocity(&w,character).y>5)
}

@(test)
field_shapes_share_falloff_filters_and_body_deduplication :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    body:=test_body(&w,Sphere{0.1},{1,0,0})
    shape:=SHAPE_DESC_DEFAULT
    shape.geometry=Sphere{0.1}
    shape.transform.p={0,0.1,0}
    shape_create(&w,body,shape)
    mass:=body_mass(&w,body)
    count,ok:=world_apply_box_force(&w,{},Vec3{2,2,2},QUAT_IDENTITY,{mass*60,0,0},.Linear)
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,body).x-0.5)<0.01)
    count,ok=world_apply_sphere_force(&w,{},3,{0,mass*60,0},.Constant)
    testing.expect(t,ok && count==1)
    world_step(&w,1.0/60)
    testing.expect(t,abs(body_linear_velocity(&w,body).y-1)<0.01)
    count,ok=world_apply_box_radial_force(&w,{},Vec3{2,2,2},QUAT_IDENTITY,mass*60,.Constant,{filter={}})
    testing.expect(t,ok && count==0)
    testing.expect_value(t,radial_weight(0.5,1,.Linear),f32(0.5))
    testing.expect_value(t,box_weight({1,0,0},{},{2,2,2},QUAT_IDENTITY,.Linear),f32(0.5))
}

@(test)
each_falloff_curve_goes_from_the_border_to_the_center_within_its_range :: proc(t:^testing.T) {
    // Weights at the center, halfway and at the border, with the formulas of Chaos fields.
    expected:=[Radial_Falloff][3]f32{
        .Constant={1,1,1},
        .Linear={1,0.5,0},
        .Inverse={1,2*(1-1/1.5),0},
        .Squared={1,0.25,0},
        .Logarithmic={1,0.5849625,0},
    }
    for curve,falloff in expected {
        for value,i in curve {
            distance:=f32(i)*0.5
            testing.expectf(t,near(radial_weight(distance,1,falloff),value,1e-5),"%v at %v: %v",falloff,distance,radial_weight(distance,1,falloff))
            testing.expectf(t,near(radial_weight(distance,1,falloff,{0.2,0.8}),0.2+0.6*value,1e-5),"%v in range at %v",falloff,distance)
            testing.expectf(t,near(radial_weight(distance,1,falloff,{1,0}),1-value,1e-5),"%v inverted at %v",falloff,distance)
            testing.expectf(t,near(box_weight({0,0,2*distance},{},{1,1,2},QUAT_IDENTITY,falloff),value,1e-5),"%v in a box at %v",falloff,distance)
            // The plane is the +Y face; the curve falls with the depth below it, over the whole box.
            testing.expectf(t,near(plane_weight({0.5,2-4*distance,0},{0,0,0},{1,2,1},QUAT_IDENTITY,falloff),value,1e-5),"%v below a plane at %v",falloff,distance)
        }
        testing.expect_value(t,radial_weight(1.01,1,falloff,{0.5,1}),f32(0))
        testing.expect_value(t,plane_weight({1.1,0,0},{},{1,2,1},QUAT_IDENTITY,falloff),f32(0))
        testing.expect_value(t,plane_weight({0,2.1,0},{},{1,2,1},QUAT_IDENTITY,falloff),f32(0))
    }
    turned:=q_axis_angle({1,0,0},PI)
    testing.expectf(t,near(plane_weight({0,-2,0},{},{1,2,1},turned,.Linear),1,1e-5),"the plane turns with the box")
    testing.expect_value(t,radial_weight(0.5,1,Radial_Falloff(5)),f32(0))
    nan:=f32(0)
    nan/=nan
    testing.expect_value(t,radial_weight(0.5,1,.Linear,{nan,1}),f32(0))
}

@(test)
field_noise_is_the_same_for_equal_inputs_and_stays_in_its_range :: proc(t:^testing.T) {
    noise:=Field_Noise{scale=2,seed=7,range={0.25,0.75}}
    rotation:=q_axis_angle({0,1,0},0.3)
    low,high:=f32(1),f32(0)
    differs:=false
    for i in 0..<64 {
        point:=Vec3{f32(i)*0.37,f32(i%5)*0.9,-f32(i%7)*1.3}
        value:=noise_weight(point,{1,2,3},rotation,noise)
        testing.expect_value(t,noise_weight(point,{1,2,3},rotation,noise),value)
        other:=noise
        other.seed=8
        differs=differs || noise_weight(point,{1,2,3},rotation,other)!=value
        low,high=min(low,value),max(high,value)
    }
    testing.expectf(t,low>=0.25 && high<=0.75 && high-low>0.1,"noise from %v to %v",low,high)
    testing.expect(t,differs)
    testing.expect_value(t,noise_weight({1,2,3},{},QUAT_IDENTITY,{}),f32(1))
    testing.expect_value(t,noise_weight({1,2,3},{},QUAT_IDENTITY,{scale=-1}),f32(0))
    far:=noise_weight({3e38,-3e38,1},{},QUAT_IDENTITY,{scale=1e-3})
    testing.expect(t,far>=0 && far<=1)
}

@(test)
plane_and_noisy_volumes_weight_the_force_on_each_body :: proc(t:^testing.T) {
    w:World
    testing.expect(t,test_world(&w))
    defer world_destroy(&w)
    world_set_gravity(&w,{})
    depths:=[3]f32{0.25,1,1.75}
    bodies:[3]Body_Handle
    for depth,i in depths {bodies[i]=test_body(&w,Sphere{0.1},{f32(i)*2-2,2-depth,0})}
    mass:=body_mass(&w,bodies[0])
    count,ok:=world_apply_plane_force(&w,{0,1,0},{4,1,1},QUAT_IDENTITY,{0,0,mass*60},.Squared)
    testing.expect(t,ok && count==3)
    world_step(&w,1.0/60)
    for depth,i in depths {
        x:=1-depth/2
        testing.expectf(t,near(body_linear_velocity(&w,bodies[i]).z,x*x,1e-3),"depth %v: %v",depth,body_linear_velocity(&w,bodies[i]).z)
        body_set_velocity(&w,bodies[i],{},{})
    }
    noise:=Field_Noise{scale=0.7,seed=3,range={-1,1}}
    expected:[3]f32
    for body,i in bodies {expected[i]=noise_weight(body_position(&w,body),{0,1,0},QUAT_IDENTITY,noise)}
    count,ok=world_apply_box_force(&w,{0,1,0},{4,1,1},QUAT_IDENTITY,{mass*60,0,0},.Constant,QUERY_FILTER_DEFAULT,{},noise)
    testing.expect(t,ok && count==3)
    world_step(&w,1.0/60)
    for body,i in bodies {
        testing.expectf(t,near(body_linear_velocity(&w,body).x,expected[i],1e-3),"noise %v against %v",body_linear_velocity(&w,body).x,expected[i])
    }
    testing.expect(t,expected[0]!=expected[1] || expected[1]!=expected[2])
    _,ok=world_apply_sphere_force(&w,{},3,{1,0,0},.Linear,QUERY_FILTER_DEFAULT,{},{scale=-1})
    testing.expect(t,!ok)
    _,ok=world_apply_radial(&w,{},3,1,Radial_Falloff(9))
    testing.expect(t,!ok)
}
