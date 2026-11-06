package texture

import "base:runtime"
import "core:mem"
import "mirai:cook/compressor/texture/bc1"
import "mirai:cook/compressor/texture/bc4"
import "mirai:cook/compressor/texture/bc6"
import "mirai:cook/compressor/texture/bc7"
import "mirai:cook/compressor/texture/common"
import "mirai:std/base"
import "mirai:std/jobs"

// The block encoder: BC1, BC3, BC4, BC5, BC6H and BC7 with
// rate-distortion optimization (RDO), which picks blocks that cost a little
// more error and repeat endpoints and indices so the level compresses better
// with LZ afterwards.

Format :: enum u8 {BC1, BC3, BC4, BC5, BC6H, BC7}

// Effort levels of the public API. Default is Normal, the default
// for RDO.
Effort :: enum u8 {Default, Low, Normal, High}

Metric :: enum u8 {
    Perceptual, // the error weighted by how visible it is in its neighborhood
    RMSE,       // plain squared error of each channel
}

Options :: struct {
    effort:Effort,
    // Lagrange multiplier of the RDO: 0 encodes for the least error;
    // 10 to 30 suit for color and 50 for a strong reduction.
    lambda:int,
    metric:Metric,
    // BC1: texels with alpha below 128 decode transparent (three color blocks).
    bc1_alpha:bool,
    // BC7: the alpha is ignored and decodes 255.
    ignore_alpha:bool,
    // BC3 and BC7 alpha, BC4 and BC5 channels keep exact 0 and 255.
    preserve_extremes:bool,
    // BC6H: channels are not RGB color (no weight by luminance).
    bc6_non_rgb:bool,
    // BC3: a lambda of its own for the alpha (0 turns the RDO of alpha off).
    bc3_alpha_lambda:Maybe(int),
}

Pixel_Format :: enum u8 {
    RGBA8,   // BC1, BC3, BC4 (R), BC5 (RG), BC7
    RGBA16F, // BC6H
    RGBA32F, // BC6H
}

// Rows from the top; stride 0 is width times the bytes of a pixel.
Surface :: struct {
    pixels:[]u8,
    width,height,stride:int,
    format:Pixel_Format,
}

Error :: enum u8 {
    None,
    Invalid_Size,       // a side of 0 or below, or above MAX_SIDE
    Invalid_Pixels,     // pixels shorter than the size and stride claim
    Invalid_Format,     // a pixel format the block format does not take
    Invalid_Lambda,     // negative
    Non_Finite,         // BC6H: a NaN or infinite color channel
    Buffer_Too_Small,   // dst shorter than encoded_size
    Out_Of_Memory,
}

MAX_SIDE :: 1<<15

block_bytes :: proc "contextless" (format:Format) -> int {
    return 8 if format==.BC1 || format==.BC4 else 16
}

encoded_size :: proc "contextless" (format:Format,width,height:int) -> int {
    return ((width+3)/4)*((height+3)/4)*block_bytes(format)
}

// Fewer blocks than this are encoded without RDO.
@(private)
RDO_MIN_BLOCKS :: 16
// Blocks of one non-RDO job.
@(private)
CHUNK_BLOCKS :: 256
// Activity is measured in tiles of this side; their borders mirror, so the
// tiling is part of the result.
@(private)
ACTIVITY_TILE :: 256

// Encodes a whole level into dst, blocks row by row. The allocator holds the
// scratch of the encode; with a worker of a job system the slices of the
// level go in parallel and the allocator must be safe across threads. The
// result is the same with or without the job system.
encode :: proc(format:Format,src:Surface,options:Options,dst:[]u8,allocator:=context.allocator,
    worker:=jobs.Worker_Ref{}) -> Error {
    if src.width<=0 || src.height<=0 {return .Invalid_Size}
    if src.width>MAX_SIDE || src.height>MAX_SIDE {return .Invalid_Size}
    if (format==.BC6H)==(src.format==.RGBA8) {return .Invalid_Format}
    if options.lambda<0 {return .Invalid_Lambda}
    if a,ok:=options.bc3_alpha_lambda.?;ok && a<0 {return .Invalid_Lambda}
    pb:=pixel_bytes(src.format)
    stride:=src.stride if src.stride!=0 else src.width*pb
    if stride<src.width*pb {return .Invalid_Pixels}
    if len(src.pixels)<(src.height-1)*stride+src.width*pb {return .Invalid_Pixels}
    n:=((src.width+3)/4)*((src.height+3)/4)
    if len(dst)<n*block_bytes(format) {return .Buffer_Too_Small}
    s:=src
    s.stride=stride
    if format==.BC6H && !finite(s) {return .Non_Finite}

    e:=Encode{format=format,src=s,level=effort_level(options.effort),
        options=dxtc_options(format,options),to=dst[:n*block_bytes(format)],
        allocator=allocator,worker=worker}
    e.rd_options={effort=e.level}
    if a,ok:=options.bc3_alpha_lambda.?;ok {
        e.rd_options.use_bc3_alpha_lambda=true
        e.rd_options.bc3_alpha_lambda=a
    }

    blocks_err:mem.Allocator_Error
    switch s.format {
    case .RGBA8: e.colors,blocks_err=gather(common.Color_Block,s,allocator,worker)
    case .RGBA16F: e.halfs,blocks_err=gather(common.Half_Block,s,allocator,worker)
    case .RGBA32F: e.floats,blocks_err=gather(common.Float4_Block,s,allocator,worker)
    }
    defer {delete(e.colors,allocator);delete(e.halfs,allocator);delete(e.floats,allocator)}
    if blocks_err!=nil {return .Out_Of_Memory}
    e.count=n

    if options.lambda==0 || n<RDO_MIN_BLOCKS {return compress_all(&e,e.to,e.level)}
    return encode_rdo(&e,options.lambda,options.metric)
}

@(private)
Encode :: struct {
    format:Format,
    src:Surface,
    level:common.Level,
    options:common.Options,
    rd_options:common.RD_Options,
    to:[]u8,
    count:int,
    // The blocks of the source in its own pixel format; one of them is set.
    colors:[]common.Color_Block,
    halfs:[]common.Half_Block,
    floats:[]common.Float4_Block,
    allocator:mem.Allocator,
    worker:jobs.Worker_Ref,
    // Scratch of the activity tiles and the RDO slices, one per worker, emptied after each:
    // the slices of a level would otherwise contend for the allocator.
    arenas:[]mem.Dynamic_Arena,
}

// Blocks of the scratch arenas; an allocation up to this size comes from a block.
@(private)
ARENA_BLOCK :: 4<<20

@(private)
arenas_init :: proc(e:^Encode) -> bool {
    n:=e.worker.system!=nil ? max(len(e.worker.system.workers),1) : 1
    arenas,err:=make([]mem.Dynamic_Arena,n,e.allocator)
    if err!=nil {return false}
    for &a in arenas {mem.dynamic_arena_init(&a,e.allocator,e.allocator,ARENA_BLOCK,ARENA_BLOCK)}
    e.arenas=arenas
    return true
}

@(private)
arenas_destroy :: proc(e:^Encode) {
    for &a in e.arenas {mem.dynamic_arena_destroy(&a)}
    delete(e.arenas,e.allocator)
}

// The scratch allocator of a worker.
@(private)
worker_arena :: proc(e:^Encode,worker:int) -> (^mem.Dynamic_Arena,mem.Allocator) {
    a:=&e.arenas[clamp(worker,0,len(e.arenas)-1)]
    return a,base.dynamic_arena_allocator(a)
}

@(private)
pixel_bytes :: proc "contextless" (format:Pixel_Format) -> int {
    switch format {
    case .RGBA8: return 4
    case .RGBA16F: return 8
    case .RGBA32F: return 16
    }
    return 4
}

@(private)
effort_level :: proc "contextless" (effort:Effort) -> common.Level {
    switch effort {
    case .Low: return .Fast
    case .Normal,.Default: return .Slow
    case .High: return .Very_Slow
    }
    return .Slow
}

// dxtcoptions_from_bcnflags of the public API.
@(private)
dxtc_options :: proc "contextless" (format:Format,options:Options) -> (o:common.Options) {
    if format==.BC1 && options.bc1_alpha {o+={.BC1_One_Bit_Alpha}}
    if format==.BC7 && options.ignore_alpha {o+={.BC7_Ignore_Alpha}}
    if options.preserve_extremes {
        #partial switch format {
        case .BC3,.BC4,.BC5: o+={.BC3457_Preserve_Extremes}
        case .BC7: if !options.ignore_alpha {o+={.BC3457_Preserve_Extremes}}
        }
    }
    if format==.BC6H && !options.bc6_non_rgb {o+={.BC6_Favor_Luminance}}
    return
}

@(private)
finite :: proc "contextless" (s:Surface) -> bool #no_bounds_check {
    for y in 0..<s.height {
        row:=s.pixels[y*s.stride:]
        for x in 0..<s.width {
            for c in 0..<3 {
                if s.format==.RGBA16F {
                    h:=u16(row[x*8+c*2])|u16(row[x*8+c*2+1])<<8
                    if h&0x7c00==0x7c00 {return false}
                } else {
                    f:=transmute(u32)[4]u8{row[x*16+c*4],row[x*16+c*4+1],row[x*16+c*4+2],
                        row[x*16+c*4+3]}
                    if f&0x7f800000==0x7f800000 {return false}
                }
            }
        }
    }
    return true
}

// A slice whose every element is written before it is read: no clearing.
@(private)
make_uninit :: proc($T:typeid/[]$E,n:int,allocator:mem.Allocator) -> (T,mem.Allocator_Error) {
    data,err:=runtime.mem_alloc_non_zeroed(size_of(E)*n,align_of(E),allocator)
    if err!=nil {return nil,err}
    return ([^]E)(raw_data(data))[:n],nil
}

@(private)
Gather_Job :: struct($T:typeid) {
    pixels:[]u8,
    width,height,stride:int, // in texels of T, stride in bytes
    blocks:[][16]T,
}

// Rows of blocks [first,last) of the job's surface, edge texels repeated into partial blocks.
@(private)
gather_rows :: proc(job:^Gather_Job($T),first,last:int,worker:int) #no_bounds_check {
    nbx:=(job.width+3)/4
    for by in first..<last {
        for r in 0..<4 {
            y:=min(by*4+r,job.height-1)
            row:=([^]T)(raw_data(job.pixels[y*job.stride:]))
            for bx in 0..<nbx {
                b:=&job.blocks[by*nbx+bx]
                for c in 0..<4 {b[r*4+c]=row[min(bx*4+c,job.width-1)]}
            }
        }
    }
}

// The 4x4 blocks of s in row order, rows of blocks in parallel with a job system.
@(private)
gather :: proc($B:typeid/[16]$T,s:Surface,allocator:mem.Allocator,
    worker:jobs.Worker_Ref) -> (blocks:[]B,err:mem.Allocator_Error) {
    nbx:=(s.width+3)/4
    nby:=(s.height+3)/4
    blocks=make_uninit([]B,nbx*nby,allocator) or_return
    job:=Gather_Job(T){s.pixels,s.width,s.height,s.stride,blocks}
    rows:proc(job:^Gather_Job(T),first,last:int,worker:int)=gather_rows
    run_rows(worker,nby,rows,&job)
    return
}

// The same for the activity surface, one float per texel.
@(private)
gather_activity :: proc(a:[]f32,w,h:int,blocks:[]common.Float_Block,worker:jobs.Worker_Ref) {
    job:=Gather_Job(f32){slice_bytes(a),w,h,w*4,blocks}
    rows:proc(job:^Gather_Job(f32),first,last:int,worker:int)=gather_rows
    run_rows(worker,(h+3)/4,rows,&job)
}

// Rows of blocks in parallel, a few at a time.
@(private)
run_rows :: proc(worker:jobs.Worker_Ref,rows:int,procedure:proc(data:^$T,first,last:int,
    worker:int),data:^T) {
    if worker.system!=nil && rows>1 {
        jobs.parallel_for(worker.system,worker.worker,rows,8,procedure,data)
    } else {
        procedure(data,0,rows,jobs.OWNER)
    }
}

@(private)
run :: proc(e:^Encode,count:int,procedure:proc(data:^$T,first,last:int,worker:int),data:^T) {
    if e.worker.system!=nil && count>1 {
        jobs.parallel_for(e.worker.system,e.worker.worker,count,1,procedure,data)
    } else {
        procedure(data,0,count,jobs.OWNER)
    }
}

@(private)
first_error :: proc(errors:[]Error) -> Error {
    for err in errors {if err!=.None {return err}}
    return .None
}

@(private)
from_common :: proc "contextless" (err:common.Error) -> Error {
    switch err {
    case .None: return .None
    case .Out_Of_Memory: return .Out_Of_Memory
    case .Invalid: return .Invalid_Format
    }
    return .Invalid_Format
}

@(private)
Compress_Job :: struct {
    e:^Encode,
    to:[]u8,
    level:common.Level,
    errors:[]Error,
}

// rrSurfaceDXTC_CompressBCN_Blocks: each block on its own, so any split into
// jobs writes the same bytes.
@(private)
compress_all :: proc(e:^Encode,to:[]u8,level:common.Level) -> Error {
    chunks:=(e.count+CHUNK_BLOCKS-1)/CHUNK_BLOCKS
    errors,err:=make([]Error,chunks,e.allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(errors,e.allocator)
    job:=Compress_Job{e=e,to=to,level=level,errors=errors}
    run(e,chunks,compress_chunks,&job)
    return first_error(errors)
}

@(private)
compress_chunks :: proc(job:^Compress_Job,first,last:int,worker:int) {
    for c in first..<last {
        start:=c*CHUNK_BLOCKS
        end:=min(start+CHUNK_BLOCKS,job.e.count)
        job.errors[c]=compress_range(job.e,job.to,start,end,job.level)
    }
}

@(private)
compress_range :: proc(e:^Encode,to:[]u8,start,end:int,level:common.Level) -> Error {
    bb:=block_bytes(e.format)
    out:=to[start*bb:end*bb]
    n:=end-start
    switch e.format {
    case .BC7:
        return from_common(bc7.compress(out,e.colors[start:end],level,e.options))
    case .BC1,.BC3:
        bgra:[CHUNK_BLOCKS]common.Color_Block
        for i in 0..<n {bgra[i]=swap_rb(e.colors[start+i])}
        if e.format==.BC1 {return from_common(bc1.compress(out,8,0,bgra[:n],level,e.options,false))}
        if err:=bc4.compress(out,16,0,slice_bytes(e.colors[start:end]),.RGBA8_Alpha,level,
            e.options);err!=.None {
            return from_common(err)
        }
        return from_common(bc1.compress(out,16,8,bgra[:n],level,e.options,true))
    case .BC4:
        r:[CHUNK_BLOCKS]common.R16_Block
        for i in 0..<n {for t in 0..<16 {r[i][t]=bc4.unorm8_to_unorm16(e.colors[start+i][t][0])}}
        return from_common(bc4.compress(out,8,0,slice_bytes(r[:n]),.R16,level,e.options))
    case .BC5:
        rg:[CHUNK_BLOCKS]common.RG16_Block
        for i in 0..<n {for t in 0..<16 {
            c:=e.colors[start+i][t]
            rg[i][t]={bc4.unorm8_to_unorm16(c[0]),bc4.unorm8_to_unorm16(c[1])}
        }}
        return from_common(bc4.compress(out,16,0,slice_bytes(rg[:n]),.RG16,level,e.options))
    case .BC6H:
        if e.halfs!=nil {return from_common(bc6.compress(out,e.halfs[start:end],level,e.options))}
        h:[CHUNK_BLOCKS]common.Half_Block
        for i in 0..<n {for t in 0..<16 {for c in 0..<4 {
            h[i][t][c]=bc6.f32_to_half(e.floats[start+i][t][c])
        }}}
        return from_common(bc6.compress(out,h[:n],level,e.options))
    }
    return .Invalid_Format
}

@(private)
swap_rb :: #force_inline proc "contextless" (b:common.Color_Block) -> (o:common.Color_Block) {
    for t,i in b {o[i]={t[2],t[1],t[0],t[3]}}
    return
}

@(private)
slice_bytes :: #force_inline proc "contextless" (s:[]$T) -> []u8 {
    return ([^]u8)(raw_data(s))[:len(s)*size_of(T)]
}

// get_rdo_encode_config: the effort of the baseline encode and the slice size.
@(private)
RDO_Config :: struct {baseline:common.Level,max_slice_blocks:int}

@(private)
rdo_config :: proc "contextless" (format:Format,level:common.Level) -> RDO_Config {
    S :: common.Level.Slow
    V :: common.Level.Very_Slow
    t:[5]RDO_Config
    switch format {
    case .BC1: t={{S,4096},{S,4096},{V,8192},{V,8192},{V,8192}}
    case .BC3: t={{S,2048},{S,2048},{V,2048},{V,4096},{V,4096}}
    case .BC4: t={{V,2048},{V,2048},{V,4096},{V,8192},{V,8192}}
    case .BC5: t={{V,1024},{V,1024},{V,2048},{V,4096},{V,4096}}
    case .BC6H: t={{S,4096},{S,4096},{V,4096},{V,4096},{V,4096}}
    case .BC7: t={{S,2048},{S,2048},{S,4096},{V,4096},{V,4096}}
    }
    return t[int(level)]
}

@(private)
Activity_Job :: struct {
    e:^Encode,
    surface:common.Surface, // R32F
    metric:Metric,
    tiles_x:int,
    errors:[]Error,
}

@(private)
activity_tiles :: proc(job:^Activity_Job,first,last:int,worker:int) {
    s:=job.e.src
    source:=common.Surface{pixels=s.pixels,width=s.width,height=s.height,stride=s.stride}
    switch s.format {
    case .RGBA8: source.format=.RGBA8
    case .RGBA16F: source.format=.RGBA16F
    case .RGBA32F: source.format=.RGBA32F
    }
    arena,scratch:=worker_arena(job.e,worker)
    for t in first..<last {
        defer mem.dynamic_arena_reset(arena)
        x:=(t%job.tiles_x)*ACTIVITY_TILE
        y:=(t/job.tiles_x)*ACTIVITY_TILE
        w:=min(ACTIVITY_TILE,s.width-x)
        h:=min(ACTIVITY_TILE,s.height-y)
        to:=common.surface_view(job.surface,x,y,w,h)
        from:=common.surface_view(source,x,y,w,h)
        err:common.Error
        if job.metric==.RMSE {
            err=common.make_activity_mask_constant_for_rmse(to,from)
        } else if job.e.format==.BC6H {
            err=common.make_activity_mask_hdr(to,from,job.e.options,scratch)
        } else {
            alpha:=job.e.format==.BC3 || job.e.format==.BC7
            mode:=common.Activity_Mode.RGBA_1F if alpha else .RGB_1F
            channels:=1 if job.e.format==.BC4 else 2 if job.e.format==.BC5 else 4
            err=common.make_activity_mask(to,from,mode,job.e.options,channels,scratch)
        }
        job.errors[t]=from_common(err)
    }
}

@(private)
Slice :: struct {start,count:int}

@(private)
Slice_Job :: struct {
    e:^Encode,
    slices:[]Slice,
    baseline:[]u8,
    activity:[]common.Float_Block,
    lambda:int,
    errors:[]Error,
}

// BlockSurface_JobSlicer_256K_then_N: chunks of 256 KiB of output, each cut
// into slices near max_slice blocks. It does not look at the threads, since
// the RDO of a slice sees only its own blocks.
@(private)
make_slices :: proc(format:Format,count,max_slice:int,
    allocator:mem.Allocator) -> (slices:[dynamic]Slice,err:mem.Allocator_Error) {
    slices=make([dynamic]Slice,allocator) or_return
    per_chunk:=256*1024/block_bytes(format)
    start:=0
    for start<count {
        chunk:=min(count-start,per_chunk)
        n:=max((chunk+max_slice*3/4)/max_slice,1)
        chunk_start:=start
        for i in 0..<n {
            end:=chunk_start+(i+1)*chunk/n
            if _,e:=append(&slices,Slice{start,end-start});e!=nil {delete(slices);return nil,e}
            start=end
        }
    }
    return
}

@(private)
encode_rdo :: proc(e:^Encode,lambda:int,metric:Metric) -> Error {
    if !arenas_init(e) {return .Out_Of_Memory}
    defer arenas_destroy(e)
    w,h:=e.src.width,e.src.height
    act,err:=make_uninit([]f32,w*h,e.allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(act,e.allocator)
    tiles_x:=(w+ACTIVITY_TILE-1)/ACTIVITY_TILE
    tiles:=tiles_x*((h+ACTIVITY_TILE-1)/ACTIVITY_TILE)
    tile_errors,err2:=make([]Error,tiles,e.allocator)
    if err2!=nil {return .Out_Of_Memory}
    defer delete(tile_errors,e.allocator)
    surface:=common.Surface{pixels=slice_bytes(act),width=w,height=h,stride=w*4,format=.R32F}
    ajob:=Activity_Job{e=e,surface=surface,metric=metric,tiles_x=tiles_x,errors=tile_errors}
    run(e,tiles,activity_tiles,&ajob)
    if r:=first_error(tile_errors);r!=.None {return r}
    activity,err3:=make_uninit([]common.Float_Block,e.count,e.allocator)
    if err3!=nil {return .Out_Of_Memory}
    defer delete(activity,e.allocator)
    gather_activity(act,w,h,activity,e.worker)

    config:=rdo_config(e.format,e.level)
    baseline,err4:=make_uninit([]u8,len(e.to),e.allocator)
    if err4!=nil {return .Out_Of_Memory}
    defer delete(baseline,e.allocator)
    if r:=compress_all(e,baseline,config.baseline);r!=.None {return r}

    slices,err5:=make_slices(e.format,e.count,config.max_slice_blocks,e.allocator)
    if err5!=nil {return .Out_Of_Memory}
    defer delete(slices)
    errors,err6:=make([]Error,len(slices),e.allocator)
    if err6!=nil {return .Out_Of_Memory}
    defer delete(errors,e.allocator)
    job:=Slice_Job{e=e,slices=slices[:],baseline=baseline,activity=activity,lambda=lambda,
        errors=errors}
    run(e,len(slices),rd_slices,&job)
    return first_error(errors)
}

@(private)
rd_slices :: proc(job:^Slice_Job,first,last:int,worker:int) {
    arena,scratch:=worker_arena(job.e,worker)
    for i in first..<last {
        job.errors[i]=rd_slice(job,job.slices[i],scratch)
        mem.dynamic_arena_reset(arena)
    }
}

// rrDXTCRD_Single on one slice, with its blocks in the format each RDO reads.
@(private)
rd_slice :: proc(job:^Slice_Job,s:Slice,scratch:mem.Allocator) -> Error {
    e:=job.e
    a:=scratch
    bb:=block_bytes(e.format)
    start,end:=s.start,s.start+s.count
    to:=e.to[start*bb:end*bb]
    base:=job.baseline[start*bb:end*bb]
    act:=job.activity[start:end]
    lambda:=job.lambda
    switch e.format {
    case .BC7:
        return from_common(bc7.rd(to,e.colors[start:end],base,act,lambda,e.options,e.rd_options,a))
    case .BC1:
        return from_common(bc1.rd(to,8,0,e.colors[start:end],base,act,lambda,e.options,
            e.rd_options,a))
    case .BC3:
        alpha:=lambda
        if e.rd_options.use_bc3_alpha_lambda {alpha=e.rd_options.bc3_alpha_lambda}
        if alpha>0 {
            err:=bc4.rd(to,16,0,slice_bytes(e.colors[start:end]),.RGBA8_Alpha,base,act,alpha,
                e.options,e.rd_options,a)
            if err!=.None {return from_common(err)}
        } else {
            for i in 0..<s.count {copy(to[i*16:i*16+8],base[i*16:i*16+8])}
        }
        return from_common(bc1.rd(to,16,8,e.colors[start:end],base,act,lambda,e.options,
            e.rd_options,a))
    case .BC4:
        r,err:=make_uninit([]common.R16_Block,s.count,a)
        if err!=nil {return .Out_Of_Memory}
        defer delete(r,a)
        for i in 0..<s.count {for t in 0..<16 {
            r[i][t]=bc4.unorm8_to_unorm16(e.colors[start+i][t][0])
        }}
        return from_common(bc4.rd(to,8,0,slice_bytes(r),.R16,base,act,lambda,e.options,
            e.rd_options,a))
    case .BC5:
        rg,err:=make_uninit([]common.RG16_Block,s.count,a)
        if err!=nil {return .Out_Of_Memory}
        defer delete(rg,a)
        for i in 0..<s.count {for t in 0..<16 {
            c:=e.colors[start+i][t]
            rg[i][t]={bc4.unorm8_to_unorm16(c[0]),bc4.unorm8_to_unorm16(c[1])}
        }}
        return from_common(bc4.rd(to,16,0,slice_bytes(rg),.RG16,base,act,lambda,e.options,
            e.rd_options,a))
    case .BC6H:
        if e.floats!=nil {
            return from_common(bc6.rd(to,e.floats[start:end],base,act,lambda,e.options,
                e.rd_options,a))
        }
        f,err:=make_uninit([]common.Float4_Block,s.count,a)
        if err!=nil {return .Out_Of_Memory}
        defer delete(f,a)
        for i in 0..<s.count {for t in 0..<16 {for c in 0..<4 {
            f[i][t][c]=f32(transmute(f16)e.halfs[start+i][t][c])
        }}}
        return from_common(bc6.rd(to,f,base,act,lambda,e.options,e.rd_options,a))
    }
    return .Invalid_Format
}
