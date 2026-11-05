package shapes

import "core:math/linalg"
import "core:testing"
import "mirai:std/geom"
import mm "mirai:std/math"

// A brush of the given full size at a point of the frame of its solid.
@(private="file")
brush_at :: proc(kind:Brush_Kind,position,size:[3]f32,subtract:=false) -> Brush {
    return {kind=kind,subtract=subtract,place={position,mm.QUAT_IDENTITY,size}}
}

// Six times the volume the triangles enclose: positive when they face out.
@(private="file")
volume6 :: proc(m:geom.Mesh) -> f64 {
    v:f64
    for i:=0;i<len(m.indices);i+=3 {
        a,b,c:=m.positions[m.indices[i]],m.positions[m.indices[i+1]],m.positions[m.indices[i+2]]
        v+=f64(linalg.dot(a,linalg.cross(b,c)))
    }
    return v
}

// Every triangle faces the way its vertex normals point.
@(private="file")
normals_agree :: proc(m:geom.Mesh) -> bool {
    for i:=0;i<len(m.indices);i+=3 {
        a,b,c:=m.positions[m.indices[i]],m.positions[m.indices[i+1]],m.positions[m.indices[i+2]]
        n:=linalg.cross(b-a,c-a)
        if linalg.length(n)<1e-9 {continue}
        for k in 0..<3 {
            if linalg.dot(n,m.normals[m.indices[i+k]])<=0 {return false}
        }
    }
    return true
}

@(test)
built_shapes_are_closed_and_face_out :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    holed:=SHAPE_DEFAULT
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{0,0},0.25,0,&circle)
    testing.expect(t,shape_stamp(&holed,circle[:],.Difference,&set)==.None && holed.loop_count==2)
    reversed:=SHAPE_DEFAULT
    reversed.points[1],reversed.points[3]=reversed.points[3],reversed.points[1]
    solid:=Shape{kind=.Solid,uv_scale=2}
    brushes:=[]Brush{
        brush_at(.Box,{0,0,0},{2,2,2}),
        brush_at(.Sphere,{1,1,1},{1.6,1.6,1.6},true),
        brush_at(.Cylinder,{0,1.5,0},{0.6,1,0.6}),
    }
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,volume_min,volume_max:f64}
    cases:=[]Case{
        {"square",SHAPE_DEFAULT,nil,1-1e-4,1+1e-4},
        {"clockwise square",reversed,nil,1-1e-4,1+1e-4},
        {"square with a hole",holed,nil,0.75,0.81},
        {"solid with a subtracted sphere and an added cylinder",solid,brushes,7.95,8.05},
    }
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        if !testing.expectf(t,shape_geometry_build(&c.shape,c.brushes,false,&g)==.None,"%s",c.name) {continue}
        m:=geom.mesh_buffer_view(&g.mesh)
        testing.expectf(t,geom.mesh_is_valid(m) && len(m.uvs)==len(m.positions) && len(m.normals)==len(m.positions),"%s: streams",c.name)
        testing.expectf(t,geom.mesh_is_closed(m.positions,m.indices),"%s: closed",c.name)
        testing.expectf(t,normals_agree(m),"%s: normals",c.name)
        volume:=volume6(m)/6
        testing.expectf(t,volume>=c.volume_min && volume<=c.volume_max,"%s: volume %v",c.name,volume)
        // What collides is the same solid, its coplanar seams disabled and its outline edges not.
        collision:=geom.mesh_buffer_view(&g.collision)
        testing.expectf(t,geom.mesh_is_closed(collision.positions,collision.indices),"%s: collision closed",c.name)
        testing.expectf(t,abs(volume6(collision)/6-volume)<1e-3,"%s: collision volume",c.name)
        testing.expect_value(t,len(g.disabled_edges),len(collision.indices)/3)
        disabled,enabled:=0,0
        for mask in g.disabled_edges {
            for k in 0..<3 {if mask&(1<<uint(k))!=0 {disabled+=1} else {enabled+=1}}
        }
        testing.expectf(t,disabled>0 && enabled>0,"%s: %d disabled, %d enabled",c.name,disabled,enabled)
    }
}

@(test)
a_shape_that_cannot_be_built_says_why :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    crossed:=SHAPE_DEFAULT
    crossed.points[1],crossed.points[2]=crossed.points[2],crossed.points[1]
    flat:=SHAPE_DEFAULT
    flat.depth=0
    counts:=SHAPE_DEFAULT
    counts.loops[0]=5
    nan:=SHAPE_DEFAULT
    nan.points[0].x=0/flat.depth
    cuts:=[]Brush{brush_at(.Box,{},{2,2,2},true)}
    flat_brush:=[]Brush{brush_at(.Box,{},{2,0,2})}
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,error:Shape_Error}
    cases:=[]Case{
        {"crossed",crossed,nil,.Self_Intersecting},
        {"flat",flat,nil,.Invalid},
        {"counts",counts,nil,.Invalid},
        {"not finite",nan,nil,.Invalid},
        {"empty",{},nil,.Empty},
        {"only subtracts",{kind=.Solid},cuts,.Empty},
        {"no brushes",{kind=.Solid},nil,.Empty},
        {"a brush without volume",{kind=.Solid},flat_brush,.Invalid},
    }
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        error:=shape_geometry_build(&c.shape,c.brushes,true,&g)
        testing.expectf(t,error==c.error,"%s: %v",c.name,error)
        testing.expectf(t,len(g.mesh.indices)==0 && len(g.pieces.sizes)==0,"%s: nothing kept",c.name)
    }
}

@(test)
bodies_are_convex_pieces_that_cover_the_shape :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    l:=SHAPE_DEFAULT
    l.point_count,l.loops[0]=6,6
    l.points[0],l.points[1],l.points[2],l.points[3],l.points[4],l.points[5]={0,0},{2,0},{2,1},{1,1},{1,2},{0,2}
    solid:=Shape{kind=.Solid}
    added:=[]Brush{brush_at(.Box,{},{2,2,2}),brush_at(.Sphere,{1,1,0},{1,1,1})}
    cut:=[]Brush{added[0],added[1],brush_at(.Box,{0,0,1},{1,1,1},true)}
    Case :: struct {name:string,shape:Shape,brushes:[]Brush,pieces:int}
    cases:=[]Case{{"L outline",l,nil,2},{"brushes",solid,added,2},{"subtracted",solid,cut,2}}
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for &c in cases {
        if !testing.expectf(t,shape_geometry_build(&c.shape,c.brushes,true,&g)==.None,"%s",c.name) {continue}
        testing.expectf(t,len(g.pieces.sizes)>=c.pieces,"%s: %d pieces",c.name,len(g.pieces.sizes))
        total:=0
        for size in g.pieces.sizes {
            testing.expectf(t,size>=4,"%s: a piece of %d points",c.name,size)
            total+=int(size)
        }
        testing.expect_value(t,total,len(g.pieces.points))
        // Every vertex of the mesh is in some piece.
        lo,hi:=geom.mesh_bounds(g.mesh.positions[:])
        plo,phi:=geom.mesh_bounds(g.pieces.points[:])
        testing.expectf(t,linalg.length(plo-lo)<0.05 && linalg.length(phi-hi)<0.05,"%s: bounds",c.name)
    }
}

@(test)
sides_share_normals_where_the_outline_turns_little :: proc(t:^testing.T) {
    defer free_all(context.temp_allocator)
    set:geom.Polygon_Set
    geom.polygon_set_init(&set)
    defer geom.polygon_set_destroy(&set)
    circle:=make([dynamic]geom.Vec2,context.temp_allocator)
    stamp_points(.Circle,{0,0},1,0,&circle)
    round:=SHAPE_DEFAULT
    testing.expect(t,shape_stamp(&round,circle[:],.Union,&set)==.None)
    g:Shape_Geometry
    shape_geometry_init(&g)
    defer shape_geometry_destroy(&g)
    for c in ([2]struct {shape:Shape,smooth:bool}{{SHAPE_DEFAULT,false},{round,true}}) {
        shape:=c.shape
        if !testing.expect(t,shape_geometry_build(&shape,nil,false,&g)==.None) {continue}
        // Side vertices at one place: the same normal when smooth, two when sharp.
        shared,split:=0,0
        m:=&g.mesh
        for i in 0..<len(m.positions) {
            if m.normals[i].z!=0 {continue}
            for j in i+1..<len(m.positions) {
                if m.normals[j].z!=0 || m.positions[j]!=m.positions[i] {continue}
                if linalg.length(m.normals[j]-m.normals[i])<1e-5 {shared+=1} else {split+=1}
            }
        }
        testing.expectf(t,c.smooth?(shared>0 && split==0):(split>0 && shared==0),"smooth %v: %d shared, %d split",c.smooth,shared,split)
    }
}
