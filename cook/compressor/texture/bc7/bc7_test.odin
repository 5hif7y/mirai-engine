package bc7

import "core:testing"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"

@(private="file")
lcg :: proc(s:^u32) -> u8 {
    s^=s^*1664525+1013904223
    return u8(s^>>24)
}

// Solid, transparent, extreme, noisy and smooth blocks.
@(private="file")
hostile_blocks :: proc() -> [dynamic]common.Color_Block {
    blocks:[dynamic]common.Color_Block
    for c in ([]common.Color{{0,0,0,255},{255,255,255,255},{0,0,0,0},{255,255,255,0},{17,130,201,
        77}}) {
        b:common.Color_Block
        for i in 0..<16 {b[i]=c}
        append(&blocks,b)
    }
    {
        b:common.Color_Block
        for i in 0..<16 {b[i]=(i&1)==0 ? common.Color{0,255,0,0} : common.Color{255,0,255,255}}
        append(&blocks,b)
    }
    seed:=u32(12345)
    for _ in 0..<6 {
        b:common.Color_Block
        for i in 0..<16 {b[i]={lcg(&seed),lcg(&seed),lcg(&seed),lcg(&seed)}}
        append(&blocks,b)
    }
    {
        b:common.Color_Block
        for i in 0..<16 {
            k:=u8(i)
            b[i]={40+k*8,60+k*6,200-k*5,255}
        }
        append(&blocks,b)
    }
    return blocks
}

@(private="file")
decode :: proc(block:[]u8) -> (out:common.Color_Block) {
    return transmute(common.Color_Block)asset.texture_bc7_block_decode((^[16]u8)(raw_data(block))^)
}

@(test)
compress_hostile_blocks_decode_within_bounds :: proc(t:^testing.T) {
    blocks:=hostile_blocks()
    defer delete(blocks)
    out:=make([]u8,len(blocks)*16)
    defer delete(out)
    option_sets:=[]common.Options{{},{.BC7_Ignore_Alpha},{.BC3457_Preserve_Extremes}}
    for level in ([]common.Level{.Very_Fast,.Fast,.Slow,.Very_Slow}) {
        for options in option_sets {
            testing.expect_value(t,compress(out,blocks[:],level,options),common.Error.None)
            for bi in 0..<len(blocks) {
                testing.expect(t,out[bi*16]!=0)
                dec:=decode(out[bi*16:])
                src:=blocks[bi]
                if bi<5 {
                    for i in 0..<16 {
                        for c in 0..<3 {testing.expect_value(t,dec[i][c],src[i][c])}
                        if .BC7_Ignore_Alpha not_in options {testing.expect_value(t,dec[i][3],
                            src[i][3])}
                    }
                }
                if bi==len(blocks)-1 {
                    for i in 0..<16 {
                        for c in 0..<4 {testing.expect(t,abs(int(dec[i][c])-int(src[i][c]))<=6)}
                    }
                }
                if .BC3457_Preserve_Extremes in options {
                    for i in 0..<16 {
                        if src[i][3]==0 || src[i][3]==255 {testing.expect_value(t,dec[i][3],
                            src[i][3])}
                    }
                }
            }
        }
    }
    testing.expect_value(t,compress(out[:15],blocks[:1],.Slow,{}),common.Error.Invalid)
}

@(test)
compress_and_rd_are_deterministic_and_valid :: proc(t:^testing.T) {
    hb:=hostile_blocks()
    defer delete(hb)
    blocks:=make([]common.Color_Block,64)
    defer delete(blocks)
    for i in 0..<len(blocks) {blocks[i]=hb[(i*7)%len(hb)]}
    baseline:=make([]u8,len(blocks)*16)
    defer delete(baseline)
    testing.expect_value(t,compress(baseline,blocks,.Slow,{}),common.Error.None)
    again:=make([]u8,len(blocks)*16)
    defer delete(again)
    compress(again,blocks,.Slow,{})
    testing.expect(t,string(baseline)==string(again))
    activity:=make([]common.Float_Block,len(blocks))
    defer delete(activity)
    for &a in activity {for &v in a {v=1}}
    a:=make([]u8,len(blocks)*16)
    defer delete(a)
    b:=make([]u8,len(blocks)*16)
    defer delete(b)
    for lambda in ([]int{0,10,50}) {
        testing.expect_value(t,rd(a,blocks,baseline,activity,lambda,{},{effort=.Slow}),
            common.Error.None)
        testing.expect_value(t,rd(b,blocks,baseline,activity,lambda,{},{effort=.Slow}),
            common.Error.None)
        testing.expect(t,string(a)==string(b))
        for bi in 0..<len(blocks) {
            desc:bc67.Block_Raw_Desc
            testing.expect(t,bc67.bc7_analyze_block_raw(&desc,(^[16]u8)(&a[bi*16])))
        }
    }
    // a slice of one block and hostile activity
    for &x in activity[:1] {for &v in x {v=-1e30}}
    testing.expect_value(t,rd(a[:16],blocks[:1],baseline[:16],activity[:1],30,{},
        {effort=.Very_Slow}),
        common.Error.None)
    testing.expect_value(t,rd(a[:16],blocks[:2],baseline[:32],activity[:2],30,{},{}),
        common.Error.Invalid)
    zero:=make([]u8,16)
    defer delete(zero)
    testing.expect_value(t,rd(a[:16],blocks[:1],zero,activity[:1],30,{},{}),common.Error.Invalid)
}
