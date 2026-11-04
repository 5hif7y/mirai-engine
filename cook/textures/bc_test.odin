package textures

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"

@(private="file")
bc1_error :: proc(texels:^[16][4]u8) -> (worst:f32) {
    decoded,_:=asset.texture_bc1_block_decode(bc1_encode_block(texels))
    for t,i in texels {
        for c in 0..<3 {worst=max(worst,abs(decoded[i][c]*255-f32(t[c])))}
    }
    return
}

@(test)
bc1_blocks_decode_close_to_their_texels :: proc(t:^testing.T) {
    // One color: both endpoints land on it, within what 5:6:5 bits hold.
    flat:[16][4]u8
    for &texel in flat {texel={200,100,50,255}}
    testing.expectf(t,bc1_error(&flat)<=4,"a flat block is off by %v",bc1_error(&flat))
    // Two colors: each texel gets its own endpoint.
    pair:[16][4]u8
    for &texel,i in pair {texel={255,0,0,255} if i%2==0 else {0,0,255,255}}
    testing.expectf(t,bc1_error(&pair)<=4,"a two color block is off by %v",bc1_error(&pair))
    // A ramp between two colors: four steps on the line cover sixteen texels.
    ramp:[16][4]u8
    for &texel,i in ramp {
        k:=f32(i)/15
        texel={u8(40+180*k),u8(200-120*k),u8(30+60*k),255}
    }
    testing.expectf(t,bc1_error(&ramp)<=36,"a ramp is off by %v",bc1_error(&ramp))
    // The first endpoint is the larger one, which is what selects four colors.
    block:=bc1_encode_block(&ramp)
    c0,c1:=u16(block[0])|u16(block[1])<<8,u16(block[2])|u16(block[3])<<8
    testing.expect(t,c0>c1,"a block with two different endpoints is in four color mode")
    // Gray texels stay gray enough: the fit follows the diagonal of the color cube.
    gray:[16][4]u8
    for &texel,i in gray {v:=u8(i*16);texel={v,v,v,255}}
    decoded,_:=asset.texture_bc1_block_decode(bc1_encode_block(&gray))
    for texel in decoded {
        testing.expect(t,abs(texel.r-texel.g)<0.03 && abs(texel.g-texel.b)<0.03,"a gray ramp picks up a tint")
    }
}

@(test)
bc4_blocks_keep_their_range :: proc(t:^testing.T) {
    values:[16]u8
    for &v,i in values {v=u8(20+i*14)}
    decoded:=asset.texture_bc4_block_decode(bc4_encode_block(&values))
    for v,i in values {
        testing.expectf(t,abs(decoded[i]*255-f32(v))<=16,"value %d decodes to %v",v,decoded[i]*255)
    }
    testing.expect(t,abs(decoded[0]*255-20)<0.5 && abs(decoded[15]*255-230)<0.5,"the ends of the range are exact")
    flat:[16]u8
    for &v in flat {v=128}
    for v in asset.texture_bc4_block_decode(bc4_encode_block(&flat)) {testing.expect(t,abs(v*255-128)<0.5)}
}

@(test)
bc_compress_covers_any_size :: proc(t:^testing.T) {
    pixels:[5*3*4]u8
    for &b,i in pixels {b=u8(i*7)}
    bc1,_:=bc_compress(pixels[:],5,3,.BC1)
    bc3,_:=bc_compress(pixels[:],5,3,.BC3)
    bc5,_:=bc_compress(pixels[:4],1,1,.BC5)
    plain,_:=bc_compress(pixels[:],5,3,.RGBA8)
    defer delete(bc1)
    defer delete(bc3)
    defer delete(bc5)
    defer delete(plain)
    testing.expect_value(t,len(bc1),2*1*8)
    testing.expect_value(t,len(bc3),2*1*16)
    testing.expect_value(t,len(bc5),16)
    testing.expect_value(t,len(plain),5*3*4)
    // One texel repeated over its block: both channels exact.
    testing.expect(t,bc5[0]==pixels[0] && bc5[8]==pixels[1])

    // A built texture has every level down to one texel, compressed or not.
    image:[16*8*4]u8
    for &b in image {b=255}
    built,error:=build(rgba8(image[:],16,8),{max_size=8,srgb=true})
    defer built_destroy(&built)
    testing.expect(t,error==.None && built.format==.BC7 && .Srgb in built.flags && built.width==8 && built.height==4)
    testing.expect(t,len(built.mips)==4 && len(built.mips[0])==2*1*16 && len(built.mips[3])==16)
    data,_:=build(rgba8(image[:],16,8),{max_size=8})
    defer built_destroy(&data)
    testing.expect(t,data.format==.BC1 && len(data.mips[0])==2*1*8 && len(data.mips[3])==8)
    image[3]=0
    holed,_:=build(rgba8(image[:],16,8),{max_size=64})
    defer built_destroy(&holed)
    testing.expect_value(t,holed.format,asset.Texture_Format.BC3)
    normals,_:=build(rgba8(image[:],16,8),{max_size=64,normal_map=true})
    defer built_destroy(&normals)
    plain_built,_:=build(rgba8(image[:],16,8),{max_size=64,encoding=.Uncompressed})
    defer built_destroy(&plain_built)
    testing.expect(t,normals.format==.BC5 && plain_built.format==.RGBA8 && len(plain_built.mips[0])==16*8*4)
    testing.expect(t,settings_hash({srgb=true})!=settings_hash({srgb=true,encoding=.Uncompressed}),"the encoding is a setting of the import")
}

@(test)
black_and_zero_blocks_decode_opaque :: proc(t:^testing.T) {
    // Both endpoints equal is the three color mode, whose fourth index is
    // transparent: an encoded block never uses it.
    black:[16][4]u8
    for &texel in black {texel={0,0,0,255}}
    _,alpha:=asset.texture_bc1_block_decode(bc1_encode_block(&black))
    for value in alpha {testing.expect(t,value==1)}
    zero:[8]u8
    _,alpha=asset.texture_bc1_block_decode(zero)
    for value in alpha {testing.expect(t,value==1)}
}

@(private="file")
smooth_image :: proc(size:int,alpha:bool) -> []u8 {
    pixels:=make([]u8,size*size*4)
    quadrants:=[4][3]f32{{0.9,0.2,0.1},{0.1,0.8,0.2},{0.2,0.3,0.9},{0.6,0.6,0.6}}
    for y in 0..<size {
        for x in 0..<size {
            color:=quadrants[(y/(size/2))*2+x/(size/2)]*(0.8+0.2*f32((x+y)%(size/2))/f32(size/2))
            at:=(y*size+x)*4
            pixels[at],pixels[at+1],pixels[at+2]=u8(color.r*255),u8(color.g*255),u8(color.b*255)
            pixels[at+3]=u8(40+x*3) if alpha else 255
        }
    }
    return pixels
}

@(test)
a_compressed_texture_survives_the_file_within_what_a_block_keeps :: proc(t:^testing.T) {
    SIZE :: 64
    types:asset.Types;asset.types_init(&types);defer asset.types_destroy(&types)
    directory,_:=os.temp_directory(context.temp_allocator)
    cases:=[?]struct{name:string,options:Build_Options,alpha:bool,format:asset.Texture_Format,channels:int,tolerance:int}{
        {"color",{srgb=true},false,.BC7,4,12},
        {"color with alpha",{srgb=true},true,.BC7,4,12},
        {"data",{},false,.BC1,4,12},
        {"data with alpha",{},true,.BC3,4,12},
        {"normal map",{normal_map=true},false,.BC5,2,6},
        {"plain",{srgb=true,encoding=.Uncompressed},true,.RGBA8,4,0},
    }
    for entry,index in cases {
        pixels:=smooth_image(SIZE,entry.alpha);defer delete(pixels)
        built,error:=build(rgba8(pixels,SIZE,SIZE),entry.options)
        defer built_destroy(&built)
        testing.expect_value(t,error,Error.None)
        testing.expect_value(t,built.format,entry.format)
        again,_:=build(rgba8(pixels,SIZE,SIZE),entry.options)
        defer built_destroy(&again)
        for level,i in built.mips {testing.expectf(t,string(level)==string(again.mips[i]),"%s: level %d is not the same in a second build",entry.name,i)}

        path:=fmt.tprintf("%s/mirai-bc-%d-%d.tex",directory,os.get_pid(),index)
        defer os.remove(path)
        testing.expect_value(t,asset.texture_save(path,&types,built_desc(&built,base.Asset_Id{9,u64(index)+1},nil)),asset.Error.None)
        a:asset.Asset
        if !testing.expect_value(t,asset.asset_load(&a,path),asset.Error.None) {continue}
        defer asset.asset_close(&a)
        view,view_error:=asset.texture_view(&a,&types)
        testing.expect_value(t,view_error,asset.Error.None)
        testing.expect(t,view.info.format==entry.format && int(view.info.mip_count)==asset.texture_mip_count(SIZE,SIZE) && view.info.width==SIZE)
        for level in 0..<int(view.info.mip_count) {testing.expect(t,string(asset.texture_mip(view,level))==string(built.mips[level]),"the file holds the built levels")}

        // Each level against the one of the plain chain, away from the steps
        // between quadrants, where a block holds two ramps.
        plain_options:=entry.options
        plain_options.encoding=.Uncompressed
        plain,_:=build(rgba8(pixels,SIZE,SIZE),plain_options)
        defer built_destroy(&plain)
        for level in 0..<3 {
            side:=SIZE>>uint(level)
            decoded:=make([]u8,side*side*4);defer delete(decoded)
            testing.expect(t,asset.texture_level_rgba8(view.info.format,asset.texture_mip(view,level),side,side,decoded))
            half:=side/2
            edge:=4 if entry.format!=.RGBA8 else 0
            worst:=0
            for y in 0..<side {
                for x in 0..<side {
                    if x%half<edge || x%half>=half-edge || y%half<edge || y%half>=half-edge {continue}
                    at:=(y*side+x)*4
                    for channel in 0..<entry.channels {worst=max(worst,abs(int(decoded[at+channel])-int(plain.mips[level][at+channel])))}
                }
            }
            testing.expectf(t,worst<=entry.tolerance,"%s: level %d is off by %d",entry.name,level,worst)
        }
        testing.expect(t,!asset.texture_level_rgba8(view.info.format,asset.texture_mip(view,0),SIZE,SIZE,built.mips[1][:0]),"a slice of another size is refused")
    }
}

@(test)
an_odd_sized_level_decodes_every_texel_of_its_last_blocks :: proc(t:^testing.T) {
    pixels:[5*3*4]u8
    for i in 0..<5*3 {pixels[i*4],pixels[i*4+1],pixels[i*4+2],pixels[i*4+3]=90,140,200,255}
    for format in ([]asset.Texture_Format{.BC1,.BC3,.BC5}) {
        blocks,_:=bc_compress(pixels[:],5,3,format);defer delete(blocks)
        decoded:[5*3*4]u8
        testing.expect(t,asset.texture_level_rgba8(format,blocks,5,3,decoded[:]))
        for i in 0..<5*3 {
            testing.expectf(t,abs(int(decoded[i*4])-90)<=4 && abs(int(decoded[i*4+1])-140)<=4 && decoded[i*4+3]==255,"%v texel %d is %v",format,i,decoded[i*4:i*4+4])
        }
    }
}
