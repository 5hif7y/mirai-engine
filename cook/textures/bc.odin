package textures

import "core:math"
import "core:mem"
import "mirai:asset"
import "mirai:std/jobs"

// Block compression of textures (BC1, BC3, BC5 and BC7): 4x4 texels in 8 or
// 16 bytes that the GPU samples directly, a quarter to an eighth of RGBA8.
// BC7, for color, is its own encoder (bc7.odin), and so is BC6H, for HDR
// (bc6h.odin).
//
// A color block (BC1) stores two RGB565 endpoints and a 2-bit index per texel
// into the four colors on the line between them. The endpoints are fitted the
// way stb_dxt and most encoders do: the principal axis of the colors of the
// block gives the first pair, and a least squares pass over the indices they
// produce refines it. An alpha or single-channel block (BC4, the alpha half
// of BC3 and each half of BC5) stores two 8-bit endpoints and a 3-bit index
// per texel into eight values between them. What a block decodes to is in
// asset (texture_bc1_block_decode, texture_level_rgba8).

@(private="file")
to_565 :: proc "contextless" (c:[3]f32) -> u16 {
    r:=u16(clamp(c.r*31+0.5,0,31))
    g:=u16(clamp(c.g*63+0.5,0,63))
    b:=u16(clamp(c.b*31+0.5,0,31))
    return r<<11|g<<5|b
}

@(private="file")
bc1_indices :: proc "contextless" (colors:^[16][3]f32,palette:[4][3]f32) -> (indices:u32,error:f32) {
    for c,i in colors {
        best,best_distance:=u32(0),f32(1e30)
        for candidate,k in palette {
            d:=c-candidate
            distance:=d.r*d.r+d.g*d.g+d.b*d.b
            if distance<best_distance {best,best_distance=u32(k),distance}
        }
        indices|=best<<(u32(i)*2)
        error+=best_distance
    }
    return
}

// Texels as RGBA bytes, row by row. Always the four color mode: no texel of
// the block decodes as transparent.
bc1_encode_block :: proc "contextless" (texels:^[16][4]u8) -> (block:[8]u8) {
    colors:[16][3]f32
    mean:[3]f32
    for t,i in texels {
        colors[i]={f32(t.r),f32(t.g),f32(t.b)}/255
        mean+=colors[i]
    }
    mean/=16
    // Principal axis of the colors by power iteration on their covariance.
    covariance:[6]f32
    for c in colors {
        d:=c-mean
        covariance[0]+=d.r*d.r
        covariance[1]+=d.r*d.g
        covariance[2]+=d.r*d.b
        covariance[3]+=d.g*d.g
        covariance[4]+=d.g*d.b
        covariance[5]+=d.b*d.b
    }
    // Start from the covariance of the channel that varies most: a vector that
    // cannot be at a right angle to the axis the iteration looks for.
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
    for c in colors {
        d:=c-mean
        t:=d.r*axis.r+d.g*axis.g+d.b*axis.b
        low,high=min(low,t),max(high,t)
    }
    c0,c1:=to_565(mean+axis*high),to_565(mean+axis*low)
    indices,error:=bc1_indices(&colors,asset.texture_bc1_palette(c0,c1))
    // Least squares: the endpoints that best explain the colors given the
    // indices they were assigned. Kept when they lower the error.
    for _ in 0..<2 {
        if c0==c1 {break}
        weights:=[4]f32{1,0,2.0/3.0,1.0/3.0} // share of the first endpoint per index
        aa,ab,bb:f32
        ax,bx:[3]f32
        for c,i in colors {
            w:=weights[(indices>>(u32(i)*2))&3]
            aa+=w*w
            ab+=w*(1-w)
            bb+=(1-w)*(1-w)
            ax+=c*w
            bx+=c*(1-w)
        }
        determinant:=aa*bb-ab*ab
        if abs(determinant)<1e-6 {break}
        n0:=to_565((ax*bb-bx*ab)/determinant)
        n1:=to_565((bx*aa-ax*ab)/determinant)
        refined,refined_error:=bc1_indices(&colors,asset.texture_bc1_palette(n0,n1))
        if refined_error>=error {break}
        c0,c1,indices,error=n0,n1,refined,refined_error
    }
    // c0 above c1 selects the four color mode; equal endpoints use index 0.
    if c0<c1 {
        c0,c1=c1,c0
        // Indices 0 and 1 swap, and so do 2 and 3.
        indices~=0x55555555
    } else if c0==c1 {
        indices=0
    }
    block[0],block[1]=u8(c0),u8(c0>>8)
    block[2],block[3]=u8(c1),u8(c1>>8)
    block[4],block[5],block[6],block[7]=u8(indices),u8(indices>>8),u8(indices>>16),u8(indices>>24)
    return
}

bc4_encode_block :: proc "contextless" (values:^[16]u8) -> (block:[8]u8) {
    low,high:=u8(255),u8(0)
    for v in values {low,high=min(low,v),max(high,v)}
    block[0],block[1]=high,low
    if high==low {return}
    // With the first endpoint above the second, the eight values are the
    // endpoints and six steps between them: index 0 is high, 1 is low, and 2
    // to 7 go from high to low.
    bits:u64
    span:=f32(high-low)
    for v,i in values {
        step:=u64(f32(high-v)/span*7+0.5)
        index:=step
        if step==0 {index=0} else if step==7 {index=1} else {index=step+1}
        bits|=index<<(u32(i)*3)
    }
    for i in 0..<6 {block[2+i]=u8(bits>>(u32(i)*8))}
    return
}

// A level and where its blocks go, for rows of blocks compressed apart.
@(private="file")
Bc_Level :: struct {
    pixels:[]u8,
    width,height:int,
    format:asset.Texture_Format,
    out:[]u8,
}

@(private="file")
bc_rows :: proc(level:^Bc_Level,first,last:int,_:int) {
    width,height:=level.width,level.height
    blocks_x:=(width+3)/4
    block_bytes:=8 if level.format==.BC1 else 16
    settings:=BC7_SETTINGS
    texels:[16][4]u8
    channel:[16]u8
    for by in first..<last {
        for bx in 0..<blocks_x {
            for y in 0..<4 {
                for x in 0..<4 {
                    at:=(min(by*4+y,height-1)*width+min(bx*4+x,width-1))*4
                    texels[y*4+x]={level.pixels[at],level.pixels[at+1],level.pixels[at+2],level.pixels[at+3]}
                }
            }
            target:=level.out[(by*blocks_x+bx)*block_bytes:]
            #partial switch level.format {
            case .BC1:
                block:=bc1_encode_block(&texels)
                copy(target,block[:])
            case .BC3:
                for t,i in texels {channel[i]=t.a}
                alpha:=bc4_encode_block(&channel)
                color:=bc1_encode_block(&texels)
                copy(target,alpha[:])
                copy(target[8:],color[:])
            case .BC5:
                for t,i in texels {channel[i]=t.r}
                first:=bc4_encode_block(&channel)
                for t,i in texels {channel[i]=t.g}
                second:=bc4_encode_block(&channel)
                copy(target,first[:])
                copy(target[8:],second[:])
            case .BC7:
                block:=bc7_encode_block(&texels,&settings)
                copy(target,block[:])
            }
        }
    }
}

// Compresses one level of RGBA8 texels into blocks (.RGBA8 copies it).
// Blocks at the right and bottom edges repeat the last texels. On a worker of
// a job system, rows of blocks go in parallel.
bc_compress :: proc(pixels:[]u8,width,height:int,format:asset.Texture_Format,allocator:=context.allocator,worker:=jobs.Worker_Ref{}) -> (out:[]u8,error:mem.Allocator_Error) {
    out=make([]u8,asset.texture_level_size(format,width,height),allocator) or_return
    if format==.RGBA8 {
        copy(out,pixels)
        return
    }
    bc_compress_into(pixels,width,height,format,out,worker)
    return
}

// Compresses one level of RGBA8 texels into the blocks of out, BC1, BC3, BC5
// or BC7, as bc_compress does.
bc_compress_into :: proc(pixels:[]u8,width,height:int,format:asset.Texture_Format,out:[]u8,worker:=jobs.Worker_Ref{}) {
    level:=Bc_Level{pixels=pixels,width=width,height=height,format=format,out=out}
    rows:=(height+3)/4
    if worker.system!=nil {jobs.parallel_for(worker.system,worker.worker,rows,1,bc_rows,&level)} else {bc_rows(&level,0,rows,jobs.OWNER)}
}

// Texels of a level from which BC6H and BC7 are spread over threads: a block
// takes microseconds of BC6H and tens of BC7.
BC7_PARALLEL_TEXELS :: 128*128
BC6H_PARALLEL_TEXELS :: 512*512

// A job system of its own for the levels of a texture whose compression is
// long, so a build in any thread uses every core; false for one that goes
// in the calling thread.
@(private)
bc_jobs_begin :: proc(js:^jobs.Job_System,format:asset.Texture_Format,width,height:int) -> bool {
    #partial switch format {
    case .BC7: if width*height<BC7_PARALLEL_TEXELS {return false}
    case .BC6H: if width*height<BC6H_PARALLEL_TEXELS {return false}
    case: return false
    }
    return jobs.system_init(js,{threads=jobs.THREADS_AUTO})
}
