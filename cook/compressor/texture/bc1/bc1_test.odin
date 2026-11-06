package bc1

import "core:math/rand"
import "core:testing"
import "mirai:cook/compressor/texture/common"

@(private="file")
test_blocks :: proc(n:int,seed:u64) -> []Color_Block {
    r:=rand.create(seed)
    gen:=rand.default_random_generator(&r)
    out:=make([]Color_Block,n)
    for i in 0..<n {
        kind:=i%6
        base:=Color{u8(rand.uint32(gen)),u8(rand.uint32(gen)),u8(rand.uint32(gen)),255}
        for t in 0..<16 {
            switch kind {
            case 0: out[i][t]={}
            case 1: out[i][t]={255,255,255,255}
            case 2: out[i][t]=base
            case 3: out[i][t]=t%3==0?Color{}:base
            case 4: out[i][t]={base[0]+u8(t),base[1],base[2]-u8(t),u8(rand.uint32(gen))}
            case: out[i][t]={u8(rand.uint32(gen)),u8(rand.uint32(gen)),u8(rand.uint32(gen)),
                u8(rand.uint32(gen))}
            }
        }
    }
    return out
}

@(test)
compress_keeps_modes_on_any_block :: proc(t:^testing.T) {
    blocks:=test_blocks(120,1)
    defer delete(blocks)
    out:=make([]u8,len(blocks)*16)
    defer delete(out)
    for level in common.Level {
        testing.expect_value(t,compress(out,8,0,blocks,level,{.BC1_One_Bit_Alpha},false),
            common.Error.None)
        for b,i in blocks {
            colors:=b
            canonicalize_colors(&colors,{.BC1_One_Bit_Alpha},false)
            blk:=common.bc1_get_block(out[i*8:])
            testing.expect(t,common.bc1_one_bit_transparent_same(&colors,blk.endpoints,blk.indices))
            if i%6==2 {
                // a solid color decodes within one quantization step
                testing.expect(t,common.bc1_compute_ssd_rgba(&colors,blk,.Alpha)<=16*3*8*8)
            }
        }
        testing.expect_value(t,compress(out,16,8,blocks,level,{},true),common.Error.None)
        for i in 0..<len(blocks) {
            testing.expect(t,
                common.bc1_is_bc3_canonical(common.bc1_get_block(out[i*16+8:]).endpoints))
        }
    }
    testing.expect_value(t,compress(out,8,4,blocks,.Slow,{},false),common.Error.Invalid)
    testing.expect_value(t,compress(out[:10],8,0,blocks,.Slow,{},false),common.Error.Invalid)
}

@(test)
rd_is_deterministic_and_keeps_transparency :: proc(t:^testing.T) {
    blocks:=test_blocks(600,2)
    defer delete(blocks)
    n:=len(blocks)
    activity:=make([]common.Float_Block,n)
    defer delete(activity)
    for i in 0..<n {for k in 0..<16 {activity[i][k]=f32(1+(i*7+k)%40)}}
    bgra:=make([]Color_Block,n)
    defer delete(bgra)
    for b,i in blocks {
        bgra[i]=b
        common.swap_rb(&bgra[i])
    }
    for case_i in 0..<3 {
        stride:=case_i==2?16:8
        offset:=case_i==2?8:0
        options:common.Options=case_i==1?{.BC1_One_Bit_Alpha}:{}
        base:=make([]u8,n*stride)
        defer delete(base)
        a:=make([]u8,n*stride)
        defer delete(a)
        b:=make([]u8,n*stride)
        defer delete(b)
        testing.expect_value(t,compress(base,stride,offset,bgra,.Very_Slow,options,stride==16),
            common.Error.None)
        for lambda in ([]int{0,10,40,10000}) {
            testing.expect_value(t,rd(a,stride,offset,blocks,base,activity,lambda,options,
                {effort=.Slow}),common.Error.None)
            testing.expect_value(t,rd(b,stride,offset,blocks,base,activity,lambda,options,
                {effort=.Slow}),common.Error.None)
            testing.expect(t,string(a)==string(b))
            if case_i==1 {
                for i in 0..<n {
                    colors:=bgra[i]
                    canonicalize_colors(&colors,options,false)
                    blk:=common.bc1_get_block(a[i*8:])
                    testing.expect(t,common.bc1_one_bit_transparent_same(&colors,blk.endpoints,
                        blk.indices))
                }
            }
        }
    }
    out:=make([]u8,n*8)
    defer delete(out)
    testing.expect_value(t,rd(out,8,0,blocks,out[:8],activity,10,{},{}),common.Error.Invalid)
    testing.expect_value(t,rd(out,8,0,blocks,out,activity[:1],10,{},{}),common.Error.Invalid)
    testing.expect_value(t,rd(out,8,0,blocks,out,activity,-1,{},{}),common.Error.Invalid)
}
