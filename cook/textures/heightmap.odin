package textures

import "core:c"
import "core:hash"
import "core:mem"
import stbi "vendor:stb/image"

Heightmap :: struct {
    values:[]f32,
    width,height:int,
    allocator:mem.Allocator,
}

heightmap_destroy :: proc(heightmap:^Heightmap) {
    if heightmap==nil {return}
    delete(heightmap.values,heightmap.allocator)
    heightmap^={}
}

// Rows start at the top; integer channels are normalized without gamma conversion.
heightmap_decode :: proc(bytes:[]u8,max_side:int=MAX_SOURCE_SIDE,allocator:=context.allocator) -> (heightmap:Heightmap,error:Error) {
    if max_side<=0 {return {},.Invalid}
    if len(bytes)==0 || len(bytes)>int(max(c.int)) {return {},.Unsupported}
    // The bundled stb PNM path mishandles 16-bit channels and truncated payloads.
    if len(bytes)>=2 && bytes[0]=='P' && (bytes[1]=='5' || bytes[1]=='6') {return {},.Unsupported}
    x,y,components:c.int
    if stbi.info_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components)==0 {return {},.Unsupported}
    if x<=0 || y<=0 || int(x)>min(max_side,MAX_SOURCE_SIDE) || int(y)>min(max_side,MAX_SOURCE_SIDE) ||
        int(x)>MAX_SOURCE_PIXELS/int(y) {return {},.Too_Large}
    if stbi.is_hdr_from_memory(raw_data(bytes),c.int(len(bytes)))!=0 {return {},.Unsupported}
    width,height:=int(x),int(y)
    count:=width*height
    values,alloc_error:=make([]f32,count,allocator)
    if alloc_error!=nil {return {},.Out_Of_Memory}
    decoded:=stbi.load_16_from_memory(raw_data(bytes),c.int(len(bytes)),&x,&y,&components,1)
    if decoded==nil {delete(values,allocator);return {},.Unsupported}
    defer stbi.image_free(decoded)
    if int(x)!=width || int(y)!=height {delete(values,allocator);return {},.Invalid}
    for value,i in decoded[:count] {values[i]=f32(value)/65535}
    return {values=values,width=width,height=height,allocator=allocator},.None
}

// A 16-bit grayscale PNG of values from 0 to 1, rows from the top, as
// heightmap_decode reads it. Its deflate blocks are stored, which every reader
// takes: the file is as large as its samples.
heightmap_encode :: proc(values:[]f32,width,height:int,allocator:=context.allocator) -> (bytes:[]u8,error:Error) {
    if width<=0 || height<=0 || width>MAX_SOURCE_SIDE || height>MAX_SOURCE_SIDE || len(values)!=width*height {return nil,.Invalid}
    row:=1+width*2
    raw,raw_error:=make([]u8,row*height,context.temp_allocator)
    if raw_error!=nil {return nil,.Out_Of_Memory}
    for z in 0..<height {
        raw[z*row]=0
        for x in 0..<width {
            v:=values[x+width*z]
            sample:=u16(clamp(v-v==0?v:0,0,1)*65535+0.5)
            raw[z*row+1+x*2],raw[z*row+2+x*2]=u8(sample>>8),u8(sample)
        }
    }
    STORED :: 65535
    blocks:=max((len(raw)+STORED-1)/STORED,1)
    idat:=2+len(raw)+blocks*5+4
    out,out_error:=make([dynamic]u8,0,8+25+12+idat+12,allocator)
    if out_error!=nil {return nil,.Out_Of_Memory}
    big :: proc(out:^[dynamic]u8,value:u32) {append(out,u8(value>>24),u8(value>>16),u8(value>>8),u8(value))}
    chunk_begin :: proc(out:^[dynamic]u8,kind:string,size:int) -> int {
        big(out,u32(size))
        at:=len(out)
        append(out,..transmute([]u8)kind)
        return at
    }
    chunk_end :: proc(out:^[dynamic]u8,at:int) {big(out,hash.crc32(out[at:]))}
    append(&out,0x89,'P','N','G','\r','\n',0x1a,'\n')
    at:=chunk_begin(&out,"IHDR",13)
    big(&out,u32(width));big(&out,u32(height))
    append(&out,16,0,0,0,0) // 16 bits, grayscale, deflate, no filter of its own, no interlace
    chunk_end(&out,at)
    at=chunk_begin(&out,"IDAT",idat)
    append(&out,0x78,0x01)
    for b in 0..<blocks {
        part:=raw[min(b*STORED,len(raw)):min((b+1)*STORED,len(raw))]
        n:=u16(len(part))
        append(&out,b==blocks-1?1:0,u8(n),u8(n>>8),u8(~n),u8(~n>>8))
        append(&out,..part)
    }
    big(&out,hash.adler32(raw))
    chunk_end(&out,at)
    at=chunk_begin(&out,"IEND",0)
    chunk_end(&out,at)
    if len(out)!=8+25+12+idat+12 {delete(out);return nil,.Invalid}
    return out[:],.None
}
