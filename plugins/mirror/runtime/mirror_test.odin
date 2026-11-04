package mirror

import "core:math/linalg"
import "core:testing"
import render "mirai:engine/render"
import mm "mirai:std/math"

@(test)
a_mirror_sends_what_is_in_front_of_it_as_far_behind :: proc(t:^testing.T) {
    // A face at x = 2 that looks towards +x.
    plane:=[4]f32{1,0,0,-2}
    m:=reflection(plane)
    seen:=m*[4]f32{5,1,-3,1}
    testing.expect_value(t,seen,[4]f32{-1,1,-3,1})
    // What is on the face stays where it is, and a direction along it keeps its way.
    testing.expect_value(t,m*[4]f32{2,7,4,1},[4]f32{2,7,4,1})
    testing.expect_value(t,m*[4]f32{0,1,0,0},[4]f32{0,1,0,0})
    testing.expect_value(t,m*[4]f32{1,0,0,0},[4]f32{-1,0,0,0})
    // Mirroring twice gives the world back, and it turns the world inside out once.
    twice:=m*m
    for row in 0..<4 {
        for column in 0..<4 {testing.expect(t,abs(twice[row,column]-(row==column?1:0))<1e-5)}
    }
    testing.expect(t,abs(linalg.determinant(m)+1)<1e-5)
}

@(test)
a_tilted_mirror_keeps_distances :: proc(t:^testing.T) {
    normal:=linalg.normalize([3]f32{1,2,-0.5})
    plane:=[4]f32{normal.x,normal.y,normal.z,0.75}
    m:=reflection(plane)
    a,b:=[4]f32{3,-1,2,1},[4]f32{-4,0.5,6,1}
    testing.expect(t,abs(linalg.length((m*a-m*b).xyz)-linalg.length((a-b).xyz))<1e-4)
    height:=linalg.dot(normal,a.xyz)+plane.w
    mirrored:=m*a
    testing.expect(t,abs(linalg.dot(normal,mirrored.xyz)+plane.w+height)<1e-4)
}

// A face goes to the view relative to the origin the renderer draws from:
// its space and its plane from where its place is.
@(test)
a_face_relative_to_the_origin_is_found_from_its_place :: proc(t:^testing.T) {
    rotation:=mm.quat_axis_angle({0,1,0},0.4)
    position:=[3]f32{16000.5,2,-21000.25}
    to_local,_:=mm.transform_inverse_matrix({position,rotation,{2,1.5,1}})
    normal:=mm.quat_rotate(rotation,[3]f32{0,0,1})
    face:=Face{to_local=mm.mat4_rows(to_local),place=position,plane={normal.x,normal.y,normal.z,-linalg.dot(normal,position)}}
    origin:=[3]f32{16384,0,-20480}
    relative,plane:=face_relative(&face,origin)
    testing.expect_value(t,relative,render.origin_from_place(face.to_local,position,origin))
    testing.expect_value(t,plane,render.origin_plane_through(face.plane,position,origin))
}
