package textures

import "core:math"
import "mirai:asset"
import "mirai:std/jobs"

// BC6H encoder (the format and its decoder are in asset/texture_bc6h.odin):
// mode 11 alone, one subset with endpoints of 10 bits per channel. A
// block is fitted in the 16-bit range the endpoints interpolate in, where the
// bits of a half float are close to the logarithm of its value: the
// principal axis of its texels gives the first endpoints, a least squares pass
// over the indices they produce refines them, and the error is measured in
// the bits of the half floats the GPU decodes.

// The bits of the half float of a channel without sign: a negative value or
// a NaN is 0, and what is above the largest half float is it.
// Rounds of moving the endpoints of a block at each step size.
BC6H_REFINE_ROUNDS :: 4

@(private="file")
half_unsigned :: proc "contextless" (value:f32) -> u16 {
    if !(value>0) {return 0}
    return transmute(u16)f16(min(value,65504))
}

// The quantized endpoint of a value of the 16-bit range, per channel.
@(private="file")
bc6h_quantize :: proc "contextless" (value:[3]f32) -> (q:[3]u32) {
    top:=f32(1<<asset.TEXTURE_BC6H_ENDPOINT_BITS-1)
    for c in 0..<3 {q[c]=u32(clamp(math.round((value[c]-32)/64),0,top))}
    return
}

@(private="file")
bc6h_indices :: proc "contextless" (halves:^[16][3]f32,q0,q1:[3]u32) -> (indices:[16]u32,error:f32) {
    palette:[16][3]f32
    for &entry,k in palette {
        for c in 0..<3 {entry[c]=f32(asset.texture_bc6h_interpolate(asset.texture_bc6h_unquantize(q0[c]),asset.texture_bc6h_unquantize(q1[c]),asset.BC7_WEIGHTS_4[k]))}
    }
    for h,i in halves {
        best,best_distance:=u32(0),f32(1e30)
        for entry,k in palette {
            d:=h-entry
            distance:=d.r*d.r+d.g*d.g+d.b*d.b
            if distance<best_distance {best,best_distance=u32(k),distance}
        }
        indices[i]=best
        error+=best_distance
    }
    return
}

// Linear rgb texels, row by row, as a block of mode 11.
bc6h_encode_block :: proc "contextless" (texels:^[16][3]f32) -> (block:[16]u8) {
    halves:[16][3]f32 // the bits of the half floats the block should decode to
    points:[16][3]f32 // the same in the range the endpoints interpolate in
    mean:[3]f32
    for t,i in texels {
        for c in 0..<3 {halves[i][c]=f32(half_unsigned(t[c]))}
        points[i]=halves[i]*(64.0/31.0)
        mean+=points[i]
    }
    mean/=16
    covariance:[6]f32
    for p in points {
        d:=p-mean
        covariance[0]+=d.r*d.r
        covariance[1]+=d.r*d.g
        covariance[2]+=d.r*d.b
        covariance[3]+=d.g*d.g
        covariance[4]+=d.g*d.b
        covariance[5]+=d.b*d.b
    }
    // The principal axis by power iteration, from the covariance of the
    // channel that varies most, as bc1_encode_block finds it.
    axis:=[3]f32{covariance[0],covariance[1],covariance[2]}
    if covariance[3]>covariance[0] && covariance[3]>=covariance[5] {axis={covariance[1],covariance[3],covariance[4]}}
    if covariance[5]>covariance[0] && covariance[5]>covariance[3] {axis={covariance[2],covariance[4],covariance[5]}}
    if length:=math.sqrt(axis.r*axis.r+axis.g*axis.g+axis.b*axis.b);length>1e-9 {axis/=length} else {axis={0.577,0.577,0.577}}
    for _ in 0..<4 {
        next:=[3]f32{
            covariance[0]*axis.r+covariance[1]*axis.g+covariance[2]*axis.b,
            covariance[1]*axis.r+covariance[3]*axis.g+covariance[4]*axis.b,
            covariance[2]*axis.r+covariance[4]*axis.g+covariance[5]*axis.b,
        }
        length:=math.sqrt(next.r*next.r+next.g*next.g+next.b*next.b)
        if length<1e-12 {break}
        axis=next/length
    }
    low,high:=f32(1e30),f32(-1e30)
    for p in points {
        t:=(p.r-mean.r)*axis.r+(p.g-mean.g)*axis.g+(p.b-mean.b)*axis.b
        low,high=min(low,t),max(high,t)
    }
    q0,q1:=bc6h_quantize(mean+axis*low),bc6h_quantize(mean+axis*high)
    indices,error:=bc6h_indices(&halves,q0,q1)
    // Least squares: the endpoints that best explain the texels given the
    // indices they were assigned. Kept when they lower the error.
    for _ in 0..<2 {
        aa,ab,bb:f32
        ax,bx:[3]f32
        for p,i in points {
            w:=f32(asset.BC7_WEIGHTS_4[indices[i]])/64 // share of the second endpoint
            aa+=(1-w)*(1-w)
            ab+=(1-w)*w
            bb+=w*w
            ax+=p*(1-w)
            bx+=p*w
        }
        determinant:=aa*bb-ab*ab
        if abs(determinant)<1e-6 {break}
        n0:=bc6h_quantize((ax*bb-bx*ab)/determinant)
        n1:=bc6h_quantize((bx*aa-ax*ab)/determinant)
        refined,refined_error:=bc6h_indices(&halves,n0,n1)
        if refined_error>=error {break}
        q0,q1,indices,error=n0,n1,refined,refined_error
    }
    // Each quantized endpoint channel moved by a few steps and then by one,
    // while that lowers the error: rounding each channel apart misses the
    // pair of endpoints whose palette lands closest.
    top:=u32(1<<asset.TEXTURE_BC6H_ENDPOINT_BITS-1)
    for step in ([2]u32{4,1}) {
        for _ in 0..<BC6H_REFINE_ROUNDS {
            improved:=false
            for which in 0..<6 {
                for up in ([2]bool{false,true}) {
                    n0,n1:=q0,q1
                    channel:=&n0[which] if which<3 else &n1[which-3]
                    if up {
                        if channel^+step>top {continue}
                        channel^+=step
                    } else {
                        if channel^<step {continue}
                        channel^-=step
                    }
                    refined,refined_error:=bc6h_indices(&halves,n0,n1)
                    if refined_error<error {q0,q1,indices,error,improved=n0,n1,refined,refined_error,true}
                }
            }
            if !improved {break}
        }
    }
    // The high bit of the first index is not stored: the endpoints swap so that it is 0.
    if indices[0]>=8 {
        q0,q1=q1,q0
        for &index in indices {index=15-index}
    }
    bits:=u128(asset.TEXTURE_BC6H_MODE_11)
    for c in 0..<3 {
        bits|=u128(q0[c])<<(5+u32(c)*10)
        bits|=u128(q1[c])<<(35+u32(c)*10)
    }
    at:=u32(65)
    for index,i in indices {
        bits|=u128(index)<<at
        at+=3 if i==0 else 4
    }
    for &b,i in block {b=u8(bits>>(u32(i)*8))}
    return
}

@(private="file")
Bc6h_Level :: struct {
    image:Source, // one layer
    transfer:^Transfer,
    out:[]u8,
}

@(private="file")
bc6h_rows :: proc(level:^Bc6h_Level,first,last:int,_:int) {
    width,height:=level.image.width,level.image.height
    blocks_x:=(width+3)/4
    texels:[16][3]f32
    for by in first..<last {
        for bx in 0..<blocks_x {
            for y in 0..<4 {
                for x in 0..<4 {
                    texels[y*4+x]=texel_read(level.image.texels,level.image.format,min(by*4+y,height-1)*width+min(bx*4+x,width-1),level.transfer).rgb
                }
            }
            block:=bc6h_encode_block(&texels)
            copy(level.out[(by*blocks_x+bx)*16:],block[:])
        }
    }
}

// Compresses each layer of a level into the BC6H blocks of out, layer after
// layer. Blocks at the right and bottom edges repeat the last texels. On a
// worker of a job system, rows of blocks go in parallel.
bc6h_compress :: proc(level:Source,transfer:^Transfer,out:[]u8,worker:=jobs.Worker_Ref{}) {
    size:=asset.texture_level_size(.BC6H,level.width,level.height)
    image:=source_bytes({width=level.width,height=level.height,format=level.format})
    rows:=(level.height+3)/4
    for layer in 0..<max(level.layers,1) {
        one:=level
        one.layers,one.texels=1,level.texels[layer*image:][:image]
        work:=Bc6h_Level{image=one,transfer=transfer,out=out[layer*size:][:size]}
        if worker.system!=nil {jobs.parallel_for(worker.system,worker.worker,rows,1,bc6h_rows,&work)} else {bc6h_rows(&work,0,rows,jobs.OWNER)}
    }
}
