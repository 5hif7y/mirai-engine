package bc7split

import "base:intrinsics"
import "core:simd"
import "core:sys/info"

// Blocks restored per pass: their mode lists and BC7 bits stay in cache.
CHUNK_BLOCKS :: 2048

// A mode list holds up to a chunk, plus what its last 8-index store writes past it.
@(private) LIST :: CHUNK_BLOCKS+8

// The scratch of a decode, allocated once by the caller; a decode does not allocate.
Decoder :: struct {
    indices:[MODE_COUNT*LIST]u16, // per mode, the blocks of the chunk that have it
    modes:[CHUNK_BLOCKS]u8,
    chunk:[CHUNK_BLOCKS*16]u8,
}

// Takes the path without AVX2 on x64, to test it.
@(private) FORCE_GENERIC :: #config(BC7SPLIT_FORCE_GENERIC,false)

// Restores the BC7 blocks of a stream into dst, 16 bytes per block. Safe for any input: it never
// reads outside src nor writes outside dst. cached_destination writes the blocks straight into
// dst; without it each chunk is restored in the decoder and copied once, which suits
// write-combined memory such as an upload buffer.
decode :: proc "contextless" (
    d:^Decoder,header:Header,src,dst:[]u8,cached_destination:=false,
) -> (written:int,err:Error) {
    if d==nil {return 0,.Missing_Decoder}
    blocks,payload_size:=header_read(header) or_return
    if blocks==0 {return 0,.None}
    if len(dst)<blocks*16 {return 0,.Output_Too_Small}
    if len(src)<payload_size {return 0,.Input_Too_Small}
    when ODIN_ARCH==.amd64 {
        if !FORCE_GENERIC && .avx2 in info.cpu_features() {
            err=decode_avx2(d,header,raw_data(src),raw_data(dst),blocks,cached_destination)
        } else {
            err=decode_base(d,header,raw_data(src),raw_data(dst),blocks,cached_destination)
        }
    } else {
        err=decode_base(d,header,raw_data(src),raw_data(dst),blocks,cached_destination)
    }
    if err!=.None {return 0,err}
    return blocks*16,.None
}

when ODIN_ARCH==.amd64 {
    @(private, enable_target_feature="avx2")
    decode_avx2 :: proc "contextless" (
        d:^Decoder,header:Header,src,dst:[^]u8,blocks:int,cached:bool,
    ) -> Error {
        return decode_chunks(d,header,src,dst,blocks,cached)
    }
}

@(private)
decode_base :: proc "contextless" (
    d:^Decoder,header:Header,src,dst:[^]u8,blocks:int,cached:bool,
) -> Error {
    return decode_chunks(d,header,src,dst,blocks,cached)
}

// src holds the whole payload and dst blocks*16 bytes: header_read checked both.
@(private="file")
decode_chunks :: #force_inline proc "contextless" (
    d:^Decoder,header:Header,src,dst:[^]u8,blocks:int,cached:bool,
) -> Error #no_bounds_check {
    sizes,splits:=MODE_SIZES,MODE_SPLITS
    first,second:[MODE_COUNT][^]u8
    first_step,second_step,left:[MODE_COUNT]int
    split:[MODE_COUNT]bool
    cs:=header.flags&FLAG_SWITCH_COLORSPACE!=0
    pos:=0
    for m in 0..<MODE_COUNT {
        n:=int(header.mode_counts[m])
        left[m]=n
        split[m]=header.flags&(FLAG_SPLIT0<<u32(m))!=0 && splits[m]>0
        first[m]=src[pos:]
        if split[m] {
            second[m]=src[pos+splits[m]*n:]
            first_step[m],second_step[m]=splits[m],sizes[m]-splits[m]
        } else {
            second[m]=src[pos+splits[m]:]
            first_step[m],second_step[m]=sizes[m],sizes[m]
        }
        pos+=n*sizes[m]
    }
    nibbles:=src[pos:]
    for base:=0;base<blocks;base+=CHUNK_BLOCKS {
        n:=min(blocks-base,CHUNK_BLOCKS)
        count,valid:=sort_modes(d,nibbles[base>>1:],n)
        if !valid {return .Payload_Corrupt}
        out:=dst[base*16:] if cached else raw_data(&d.chunk)
        for m in 0..<MODE_COUNT {
            c:=count[m]
            if c==0 {continue}
            if c>left[m] {return .Payload_Corrupt}
            left[m]-=c
            target:=raw_data(d.indices[m*LIST:])
            v:=int(cs)|int(split[m])<<1
            switch m {
            case 0: run_variant(out,first[m],second[m],c,target,0,v)
            case 1: run_variant(out,first[m],second[m],c,target,1,v)
            case 2: run_variant(out,first[m],second[m],c,target,2,v)
            case 3: run_variant(out,first[m],second[m],c,target,3,v)
            case 4: run_variant(out,first[m],second[m],c,target,4,v)
            case 5: run_variant(out,first[m],second[m],c,target,5,v)
            case 6: run_variant(out,first[m],second[m],c,target,6,v)
            case 7: run_variant(out,first[m],second[m],c,target,7,v)
            case 8: run(out,first[m],second[m],c,target,8,false,false)
            case 9:
                if cs {run(out,first[m],second[m],c,target,9,false,true)}
                else {run(out,first[m],second[m],c,target,9,false,false)}
            }
            first[m]=first[m][c*first_step[m]:]
            second[m]=second[m][c*second_step[m]:]
        }
        if !cached {intrinsics.mem_copy_non_overlapping(dst[base*16:],&d.chunk,n*16)}
    }
    return .None
}

@(private="file") WINDOW :: 32
@(private="file") Window_Mask :: u32
@(private="file") Window :: #simd[WINDOW]u8

// Lists the blocks of each mode in order, false on a mode above 9. Looks at WINDOW blocks at a
// time and lists together those that share the mode of the first one not listed yet.
@(private="file")
sort_modes :: #force_inline proc "contextless" (
    d:^Decoder,nibbles:[^]u8,n:int,
) -> (count:[MODE_COUNT]int,valid:bool) #no_bounds_check {
    modes:=raw_data(&d.modes)
    over:simd.u8x16
    i:=0
    for ;i+32<=n;i+=32 {
        v:=intrinsics.unaligned_load((^simd.u8x16)(nibbles[i>>1:]))
        lo,hi:=v&0xf,simd.shr(v,4)
        over|=simd.saturating_sub(lo,9)|simd.saturating_sub(hi,9)
        a:=simd.shuffle(lo,hi,0,16,1,17,2,18,3,19,4,20,5,21,6,22,7,23)
        b:=simd.shuffle(lo,hi,8,24,9,25,10,26,11,27,12,28,13,29,14,30,15,31)
        intrinsics.unaligned_store((^simd.u8x16)(modes[i:]),a)
        intrinsics.unaligned_store((^simd.u8x16)(modes[i+16:]),b)
    }
    tail_over:=u8(0)
    for ;i<n;i+=1 {
        m:=(nibbles[i>>1]>>(u32(i&1)*4))&0xf
        modes[i]=m
        tail_over|=u8(m>9)
    }
    if simd.reduce_or(over)|tail_over!=0 {return}
    indices:=raw_data(&d.indices)
    // Bit k: block i+k is listed. Never more than WINDOW bits, so a clear bit is always found.
    listed:u64
    i=0
    for i+WINDOW<=n {
        v:=intrinsics.unaligned_load((^Window)(modes[i:]))
        m:=modes[i]
        mask:=u64(transmute(Window_Mask)simd.extract_msbs(simd.lanes_eq(v,Window(m))))
        out:=indices[int(m)*LIST+count[m]:]
        #unroll for g in 0..<WINDOW/8 {
            part:=(mask>>(8*u64(g)))&0xff
            at:=simd.u16x8(u16(i+8*g))+simd.u16x8(transmute(#simd[8]u8)COMPACT[part])
            intrinsics.unaligned_store((^simd.u16x8)(out),at)
            out=out[intrinsics.count_ones(part):]
        }
        count[m]+=int(intrinsics.count_ones(mask))
        listed|=mask
        skip:=intrinsics.count_trailing_zeros(~listed)
        listed>>=skip
        i+=int(skip)
    }
    for ;i<n;i+=1 {
        if listed&1==0 {
            m:=modes[i]
            indices[int(m)*LIST+count[m]]=u16(i)
            count[m]+=1
        }
        listed>>=1
    }
    return count,true
}

// For each 8-bit mask, the positions of its set bits in order.
@(private="file", rodata)
COMPACT := [256][8]u8{
    {0,0,0,0,0,0,0,0},{0,0,0,0,0,0,0,0},{1,0,0,0,0,0,0,0},{0,1,0,0,0,0,0,0},{2,0,0,0,0,0,0,0},
    {0,2,0,0,0,0,0,0},{1,2,0,0,0,0,0,0},{0,1,2,0,0,0,0,0},{3,0,0,0,0,0,0,0},{0,3,0,0,0,0,0,0},
    {1,3,0,0,0,0,0,0},{0,1,3,0,0,0,0,0},{2,3,0,0,0,0,0,0},{0,2,3,0,0,0,0,0},{1,2,3,0,0,0,0,0},
    {0,1,2,3,0,0,0,0},{4,0,0,0,0,0,0,0},{0,4,0,0,0,0,0,0},{1,4,0,0,0,0,0,0},{0,1,4,0,0,0,0,0},
    {2,4,0,0,0,0,0,0},{0,2,4,0,0,0,0,0},{1,2,4,0,0,0,0,0},{0,1,2,4,0,0,0,0},{3,4,0,0,0,0,0,0},
    {0,3,4,0,0,0,0,0},{1,3,4,0,0,0,0,0},{0,1,3,4,0,0,0,0},{2,3,4,0,0,0,0,0},{0,2,3,4,0,0,0,0},
    {1,2,3,4,0,0,0,0},{0,1,2,3,4,0,0,0},{5,0,0,0,0,0,0,0},{0,5,0,0,0,0,0,0},{1,5,0,0,0,0,0,0},
    {0,1,5,0,0,0,0,0},{2,5,0,0,0,0,0,0},{0,2,5,0,0,0,0,0},{1,2,5,0,0,0,0,0},{0,1,2,5,0,0,0,0},
    {3,5,0,0,0,0,0,0},{0,3,5,0,0,0,0,0},{1,3,5,0,0,0,0,0},{0,1,3,5,0,0,0,0},{2,3,5,0,0,0,0,0},
    {0,2,3,5,0,0,0,0},{1,2,3,5,0,0,0,0},{0,1,2,3,5,0,0,0},{4,5,0,0,0,0,0,0},{0,4,5,0,0,0,0,0},
    {1,4,5,0,0,0,0,0},{0,1,4,5,0,0,0,0},{2,4,5,0,0,0,0,0},{0,2,4,5,0,0,0,0},{1,2,4,5,0,0,0,0},
    {0,1,2,4,5,0,0,0},{3,4,5,0,0,0,0,0},{0,3,4,5,0,0,0,0},{1,3,4,5,0,0,0,0},{0,1,3,4,5,0,0,0},
    {2,3,4,5,0,0,0,0},{0,2,3,4,5,0,0,0},{1,2,3,4,5,0,0,0},{0,1,2,3,4,5,0,0},{6,0,0,0,0,0,0,0},
    {0,6,0,0,0,0,0,0},{1,6,0,0,0,0,0,0},{0,1,6,0,0,0,0,0},{2,6,0,0,0,0,0,0},{0,2,6,0,0,0,0,0},
    {1,2,6,0,0,0,0,0},{0,1,2,6,0,0,0,0},{3,6,0,0,0,0,0,0},{0,3,6,0,0,0,0,0},{1,3,6,0,0,0,0,0},
    {0,1,3,6,0,0,0,0},{2,3,6,0,0,0,0,0},{0,2,3,6,0,0,0,0},{1,2,3,6,0,0,0,0},{0,1,2,3,6,0,0,0},
    {4,6,0,0,0,0,0,0},{0,4,6,0,0,0,0,0},{1,4,6,0,0,0,0,0},{0,1,4,6,0,0,0,0},{2,4,6,0,0,0,0,0},
    {0,2,4,6,0,0,0,0},{1,2,4,6,0,0,0,0},{0,1,2,4,6,0,0,0},{3,4,6,0,0,0,0,0},{0,3,4,6,0,0,0,0},
    {1,3,4,6,0,0,0,0},{0,1,3,4,6,0,0,0},{2,3,4,6,0,0,0,0},{0,2,3,4,6,0,0,0},{1,2,3,4,6,0,0,0},
    {0,1,2,3,4,6,0,0},{5,6,0,0,0,0,0,0},{0,5,6,0,0,0,0,0},{1,5,6,0,0,0,0,0},{0,1,5,6,0,0,0,0},
    {2,5,6,0,0,0,0,0},{0,2,5,6,0,0,0,0},{1,2,5,6,0,0,0,0},{0,1,2,5,6,0,0,0},{3,5,6,0,0,0,0,0},
    {0,3,5,6,0,0,0,0},{1,3,5,6,0,0,0,0},{0,1,3,5,6,0,0,0},{2,3,5,6,0,0,0,0},{0,2,3,5,6,0,0,0},
    {1,2,3,5,6,0,0,0},{0,1,2,3,5,6,0,0},{4,5,6,0,0,0,0,0},{0,4,5,6,0,0,0,0},{1,4,5,6,0,0,0,0},
    {0,1,4,5,6,0,0,0},{2,4,5,6,0,0,0,0},{0,2,4,5,6,0,0,0},{1,2,4,5,6,0,0,0},{0,1,2,4,5,6,0,0},
    {3,4,5,6,0,0,0,0},{0,3,4,5,6,0,0,0},{1,3,4,5,6,0,0,0},{0,1,3,4,5,6,0,0},{2,3,4,5,6,0,0,0},
    {0,2,3,4,5,6,0,0},{1,2,3,4,5,6,0,0},{0,1,2,3,4,5,6,0},{7,0,0,0,0,0,0,0},{0,7,0,0,0,0,0,0},
    {1,7,0,0,0,0,0,0},{0,1,7,0,0,0,0,0},{2,7,0,0,0,0,0,0},{0,2,7,0,0,0,0,0},{1,2,7,0,0,0,0,0},
    {0,1,2,7,0,0,0,0},{3,7,0,0,0,0,0,0},{0,3,7,0,0,0,0,0},{1,3,7,0,0,0,0,0},{0,1,3,7,0,0,0,0},
    {2,3,7,0,0,0,0,0},{0,2,3,7,0,0,0,0},{1,2,3,7,0,0,0,0},{0,1,2,3,7,0,0,0},{4,7,0,0,0,0,0,0},
    {0,4,7,0,0,0,0,0},{1,4,7,0,0,0,0,0},{0,1,4,7,0,0,0,0},{2,4,7,0,0,0,0,0},{0,2,4,7,0,0,0,0},
    {1,2,4,7,0,0,0,0},{0,1,2,4,7,0,0,0},{3,4,7,0,0,0,0,0},{0,3,4,7,0,0,0,0},{1,3,4,7,0,0,0,0},
    {0,1,3,4,7,0,0,0},{2,3,4,7,0,0,0,0},{0,2,3,4,7,0,0,0},{1,2,3,4,7,0,0,0},{0,1,2,3,4,7,0,0},
    {5,7,0,0,0,0,0,0},{0,5,7,0,0,0,0,0},{1,5,7,0,0,0,0,0},{0,1,5,7,0,0,0,0},{2,5,7,0,0,0,0,0},
    {0,2,5,7,0,0,0,0},{1,2,5,7,0,0,0,0},{0,1,2,5,7,0,0,0},{3,5,7,0,0,0,0,0},{0,3,5,7,0,0,0,0},
    {1,3,5,7,0,0,0,0},{0,1,3,5,7,0,0,0},{2,3,5,7,0,0,0,0},{0,2,3,5,7,0,0,0},{1,2,3,5,7,0,0,0},
    {0,1,2,3,5,7,0,0},{4,5,7,0,0,0,0,0},{0,4,5,7,0,0,0,0},{1,4,5,7,0,0,0,0},{0,1,4,5,7,0,0,0},
    {2,4,5,7,0,0,0,0},{0,2,4,5,7,0,0,0},{1,2,4,5,7,0,0,0},{0,1,2,4,5,7,0,0},{3,4,5,7,0,0,0,0},
    {0,3,4,5,7,0,0,0},{1,3,4,5,7,0,0,0},{0,1,3,4,5,7,0,0},{2,3,4,5,7,0,0,0},{0,2,3,4,5,7,0,0},
    {1,2,3,4,5,7,0,0},{0,1,2,3,4,5,7,0},{6,7,0,0,0,0,0,0},{0,6,7,0,0,0,0,0},{1,6,7,0,0,0,0,0},
    {0,1,6,7,0,0,0,0},{2,6,7,0,0,0,0,0},{0,2,6,7,0,0,0,0},{1,2,6,7,0,0,0,0},{0,1,2,6,7,0,0,0},
    {3,6,7,0,0,0,0,0},{0,3,6,7,0,0,0,0},{1,3,6,7,0,0,0,0},{0,1,3,6,7,0,0,0},{2,3,6,7,0,0,0,0},
    {0,2,3,6,7,0,0,0},{1,2,3,6,7,0,0,0},{0,1,2,3,6,7,0,0},{4,6,7,0,0,0,0,0},{0,4,6,7,0,0,0,0},
    {1,4,6,7,0,0,0,0},{0,1,4,6,7,0,0,0},{2,4,6,7,0,0,0,0},{0,2,4,6,7,0,0,0},{1,2,4,6,7,0,0,0},
    {0,1,2,4,6,7,0,0},{3,4,6,7,0,0,0,0},{0,3,4,6,7,0,0,0},{1,3,4,6,7,0,0,0},{0,1,3,4,6,7,0,0},
    {2,3,4,6,7,0,0,0},{0,2,3,4,6,7,0,0},{1,2,3,4,6,7,0,0},{0,1,2,3,4,6,7,0},{5,6,7,0,0,0,0,0},
    {0,5,6,7,0,0,0,0},{1,5,6,7,0,0,0,0},{0,1,5,6,7,0,0,0},{2,5,6,7,0,0,0,0},{0,2,5,6,7,0,0,0},
    {1,2,5,6,7,0,0,0},{0,1,2,5,6,7,0,0},{3,5,6,7,0,0,0,0},{0,3,5,6,7,0,0,0},{1,3,5,6,7,0,0,0},
    {0,1,3,5,6,7,0,0},{2,3,5,6,7,0,0,0},{0,2,3,5,6,7,0,0},{1,2,3,5,6,7,0,0},{0,1,2,3,5,6,7,0},
    {4,5,6,7,0,0,0,0},{0,4,5,6,7,0,0,0},{1,4,5,6,7,0,0,0},{0,1,4,5,6,7,0,0},{2,4,5,6,7,0,0,0},
    {0,2,4,5,6,7,0,0},{1,2,4,5,6,7,0,0},{0,1,2,4,5,6,7,0},{3,4,5,6,7,0,0,0},{0,3,4,5,6,7,0,0},
    {1,3,4,5,6,7,0,0},{0,1,3,4,5,6,7,0},{2,3,4,5,6,7,0,0},{0,2,3,4,5,6,7,0},{1,2,3,4,5,6,7,0},
    {0,1,2,3,4,5,6,7},
}

@(private="file")
run_variant :: #force_inline proc "contextless" (
    out,first,second:[^]u8,n:int,target:[^]u16,$mode:int,variant:int,
) {
    switch variant {
    case 0: run(out,first,second,n,target,mode,false,false)
    case 1: run(out,first,second,n,target,mode,false,true)
    case 2: run(out,first,second,n,target,mode,true,false)
    case 3: run(out,first,second,n,target,mode,true,true)
    }
}

@(private="file")
run :: #force_inline proc "contextless" (
    out,first,second:[^]u8,n:int,target:[^]u16,$mode:int,$split,$cs:bool,
) #no_bounds_check {
    SIZES,SPLITS :: MODE_SIZES,MODE_SPLITS
    FA :: SPLITS[mode] when split else SIZES[mode]
    SA :: SIZES[mode]-SPLITS[mode] when split else SIZES[mode]
    i:=0
    for ;i+LANES<=n;i+=LANES {
        lo,hi:=block(Lanes,first[i*FA:],second[i*SA:],mode,FA,SA,cs)
        put(out,target[i:],lo,hi)
    }
    for ;i<n;i+=1 {
        lo,hi:=block(u64,first[i*FA:],second[i*SA:],mode,FA,SA,cs)
        put(out,target[i:],lo,hi)
    }
}

// Loads the two parts of one block or of LANES consecutive blocks and restores their bits.
@(private="file")
block :: #force_inline proc "contextless" (
    $T:typeid,first,second:[^]u8,$mode,$FA,$SA:int,$cs:bool,
) -> (lo,hi:T) {
    when mode==0 {return mode0(ld(T,8,first,FA),ld(T,8,second,SA),cs)}
    else when mode==1 {return mode1(ld(T,8,first,FA),ld(T,8,second,SA),cs)}
    else when mode==2 {return mode2(ld(T,8,first,FA),ld(T,4,first[8:],FA),ld(T,4,second,SA),cs)}
    else when mode==3 {return mode3(ld(T,8,first,FA),ld(T,4,first[8:],FA),ld(T,4,second,SA),cs)}
    else when mode==4 {return mode4(ld(T,6,first,FA),ld(T,2,second,SA),ld(T,8,second[2:],SA),cs)}
    else when mode==5 {return mode5(ld(T,8,first,FA),ld(T,8,second,SA),cs)}
    else when mode==6 {return mode6(ld(T,8,first,FA),ld(T,8,second,SA),cs)}
    else when mode==7 {
        return mode7(ld(T,8,first,FA),ld(T,4,first[8:],FA)|shl(ld(T,4,second,SA),32),cs)
    }
    else when mode==8 {return ld(T,8,first,FA),ld(T,8,first[8:],FA)}
    else {return mode9(ld(T,4,first,FA),cs),0xaaaaaaac}
}

// W little-endian bytes of each block, W in 2, 4, 6 or 8.
@(private="file")
ld :: #force_inline proc "contextless" (
    $T:typeid,$W:int,p:[^]u8,$stride:int,
) -> T #no_bounds_check {
    when intrinsics.type_is_array(T) {
        v:T
        #unroll for j in 0..<LANES {v[j]=ld1(W,p[j*stride:])}
        return v
    } else {
        return ld1(W,p)
    }
}

@(private="file")
ld1 :: #force_inline proc "contextless" ($W:int,p:[^]u8) -> u64 {
    when W==8 {return u64(intrinsics.unaligned_load((^u64le)(p)))}
    else when W==6 {
        lo,hi:=intrinsics.unaligned_load((^u32le)(p)),intrinsics.unaligned_load((^u16le)(p[4:]))
        return u64(lo)|u64(hi)<<32
    }
    else when W==4 {return u64(intrinsics.unaligned_load((^u32le)(p)))}
    else {return u64(intrinsics.unaligned_load((^u16le)(p)))}
}

@(private="file")
put :: #force_inline proc "contextless" (out:[^]u8,target:[^]u16,lo,hi:$T) #no_bounds_check {
    when intrinsics.type_is_array(T) {
        #unroll for j in 0..<LANES {
            p:=(^#simd[2]u64)(out[int(target[j])*16:])
            intrinsics.unaligned_store(p,#simd[2]u64{lo[j],hi[j]})
        }
    } else {
        p:=out[int(target[0])*16:]
        intrinsics.unaligned_store((^u64le)(p),u64le(lo))
        intrinsics.unaligned_store((^u64le)(p[8:]),u64le(hi))
    }
}
