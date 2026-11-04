package mirai_math

import "core:testing"

// Every public procedure takes whatever it is given and returns: NaN,
// infinities and huge or tiny numbers, zero-length vectors, degenerate
// matrices and shapes, curves and tables that are empty or unsorted, slices of
// other lengths, and bit counts and ranges out of range.

@(private="file") HOSTILE_ROUNDS :: #config(MATH_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,14) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    case 8: return -1
    case 9: return f32(0h7f7fffff)
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_vec2 :: proc(h:^Hostile) -> Vec2 {return {hostile_f32(h),hostile_f32(h)}}

@(private="file")
hostile_vec3 :: proc(h:^Hostile) -> Vec3 {
    if hostile_int(h,6)==0 {return {}}
    return {hostile_f32(h),hostile_f32(h),hostile_f32(h)}
}

@(private="file")
hostile_vec4 :: proc(h:^Hostile) -> Vec4 {return {hostile_f32(h),hostile_f32(h),hostile_f32(h),hostile_f32(h)}}

@(private="file")
hostile_quat :: proc(h:^Hostile) -> Quat {
    if hostile_int(h,6)==0 {return quaternion(w=0,x=0,y=0,z=0)}
    v:=hostile_vec4(h)
    return quaternion(w=v.w,x=v.x,y=v.y,z=v.z)
}

@(private="file")
hostile_mat4 :: proc(h:^Hostile) -> Mat4 {
    if hostile_int(h,6)==0 {return Mat4(0)}
    m:Mat4
    for column in 0..<4 {for row in 0..<4 {m[row,column]=hostile_f32(h)}}
    return m
}

@(private="file")
hostile_transform :: proc(h:^Hostile) -> Transform {return {hostile_vec3(h),hostile_quat(h),hostile_vec3(h)}}

@(private="file")
hostile_plane :: proc(h:^Hostile) -> Plane {return {hostile_vec3(h),hostile_f32(h)}}

@(private="file")
hostile_aabb :: proc(h:^Hostile) -> Aabb {
    if hostile_int(h,8)==0 {return AABB_EMPTY}
    return {hostile_vec3(h),hostile_vec3(h)}
}

@(private="file")
hostile_obb :: proc(h:^Hostile) -> Obb {return {hostile_vec3(h),hostile_quat(h),hostile_vec3(h)}}

@(private="file")
hostile_sphere :: proc(h:^Hostile) -> Sphere {return {hostile_vec3(h),hostile_f32(h)}}

@(private="file")
hostile_capsule :: proc(h:^Hostile) -> Capsule {return {hostile_vec3(h),hostile_vec3(h),hostile_f32(h)}}

@(private="file")
hostile_triangle :: proc(h:^Hostile) -> Triangle {return {hostile_vec3(h),hostile_vec3(h),hostile_vec3(h)}}

@(private="file")
hostile_ray :: proc(h:^Hostile) -> Ray {return {hostile_vec3(h),hostile_vec3(h)}}

@(private="file")
hostile_frustum :: proc(h:^Hostile) -> Frustum {
    if hostile_int(h,2)==0 {return frustum_from_matrix(hostile_mat4(h))}
    f:Frustum
    for &plane in f.planes {plane=hostile_plane(h)}
    return f
}

@(private="file")
hostile_ease :: proc(h:^Hostile) -> Ease {return Ease(hostile_int(h,4)==0?hostile_int(h,256):hostile_int(h,31))}

@(private="file")
hostile_rng :: proc(h:^Hostile) -> Rng {return rng_make(hostile_next(h),hostile_next(h))}

@(private="file")
hostile_bits :: proc(h:^Hostile) -> uint {
    switch hostile_int(h,6) {
    case 0: return 0
    case 1: return 64
    case 2: return 200
    case 3: return max(uint)
    case 4: return 1
    }
    return uint(hostile_int(h,33))
}

@(test)
hostile_numbers_through_the_scalar_functions :: proc(t:^testing.T) {
    h:=Hostile{1}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b,c,d,e:=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
        _=saturate(a);_=remap(a,b,c,d,e);_=remap_clamped(a,b,c,d,e);_=smoothstep(a,b,c);_=smootherstep(a,b,c)
        _=approach(a,b,c);_=approach_point(hostile_vec3(&h),hostile_vec3(&h),a)
        _=angle_wrap(a);_=angle_delta(a,b);_=angle_lerp(a,b,c);_=angle_approach(a,b,c)
        _=damp(a,b,c,d);_=damp(hostile_vec3(&h),hostile_vec3(&h),c,d);_=damp_angle(a,b,c,d)
        _,_=spring_critical(a,b,c,d,e)
        _,_=spring_critical(hostile_vec3(&h),hostile_vec3(&h),hostile_vec3(&h),d,e)
        _=spring_omega(a)
        _=snap(a,b);_=snap(hostile_vec3(&h),b);_=snap_from(a,b,c)
        velocity:f32
        _=smooth_damp(a,b,&velocity,c,d,e)
        velocity3:Vec3
        _=smooth_damp(hostile_vec3(&h),hostile_vec3(&h),&velocity3,c,d,e)
        _=smooth_damp_angle(a,b,&velocity,c,d,e)
        _=ease_apply(hostile_ease(&h),a)
        _=exp_det(a);_=ln_det(a);_,_=sincos_det(a);_=sin_det(b);_=cos_det(c)
    }
}

@(test)
hostile_numbers_through_the_easing :: proc(t:^testing.T) {
    h:=Hostile{2}
    for _ in 0..<HOSTILE_ROUNDS {
        for kind in 0..<256 {_=ease_apply(Ease(kind),hostile_f32(&h))}
    }
}

@(test)
hostile_numbers_through_the_quaternions :: proc(t:^testing.T) {
    h:=Hostile{3}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:=hostile_quat(&h),hostile_quat(&h)
        v,w:=hostile_vec3(&h),hostile_vec3(&h)
        _=quat_rotate(a,v);_=quat_inverse(a);_=quat_to_mat3(a);_=quat_from_mat3(Mat3(hostile_f32(&h)))
        _=quat_axis_angle(v,hostile_f32(&h));_=quat_between(v,w);_=quat_nlerp(a,b,hostile_f32(&h));_=quat_slerp(a,b,hostile_f32(&h))
        _=quat_angle(a,b);_=quat_look(v,w);_,_,_=look_basis(v,w)
        _=quat_from_euler(v);_=quat_to_euler(a);_=euler_near(v,w);_=euler_closest(v,w);_,_=quat_swing_twist(a,v)
    }
}

@(test)
hostile_matrices_through_the_transforms :: proc(t:^testing.T) {
    h:=Hostile{4}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b:=hostile_transform(&h),hostile_transform(&h)
        v,w:=hostile_vec3(&h),hostile_vec3(&h)
        m:=hostile_mat4(&h)
        _=mat4_point(m,v);_=mat4_vector(m,w)
        _=transform_compose(a,b);_,_=transform_relative(a,b);_,_=transform_inverse(a)
        _=transform_point(a,v);_=transform_vector(a,v);_=transform_direction(a,v)
        _=transform_inverse_point(a,v);_=transform_inverse_vector(a,v)
        _=transform_matrix(a);_,_=transform_inverse_matrix(a);_,_=transform_from_matrix(m)
        _=transform_from_euler(v,w,hostile_vec3(&h));_=transform_interpolate(a,b,hostile_f32(&h))
        _=aabb_transform(hostile_aabb(&h),m)
    }
}

@(test)
hostile_numbers_through_the_camera_matrices :: proc(t:^testing.T) {
    h:=Hostile{5}
    for _ in 0..<HOSTILE_ROUNDS {
        v,w:=hostile_vec3(&h),hostile_vec3(&h)
        m:=hostile_mat4(&h)
        _=look_at(v,w,hostile_vec3(&h));_=view_matrix(v,hostile_quat(&h))
        _=perspective(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
        _=perspective_infinite(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
        _=orthographic(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
        _=orthographic_off_center(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
        _,_,_=world_to_screen(v,hostile_vec2(&h),m)
        _=screen_ray(hostile_vec2(&h),hostile_vec2(&h),m,hostile_mat4(&h))
        _=perspective_world_per_pixel(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h))
    }
}

@(test)
hostile_shapes_through_the_queries :: proc(t:^testing.T) {
    h:=Hostile{6}
    points:[dynamic]Vec3
    defer delete(points)
    for _ in 0..<HOSTILE_ROUNDS {
        clear(&points)
        for _ in 0..<hostile_int(&h,6) {append(&points,hostile_vec3(&h))}
        box,other:=hostile_aabb(&h),hostile_aabb(&h)
        v:=hostile_vec3(&h)
        _=aabb_from_center(v,hostile_vec3(&h));_=aabb_from_points(points[:]);_=aabb_center(box);_=aabb_half(box);_=aabb_size(box)
        _=aabb_is_empty(box);_=aabb_merge(box,other);_=aabb_add_point(box,v);_=aabb_expand(box,hostile_f32(&h))
        _=aabb_surface_area(box);_=aabb_volume(box);_=aabb_contains_point(box,v);_=aabb_contains(box,other)
        _=aabb_from_obb(hostile_obb(&h));_=aabb_from_sphere(hostile_sphere(&h));_=aabb_from_capsule(hostile_capsule(&h))
        _=plane_from_point(v,hostile_vec3(&h));_=plane_from_points(v,hostile_vec3(&h),hostile_vec3(&h));_=plane_distance(hostile_plane(&h),v)
        frustum:=hostile_frustum(&h)
        _=aabb_overlaps(box,other);_=sphere_overlaps(hostile_sphere(&h),hostile_sphere(&h));_=sphere_overlaps_aabb(hostile_sphere(&h),box)
        _=frustum_overlaps_aabb(frustum,box);_=frustum_overlaps_sphere(frustum,hostile_sphere(&h))
        _=obb_overlaps(hostile_obb(&h),hostile_obb(&h));_=obb_separation(hostile_obb(&h),hostile_obb(&h))
        ray:=hostile_ray(&h)
        _=ray_at(ray,hostile_f32(&h));_,_=ray_plane(ray,hostile_plane(&h));_,_,_=ray_aabb(ray,box)
        _,_=ray_aabb_fast(ray.origin,ray.direction,box,hostile_f32(&h))
        _,_,_=ray_obb(ray,hostile_obb(&h));_,_,_=ray_sphere(ray,hostile_sphere(&h));_,_,_=ray_capsule(ray,hostile_capsule(&h))
        _,_,_=ray_triangle(ray,hostile_triangle(&h));_=triangle_normal(hostile_triangle(&h));_,_,_=ray_frustum(ray,frustum)
        _,_,_=line_line_closest(v,hostile_vec3(&h),hostile_vec3(&h),hostile_vec3(&h))
        _=closest_point_plane(v,hostile_plane(&h));_=closest_point_aabb(v,box);_=closest_point_obb(v,hostile_obb(&h))
        _,_=closest_point_segment(v,Segment{hostile_vec3(&h),hostile_vec3(&h)})
        _,_,_,_=closest_segment_segment(Segment{hostile_vec3(&h),hostile_vec3(&h)},Segment{hostile_vec3(&h),hostile_vec3(&h)})
        _=closest_point_triangle(v,hostile_triangle(&h))
    }
}

@(test)
hostile_lengths_through_the_frustum_culling :: proc(t:^testing.T) {
    h:=Hostile{7}
    boxes:[dynamic]Aabb
    visible:[dynamic]u64
    defer {delete(boxes);delete(visible)}
    for _ in 0..<HOSTILE_ROUNDS {
        resize(&boxes,hostile_int(&h,130))
        for &box in boxes {box=hostile_aabb(&h)}
        resize(&visible,(len(boxes)+63)/64+hostile_int(&h,2))
        _=frustum_cull_aabbs(hostile_frustum(&h),boxes[:],visible[:])
        _=frustum_cull_aabbs_scalar(hostile_frustum(&h),boxes[:],visible[:])
    }
}

@(test)
hostile_short_visibility_through_the_frustum_culling :: proc(t:^testing.T) {
    h:=Hostile{8}
    boxes:[130]Aabb
    visible:[3]u64
    for _ in 0..<HOSTILE_ROUNDS {
        count:=hostile_int(&h,131)
        _=frustum_cull_aabbs(hostile_frustum(&h),boxes[:count],visible[:hostile_int(&h,(count+63)/64)])
    }
}

@(test)
hostile_lanes_through_the_box_packets :: proc(t:^testing.T) {
    h:=Hostile{9}
    for _ in 0..<HOSTILE_ROUNDS {
        boxes:Aabb4
        aabb4_set(&boxes,hostile_int(&h,6)-1,hostile_aabb(&h))
        ray:=hostile_ray(&h)
        _,_=ray_aabb4(ray.origin,ray.direction,&boxes,hostile_f32(&h))
    }
}

@(test)
hostile_numbers_through_the_curves :: proc(t:^testing.T) {
    h:=Hostile{10}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b,c,d:=hostile_vec3(&h),hostile_vec3(&h),hostile_vec3(&h),hostile_vec3(&h)
        s:=hostile_f32(&h)
        _=bezier_quadratic(a,b,c,s);_=bezier_quadratic_tangent(a,b,c,s);_=bezier_cubic(a,b,c,d,s);_=bezier_cubic_tangent(a,b,c,d,s)
        _=hermite(a,b,c,d,s);_=catmull_rom(a,b,c,d,s);_=catmull_rom_tangent(a,b,c,d,s);_=b_spline(a,b,c,d,s)
        _=bezier_cubic(hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),hostile_f32(&h),s)
    }
}

@(test)
hostile_lengths_through_the_arc_table :: proc(t:^testing.T) {
    h:=Hostile{11}
    points:[dynamic]Vec3
    lengths:[dynamic]f32
    defer {delete(points);delete(lengths)}
    for _ in 0..<HOSTILE_ROUNDS {
        resize(&points,hostile_int(&h,8))
        for &p in points {p=hostile_vec3(&h)}
        resize(&lengths,len(points)+hostile_int(&h,3)-1)
        _=arc_table_build(points[:],lengths[:])
    }
}

@(test)
hostile_numbers_through_the_arc_table_lookups :: proc(t:^testing.T) {
    h:=Hostile{12}
    lengths:[dynamic]f32
    defer delete(lengths)
    for _ in 0..<HOSTILE_ROUNDS {
        resize(&lengths,hostile_int(&h,8))
        total:f32
        for &l in lengths {
            total+=hostile_int(&h,4)==0?hostile_f32(&h):f32(hostile_int(&h,5))
            l=total
        }
        _=arc_table_parameter(lengths[:],hostile_f32(&h))
        _=arc_table_distance(lengths[:],hostile_f32(&h))
    }
}

@(private="file")
hostile_curve_keys :: proc(h:^Hostile,keys:^[dynamic]Curve_Key) {
    resize(keys,hostile_int(h,7))
    time:f32
    for &key in keys {
        time=hostile_int(h,5)==0?hostile_f32(h):time+f32(hostile_int(h,4))/2
        key={time,hostile_f32(h),hostile_f32(h),hostile_f32(h),Curve_Interpolation(hostile_int(h,5)==0?hostile_int(h,256):hostile_int(h,3))}
    }
}

@(test)
hostile_keys_through_the_curve_evaluation :: proc(t:^testing.T) {
    h:=Hostile{13}
    keys:[dynamic]Curve_Key
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_curve_keys(&h,&keys)
        for _ in 0..<6 {_=curve_evaluate(keys[:],hostile_f32(&h))}
        curve_smooth_slopes(keys[:])
    }
}

@(test)
hostile_segments_through_the_curve_cursor :: proc(t:^testing.T) {
    h:=Hostile{14}
    keys:[dynamic]Curve_Key
    defer delete(keys)
    for _ in 0..<HOSTILE_ROUNDS {
        hostile_curve_keys(&h,&keys)
        segment:=hostile_int(&h,3)==0?hostile_int(&h,100)-50:hostile_int(&h,len(keys)+1)
        for _ in 0..<6 {_=curve_evaluate_from(keys[:],hostile_f32(&h),&segment)}
    }
}

@(test)
hostile_numbers_through_the_random_functions :: proc(t:^testing.T) {
    h:=Hostile{15}
    items:[dynamic]u32
    weights:[dynamic]f32
    defer {delete(items);delete(weights)}
    for _ in 0..<HOSTILE_ROUNDS {
        rng:=hostile_rng(&h)
        bound:=hostile_int(&h,3)==0?hostile_int(&h,2)==0?max(int):min(int):hostile_int(&h,100)-50
        low:=hostile_int(&h,3)==0?min(int):hostile_int(&h,100)-50
        _=random_f32(&rng);_=random_range(&rng,hostile_f32(&h),hostile_f32(&h));_=random_below(&rng,u32(hostile_next(&h)))
        _=random_int(&rng,low,bound)
        _=random_bool(&rng,hostile_f32(&h));_=random_sign(&rng)
        _=random_in_disc(&rng);_=random_unit_vec2(&rng);_=random_in_sphere(&rng);_=random_unit_vec3(&rng)
        _=random_in_cone(&rng,hostile_vec3(&h),hostile_f32(&h));_=random_quat(&rng);_=random_gaussian(&rng,hostile_f32(&h),hostile_f32(&h))
        resize(&weights,hostile_int(&h,8))
        for &w in weights {w=hostile_f32(&h)}
        _=random_weighted(&rng,weights[:])
        resize(&items,hostile_int(&h,8))
        random_shuffle(&rng,items[:])
        nothing:[]u32
        random_shuffle(&rng,nothing)
    }
}

@(test)
hostile_coordinates_through_the_noise :: proc(t:^testing.T) {
    h:=Hostile{16}
    for _ in 0..<HOSTILE_ROUNDS {
        p2,p3:=hostile_vec2(&h),hostile_vec3(&h)
        seed:=u32(hostile_next(&h))
        _=noise_hash(i32(hostile_next(&h)),i32(hostile_next(&h)),i32(hostile_next(&h)),seed);_=noise_unit(u32(hostile_next(&h)));_=noise_fade(p2.x);_=noise_fade_slope(p2.y)
        _=noise_value2(p2,seed);_=noise_value3(p3,seed);_=noise_perlin2(p2,seed);_=noise_perlin3(p3,seed)
        _,_=noise_perlin2_gradient(p2,seed);_,_=noise_perlin3_gradient(p3,seed)
        _,_=noise_worley2(p2,seed);_,_=noise_worley3(p3,seed)
        _=noise_curl2(p2,seed);_=noise_curl3(p3,seed)
    }
}

@(test)
hostile_coordinates_through_the_simplex_noise :: proc(t:^testing.T) {
    h:=Hostile{17}
    for _ in 0..<HOSTILE_ROUNDS {
        p2,p3:=hostile_vec2(&h),hostile_vec3(&h)
        seed:=u32(hostile_next(&h))
        _=noise_simplex2(p2,seed);_=noise_simplex3(p3,seed)
        kind:=Noise_Kind(hostile_int(&h,4))
        _=noise2(kind,p2,seed);_=noise3(kind,p3,seed)
    }
}

@(test)
hostile_fractals_through_the_noise :: proc(t:^testing.T) {
    h:=Hostile{18}
    for _ in 0..<HOSTILE_ROUNDS {
        p2,p3:=hostile_vec2(&h),hostile_vec3(&h)
        fractal:=Fractal{Noise_Kind(hostile_int(&h,2)),u8(hostile_next(&h)),hostile_f32(&h),hostile_f32(&h),u32(hostile_next(&h))}
        _=noise_fbm2(p2,fractal);_=noise_fbm3(p3,fractal);_=noise_ridged2(p2,fractal);_=noise_ridged3(p3,fractal)
        _=noise_turbulence2(p2,fractal);_=noise_turbulence3(p3,fractal)
    }
}

@(test)
hostile_numbers_through_the_colors :: proc(t:^testing.T) {
    h:=Hostile{19}
    for _ in 0..<HOSTILE_ROUNDS {
        v3:=hostile_vec3(&h)
        v4:=hostile_vec4(&h)
        a:=hostile_f32(&h)
        _=srgb_to_linear(a);_=linear_to_srgb(a);_=srgb_to_linear(v3);_=linear_to_srgb(v3);_=srgb_to_linear(v4);_=linear_to_srgb(v4)
        _=hsv_to_rgb(v3);_=rgb_to_hsv(v3);_=hsl_to_rgb(v3);_=rgb_to_hsl(v3);_=linear_to_oklab(v3);_=oklab_to_linear(v3)
        _=color_mix_oklab(v4,hostile_vec4(&h),a)
        packed:=rgba8_pack(v4)
        _=rgba8_unpack(u32(hostile_next(&h)));_=rgba8_from_linear(v4);_=rgba8_to_linear(packed)
    }
}

@(test)
hostile_stops_through_the_gradient :: proc(t:^testing.T) {
    h:=Hostile{20}
    stops:[dynamic]Gradient_Stop
    defer delete(stops)
    for _ in 0..<HOSTILE_ROUNDS {
        resize(&stops,hostile_int(&h,7))
        position:f32
        for &stop in stops {
            position=hostile_int(&h,5)==0?hostile_f32(&h):position+f32(hostile_int(&h,3))
            stop={position,hostile_vec4(&h)}
        }
        for _ in 0..<4 {_=gradient_evaluate(stops[:],hostile_f32(&h),Gradient_Space(hostile_int(&h,3)))}
    }
}

@(test)
hostile_text_through_the_hex_colors :: proc(t:^testing.T) {
    h:=Hostile{21}
    digits:="0123456789abcdefABCDEF"
    bytes:[16]u8
    out:[16]u8
    for _ in 0..<HOSTILE_ROUNDS {
        for &b in bytes {
            switch hostile_int(&h,5) {
            case 0: b=u8(hostile_next(&h))
            case 1: b='#'
            case 2: b=u8(digits[hostile_int(&h,22)])
            case: b=u8(digits[hostile_int(&h,16)])
            }
        }
        _,_=color_parse_hex(string(bytes[:hostile_int(&h,17)]))
        _,_=color_parse_hex("")
        _=color_format_hex(hostile_vec4(&h),out[:hostile_int(&h,17)])
    }
}

@(test)
hostile_values_through_the_quantization :: proc(t:^testing.T) {
    h:=Hostile{22}
    for _ in 0..<HOSTILE_ROUNDS {
        a,b,c:=hostile_f32(&h),hostile_f32(&h),hostile_f32(&h)
        bits:=hostile_bits(&h)
        _=quantize(a,b,c,bits);_=dequantize(u32(hostile_next(&h)),b,c,bits)
        _=unorm8_pack(a);_=unorm8_unpack(u8(hostile_next(&h)));_=unorm16_pack(a);_=unorm16_unpack(u16(hostile_next(&h)))
        _=snorm8_pack(a);_=snorm8_unpack(i8(hostile_next(&h)));_=snorm16_pack(a);_=snorm16_unpack(i16(hostile_next(&h)))
        _=half_pack(a);_=half_unpack(u16(hostile_next(&h)))
        _=octahedral_encode(hostile_vec3(&h));_=octahedral_decode(hostile_vec2(&h))
        _=normal_pack(hostile_vec3(&h));_=normal_unpack(u32(hostile_next(&h)))
        q:=hostile_quat(&h)
        _=quat_pack(q,bits);_=quat_unpack(hostile_next(&h),bits)
        _=quat_pack(q);_=quat_unpack(hostile_next(&h))
    }
}
