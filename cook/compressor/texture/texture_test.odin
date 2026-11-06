package texture

import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:cook/compressor/texture/bc7"
import "mirai:cook/compressor/texture/common"
import "mirai:std/jobs"

@(private="file")
W :: 67
@(private="file")
H :: 45

// Gradients, a hard edge and some noise, with partial blocks at the right and bottom.
@(private="file")
test_image :: proc(w,h:int) -> []u8 {
    p:=make([]u8,w*h*4)
    seed:=u32(12345)
    for y in 0..<h {
        for x in 0..<w {
            seed=seed*1664525+1013904223
            noise:=int(seed>>28)
            i:=(y*w+x)*4
            p[i+0]=u8(clamp(x*255/w+noise,0,255))
            p[i+1]=u8(clamp(y*255/h-noise,0,255))
            p[i+2]=200 if x>w/2 else 40
            p[i+3]=u8(255 if y<h/2 else clamp((x+y)*3,0,255))
        }
    }
    return p
}

@(private="file")
hdr_image :: proc(w,h:int) -> []u8 {
    p:=make([]u8,w*h*8)
    texels:=([^][4]f16)(raw_data(p))[:w*h]
    for y in 0..<h {
        for x in 0..<w {
            texels[y*w+x]={f16(f32(x)/f32(w)*6),f16(f32(y)/f32(h)),f16(0.25 if x<w/3 else 3),1}
        }
    }
    return p
}

// Root mean square error, in 8-bit steps, of the channels a format keeps.
@(private="file")
rmse :: proc(format:Format,blocks,src:[]u8,w,h:int) -> f64 {
    out:=make([]u8,w*h*4)
    defer delete(out)
    nbx:=(w+3)/4
    channels:=4
    switch format {
    case .BC1: _=asset.texture_level_rgba8(.BC1,blocks,w,h,out);channels=3
    case .BC5: _=asset.texture_level_rgba8(.BC5,blocks,w,h,out);channels=2
    case .BC7: _=asset.texture_level_rgba8(.BC7,blocks,w,h,out)
    case .BC4,.BC3,.BC6H:
        for y in 0..<h {for x in 0..<w {
            b:=(y/4)*nbx+x/4
            t:=(y%4)*4+x%4
            o:=out[(y*w+x)*4:]
            if format==.BC4 {
                o[0]=u8(asset.texture_bc4_block_decode((^[8]u8)(&blocks[b*8])^)[t]*255+0.5)
                channels=1
            } else if format==.BC3 {
                colors:common.Color_Block
                common.bc1_decompress(&colors,common.bc1_get_block(blocks[b*16+8:]),.Four_Color)
                o[0],o[1],o[2]=colors[t][2],colors[t][1],colors[t][0]
                o[3]=u8(asset.texture_bc4_block_decode((^[8]u8)(&blocks[b*16])^)[t]*255+0.5)
            }
        }}
    }
    sum:f64
    for i in 0..<w*h {for c in 0..<channels {
        d:=f64(out[i*4+c])-f64(src[i*4+c])
        sum+=d*d
    }}
    return math.sqrt(sum/f64(w*h*channels))
}

@(private="file")
encoded :: proc(t:^testing.T,format:Format,src:Surface,options:Options,
    worker:=jobs.Worker_Ref{}) -> []u8 {
    dst:=make([]u8,encoded_size(format,src.width,src.height))
    testing.expect_value(t,encode(format,src,options,dst,worker=worker),Error.None)
    return dst
}

@(test)
blocks_decode_within_a_bound_of_the_source_and_rdo_costs_little :: proc(t:^testing.T) {
    src:=test_image(W,H)
    defer delete(src)
    s:=Surface{pixels=src,width=W,height=H}
    // RMSE bounds at lambda 0 and 30: what each format keeps of this image.
    Case :: struct {format:Format,exact,rdo:f64}
    cases:=[?]Case{{.BC1,6,9},{.BC3,6,9},{.BC4,3,6},{.BC5,3,6},{.BC7,3,7}}
    for c in cases {
        base:=encoded(t,c.format,s,{})
        rdo:=encoded(t,c.format,s,{lambda=30})
        e0,e30:=rmse(c.format,base,src,W,H),rmse(c.format,rdo,src,W,H)
        testing.expectf(t,e0<c.exact,"%v lambda 0: rmse %v",c.format,e0)
        testing.expectf(t,e30<c.rdo && e30>=e0*0.9,"%v lambda 30: rmse %v (lambda 0 %v)",c.format,
            e30,e0)
        delete(base);delete(rdo)
    }
    hdr:=hdr_image(W,H)
    defer delete(hdr)
    hs:=Surface{pixels=hdr,width=W,height=H,format=.RGBA16F}
    for lambda in ([?]int{0,30}) {
        blocks:=encoded(t,.BC6H,hs,{lambda=lambda})
        defer delete(blocks)
        texels:=([^][4]f16)(raw_data(hdr))[:W*H]
        worst,sum:f32
        for b in 0..<len(blocks)/16 {
            decoded:=asset.texture_bc6h_block_decode((^[16]u8)(&blocks[b*16])^)
            bx,by:=b%((W+3)/4),b/((W+3)/4)
            for y in 0..<4 {for x in 0..<4 {
                px,py:=min(bx*4+x,W-1),min(by*4+y,H-1)
                for c in 0..<3 {
                    want:=f32(texels[py*W+px][c])
                    got:=f32(transmute(f16)decoded[y*4+x][c])
                    rel:=abs(got-want)/max(want,0.25)
                    worst=max(worst,rel)
                    sum+=rel
                }
            }}
        }
        mean:=sum/f32(len(blocks)/16*48)
        testing.expectf(t,worst<0.5 && mean<0.03,"BC6H lambda %v: relative error %v worst %v",
            lambda,mean,worst)
    }
}

@(test)
lambda_0_and_tiny_levels_take_the_non_rdo_path :: proc(t:^testing.T) {
    src:=test_image(W,H)
    defer delete(src)
    s:=Surface{pixels=src,width=W,height=H}
    blocks:=encoded(t,.BC7,s,{})
    defer delete(blocks)
    from:=make([]common.Color_Block,len(blocks)/16)
    defer delete(from)
    nbx:=(W+3)/4
    for &b,i in from {for y in 0..<4 {for x in 0..<4 {
        px,py:=min((i%nbx)*4+x,W-1),min((i/nbx)*4+y,H-1)
        b[y*4+x]=(^[4]u8)(&src[(py*W+px)*4])^
    }}}
    direct:=make([]u8,len(blocks))
    defer delete(direct)
    testing.expect_value(t,bc7.compress(direct,from,.Slow,{}),common.Error.None)
    testing.expect(t,string(direct)==string(blocks))
    // Fewer than 16 blocks: no RDO, whatever the lambda.
    small:=Surface{pixels=src,width=12,height=12,stride=W*4}
    for f in Format {
        if f==.BC6H {continue}
        a:=encoded(t,f,small,{})
        b:=encoded(t,f,small,{lambda=50})
        testing.expectf(t,string(a)==string(b),"%v",f)
        delete(a);delete(b)
    }
}

@(test)
threads_write_the_same_blocks :: proc(t:^testing.T) {
    src:=test_image(300,260)
    defer delete(src)
    s:=Surface{pixels=src,width=300,height=260}
    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    for f in ([?]Format{.BC1,.BC3,.BC7}) {
        a:=encoded(t,f,s,{lambda=30})
        b:=encoded(t,f,s,{lambda=30},jobs.Worker_Ref{system=&js})
        testing.expectf(t,string(a)==string(b),"%v",f)
        delete(a);delete(b)
    }
}

@(test)
invalid_inputs_return_errors :: proc(t:^testing.T) {
    px:=make([]u8,64*64*16)
    defer delete(px)
    dst:=make([]u8,encoded_size(.BC7,64,64))
    defer delete(dst)
    Case :: struct {format:Format,src:Surface,options:Options,dst:[]u8,want:Error}
    cases:=[?]Case{
        {.BC7,{pixels=px,width=0,height=4},{},dst,.Invalid_Size},
        {.BC7,{pixels=px,width=4,height=-1},{},dst,.Invalid_Size},
        {.BC7,{pixels=px,width=MAX_SIDE+1,height=4},{},dst,.Invalid_Size},
        {.BC7,{pixels=px[:100],width=64,height=64},{},dst,.Invalid_Pixels},
        {.BC7,{pixels=px,width=64,height=4,stride=3},{},dst,.Invalid_Pixels},
        {.BC7,{pixels=px,width=64,height=64},{},dst[:10],.Buffer_Too_Small},
        {.BC7,{pixels=px,width=64,height=64,format=.RGBA16F},{},dst,.Invalid_Format},
        {.BC6H,{pixels=px,width=64,height=64},{},dst,.Invalid_Format},
        {.BC1,{pixels=px,width=64,height=64},{lambda=-1},dst,.Invalid_Lambda},
        {.BC3,{pixels=px,width=64,height=64},{bc3_alpha_lambda=-5},dst,.Invalid_Lambda},
    }
    for c in cases {
        testing.expectf(t,encode(c.format,c.src,c.options,c.dst)==c.want,"%v",c)
    }
    // NaN and infinities in a BC6H source.
    halfs:=([^]u16)(raw_data(px))[:64*64*4]
    for bad in ([?]u16{0x7e00,0x7c00,0xfc00}) {
        halfs[17*4+1]=bad
        testing.expect_value(t,encode(.BC6H,{pixels=px,width=64,height=64,format=.RGBA16F},{},dst),
            Error.Non_Finite)
    }
    floats:=([^]f32)(raw_data(px))[:64*64*4]
    floats[5]=math.inf_f32(1)
    testing.expect_value(t,encode(.BC6H,{pixels=px,width=64,height=64,format=.RGBA32F},{lambda=30},
        dst),Error.Non_Finite)
}

@(test)
odd_sizes_and_random_texels_encode :: proc(t:^testing.T) {
    px:=make([]u8,70*70*8)
    defer delete(px)
    seed:=u32(7)
    for &b in px {seed=seed*1103515245+12345;b=u8(seed>>23)}
    // Random halfs include NaN and infinity: keep them finite, any sign.
    halfs:=([^]u16)(raw_data(px))[:70*70*4]
    for &h in halfs {if h&0x7c00==0x7c00 {h&=0xbfff}}
    sizes:=[?][2]int{{1,1},{3,5},{17,9},{70,1},{1,70},{70,70}}
    for f in Format {
        for size in sizes {
            for lambda in ([?]int{0,40}) {for metric in Metric {
                s:=Surface{pixels=px,width=size.x,height=size.y,
                    format=.RGBA16F if f==.BC6H else .RGBA8}
                dst:=make([]u8,encoded_size(f,size.x,size.y))
                err:=encode(f,s,{lambda=lambda,metric=metric},dst)
                testing.expectf(t,err==.None,"%v %v %v",f,size,err)
                delete(dst)
            }}
        }
    }
}
