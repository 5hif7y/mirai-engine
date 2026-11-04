package asset

import "mirai:std/base"

// .tex: an image ready for the GPU.
//
//   texture         Texture_Info, one row
//   mips            Texture_Mip: where each level is inside texels, largest first
//   texels   bulk   bytes of every level, each one starting at a multiple of 16
//
// A level is half the one above, rounded down, and never smaller than 1. It
// holds its layers one after another: the images of an array, or the faces
// of its cubes. Block formats store 4x4 blocks: BC1 in 8 bytes, BC3, BC5,
// BC6H and BC7 in 16.

TEXTURE_VERSION :: 1
TEXTURE_MAX_SIZE :: 16384
TEXTURE_MAX_MIPS :: 15
// Of an array or of cube faces: the least every GPU Mirai runs on takes.
TEXTURE_MAX_LAYERS :: 256
TEXTURE_CUBE_FACES :: 6
TEXTURE_BULK_ALIGNMENT :: 16

Texture_Format :: enum u8 {
    RGBA8,   // rows from the top of the image
    BC1,     // rgb: data maps without alpha
    BC3,     // rgba: data maps with alpha
    BC5,     // two channels: tangent-space normals
    BC7,     // color, with or without alpha
    RGBA16,  // 16-bit channels, linear: data that keeps its precision
    RGBA16F, // half floats, linear: HDR with alpha, negative values or kept uncompressed
    BC6H,    // rgb half floats without sign, linear: HDR light and color
}

Texture_Flag :: enum u8 {
    Srgb,       // color: stored as sRGB in RGBA8, BC1, BC3 and BC7, linear in the others; filtered as light
    Normal_Map, // levels are averaged as vectors and renormalized
    Cube,       // its layers are the faces +X, -X, +Y, -Y, +Z and -Z of cubes, sampled with a direction of the world
}
Texture_Flags :: bit_set[Texture_Flag;u32]

Texture_Info :: struct {
    width:u32,
    height:u32,
    mip_count:u32,
    format:Texture_Format,
    flags:Texture_Flags,
    alpha_coverage:f32, // above 0: the cutoff of the masked material whose coverage every level keeps
    layers:u32,         // images of each level: one, those of an array, or six per cube
}

// What a file that does not store a field reads.
TEXTURE_DEFAULTS :: Texture_Info{layers=1}

Texture_Mip :: struct {
    width:u32,
    height:u32,
    offset:u32, // into texels
    size:u32,   // of every layer
}

Texture_Desc :: struct {
    id:base.Asset_Id,
    owner:base.Asset_Id, // the asset it is a part of: the prefab of the import that made it
    width,height:int,
    layers:int,          // 0: one
    format:Texture_Format,
    flags:Texture_Flags,
    alpha_coverage:f32,
    mips:[][]u8,         // level 0 first, each with its layers one after another
    source:^Import_Info,
    compression:Compression,
}

Texture_View :: struct {
    info:^Texture_Info,
    mips:[]Texture_Mip,
    texels:[]u8,
    source:^Import_Info,
}

// Bytes of one image of a level of a size, in a format.
texture_level_size :: proc "contextless" (format:Texture_Format,width,height:int) -> int {
    switch format {
    case .RGBA8: return width*height*4
    case .RGBA16,.RGBA16F: return width*height*8
    case .BC1: return ((width+3)/4)*((height+3)/4)*8
    case .BC3,.BC5,.BC6H,.BC7: return ((width+3)/4)*((height+3)/4)*16
    }
    return 0
}

// Levels of a full chain down to 1x1.
texture_mip_count :: proc "contextless" (width,height:int) -> int {
    count:=1
    for size:=max(width,height);size>1;size>>=1 {count+=1}
    return count
}

// Whether a count of layers is one a texture of those flags holds: a cube is
// square and has whole cubes.
texture_layers_valid :: proc "contextless" (layers,width,height:int,flags:Texture_Flags) -> bool {
    if layers<1 || layers>TEXTURE_MAX_LAYERS {return false}
    return .Cube not_in flags || layers%TEXTURE_CUBE_FACES==0 && width==height
}

texture_document :: proc(doc:^Document,types:^Types,desc:Texture_Desc,allocator:=context.allocator) -> Error {
    if desc.width<=0 || desc.height<=0 || desc.width>TEXTURE_MAX_SIZE || desc.height>TEXTURE_MAX_SIZE {return .Invalid}
    layers:=max(desc.layers,1)
    if desc.layers<0 || !texture_layers_valid(layers,desc.width,desc.height,desc.flags) {return .Invalid}
    if len(desc.mips)==0 || len(desc.mips)>texture_mip_count(desc.width,desc.height) || !finite(desc.alpha_coverage) {return .Invalid}
    info:=Texture_Info{width=u32(desc.width),height=u32(desc.height),mip_count=u32(len(desc.mips)),format=desc.format,flags=desc.flags,alpha_coverage=desc.alpha_coverage,layers=u32(layers)}
    mips:[TEXTURE_MAX_MIPS]Texture_Mip
    total:=0
    for level,i in desc.mips {
        width,height:=max(desc.width>>uint(i),1),max(desc.height>>uint(i),1)
        if len(level)!=texture_level_size(desc.format,width,height)*layers {return .Invalid}
        total=(total+TEXTURE_BULK_ALIGNMENT-1)&~int(TEXTURE_BULK_ALIGNMENT-1)
        if total+len(level)>int(max(u32)) {return .Invalid}
        mips[i]={u32(width),u32(height),u32(total),u32(len(level))}
        total+=len(level)
    }
    document_init(doc,KIND_TEXTURE,desc.id,allocator)
    doc.owner=desc.owner
    doc.kind_version=TEXTURE_VERSION
    error:=texture_tables(doc,types,&info,mips[:len(desc.mips)],total,desc)
    if error!=.None {document_destroy(doc)}
    return error
}

@(private="file")
texture_tables :: proc(doc:^Document,types:^Types,info:^Texture_Info,mips:[]Texture_Mip,total:int,desc:Texture_Desc) -> Error {
    document_put_row(doc,types,"texture",info) or_return
    document_put(doc,types,"mips",mips) or_return
    import_put(doc,types,desc.source) or_return
    texels:=document_table_add(doc,"texels",{.Bulk}) or_return
    document_resize(doc,texels,total) or_return
    byte,_:=document_type(doc,types,u8)
    column:=document_column_add(doc,texels,"",byte,{},desc.compression,TEXTURE_BULK_ALIGNMENT) or_return
    data:=doc.tables[texels].columns[column].data[:]
    for level,i in desc.mips {copy(data[mips[i].offset:],level)}
    return .None
}

texture_save :: proc(path:string,types:^Types,desc:Texture_Desc,allocator:=context.allocator) -> Error {
    doc:Document
    texture_document(&doc,types,desc,allocator) or_return
    defer document_destroy(&doc)
    return document_save(&doc,path)
}

texture_view :: proc(a:^Asset,types:^Types) -> (view:Texture_View,error:Error) {
    kind_check(a,KIND_TEXTURE,TEXTURE_VERSION) or_return
    defaults:=TEXTURE_DEFAULTS
    view.info=asset_row(a,types,"texture",Texture_Info,&defaults) or_return
    view.mips=asset_rows(a,types,"mips","",Texture_Mip) or_return
    view.texels=asset_rows(a,types,"texels","",u8) or_return
    view.source=import_info(a,types) or_return
    if !texture_check(view) {return {},.Corrupt}
    return view,.None
}

// The bytes of a level, with every layer.
texture_mip :: proc(view:Texture_View,level:int) -> []u8 {
    mip:=view.mips[level]
    return view.texels[mip.offset:][:mip.size]
}

// The bytes of one layer of a level.
texture_layer :: proc(view:Texture_View,level,layer:int) -> []u8 {
    mip:=view.mips[level]
    size:=int(mip.size)/int(view.info.layers)
    return view.texels[int(mip.offset)+layer*size:][:size]
}

texture_check :: proc(view:Texture_View) -> bool {
    info:=view.info
    if info==nil || info.width==0 || info.height==0 || info.width>TEXTURE_MAX_SIZE || info.height>TEXTURE_MAX_SIZE {return false}
    if info.format>max(Texture_Format) || !finite(info.alpha_coverage) {return false}
    if !texture_layers_valid(int(info.layers),int(info.width),int(info.height),info.flags) {return false}
    if int(info.mip_count)!=len(view.mips) || len(view.mips)==0 || len(view.mips)>texture_mip_count(int(info.width),int(info.height)) {return false}
    for mip,i in view.mips {
        width,height:=max(int(info.width)>>uint(i),1),max(int(info.height)>>uint(i),1)
        if int(mip.width)!=width || int(mip.height)!=height || int(mip.size)!=texture_level_size(info.format,width,height)*int(info.layers) {return false}
        if u64(mip.offset)+u64(mip.size)>u64(len(view.texels)) {return false}
    }
    return true
}
