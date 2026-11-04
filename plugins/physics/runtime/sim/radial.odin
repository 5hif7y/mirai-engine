package mirai_physics

import cmath "core:math"
import "mirai:std/spatial"
import "mirai:std/base"
import math "mirai:std/math"

// How the weight of a volume goes from its border (x=0) to its center (x=1): the falloff curves of Chaos
// fields.
Radial_Falloff :: enum u8 {
    Constant,    // 1
    Linear,      // x
    Inverse,     // 2(1-1/(x+1)): drops slowly near the center and fast near the border
    Squared,     // x*x: drops fast near the center and slowly near the border
    Logarithmic, // log2(x+1)
}

// Weights at the border (min) and at the center (max): the curve goes from one to the other, as MinRange and
// MaxRange of a Chaos field. The zero value is {0,1}.
Weight_Range :: struct {min,max:f32}

// Gradient noise that scales the weight of a volume: features about `scale` meters across, fixed to the frame
// of the volume, taken from 0..1 to `range`. Zero scale is no noise.
Field_Noise :: struct {
    scale:f32, // m
    seed:u32,
    range:Weight_Range,
}

@(private) NOISE_REACH :: f32(1<<24) // noise coordinates beyond it repeat the border instead of overflowing

@(private)
weight_range_valid :: #force_inline proc "contextless" (range:Weight_Range) -> bool {
    return range.min>=-max(f32) && range.min<=max(f32) && range.max>=-max(f32) && range.max<=max(f32)
}

@(private)
field_noise_valid :: #force_inline proc "contextless" (noise:Field_Noise) -> bool {
    return noise.scale==0 || noise.scale>0 && noise.scale<=max(f32) && weight_range_valid(noise.range)
}

@(private)
weight_from_range :: #force_inline proc "contextless" (range:Weight_Range,x:f32) -> f32 {
    if range=={} {return x}
    return range.min+(range.max-range.min)*x
}

@(private)
falloff_curve :: proc "contextless" (x:f32,falloff:Radial_Falloff) -> f32 {
    switch falloff {
    case .Constant: return 1
    case .Linear: return x
    case .Inverse: return 2*(1-1/(x+1))
    case .Squared: return x*x
    case .Logarithmic: return cmath.log2(x+1)
    }
    return 0
}

// Weight at `distance` from the center of a volume of `radius`: zero outside it or for values that are not
// valid.
radial_weight :: proc "contextless" (distance,radius:f32,falloff:Radial_Falloff,range:Weight_Range={}) -> f32 {
    if !(radius>0 && radius<=max(f32) && distance>=0 && distance<=radius) || falloff>.Logarithmic || !weight_range_valid(range) {return 0}
    return weight_from_range(range,falloff_curve(max(1-distance/radius,0),falloff))
}

// Weight in an oriented box, whose border is its surface.
box_weight :: proc "contextless" (point,center,half:Vec3,rotation:Quat,falloff:Radial_Falloff,range:Weight_Range={}) -> f32 {
    for value in half {if !(value>0 && value<=max(f32)) {return 0}}
    local:=vabs(q_inv_rotate(q_normalize(rotation),point-center))/half
    distance:=max(local.x,local.y,local.z)
    return radial_weight(distance,1,falloff,range)
}

// Weight in an oriented box whose local +Y face is the plane: it is the center of the curve, and the border is
// the -Y face, the whole depth of the box below it.
plane_weight :: proc "contextless" (point,center,half:Vec3,rotation:Quat,falloff:Radial_Falloff,range:Weight_Range={}) -> f32 {
    for value in half {if !(value>0 && value<=max(f32)) {return 0}}
    local:=q_inv_rotate(q_normalize(rotation),point-center)/half
    if !(abs(local.x)<=1 && abs(local.y)<=1 && abs(local.z)<=1) {return 0}
    return radial_weight(1-local.y,2,falloff,range)
}

// Weight of the noise of a volume at a point: 1 without noise, zero for a noise that is not valid.
noise_weight :: proc "contextless" (point,center:Vec3,rotation:Quat,noise:Field_Noise) -> f32 {
    if noise.scale==0 {return 1}
    if !field_noise_valid(noise) {return 0}
    local:=q_inv_rotate(q_normalize(rotation),point-center)/noise.scale
    for &value in local {value=clamp(value,-NOISE_REACH,NOISE_REACH)}
    value:=clamp(0.5*(math.noise_perlin3(local,noise.seed)+1),0,1)
    return weight_from_range(noise.range,value)
}

world_apply_radial :: proc(w:^World,center:Vec3,radius,strength:f32,falloff:Radial_Falloff=.Linear,impulse:=false,velocity_change:=false,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    if !(radius>0 && radius<=max(f32) && strength>=-max(f32) && strength<=max(f32)) || velocity_change && !impulse {return 0,false}
    return world_apply_volume(w,Sphere{radius},{center,QUAT_IDENTITY},{strength,0,0},{falloff,range,noise,false},true,impulse,velocity_change,filter)
}

world_apply_box_force :: proc(w:^World,center,half:Vec3,rotation:Quat,force:Vec3,falloff:Radial_Falloff=.Constant,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    for value in half {if !(value>0 && value<=max(f32)) {return 0,false}}
    return world_apply_volume(w,Box{half},{center,rotation},force,{falloff,range,noise,false},false,false,false,filter)
}

world_apply_sphere_force :: proc(w:^World,center:Vec3,radius:f32,force:Vec3,falloff:Radial_Falloff=.Constant,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    if !(radius>0 && radius<=max(f32)) {return 0,false}
    return world_apply_volume(w,Sphere{radius},{center,QUAT_IDENTITY},force,{falloff,range,noise,false},false,false,false,filter)
}

world_apply_box_radial_force :: proc(w:^World,center,half:Vec3,rotation:Quat,strength:f32,falloff:Radial_Falloff=.Linear,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    for value in half {if !(value>0 && value<=max(f32)) {return 0,false}}
    return world_apply_volume(w,Box{half},{center,rotation},{strength,0,0},{falloff,range,noise,false},true,false,false,filter)
}

// A force in a box weighted by plane_weight: strongest at its local +Y face, falling with the depth below it.
world_apply_plane_force :: proc(w:^World,center,half:Vec3,rotation:Quat,force:Vec3,falloff:Radial_Falloff=.Linear,filter:=QUERY_FILTER_DEFAULT,range:Weight_Range={},noise:Field_Noise={}) -> (count:int,ok:bool) {
    for value in half {if !(value>0 && value<=max(f32)) {return 0,false}}
    return world_apply_volume(w,Box{half},{center,rotation},force,{falloff,range,noise,true},false,false,false,filter)
}

@(private) Volume_Weight :: struct {falloff:Radial_Falloff,range:Weight_Range,noise:Field_Noise,plane:bool}

@(private)
world_apply_volume :: proc(w:^World,geometry:Geometry,transform:Transform,force:Vec3,weight:Volume_Weight,radial,impulse,velocity_change:bool,filter:Query_Filter) -> (count:int,ok:bool) {
    if w==nil || len(w.bodies)==0 || weight.falloff>.Logarithmic || !weight_range_valid(weight.range) || !field_noise_valid(weight.noise) {return 0,false}
    for value in transform.p {if !(value>=-max(f32) && value<=max(f32)) {return 0,false}}
    for value in force {if !(value>=-max(f32) && value<=max(f32)) {return 0,false}}
    for value in ([4]f32{transform.q.x,transform.q.y,transform.q.z,transform.q.w}) {if !(value>=-max(f32) && value<=max(f32)) {return 0,false}}
    xf:=Transform{transform.p,q_normalize(transform.q)}
    storage:[8]Vec3
    proxy,valid:=query_proxy(w,geometry,&storage)
    if !valid {return 0,false}
    box:=proxy_aabb(proxy,xf)
    for value in box.min {if !(value>=-max(f32) && value<=max(f32)) {return 0,false}}
    for value in box.max {if !(value>=-max(f32) && value<=max(f32)) {return 0,false}}
    marks:=w.step.color_bits[:w.step.color_words]
    for &word in marks {word=0}
    query:=spatial.dynamic_tree_query(&w.trees[DYNAMIC_TREE],box)
    for _,user in spatial.tree_query_next(&query) {
        shape:=&w.shapes[user]
        body:=&w.bodies[shape.body]
        if body.type!=.Dynamic || query_response(w,shape,filter)==.Ignore || !math.aabb_overlaps(shape.aabb,box) {continue}
        slot:=int(shape.body)
        bit:=u64(1)<<u32(slot&63)
        if marks[slot>>6]&bit!=0 {continue}
        if _,touching:=shape_distance_local(w,shape,proxy,xf_inv_mul(shape_transform_of(w,shape),xf),0);!touching {continue}
        marks[slot>>6]|=bit
        vector:=force
        if radial {vector=normalize(body.center-transform.p)*force.x}
        switch g in geometry {
        case Sphere:
            vector*=radial_weight(length(body.center-transform.p),g.radius,weight.falloff,weight.range)
        case Box:
            if weight.plane {vector*=plane_weight(body.center,xf.p,g.half_extents,xf.q,weight.falloff,weight.range)}
            else {vector*=box_weight(body.center,xf.p,g.half_extents,xf.q,weight.falloff,weight.range)}
        case Capsule,Cylinder,Hull_Handle,Mesh_Handle,Heightfield_Handle: continue
        }
        if weight.noise.scale!=0 {vector*=noise_weight(body.center,xf.p,xf.q,weight.noise)}
        if vector=={} {continue}
        handle:=body_handle(w,shape.body)
        if impulse {
            if velocity_change {vector*=body.mass}
            if .Character in body.flags {
                for &character,character_slot in w.characters[:w.character_high] {
                    if character.generation&1!=0 && character.body==handle {
                        character_launch(w,Character_Handle(base.handle_make(u32(character_slot),character.generation)),vector*body.inv_mass)
                        break
                    }
                }
                count+=1
                continue
            }
            body_apply_impulse(w,handle,vector)
        } else {
            body_apply_force(w,handle,vector)
        }
        count+=1
    }
    return count,true
}
