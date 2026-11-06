package bc4

import "core:math/rand"
import "core:testing"
import "mirai:cook/compressor/texture/common"

@(private="file")
SOURCES :: [3]Source{.R16,.RG16,.RGBA8_Alpha}

// Runs of extremes as well as noise.
@(private="file")
random_bytes :: proc(b:[]u8,r:rand.Generator) {
    for &x in b {
        v:=rand.uint32(r)
        switch v&3 {
        case 0: x=0
        case 1: x=255
        case: x=u8(v>>8)
        }
    }
}

@(test)
hostile_blocks_never_crash :: proc(t:^testing.T) {
    state:=rand.create(7)
    r:=rand.default_random_generator(&state)
    N :: 40
    for source in SOURCES {
        sb:=source_bytes(source)
        ob:=block_bytes(source)
        from:=make([]u8,N*sb)
        defer delete(from)
        random_bytes(from,r)
        stride:=ob+8
        to:=make([]u8,N*stride)
        defer delete(to)
        baseline:=make([]u8,N*stride)
        defer delete(baseline)
        random_bytes(baseline,r)
        activity:=make([]common.Float_Block,N)
        defer delete(activity)
        for &a,i in activity {
            for &v,k in a {v=f32(i*k%7)}
            if i==3 {a[0]=max(f32)}
        }
        for level in common.Level {
            if level==.Reference {continue}
            for options in ([2]common.Options{{},{.BC3457_Preserve_Extremes}}) {
                testing.expect_value(t,compress(to,stride,8,from,source,level,options),
                    common.Error.None)
                testing.expect_value(t,rd(to,stride,8,from,source,baseline,activity,1000,options,
                    {effort=level}),common.Error.None)
            }
        }
        E :: common.Error
        testing.expect_value(t,compress(to,stride,0,from[:sb],source,.Reference,{}),E.None)
        testing.expect_value(t,compress(to,stride,0,from[:sb+1],source,.Slow,{}),E.Invalid)
        testing.expect_value(t,compress(to[:stride],stride,0,from,source,.Slow,{}),E.Invalid)
        testing.expect_value(t,compress(to,ob-1,0,from,source,.Slow,{}),E.Invalid)
        testing.expect_value(t,rd(to,stride,0,from,source,baseline,activity[:1],10,{},{}),E.Invalid)
        testing.expect_value(t,rd(to,stride,0,from,source,baseline[:8],activity,10,{},{}),E.Invalid)
        testing.expect_value(t,rd(to,stride,0,from,source,baseline,activity,10,{},
            {effort=common.Level(9)}),E.Invalid)
    }
}

@(test)
encodes_are_deterministic :: proc(t:^testing.T) {
    state:=rand.create(11)
    r:=rand.default_random_generator(&state)
    N :: 300
    for source in SOURCES {
        sb:=source_bytes(source)
        ob:=block_bytes(source)
        from:=make([]u8,N*sb)
        defer delete(from)
        // Gradients with a little noise, so blocks share indices.
        for i in 0..<len(from) {from[i]=u8((i/sb)%32*8+int(rand.uint32(r)&3))}
        activity:=make([]common.Float_Block,N)
        defer delete(activity)
        for &a in activity {for &v in a {v=1}}
        baseline:=make([]u8,N*ob)
        defer delete(baseline)
        compress(baseline,ob,0,from,source,.Very_Slow,{})
        outs:[2][]u8
        for &o in outs {
            o=make([]u8,N*ob)
            testing.expect_value(t,rd(o,ob,0,from,source,baseline,activity,40,{},{effort=.Slow}),
                common.Error.None)
        }
        defer for o in outs {delete(o)}
        testing.expect(t,string(outs[0])==string(outs[1]))
        again:=make([]u8,N*ob)
        defer delete(again)
        compress(again,ob,0,from,source,.Very_Slow,{})
        testing.expect(t,string(again)==string(baseline))
    }
}

@(test)
flat_blocks_decode_close :: proc(t:^testing.T) {
    for v in 0..<256 {
        values:Source_Data
        values.type=.UNorm
        for &x in values.values {x=convert_u16(unorm8_to_unorm16(u8(v)))}
        bits,_:=compress_block(&values,.Slow,{})
        for d in decode_u16(bits) {testing.expect(t,abs(int(d)-v*257)<=257)}
        values.type=.Alpha
        for &x in values.values {x=i16(v)}
        bits,_=compress_block(&values,.Slow,{})
        for d in decode_alpha(bits) {testing.expect_value(t,int(d),v)}
    }
}
