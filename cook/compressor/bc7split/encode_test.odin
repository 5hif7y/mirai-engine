package bc7split_encode

import "core:math/rand"
import "core:testing"
import "mirai:asset"
import rt "mirai:std/compressor/bc7split"

// The last levels of a demo texture and its stream from the reference encoder: header then payload.
@(private="file") FIXTURE_BLOCKS :: #load("../../../std/compressor/bc7split/testdata/vase_tail.bc7")
@(private="file") FIXTURE_STREAM :: #load("../../../std/compressor/bc7split/testdata/vase_tail.bc7split")

@(test)
encode_matches_the_library :: proc(t:^testing.T) {
    src:=FIXTURE_BLOCKS
    blocks:=len(src)/16
    dst:=make([]u8,min_output_size(blocks));defer delete(dst)
    scratch:=make([]u8,min_scratch_size(blocks));defer delete(scratch)
    header:rt.Header
    written,err:=encode(&header,dst,src,scratch)
    testing.expect_value(t,err,Error.None)
    want:=FIXTURE_STREAM
    testing.expect(t,header==(^rt.Header)(raw_data(want))^)
    testing.expect(t,string(dst[:written])==string(want[size_of(rt.Header):]))
}

// Blocks of every mode with random fields, solid blocks in runs and blocks of no mode, more than
// a chunk and an odd count.
@(private="file")
synthetic_blocks :: proc(blocks:int) -> []u8 {
    out:=make([]u8,blocks*16)
    state:=rand.create(11)
    gen:=rand.default_random_generator(&state)
    for b in 0..<blocks {
        block:=out[b*16:][:16]
        for &v in block {v=u8(rand.uint32(gen))}
        switch kind:=b%23; kind {
        case 0..=7: block[0]=block[0]&~u8((2<<uint(kind))-1)|1<<uint(kind)
        case 8: for &v in block {v=0}
        case 9..=11:
            // A solid mode 6 block: equal endpoints, indices whatever.
            lo:=u64(0x40)|u64(b/50)<<7|u64(b/50)<<14|u64(0x55)<<21|u64(0x55)<<28
            lo|=u64(0x2a)<<35|u64(0x2a)<<42|u64(0x7f)<<49|u64(0x7f)<<56
            for i in 0..<8 {block[i]=u8(lo>>(8*uint(i)))}
            for i in 8..<16 {block[i]=0}
        case:
            block[0]=block[0]&~u8(0x7f)|0x40
        }
    }
    return out
}

@(test)
every_layout_round_trips :: proc(t:^testing.T) {
    blocks:=2*rt.CHUNK_BLOCKS+77
    src:=synthetic_blocks(blocks);defer delete(src)
    dst:=make([]u8,min_output_size(blocks));defer delete(dst)
    scratch:=make([]u8,min_scratch_size(blocks));defer delete(scratch)
    decoded:=make([]u8,blocks*16);defer delete(decoded)
    d:=new(rt.Decoder);defer free(d)

    // What the encoder chose, then each color space with every mode split and with none.
    header:rt.Header
    written,err:=encode(&header,dst,src,scratch)
    testing.expect_value(t,err,Error.None)
    expect_restored(t,d,header,dst[:written],src,decoded)
    for variant in 0..<4 {
        cs,split:=variant&1!=0,variant&2!=0
        h:=rt.Header{version=rt.HEADER_VERSION,flags=rt.FLAG_SWITCH_COLORSPACE if cs else 0}
        modes:=scratch[:(blocks+1)&~1]
        counts:=choose_modes(modes,src)
        sizes,splits:=rt.MODE_SIZES,rt.MODE_SPLITS
        offsets:[rt.MODE_COUNT]int
        size:=0
        for m in 0..<rt.MODE_COUNT {
            offsets[m]=size
            size+=counts[m]*sizes[m]
            h.mode_counts[m]=u32(counts[m])
            testing.expectf(t,m==8 || counts[m]>0,"no block of mode %d",m)
        }
        twiddled:=scratch[(blocks+15)&~15:][:size]
        munge(twiddled,modes,offsets,src,cs)
        for m in 0..<rt.MODE_COUNT {
            size_m:=counts[m]*sizes[m]
            from,to:=twiddled[offsets[m]:][:size_m],dst[offsets[m]:][:size_m]
            if split && splits[m]>0 {
                append_split(to,from,splits[m])
                h.flags|=rt.FLAG_SPLIT0<<u32(m)
            } else {
                copy(to,from)
            }
        }
        for i:=0;i<blocks;i+=2 {dst[size+i/2]=modes[i]|modes[i+1]<<4}
        expect_restored(t,d,h,dst[:size+(blocks+1)/2],src,decoded)
    }
}

// Every block comes back with its bits, except solid ones, which come back with their pixels.
@(private="file")
expect_restored :: proc(t:^testing.T,d:^rt.Decoder,header:rt.Header,stream,src,decoded:[]u8) {
    n,err:=rt.decode(d,header,stream,decoded)
    testing.expect_value(t,err,rt.Error.None)
    testing.expect_value(t,n,len(src))
    for b in 0..<len(src)/16 {
        x,y:=src[b*16:][:16],decoded[b*16:][:16]
        if string(x)==string(y) {continue}
        px:=asset.texture_bc7_block_decode(([^][16]u8)(raw_data(x))[0])
        py:=asset.texture_bc7_block_decode(([^][16]u8)(raw_data(y))[0])
        if px!=py {
            testing.fail_now(t,"a block changed its pixels")
        }
        _,solid:=solid_color(x)
        testing.expect(t,solid)
    }
}

@(test)
encode_rejects_bad_buffers :: proc(t:^testing.T) {
    src:=make([]u8,64);defer delete(src)
    dst:=make([]u8,min_output_size(4));defer delete(dst)
    scratch:=make([]u8,min_scratch_size(4));defer delete(scratch)
    header:rt.Header
    Case :: struct {name:string,src,dst,scratch:[]u8,want:Error}
    cases:=[?]Case{
        {"partial block",src[:63],dst,scratch,.Not_Blocks},
        {"short output",src,dst[:len(dst)-1],scratch,.Output_Too_Small},
        {"short scratch",src,dst,scratch[:len(scratch)-1],.Scratch_Too_Small},
    }
    for c in cases {
        written,err:=encode(&header,c.dst,c.src,c.scratch)
        testing.expectf(t,err==c.want && written==0,"%s: %v",c.name,err)
    }
    written,err:=encode(nil,dst,src,scratch)
    testing.expect_value(t,err,Error.Missing_Header)
    written,err=encode(&header,nil,nil,nil)
    testing.expect(t,err==.None && written==0)
    blocks,_,herr:=rt.header_read(header)
    testing.expect(t,herr==.None && blocks==0)
}
