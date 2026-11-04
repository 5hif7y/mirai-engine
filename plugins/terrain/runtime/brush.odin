package terrain

import "core:math"
import "core:math/linalg"
import "mirai:std/geom"
import mm "mirai:std/math"

Brush_Kind :: enum u8 {Raise,Lower,Smooth,Flatten,Add,Remove,Refine,Union,Subtract,Grab,Grow,Paint,Erase,Hole,Fill,Ramp,Terrace,Noise,Erode}

// Which way a brush may move a sample: Up never lowers one, Down never raises one.
Brush_Way :: enum u8 {Both,Up,Down}

// A shape a brush takes inside its disc: size by size values from 0 to 1, x
// first, over the square that holds the disc.
Brush_Alpha :: struct {size:int,values:[]f32}

// What Union and Subtract join or take: a sphere at center, a capsule from
// center to center+delta, a box of half size extent turned by rotation.
Brush_Shape :: enum u8 {Sphere,Capsule,Box}

Brush :: struct {
    kind:Brush_Kind,
    center:[3]f32,
    radius,amount,target:f32,
    normal:[3]f32,
    delta:[3]f32,
    rotation:quaternion128,
    max_edge:f32,
    layer:u32, // Paint and Erase
    falloff:geom.Falloff,
    hardness:f32, // the part of the radius at full weight
    shape:Brush_Shape,
    extent:[3]f32,
    blend:f32, // Union and Subtract of a Volume: the width over which the shape joins what was there
    way:Brush_Way,      // Smooth, Flatten, Ramp, Terrace, Noise and Erode
    capped:bool,        // Raise and Lower of a Heightfield stop at target: Raise lifts what is under it, Lower cuts what is over it
    interval:f32,       // Terrace: metres between its steps, from target
    riser:f32,          // Terrace: the part of each step that rises, from 0 (a cliff) to 1
    scale:f32,          // Noise: metres across its features
    seed:u32,           // Noise and Erode
    slope:[2]f32,       // radians from horizontal of the Heightfield it touches; zero: any
    slope_invert:bool,  // it touches outside slope instead
    toward:bool,        // Paint takes the weight of its layer toward target, from 0 to 1, in place of adding
    alpha:^Brush_Alpha, // nil: the whole disc
    turn:f32,           // radians the alpha turns around y
}

// Smooth averages a box of this part of its radius, from one sample to
// SMOOTH_SAMPLES_MAX on each side.
SMOOTH_REACH :: f32(0.25)
SMOOTH_SAMPLES_MAX :: 8

Edit_Error :: enum u8 {None,Invalid,Not_Closed,Out_Of_Memory,Budget,Topology}
Change :: struct {
    changed:bool,
    low,high:[3]int, // inclusive sample coordinates
    mesh:bool,
    error:Edit_Error,
}

source_edit :: proc(s:^Source,brush:Brush,vertex_budget:int=MESH_TRIANGLES_MAX*3,baseline:^Source=nil) -> (change:Change) {
    s.dug={}
    if !(brush.hardness>=0 && brush.hardness<1) || brush.falloff>.Constant || brush.shape>.Box || brush.way>.Down || !brush_options_valid(brush) {return Change{error=.Invalid}}
    // What a brush adds to a Volume is of brush.layer.
    if s.kind==.Volume && brush_grows(brush.kind) && brush.layer>=s.layer_count {return Change{error=.Invalid}}
    if brush.kind==.Paint || brush.kind==.Erase {return source_paint(s,brush)}
    if brush.kind==.Hole || brush.kind==.Fill {return source_holes_edit(s,brush)}
    if s.kind==.Mesh {return source_mesh_edit(s,brush,vertex_budget,baseline)}
    grid_only:=brush.kind==.Ramp || brush.kind==.Terrace || brush.kind==.Erode
    if brush.kind==.Refine || brush.kind==.Grab || (brush.kind==.Grow && s.kind!=.Volume) || grid_only && s.kind!=.Heightfield {return Change{error=.Invalid}}
    if (brush.kind==.Union || brush.kind==.Subtract) {
        if s.kind!=.Volume {return Change{error=.Invalid}}
        return source_volume_shape(s,brush)
    }
    if !source_valid(s.info) || !source_samples_held(s) {return}
    if !(brush.radius>0) || !(brush.amount>0) || brush.radius-brush.radius!=0 || brush.amount-brush.amount!=0 || brush.target-brush.target!=0 {return}
    for coordinate in brush.center {if coordinate-coordinate!=0 {return}}
    for coordinate in brush.delta {if coordinate-coordinate!=0 || abs(coordinate)>HEIGHT_LIMIT*2 {return Change{error=.Invalid}}}
    if s.kind==.Heightfield && (brush.kind==.Add || brush.kind==.Remove) || s.kind==.Volume && (brush.kind==.Raise || brush.kind==.Lower) {return}
    segment:=brush.kind==.Grow || brush.kind==.Ramp
    reach:=brush.radius
    if s.kind==.Volume && (brush.kind==.Add || brush.kind==.Remove || brush.kind==.Grow) {reach+=s.cell*SDF_BAND_CELLS}
    // The water of Erode runs past the disc and leaves there what it carries.
    if brush.kind==.Erode {reach*=EROSION_REACH}
    center:=(brush.center-source_origin(s))/s.cell
    low,high:[3]int
    for axis in 0..<3 {
        if s.kind==.Heightfield && axis==1 {continue}
        end:=center[axis]+(segment?brush.delta[axis]/s.cell:0)
        lo,hi:=math.ceil(min(center[axis],end)-reach/s.cell),math.floor(max(center[axis],end)+reach/s.cell)
        first,last:=f32(0),f32(s.samples[axis]-1)
        if s.kind==.Volume {first,last=1,last-1}
        if hi<first || lo>last {return}
        low[axis]=int(clamp(lo,first,last))
        high[axis]=int(clamp(hi,first,last))
    }
    if s.kind==.Heightfield {low.y,high.y=0,0}
    if !grid_prepare(source_samples_grid(s),low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    if brush.kind==.Erode {return source_erode(s,brush,low,high)}
    layered:=s.kind==.Volume && brush_grows(brush.kind)
    if layered && !grid_prepare(&s.weights,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    // Smooth reads the region as it was, with a halo as wide as its box, and
    // so does the slope filter: what the brush raises before a sample does not
    // change whether it touches it.
    from,to:=low,high
    blurred:[]f32
    k:=clamp(int(brush.radius/s.cell*SMOOTH_REACH),1,SMOOTH_SAMPLES_MAX)
    smoothing:=0
    if brush.kind==.Smooth {
        for axis in 0..<3 {
            if s.kind==.Heightfield && axis==1 {continue}
            from[axis]=max(from[axis]-k,0);to[axis]=min(to[axis]+k,int(s.samples[axis])-1)
        }
        size:=to-from+1
        smoothing=2*size.x*size.y*size.z
    }
    filter_size:=high.xz-low.xz+1
    filtering:=s.kind==.Heightfield && brush.slope!={}?filter_size.x*filter_size.y:0
    if smoothing+filtering>0 && resize(&s.scratch,smoothing+filtering)!=nil {return Change{error=.Out_Of_Memory}}
    allowed:=s.scratch[smoothing:][:filtering]
    for z in 0..<(filtering>0?filter_size.y:0) {for x in 0..<filter_size.x {allowed[x+filter_size.x*z]=brush_slope_allows(s,brush,low.x+x,low.z+z)?1:0}}
    if brush.kind==.Smooth {
        size:=to-from+1
        n:=smoothing/2
        a,b:=s.scratch[:n],s.scratch[n:2*n]
        for z in from.z..=to.z {for y in from.y..=to.y {for x in from.x..=to.x {
            p:=[3]int{x,y,z}-from
            a[p.x+size.x*(p.y+size.y*p.z)]=source_value(s,{x,y,z})
        }}}
        for axis in 0..<3 {
            if size[axis]==1 {continue}
            box_blur(a,b,size,axis,k)
            a,b=b,a
        }
        blurred=a
    }
    size:=to-from+1
    change.low=high;change.high=low
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        p:=[3]int{x,y,z}
        point:=source_origin(s)+[3]f32{f32(x),f32(y),f32(z)}*s.cell
        distance:=f32(0)
        along:=f32(0)
        if s.kind==.Heightfield {
            nearest:=brush.center.xz
            if segment {
                length:=linalg.dot(brush.delta.xz,brush.delta.xz)
                if length>0 {along=clamp(linalg.dot(point.xz-brush.center.xz,brush.delta.xz)/length,0,1);nearest+=brush.delta.xz*along}
            }
            distance=linalg.length(point.xz-nearest)
        } else {
            nearest:=brush.center
            if segment {length:=linalg.dot(brush.delta,brush.delta);if length>0 {along=clamp(linalg.dot(point-brush.center,brush.delta)/length,0,1);nearest+=brush.delta*along}}
            distance=linalg.length(point-nearest)
        }
        if distance>=reach {continue}
        old:=source_value(s,p)
        value:=old
        if brush.kind==.Add || brush.kind==.Remove || brush.kind==.Grow {
            sphere:=clamp(distance-brush.radius,-s.cell*SDF_BAND_CELLS,s.cell*SDF_BAND_CELLS)
            target:=brush.kind!=.Remove?min(old,sphere):max(old,-sphere)
            value=math.lerp(old,target,min(brush.amount,1))
        } else {
            weight:=brush_weight(brush,point.xz-brush.center.xz,distance)
            if weight>0 && filtering>0 && allowed[x-low.x+filter_size.x*(z-low.z)]==0 {weight=0}
            if weight<=0 {continue}
            grid:=s.kind==.Heightfield
            switch brush.kind {
            case .Raise:
                if brush.capped && grid {
                    if old>=brush.target {continue}
                    value=min(old+brush.amount*weight,brush.target)
                } else {value+=brush.amount*weight}
            case .Lower:
                if brush.capped && grid {
                    if old<=brush.target {continue}
                    value=max(old-brush.amount*weight,brush.target)
                } else {value-=brush.amount*weight}
            case .Flatten:
                target:=grid?brush.target:clamp(point.y-brush.target,-s.cell*SDF_BAND_CELLS,s.cell*SDF_BAND_CELLS)
                value=math.lerp(old,target,min(brush.amount*weight,1))
            case .Terrace:
                value=math.lerp(old,terrace_height(old,brush.target,brush.interval,brush.riser),min(brush.amount*weight,1))
            case .Noise:
                // The surface of a Volume rises where its value falls.
                n:=brush_noise(point,brush.scale,brush.seed,!grid)*brush.amount*weight
                value+=grid?n:-n
            case .Ramp:
                value=math.lerp(old,brush.center.y+brush.delta.y*along,min(brush.amount*weight,1))
            case .Smooth:
                // The mean of the box without the sample: its neighbors.
                at:=p-from
                n:=1
                for axis in 0..<3 {n*=min(at[axis]+k,size[axis]-1)-max(at[axis]-k,0)+1}
                if n<2 {continue}
                mean:=blurred[at.x+size.x*(at.y+size.y*at.z)]
                value=math.lerp(old,(mean*f32(n)-old)/f32(n-1),min(brush.amount*weight,1))
            case .Add,.Remove,.Refine,.Union,.Subtract,.Grab,.Grow,.Paint,.Erase,.Hole,.Fill,.Erode:
            }
            value=brush_way_keep(brush.way,!grid,old,value)
        }
        limit:=s.kind==.Heightfield?HEIGHT_LIMIT:s.cell*SDF_BAND_CELLS
        value=clamp(value,-limit,limit)
        if value==old {continue}
        dug_count(s,p,old,value)
        if layered {grid_write(&s.weights,p,weights_grow(grid_value(&s.weights,p),int(brush.layer),int(s.layer_count),volume_solid(old,s.cell),volume_solid(value,s.cell)))}
        if s.kind==.Heightfield {grid_set(&s.heights,x,z,value)} else {block_set(&s.distances,p,value)}
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    if s.kind==.Volume {grid_settle(&s.distances,low,high,s.allocator)}
    if layered {grid_settle(&s.weights,low,high,s.allocator)}
    return
}

// Whether a brush gives a Volume solid of its layer.
@(private)
brush_grows :: #force_inline proc "contextless" (kind:Brush_Kind) -> bool {return kind==.Add || kind==.Union || kind==.Grow}

// Whether what a brush adds to its disc is in range.
@(private)
brush_options_valid :: proc "contextless" (brush:Brush) -> bool {
    finite :: proc "contextless" (value:f32) -> bool {return value-value==0}
    if !finite(brush.turn) || !finite(brush.slope.x) || !finite(brush.slope.y) {return false}
    if brush.slope!={} && !(brush.slope.x>=0 && brush.slope.x<=brush.slope.y && brush.slope.y<=math.PI/2+1e-4) {return false}
    if brush.alpha!=nil && (brush.alpha.size<2 || len(brush.alpha.values)!=brush.alpha.size*brush.alpha.size) {return false}
    #partial switch brush.kind {
    case .Terrace: return brush.interval>0 && brush.interval<=HEIGHT_LIMIT && brush.riser>=0 && brush.riser<=1
    case .Noise:   return brush.scale>0 && brush.scale<=HEIGHT_LIMIT
    case .Paint:   return !brush.toward || brush.target>=0 && brush.target<=1
    }
    return true
}

// The weight of a brush at an offset over x and z from its center, at a
// distance from it: its falloff times its alpha.
brush_weight :: proc "contextless" (brush:Brush,offset:[2]f32,distance:f32) -> f32 {
    weight:=geom.falloff_weight(brush.falloff,brush.hardness,distance/brush.radius)
    if weight<=0 || brush.alpha==nil {return weight}
    return weight*alpha_sample(brush.alpha^,offset,brush.radius,brush.turn)
}

// An alpha at an offset over x and z from the center of a disc of radius,
// turned by turn: bilinear between its values, 0 outside its square.
alpha_sample :: proc "contextless" (a:Brush_Alpha,offset:[2]f32,radius,turn:f32) -> f32 {
    if a.size<2 || len(a.values)!=a.size*a.size || !(radius>0) {return 0}
    sin,cos:=math.sin(turn),math.cos(turn)
    u:=(cos*offset.x+sin*offset.y)/radius
    v:=(cos*offset.y-sin*offset.x)/radius
    last:=f32(a.size-1)
    x,z:=(u*0.5+0.5)*last,(v*0.5+0.5)*last
    if !(x>=0 && z>=0 && x<=last && z<=last) {return 0}
    c,r:=min(int(x),a.size-2),min(int(z),a.size-2)
    fx,fz:=x-f32(c),z-f32(r)
    i:=r*a.size+c
    top:=a.values[i]+(a.values[i+1]-a.values[i])*fx
    bottom:=a.values[i+a.size]+(a.values[i+a.size+1]-a.values[i+a.size])*fx
    return top+(bottom-top)*fz
}

// Whether the slope filter of a brush lets it touch sample x, z of a
// Heightfield: the slope of its neighbors across it in the range, or out of it.
brush_slope_allows :: proc "contextless" (s:^Source,brush:Brush,x,z:int) -> bool {
    if brush.slope=={} {return true}
    x0,x1:=max(x-1,0),min(x+1,int(s.samples.x)-1)
    z0,z1:=max(z-1,0),min(z+1,int(s.samples.z)-1)
    dx:=(grid_get(&s.heights,x1,z)-grid_get(&s.heights,x0,z))/(f32(x1-x0)*s.cell)
    dz:=(grid_get(&s.heights,x,z1)-grid_get(&s.heights,x,z0))/(f32(z1-z0)*s.cell)
    slope:=math.atan(math.sqrt(dx*dx+dz*dz))
    return (slope>=brush.slope.x && slope<=brush.slope.y)!=brush.slope_invert
}

// What a brush moves old to, kept to the way it may go: up is a higher value
// of a Heightfield and a lower one of a Volume, whose surface rises as it falls.
@(private)
brush_way_keep :: proc "contextless" (way:Brush_Way,volume:bool,old,value:f32) -> f32 {
    if way==.Both {return value}
    up:=(way==.Up)!=volume
    return up?max(value,old):min(value,old)
}

// The height of a terrace of steps interval apart from base at a height: level
// over each step, rising to the next over its last riser part.
terrace_height :: proc "contextless" (height,base,interval,riser:f32) -> f32 {
    t:=(height-base)/interval
    step:=math.floor(t)
    rise:=f32(0)
    if riser>0 {
        x:=clamp((t-step-(1-riser))/riser,0,1)
        rise=x*x*(3-2*x)
    }
    return base+(step+rise)*interval
}

// Noise from -1 to 1 at a point, of features scale metres across: three
// octaves of value noise, over x and z, or x, y and z for a volume. It is
// the same at a point for a seed, so passes over it deepen one pattern.
brush_noise :: proc(p:[3]f32,scale:f32,seed:u32,volume:bool) -> f32 {
    fractal:=mm.Fractal{kind=.Value,octaves=3,lacunarity=2,gain=0.5,seed=seed}
    q:=p/scale
    return volume?mm.noise_fbm3(q,fractal):mm.noise_fbm2(q.xz,fractal)
}

// The mean of each sample of src over the 2k+1 samples around it along an
// axis, those of the region only, into dst.
@(private)
box_blur :: proc(src,dst:[]f32,size:[3]int,axis,k:int) {
    steps:=[3]int{1,size.x,size.x*size.y}
    step,n:=steps[axis],size[axis]
    lines:=size;lines[axis]=1
    for z in 0..<lines.z {for y in 0..<lines.y {for x in 0..<lines.x {
        base:=x+size.x*(y+size.y*z)
        for i in 0..<n {
            lo,hi:=max(i-k,0),min(i+k,n-1)
            sum:=f64(0)
            for j in lo..=hi {sum+=f64(src[base+j*step])}
            dst[base+i*step]=f32(sum/f64(hi-lo+1))
        }
    }}}
}

// The signed distance from p to the shape of a brush: negative inside.
brush_shape_distance :: proc(brush:Brush,p:[3]f32) -> f32 {
    switch brush.shape {
    case .Sphere: return linalg.length(p-brush.center)-brush.radius
    case .Capsule:
        length:=linalg.dot(brush.delta,brush.delta)
        along:=length>0?clamp(linalg.dot(p-brush.center,brush.delta)/length,0,1):0
        return linalg.length(p-(brush.center+brush.delta*along))-brush.radius
    case .Box:
        turn:=brush.rotation==0?quaternion128(1):brush.rotation
        q:=linalg.abs(mm.quat_rotate(mm.quat_inverse(turn),p-brush.center))-brush.extent
        return linalg.length(linalg.max(q,0))+min(max(q.x,q.y,q.z),0)
    }
    return 0
}

// The box around the shape of a brush.
brush_shape_bounds :: proc(brush:Brush) -> (low,high:[3]f32) {
    switch brush.shape {
    case .Sphere: return brush.center-brush.radius,brush.center+brush.radius
    case .Capsule:
        end:=brush.center+brush.delta
        return linalg.min(brush.center,end)-brush.radius,linalg.max(brush.center,end)+brush.radius
    case .Box:
        turn:=brush.rotation==0?quaternion128(1):brush.rotation
        reach:[3]f32
        for axis in 0..<3 {
            side:[3]f32;side[axis]=brush.extent[axis]
            reach+=linalg.abs(mm.quat_rotate(turn,side))
        }
        return brush.center-reach,brush.center+reach
    }
    return
}

@(private)
smooth_min :: proc "contextless" (a,b,k:f32) -> f32 {
    if !(k>0) {return min(a,b)}
    h:=max(k-abs(a-b),0)/k
    return min(a,b)-h*h*k*0.25
}

// Union joins the shape of the brush to a Volume and Subtract takes it away,
// over blend; amount is the part of the way to that.
@(private)
source_volume_shape :: proc(s:^Source,brush:Brush) -> (change:Change) {
    if !source_valid(s.info) || !source_samples_held(s) {return}
    finite3 :: proc "contextless" (v:[3]f32) -> bool {return v.x-v.x==0 && v.y-v.y==0 && v.z-v.z==0}
    if !finite3(brush.center) || !finite3(brush.delta) || !finite3(brush.extent) || !(brush.amount>0) || brush.amount>1 || !(brush.blend>=0) || brush.blend>HEIGHT_LIMIT {return Change{error=.Invalid}}
    switch brush.shape {
    case .Sphere,.Capsule: if !(brush.radius>0) || brush.radius>HEIGHT_LIMIT {return Change{error=.Invalid}}
    case .Box: if !(brush.extent.x>0 && brush.extent.y>0 && brush.extent.z>0) || max(brush.extent.x,brush.extent.y,brush.extent.z)>HEIGHT_LIMIT {return Change{error=.Invalid}}
    }
    band:=s.cell*SDF_BAND_CELLS
    shape_low,shape_high:=brush_shape_bounds(brush)
    margin:=brush.blend+band
    origin:=source_origin(s)
    low,high:[3]int
    for axis in 0..<3 {
        lo,hi:=math.ceil((shape_low[axis]-margin-origin[axis])/s.cell),math.floor((shape_high[axis]+margin-origin[axis])/s.cell)
        first,last:=f32(1),f32(s.samples[axis]-2)
        if hi<first || lo>last {return}
        low[axis],high[axis]=int(clamp(lo,first,last)),int(clamp(hi,first,last))
    }
    change.low=high;change.high=low
    if !grid_prepare(&s.distances,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    defer grid_settle(&s.distances,low,high,s.allocator)
    layered:=brush.kind==.Union
    if layered && !grid_prepare(&s.weights,low,high,s.allocator) {return Change{error=.Out_Of_Memory}}
    defer if layered {grid_settle(&s.weights,low,high,s.allocator)}
    for z in low.z..=high.z {for y in low.y..=high.y {for x in low.x..=high.x {
        p:=[3]int{x,y,z}
        d:=brush_shape_distance(brush,origin+[3]f32{f32(x),f32(y),f32(z)}*s.cell)
        old:=source_value(s,p)
        target:=brush.kind==.Union?smooth_min(old,d,brush.blend):-smooth_min(-old,d,brush.blend)
        value:=clamp(math.lerp(old,target,brush.amount),-band,band)
        if value==old {continue}
        dug_count(s,p,old,value)
        if layered {grid_write(&s.weights,p,weights_grow(grid_value(&s.weights,p),int(brush.layer),int(s.layer_count),volume_solid(old,s.cell),volume_solid(value,s.cell)))}
        block_set(&s.distances,p,value)
        change.changed=true
        for axis in 0..<3 {change.low[axis]=min(change.low[axis],p[axis]);change.high[axis]=max(change.high[axis],p[axis])}
    }}}
    return
}
