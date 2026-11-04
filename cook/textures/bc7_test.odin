package textures

import "core:math"
import "core:testing"
import "mirai:asset"
import "mirai:std/jobs"

// A value of bits widened to 8, as BC7 decoders do.
@(private="file")
widen :: proc(v,bits:u32) -> u32 {
    x:=v<<(8-bits)
    return x|x>>bits
}

// The search the tables come from: every pair of endpoints, lower first,
// keeping the first best.
@(private="file")
search :: proc(c,levels,bits,lo_p,hi_p:u32,pbits:bool,weight:u32) -> (best:Bc7_Endpoints) {
    best.error=max(u16)
    for l in 0..<levels {
        lo:=widen(l<<1|lo_p if pbits else l,bits)
        for h in 0..<levels {
            hi:=widen(h<<1|hi_p if pbits else h,bits)
            k:=i32(asset.bc7_interpolate(lo,hi,weight))
            if e:=u16((k-i32(c))*(k-i32(c)));e<best.error {best={u8(l),u8(h),e}}
        }
    }
    return
}

@(test)
bc7_single_color_tables_match_their_search :: proc(t:^testing.T) {
    w2,w3,w4:=asset.BC7_WEIGHTS_2,asset.BC7_WEIGHTS_3,asset.BC7_WEIGHTS_4
    mismatches:=0
    for c in u32(0)..<256 {
        for hp in u32(0)..<2 {
            for lp in u32(0)..<2 {
                if BC7_ONE_COLOR_0[c][hp][lp]!=search(c,16,5,lp,hp,true,w3[2]) {mismatches+=1}
                if BC7_ONE_COLOR_6[c][hp][lp]!=search(c,128,8,lp,hp,true,w4[5]) {mismatches+=1}
                if BC7_ONE_COLOR_7[c][hp][lp]!=search(c,32,6,lp,hp,true,w2[1]) {mismatches+=1}
            }
            if BC7_ONE_COLOR_1[c][hp]!=search(c,64,7,hp,hp,true,w3[2]) {mismatches+=1}
        }
        if BC7_ONE_COLOR_4_3[c]!=search(c,32,5,0,0,false,w3[2]) {mismatches+=1}
        if BC7_ONE_COLOR_4_2[c]!=search(c,32,5,0,0,false,w2[1]) {mismatches+=1}
        if BC7_ONE_COLOR_5[c]!=search(c,128,7,0,0,false,w2[1]) {mismatches+=1}
    }
    testing.expect_value(t,mismatches,0)
}

// Bits of a hand made block, from the lowest.
@(private="file")
Bits :: struct {value:u128,at:u32}

@(private="file")
put :: proc(b:^Bits,value,count:u32) {
    b.value|=u128(value)<<b.at
    b.at+=count
}

@(test)
bc7_blocks_decode_by_the_specification :: proc(t:^testing.T) {
    // A block of no mode is transparent black.
    for texel in asset.texture_bc7_block_decode({}) {testing.expect_value(t,texel,[4]u8{})}
    // Mode 6: 7-bit endpoints with a p-bit each (0 and 1), the texel i at
    // index i (that of the anchor, 0, in 3 bits).
    b:Bits
    put(&b,1<<6,7)
    for v in ([]u32{0,127,32,32,100,100,127,127}) {put(&b,v,7)}
    put(&b,0,1)
    put(&b,1,1)
    for i in u32(0)..<16 {put(&b,i,3 if i==0 else 4)}
    testing.expect_value(t,b.at,128)
    texels:=asset.texture_bc7_block_decode(transmute([16]u8)b.value)
    e0,e1:=[4]u32{0,64,200,254},[4]u32{255,65,201,255}
    for texel,i in texels {
        expected:[4]u8
        for c in 0..<4 {expected[c]=u8(asset.bc7_interpolate(e0[c],e1[c],asset.BC7_WEIGHTS_4[i]))}
        testing.expectf(t,texel==expected,"texel %d decodes to %v, not %v",i,texel,expected)
    }
    // Mode 5 with rotation 1: what the block keeps as alpha is red, and red
    // the alpha. Color endpoints 7 bits, alpha 8, two bits of index each.
    b={}
    put(&b,1<<5,6)
    put(&b,1,2)
    for v in ([]u32{0,127,10,10,20,20}) {put(&b,v,7)}
    put(&b,40,8)
    put(&b,240,8)
    for i in u32(0)..<16 {put(&b,i&1,1 if i==0 else 2)}
    for i in u32(0)..<16 {put(&b,(i>>1)&1,1 if i==0 else 2)}
    testing.expect_value(t,b.at,128)
    texels=asset.texture_bc7_block_decode(transmute([16]u8)b.value)
    for texel,i in texels {
        stored_red:=u8(asset.bc7_interpolate(0,255,asset.BC7_WEIGHTS_2[i&1]))
        stored_alpha:=u8(asset.bc7_interpolate(40,240,asset.BC7_WEIGHTS_2[(i>>1)&1]))
        testing.expectf(t,texel==[4]u8{stored_alpha,20,40,stored_red},"rotated texel %d decodes to %v",i,texel)
    }
}

@(private="file")
Random :: struct {state:u64}

@(private="file")
next :: proc(r:^Random,below:int) -> int {
    r.state=r.state*6364136223846793005+1442695040888963407
    return int((r.state>>33)%u64(below))
}

// Texels with a ramp, an edge and noise, so that no mode fits them exactly.
@(private="file")
random_block :: proc(r:^Random,alpha:bool) -> (texels:[16][4]u8) {
    base:=[4]int{next(r,256),next(r,256),next(r,256),next(r,256)}
    step:=[4]int{next(r,41)-20,next(r,41)-20,next(r,41)-20,next(r,41)-20}
    edge:=next(r,4)
    for &texel,i in texels {
        x,y:=i%4,i/4
        for c in 0..<4 {
            v:=base[c]+step[c]*(x+y)+next(r,9)-4
            if x>edge {v+=60}
            texel[c]=u8(clamp(v,0,255))
        }
        texel[3]=u8(clamp(base[3]-next(r,128),0,254)) if alpha else 255
    }
    return
}

@(test)
bc7_every_mode_decodes_to_the_error_the_encoder_measured :: proc(t:^testing.T) {
    r:=Random{state=7}
    for mode in u32(0)..<8 {
        for alpha in ([]bool{false,true}) {
            settings:=BC7_SETTINGS
            settings.opaque_modes,settings.alpha_modes={},{}
            if alpha {
                if mode<4 {continue}
                settings.alpha_modes={int(mode)}
            } else {
                if mode==7 {continue}
                settings.opaque_modes={int(mode)}
            }
            for _ in 0..<40 {
                texels:=random_block(&r,alpha)
                block,error:=bc7_choose(&texels,&settings)
                testing.expectf(t,block.mode==mode,"mode %d alone gave mode %d",mode,block.mode)
                encoded:=bc7_pack(&block)
                testing.expectf(t,u32(encoded[0])&(1<<mode)!=0 && u32(encoded[0])&(1<<mode-1)==0,"mode %d packs its mode bits",mode)
                decoded:=asset.texture_bc7_block_decode(encoded)
                measured:u64
                for texel,i in texels {
                    for c in 0..<(4 if alpha else 3) {
                        d:=i64(decoded[i][c])-i64(texel[c])
                        measured+=u64(d*d)
                    }
                    if !alpha {testing.expectf(t,decoded[i][3]>=254,"an opaque block of mode %d decodes alpha %d",mode,decoded[i][3])}
                }
                testing.expectf(t,measured==error,"mode %d (alpha %v): the encoder measured %d and the block decodes to %d",mode,alpha,error,measured)
            }
        }
    }
}

@(test)
bc7_one_color_blocks_are_exact :: proc(t:^testing.T) {
    r:=Random{state=11}
    settings:=BC7_SETTINGS
    for _ in 0..<200 {
        color:=[4]u8{u8(next(&r,256)),u8(next(&r,256)),u8(next(&r,256)),u8(next(&r,256))}
        texels:[16][4]u8
        for &texel in texels {texel=color}
        for texel in asset.texture_bc7_block_decode(bc7_encode_block(&texels,&settings)) {
            testing.expectf(t,texel==color,"%v decodes to %v",color,texel)
        }
    }
}

// Peak signal to noise ratio of a level against the texels it was made
// from, in dB, over channels.
@(private="file")
psnr :: proc(format:asset.Texture_Format,pixels:[]u8,width,height,channels:int) -> f64 {
    blocks,_:=bc_compress(pixels,width,height,format,context.temp_allocator)
    decoded:=make([]u8,width*height*4,context.temp_allocator)
    asset.texture_level_rgba8(format,blocks,width,height,decoded)
    total:f64
    for i in 0..<width*height {
        for c in 0..<channels {
            d:=f64(decoded[i*4+c])-f64(pixels[i*4+c])
            total+=d*d
        }
    }
    return 10*math.log10(255*255/max(total/f64(width*height*channels),1e-10))
}

@(test)
bc7_keeps_color_better_than_bc1_and_bc3 :: proc(t:^testing.T) {
    SIZE :: 64
    pixels:=make([]u8,SIZE*SIZE*4,context.temp_allocator)
    for y in 0..<SIZE {
        for x in 0..<SIZE {
            at:=(y*SIZE+x)*4
            // Two hues in smooth ramps, a pattern of small cells and alpha in a ramp.
            pixels[at]=u8(x*4)
            pixels[at+1]=u8(255-y*3)
            pixels[at+2]=u8(128+int(60*math.sin(f64(x)*0.7)*math.cos(f64(y)*0.5)))
            pixels[at+3]=u8(y*4)
            if (x/3+y/5)%4==0 {pixels[at],pixels[at+2]=pixels[at+2],pixels[at]}
        }
    }
    opaque:=make([]u8,len(pixels),context.temp_allocator)
    copy(opaque,pixels)
    for i:=3;i<len(opaque);i+=4 {opaque[i]=255}
    bc1,bc7_rgb:=psnr(.BC1,opaque,SIZE,SIZE,3),psnr(.BC7,opaque,SIZE,SIZE,3)
    bc3,bc7_rgba:=psnr(.BC3,pixels,SIZE,SIZE,4),psnr(.BC7,pixels,SIZE,SIZE,4)
    testing.expectf(t,bc7_rgb>bc1+6,"BC7 %.2f dB against BC1 %.2f dB",bc7_rgb,bc1)
    testing.expectf(t,bc7_rgba>bc3+4,"BC7 %.2f dB against BC3 %.2f dB with alpha",bc7_rgba,bc3)
}

@(test)
bc7_levels_in_parallel_give_the_same_blocks :: proc(t:^testing.T) {
    SIZE :: 130 // not a multiple of four: the last blocks repeat the edge
    pixels:=make([]u8,SIZE*SIZE*4,context.temp_allocator)
    r:=Random{state=3}
    for &p,i in pixels {p=u8((i*7+next(&r,32))%256)}
    serial,_:=bc_compress(pixels,SIZE,SIZE,.BC7,context.temp_allocator)
    js:jobs.Job_System
    testing.expect(t,jobs.system_init(&js,{threads=3}))
    defer jobs.system_destroy(&js)
    parallel,_:=bc_compress(pixels,SIZE,SIZE,.BC7,context.temp_allocator,{&js,jobs.OWNER,nil})
    testing.expect_value(t,len(serial),33*33*16)
    testing.expect(t,string(serial)==string(parallel),"rows of blocks in other threads give the same bytes")
}

@(test)
color_is_bc7_data_maps_bc1_or_bc3_and_hdr_bc6h :: proc(t:^testing.T) {
    opaque:=[]u8{10,20,30,255,40,50,60,255}
    cutout:=[]u8{10,20,30,255,40,50,60,0}
    stored :: proc(texels:[]u8,format:Source_Format,options:Build_Options) -> asset.Texture_Format {
        return stored_format({texels=texels,width=2,height=1,format=format},options)
    }
    testing.expect_value(t,stored(opaque,.RGBA8,{srgb=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(cutout,.RGBA8,{srgb=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(opaque,.RGBA8,{}),asset.Texture_Format.BC1)
    testing.expect_value(t,stored(cutout,.RGBA8,{}),asset.Texture_Format.BC3)
    testing.expect_value(t,stored(cutout,.RGBA8,{srgb=true,normal_map=true}),asset.Texture_Format.BC5)
    testing.expect_value(t,stored(opaque,.RGBA8,{srgb=true,keep_precision=true}),asset.Texture_Format.BC7)
    testing.expect_value(t,stored(opaque,.RGBA8,{encoding=.Uncompressed}),asset.Texture_Format.RGBA8)

    floats :: proc(values:[2][4]f32) -> []u8 {
        texels:=make([]u8,32,context.temp_allocator)
        linear:=transfer_make(false)
        for value,at in values {texel_write(texels,.RGBA32F,at,value,&linear)}
        return texels
    }
    bright:=floats({{40,2,0.5,1},{0,0,0,1}})
    testing.expect_value(t,stored(bright,.RGBA32F,{srgb=true}),asset.Texture_Format.BC6H)
    testing.expect_value(t,stored(floats({{40,2,0.5,0.5},{0,0,0,1}}),.RGBA32F,{}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(floats({{40,-2,0.5,1},{0,0,0,1}}),.RGBA32F,{}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(bright,.RGBA32F,{keep_precision=true}),asset.Texture_Format.RGBA16F)
    testing.expect_value(t,stored(bright,.RGBA32F,{normal_map=true}),asset.Texture_Format.BC5)
    wide:=make([]u8,16,context.temp_allocator)
    for &b in wide {b=0xff}
    testing.expect_value(t,stored(wide,.RGBA16,{}),asset.Texture_Format.BC1)
    testing.expect_value(t,stored(wide,.RGBA16,{keep_precision=true}),asset.Texture_Format.RGBA16)
    testing.expect_value(t,stored(wide,.RGBA16,{encoding=.Uncompressed}),asset.Texture_Format.RGBA16)
}
