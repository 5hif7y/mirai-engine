package bc7split_encode

import "base:intrinsics"
import "core:math"
import "mirai:asset"
import "mirai:std/compressor/lz/entropy"
import rt "mirai:std/compressor/bc7split"

// The BC7Split encoder: it sorts the blocks by mode, rewrites each mode's bits so that equal
// fields line up in bytes, splits the modes whose halves compress differently and keeps the color
// space (RGB or G, R-G, B-G) whose estimate is smaller. Solid blocks become 4-byte colors.

Error :: enum u8 {
    None,
    Missing_Header,    // header is nil
    Not_Blocks,        // src is not a whole number of 16-byte blocks
    Too_Many_Blocks,   // more than rt.MAX_BLOCKS
    Output_Too_Small,  // dst is below min_output_size
    Scratch_Too_Small, // scratch is below min_scratch_size
}

// Space trade of the encoder: bytes saved against decode cycles.
@(private) LAMBDA :: f32(0.01)

// Estimated decode cycles per block, [mode][colorspace switch + 2 if split].
@(private, rodata)
DECODE_CYCLES := [rt.MODE_COUNT][4]f32{
    {18.6,16.6,17.7,14.9},
    {15.9,16.2,13.6,14.7},
    {26.0,28.9,25.3,30.2},
    {17.6,19.1,14.6,17.7},
    {15.5,23.0,12.7,21.8},
    {13.3,16.7,10.7,13.2},
    { 9.0,10.0,11.5, 8.7},
    {15.2,21.2,18.0,19.1},
    { 6.2, 6.2, 6.2, 6.2},
    { 5.4, 5.6, 5.4, 5.6},
}

min_output_size :: proc "contextless" (blocks:int) -> int {return 16*blocks+(blocks+1)/2}

min_scratch_size :: proc "contextless" (blocks:int) -> int {return (blocks+15)&~15+3*16*blocks}

// Encodes the BC7 blocks of src into dst and returns the bytes written; header goes next to the
// payload, which rt.decode needs. The output is the same as the reference encoder's.
encode :: proc "contextless" (header:^rt.Header,dst,src,scratch:[]u8) -> (written:int,err:Error) {
    if header==nil {return 0,.Missing_Header}
    if len(src)%16!=0 {return 0,.Not_Blocks}
    blocks:=len(src)/16
    if blocks>rt.MAX_BLOCKS {return 0,.Too_Many_Blocks}
    if len(dst)<min_output_size(blocks) {return 0,.Output_Too_Small}
    if len(scratch)<min_scratch_size(blocks) {return 0,.Scratch_Too_Small}
    header^={version=rt.HEADER_VERSION}
    if blocks==0 {return 0,.None}

    modes:=scratch[:(blocks+1)&~1]
    counts:=choose_modes(modes,src)
    sizes:=rt.MODE_SIZES
    offsets:[rt.MODE_COUNT]int
    payload_size:=0
    for m in 0..<rt.MODE_COUNT {
        offsets[m]=payload_size
        payload_size+=counts[m]*sizes[m]
        header.mode_counts[m]=u32(counts[m])
    }
    at:=(blocks+15)&~15
    twiddled:=scratch[at:][:payload_size]
    candidate:=scratch[at+16*blocks:][:payload_size]
    best_j:f64
    for colorspace in 0..<2 {
        switch_colorspace:=colorspace!=0
        munge(twiddled,modes,offsets,src,switch_colorspace)
        splits,j:=decide_splits(candidate,twiddled,counts,offsets,colorspace)
        if colorspace==0 || j<best_j {
            best_j=j
            copy(dst,candidate)
            header.flags=splits|(rt.FLAG_SWITCH_COLORSPACE if switch_colorspace else 0)
        }
    }
    for i:=0;i<blocks;i+=2 {dst[payload_size+i/2]=modes[i]|modes[i+1]<<4}
    return payload_size+(blocks+1)/2,.None
}

@(private)
solid_color :: proc "contextless" (block:[]u8) -> (color:[4]u8,solid:bool) {
    texels:=asset.texture_bc7_block_decode(([^][16]u8)(raw_data(block))[0])
    for t in texels[1:] {if t!=texels[0] {return}}
    return texels[0],true
}

// The mode of each block (8 for no valid mode, 9 for a solid color), padded to an even count.
@(private)
choose_modes :: proc "contextless" (modes,src:[]u8) -> (counts:[rt.MODE_COUNT]int) {
    blocks:=len(src)/16
    for b in 0..<blocks {
        block:=src[b*16:][:16]
        mode:=u8(0)
        for mode<8 && block[0]&(1<<mode)==0 {mode+=1}
        if _,solid:=solid_color(block);solid {mode=9}
        modes[b]=mode
        counts[mode]+=1
    }
    if blocks&1==1 {modes[blocks]=0}
    return
}

@(private)
get64 :: #force_inline proc "contextless" (p:[]u8) -> u64 {
    return u64(intrinsics.unaligned_load((^u64le)(raw_data(p))))
}

@(private)
put64 :: #force_inline proc "contextless" (p:[]u8,v:u64) {
    intrinsics.unaligned_store((^u64le)(raw_data(p)),u64le(v))
}

@(private)
bits :: #force_inline proc "contextless" (v:u64,start,width:u64) -> u64 {
    return (v>>start)&((1<<width)-1)
}

@(private)
packed_sub :: #force_inline proc "contextless" (a,b,msb,nonmsb:u64) -> u64 {
    return ((a|msb)-(b&nonmsb))~((a~(~b))&msb)
}

// (R, G, B) to (G, R-G, B-G), each field wrapping at its bit of msb.
@(private)
decorr :: #force_inline proc "contextless" (r,g,b:^u64,msb:u64) {
    decorr2(r,g,b,msb,~msb)
}

@(private)
decorr2 :: #force_inline proc "contextless" (r,g,b:^u64,msb,nonmsb:u64) {
    y:=g^
    cr:=packed_sub(r^,g^,msb,nonmsb)
    cb:=packed_sub(b^,g^,msb,nonmsb)
    r^,g^,b^=y,cr,cb
}

@(private)
expand1to8_8x :: proc "contextless" (x:u64) -> u64 {
    return ((x&0x7f)*0x0002040810204081|(x&0x80)<<49)&0x0101010101010101
}

@(private)
expand1to16_4x :: proc "contextless" (x:u64) -> u64 {
    return ((x&0xf)*0x0000200040008001)&0x0001000100010001
}

@(private)
expand6to16_4x :: proc "contextless" (x:u64) -> u64 {
    x:=((x<<20)|x)&0x00000fff00000fff
    return ((x<<10)|x)&0x003f003f003f003f
}

@(private)
expand5to16_4x :: proc "contextless" (x:u64) -> u64 {
    x:=x&0xffffff
    x=((x<<22)|x)&0x000003ff000003ff
    return ((x<<11)|x)&0x001f001f001f001f
}

@(private)
expand5to16_2x :: proc "contextless" (x:u64) -> u64 {return (x&0x1f)|((x&0x3e0)<<11)}

@(private)
expand1to16_2x :: proc "contextless" (x:u64) -> u64 {return (x&1)|((x&2)<<15)}

@(private)
expand7to24_2x :: proc "contextless" (x:u64) -> u64 {return (x&0x7f)|((x&0x3f80)<<17)}

@(private)
expand7to24_3x :: proc "contextless" (x:u64) -> u64 {
    return (x&0x7f)|((x&0x3f80)<<17)|((x&0x1fc000)<<34)
}

@(private)
expand7to32_2x :: proc "contextless" (x:u64) -> u64 {return (x&0x7f)|((x&0x3f80)<<25)}

@(private)
expand8to32_2x :: proc "contextless" (x:u64) -> u64 {return (x&0xff)|((x&0xff00)<<24)}

@(private)
expand7to8_8x :: proc "contextless" (x:u64) -> u64 {
    STAY4 :: u64(0x000000000fffffff)
    STAY2 :: u64(0x00003fff00003fff)
    x:=((x<<4)&(STAY4<<32))|(x&STAY4)
    x=((x<<2)&(STAY2<<16))|(x&STAY2)
    return x+(x&0x3f803f803f803f80)
}

@(private)
compact6to2_4x :: proc "contextless" (x:u64) -> u64 {
    x:=x&0xc30c3
    x=((x>>4)|x)&0xf00f
    return ((x>>8)|x)&0xff
}

@(private)
mode5_stretch :: proc "contextless" (x:u64) -> u64 {return ((x&0x7f)<<1)|((x&0x3f80)<<2)}

// Rewrites every block into the layout of its mode, the modes one after another from offsets.
@(private)
munge :: proc "contextless" (
    out,modes:[]u8,offsets:[rt.MODE_COUNT]int,src:[]u8,switch_colorspace:bool,
) {
    sizes:=rt.MODE_SIZES
    at:=offsets
    for b in 0..<len(src)/16 {
        mode:=modes[b]
        s:=src[b*16:][:16]
        o:=out[at[mode]:][:sizes[mode]]
        at[mode]+=sizes[mode]
        cs:=switch_colorspace
        switch mode {
        case 0:
            lo,hi:=get64(s),get64(s[8:])
            part:=bits(lo,1,4)
            r,g,bl:=bits(lo,5,24),bits(lo,29,24),bits(lo,53,11)|bits(hi,0,13)<<11
            if cs {decorr(&r,&g,&bl,0x888888)}
            put64(o,r|g<<24|bl<<48)
            put64(o[8:],bl>>16|part<<8|hi&~u64(0x1fff))
        case 1:
            lo,hi:=get64(s),get64(s[8:])
            part:=bits(lo,2,6)
            r,g,bl:=bits(lo,8,24),bits(lo,32,24),bits(lo,56,8)|bits(hi,0,16)<<8
            if cs {decorr(&r,&g,&bl,0x820820)}
            // RGB655 per endpoint; the low bits of G and B go to the second half.
            l:=expand6to16_4x(r)|expand6to16_4x(g&~u64(0x41041))<<5
            put64(o,l|expand6to16_4x(bl&~u64(0x41041))<<10)
            low:=compact6to2_4x((g&0x41041)|((bl&0x41041)<<1))
            put64(o[8:],low|part<<8|hi&~u64(0xffff))
        case 2:
            lo,hi:=get64(s),get64(s[8:])
            part:=bits(lo,3,6)
            r,g,bl:=bits(lo,9,30),bits(lo,39,25)|bits(hi,0,5)<<25,bits(hi,5,30)
            index:=bits(hi,35,29)
            if cs {decorr(&r,&g,&bl,0x21084210)}
            l:=expand1to16_4x(part)|expand5to16_4x(r)<<1|expand5to16_4x(g)<<6
            put64(o,l|expand5to16_4x(bl)<<11)
            h:=expand1to16_2x(part>>4)|expand5to16_2x(r>>20)<<1|expand5to16_2x(g>>20)<<6
            h|=expand5to16_2x(bl>>20)<<11|index<<35
            put64(o[8:],h)
        case 3:
            lo,hi:=get64(s),get64(s[8:])
            part:=bits(lo,4,6)
            r,g,bl:=bits(lo,10,28),bits(lo,38,26)|(hi&3)<<26,bits(hi,2,28)
            p_lo,p_hi_index:=bits(hi,30,2),bits(hi,32,32)
            if cs {decorr(&r,&g,&bl,0x8102040)}
            l:=expand1to8_8x(part|p_lo<<6)<<7
            l|=expand7to24_3x(r)|expand7to24_3x(g)<<8|expand7to24_2x(bl)<<16
            put64(o,l)
            put64(o[8:],p_hi_index<<32|expand7to24_2x(bl>>14)|(r>>21)<<8|(g>>21)<<16)
        case 4:
            lo,hi:=get64(s),get64(s[8:])
            crot:=bits(lo,5,2)
            c:=[4]u64{bits(lo,8,10),bits(lo,18,10),bits(lo,28,10),bits(lo,39,5)|bits(lo,45,5)<<5}
            k:=(crot-1)&3
            c[k],c[3]=c[3],c[k]
            if cs {decorr(&c[0],&c[1],&c[2],0x210)}
            l:=bits(lo,38,1)|bits(lo,44,1)<<1|c[0]<<2|c[1]<<12|c[2]<<22|c[3]<<32
            l|=bits(lo,7,1)<<42|crot<<48|bits(lo,50,14)<<50
            put64(o,l)
            put64(o[8:],hi)
        case 5:
            lo,hi:=get64(s),get64(s[8:])
            crot:=bits(lo,6,2)
            indices:=bits(hi,2,62)
            c:=[4]u64{
                mode5_stretch(bits(lo,8,14)),mode5_stretch(bits(lo,22,14)),
                mode5_stretch(bits(lo,36,14)),bits(lo,50,14)|bits(hi,0,2)<<14,
            }
            k:=(crot-1)&3
            c[k],c[3]=c[3],c[k]
            l:u64
            if cs {
                low:=[3]u64{c[0]&0x0101,c[1]&0x0101,c[2]&0x0101}
                c[0]&=0xfefe;c[1]&=0xfefe;c[2]&=0xfefe
                decorr2(&c[0],&c[1],&c[2],0x8080,0x7e7e)
                c[0]|=low[0];c[1]|=low[1];c[2]|=low[2]
                l=expand8to32_2x(c[0])|expand8to32_2x(c[1])<<8|expand8to32_2x(c[2])<<16
                l|=expand8to32_2x(c[3])<<24
            } else {
                l=c[0]|c[1]<<16|c[2]<<32|c[3]<<48
            }
            put64(o,l)
            put64(o[8:],crot|indices<<2)
        case 6:
            lo,hi:=get64(s),get64(s[8:])
            l:=lo&(1<<63)
            if cs {
                r,g,bl,a:=bits(lo,7,14),bits(lo,21,14),bits(lo,35,14),bits(lo,49,14)
                decorr(&r,&g,&bl,0x2040)
                l|=expand7to32_2x(r)|expand7to32_2x(g)<<8
                l|=expand7to32_2x(bl)<<16|expand7to32_2x(a)<<24
            } else {
                l|=expand7to8_8x(bits(lo,7,56))
            }
            put64(o,l)
            put64(o[8:],hi)
        case 7:
            lo,hi:=get64(s),get64(s[8:])
            part:=bits(lo,8,6)
            r,g,bl:=bits(lo,14,20),bits(lo,34,20),bits(lo,54,10)|bits(hi,0,10)<<10
            a,p,index:=bits(hi,10,20),bits(hi,30,4),bits(hi,34,30)
            l,h:u64
            if cs {
                decorr(&r,&g,&bl,0x84210)
                l=expand1to16_4x(p)|expand5to16_4x(r)<<1|expand5to16_4x(g)<<6|expand5to16_4x(bl)<<11
                h=a<<8|part<<28|index<<34
            } else {
                for i in u64(0)..<4 {
                    l|=bits(r,i*5+1,4)<<(i*4)
                    l|=bits(g,i*5+1,4)<<(i*4+16)
                    l|=bits(bl,i*5+1,4)<<(i*4+32)
                    l|=bits(a,i*5+1,4)<<(i*4+48)
                    h|=bits(r,i*5,1)<<(i+12)
                    h|=bits(g,i*5,1)<<(i+16)
                    h|=bits(bl,i*5,1)<<(i+20)
                    h|=bits(a,i*5,1)<<(i+24)
                }
                h|=p<<8|part<<28|index<<34
            }
            put64(o,l)
            put64(o[8:],h)
        case 8:
            copy(o,s)
        case 9:
            color,_:=solid_color(s)
            r,g,bl:=color[0],color[1],color[2]
            if cs {r,g,bl=g,r-g,bl-g}
            o[0],o[1],o[2],o[3]=r,g,bl,color[3]
        }
    }
}

// Appends the first split bytes of each block, then the rest of each.
@(private)
append_split :: proc "contextless" (out,src:[]u8,split:int) {
    blocks:=len(src)/16
    second:=out[blocks*split:]
    for b in 0..<blocks {
        copy(out[b*split:][:split],src[b*16:][:split])
        copy(second[b*(16-split):][:16-split],src[b*16+split:][:16-split])
    }
}

// Chooses per mode whether to split; candidate gets the payload, j its estimated cost.
@(private)
decide_splits :: proc "contextless" (
    candidate,twiddled:[]u8,counts,offsets:[rt.MODE_COUNT]int,colorspace:int,
) -> (flags:u32,j:f64) {
    sizes,splits:=rt.MODE_SIZES,rt.MODE_SPLITS
    cycles:=0.0
    for m in 0..<rt.MODE_COUNT {
        n:=counts[m]
        if n==0 {continue}
        size:=n*sizes[m]
        from:=twiddled[offsets[m]:][:size]
        to:=candidate[offsets[m]:][:size]
        if splits[m]==0 {
            cycles+=f64(DECODE_CYCLES[m][colorspace])*f64(n)
            copy(to,from)
            continue
        }
        append_split(to,from,splits[m])
        size0:=n*splits[m]
        size1:=size-size0
        ratio0:=f64(pseudolz_matches(to[:size0]))/f64(size0)
        ratio1:=f64(pseudolz_matches(to[size0:]))/f64(size1)
        entropy0:=f64(code_len(to[:size0]))/f64(size0)
        entropy1:=f64(code_len(to[size0:]))/f64(size1)
        // Split when one half has far more matches, or a far different entropy.
        if ratio1>ratio0*2 || ratio0>ratio1*2 || abs(entropy0-entropy1)>1 {
            cycles+=f64(DECODE_CYCLES[m][colorspace+2])*f64(n)
            flags|=rt.FLAG_SPLIT0<<u32(m)
        } else {
            cycles+=f64(DECODE_CYCLES[m][colorspace])*f64(n)
            copy(to,from)
        }
    }
    return flags,f64(rate_estimate(candidate))+f64(LAMBDA)*cycles
}

// Bytes an LZ would take: order-0 entropy of the bytes not covered by matches.
@(private)
rate_estimate :: proc "contextless" (bytes:[]u8) -> int {
    bpb:=f64(code_len(bytes))/f64(len(bytes))
    expected_bits:=f64(len(bytes)-pseudolz_matches(bytes))*bpb
    return int(math.ceil(expected_bits/8))
}

// Positions whose next 4 bytes hash like an earlier position in a small table: a rough count of
// the bytes an LZ would match.
@(private)
pseudolz_matches :: proc "contextless" (bytes:[]u8) -> (matches:int) #no_bounds_check {
    HASH_BITS :: 13
    table:[1<<HASH_BITS]u8
    p:=raw_data(bytes)
    for i:=0;i<len(bytes)-7;i+=4 {
        // Four positions are looked up before any of them is stored.
        index:[4]u32
        id:[4]u8
        #unroll for k in 0..<4 {
            h:=u32(intrinsics.unaligned_load((^u32le)(p[i+k:])))*0x9E3779B1
            index[k],id[k]=h>>(32-HASH_BITS),u8(h>>(24-HASH_BITS))
            matches+=int(table[index[k]]==id[k])
        }
        #unroll for k in 0..<4 {table[index[k]]=id[k]}
    }
    return
}

// Order-0 entropy of bytes, in bits.
@(private)
code_len :: proc "contextless" (bytes:[]u8) -> u64 {
    histogram:[256]u32
    for b in bytes {histogram[b]+=1}
    total:=u32(len(bytes))
    if total==0 {return 0}
    inv:=u32(1<<30)/total
    sum:u64
    for c in histogram {
        if c>0 {sum+=u64(c)*u64(entropy.log2tabled_bk(c*inv,30))}
    }
    return sum>>entropy.LOG2TABLE_ONE_SHIFT
}
