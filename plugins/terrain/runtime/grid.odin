package terrain

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "mirai:asset"
import "mirai:std/base"
import "mirai:std/serial"

// Samples per side of a page of an X/Z grid.
PAGE :: 64
// Samples per side of a block of a Volume: its page of BLOCK³ samples.
BLOCK :: 16
PAGE_VALUES :: PAGE*PAGE
#assert(BLOCK*BLOCK*BLOCK==PAGE_VALUES)

// A page holds its samples, X contiguous, then Y and Z, or none: every value
// is fill, or, in a grid read by pages, the values are in its block. A page
// at a far edge holds only the samples of the grid there (grid_page_extent).
// Its values are shared (shared_make): the copies of a grid hold the same
// ones, and a writer takes values of its own first (grid_page_own).
Page :: struct($T:typeid) {
    fill:T,
    values:[]T,
    altered:bool, // written since its source was read from its file or saved to it (Source.origin)
}

// Precedes the values of a page or an own block in their allocation: how
// many grids hold them, atomic because a copy in another World can let go of
// them in another thread, and the allocator that made them, which has to
// outlive every holder (that of the application or the heap).
@(private)
Shared :: struct #align(16) {
    allocator:runtime.Allocator,
    bytes:int,   // of the values after it
    holders:i32,
}

@(private)
shared_of :: #force_inline proc "contextless" (values:[]$T) -> ^Shared {
    return (^Shared)(uintptr(raw_data(values))-size_of(Shared))
}

// count values held by one, not zeroed.
shared_make :: proc($T:typeid,count:int,allocator:runtime.Allocator) -> (values:[]T,ok:bool) {
    if count<=0 {return nil,count==0}
    bytes:=count*size_of(T)
    data,error:=mem.alloc_bytes_non_zeroed(size_of(Shared)+bytes,align_of(Shared),allocator)
    if error!=nil {return}
    shared:=(^Shared)(raw_data(data))
    shared^={allocator=allocator,bytes=bytes,holders=1}
    return ([^]T)(uintptr(raw_data(data))+size_of(Shared))[:count],true
}

// One more holder of values made by shared_make, or nil.
shared_hold :: proc "contextless" (values:[]$T) -> []T {
    if values!=nil {intrinsics.atomic_add(&shared_of(values).holders,1)}
    return values
}

// A holder lets go of values made by shared_make, or nil: the last frees them.
shared_free :: proc(values:[]$T) {
    if values==nil {return}
    shared:=shared_of(values)
    if intrinsics.atomic_sub(&shared.holders,1)!=1 {return}
    _=mem.free_with_size(shared,size_of(Shared)+shared.bytes,shared.allocator)
}

// Whether only one holds values made by shared_make: it can write them.
shared_alone :: #force_inline proc "contextless" (values:[]$T) -> bool {
    return intrinsics.atomic_load(&shared_of(values).holders)==1
}

// Lets go of the values of a page, as a grid that held it.
page_free :: proc(page:Page($T)) {shared_free(page.values)}

// Gives page i values that no other grid holds, so they can be written:
// those it has when it holds them alone, otherwise a copy. A job of another
// World that reads the shared ones goes on reading them. False without
// memory, the page as it was.
grid_page_own :: proc(g:^Grid($T),i:int,allocator:runtime.Allocator) -> bool {
    page:=&g.pages[i]
    if page.values==nil || shared_alone(page.values) {return true}
    values,ok:=shared_make(T,len(page.values),allocator)
    if !ok {return false}
    copy(values,page.values)
    shared_free(page.values)
    page.values=values
    return true
}

// Where the values of a page are while they are not in memory: an LZ block
// of the file of its source, or one of its own with what the page held when
// it left with edits that file does not have.
Page_Block :: struct {
    offset:u64,  // of the block in the file
    size:u32,    // bytes of the block; 0: none, the page is uniform
    hash:u64,    // XXH3 of the block
    own:[]u8,    // the block in memory, in place of the one in the file; shared as the values of a page, and never written
    edited:bool, // its values in memory were written since they came from the block
}

// Values over a grid in pages: one sample along Y is an X/Z grid in pages of
// PAGE by PAGE, more a Volume in blocks of BLOCK³. Without pages every value
// is the zero of T.
Grid :: struct($T:typeid) {
    size:[3]int,
    counts:[3]int, // pages along each axis
    side:[3]int,   // samples of a page along each axis
    pages:[]Page(T),
    blocks:[]Page_Block, // of a grid read by pages, one per page; empty: every page is in memory or uniform
    encoded:[]Page_Encoded, // the blocks grid_put_document made, kept by a writer that asks for them
}

// The LZ block of a page as it was last written, and the hash of the values
// it holds: a page that still holds them is not compressed again.
Page_Encoded :: struct {raw:u64,block:[]u8}

@(private)
Page_Record :: struct {fill:u32,size:u32,offset:u64,hash:u64}

grid_side :: proc "contextless" (size:[3]int) -> [3]int {return size.y==1?{PAGE,1,PAGE}:{BLOCK,BLOCK,BLOCK}}

grid_page_counts :: proc "contextless" (size:[3]int) -> [3]int {
    side:=grid_side(size)
    return (size+side-1)/side
}

grid_init :: proc(g:^Grid($T),size:[3]int,fill:T,allocator:runtime.Allocator) -> bool {
    size:=size // it may be g.size, which grid_destroy clears
    if size.x<1 || size.y<1 || size.z<1 {return false}
    counts:=grid_page_counts(size)
    pages,error:=make([]Page(T),counts.x*counts.y*counts.z,allocator)
    if error!=nil {return false}
    for &page in pages {page.fill=fill}
    grid_destroy(g,allocator)
    g.size,g.counts,g.side,g.pages=size,counts,grid_side(size),pages
    return true
}

grid_destroy :: proc(g:^Grid($T),allocator:runtime.Allocator) {
    for page in g.pages {shared_free(page.values)}
    for block in g.blocks {shared_free(block.own)}
    for encoded in g.encoded {delete(encoded.block,allocator)}
    delete(g.pages,allocator);delete(g.blocks,allocator);delete(g.encoded,allocator)
    g^={}
}

// Whether page i of two grids of one size reads the same values.
grid_page_same :: proc(a,b:^Grid($T),i:int) -> bool {
    pa,pb:=&a.pages[i],&b.pages[i]
    if pa.values==nil && pb.values==nil {return pa.fill==pb.fill}
    if raw_data(pa.values)==raw_data(pb.values) {return true}
    if pa.values!=nil && pb.values!=nil {return mem.compare(mem.slice_to_bytes(pa.values),mem.slice_to_bytes(pb.values))==0}
    held,fill:=pa.values,pb.fill
    if held==nil {held,fill=pb.values,pa.fill}
    for value in held {if value!=fill {return false}}
    return true
}

// The page for one more grid: the same values, held once more (page_free).
page_share :: proc "contextless" (page:Page($T)) -> Page(T) {return {page.fill,shared_hold(page.values),page.altered}}

// The pages of a grid of the size of g that an inclusive region of values
// touches, as coordinates of its pages: from the lowest page to the highest
// along each axis.
grid_page_range :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> (from,to:[3]int,ok:bool) {
    if len(g.pages)==0 {return}
    for axis in 0..<3 {
        lo,hi:=max(low[axis],0),min(high[axis],g.size[axis]-1)
        if lo>hi {return}
        from[axis],to[axis]=lo/g.side[axis],hi/g.side[axis]
    }
    return from,to,true
}

// A value of an X/Z grid.
grid_get :: #force_inline proc "contextless" (g:^Grid($T),x,z:int) -> T #no_bounds_check {
    if len(g.pages)==0 {return {}}
    px,pz:=x/PAGE,z/PAGE
    page:=&g.pages[px+g.counts.x*pz]
    if page.values==nil {return page.fill}
    return page.values[x-px*PAGE+min(PAGE,g.size.x-px*PAGE)*(z-pz*PAGE)]
}

// Writes into a page of an X/Z grid that already holds its values (grid_prepare).
grid_set :: #force_inline proc "contextless" (g:^Grid($T),x,z:int,value:T) #no_bounds_check {
    px,pz:=x/PAGE,z/PAGE
    page:=&g.pages[px+g.counts.x*pz]
    page.values[x-px*PAGE+min(PAGE,g.size.x-px*PAGE)*(z-pz*PAGE)]=value
}

// A value of a grid in blocks.
block_get :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int) -> T #no_bounds_check {
    if len(g.pages)==0 {return {}}
    q:=p/BLOCK
    page:=&g.pages[q.x+g.counts.x*(q.y+g.counts.y*q.z)]
    if page.values==nil {return page.fill}
    q*=BLOCK
    return page.values[p.x-q.x+min(BLOCK,g.size.x-q.x)*(p.y-q.y+min(BLOCK,g.size.y-q.y)*(p.z-q.z))]
}

// Writes into a block that already holds its values (grid_prepare).
block_set :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int,value:T) #no_bounds_check {
    q:=p/BLOCK
    page:=&g.pages[q.x+g.counts.x*(q.y+g.counts.y*q.z)]
    q*=BLOCK
    page.values[p.x-q.x+min(BLOCK,g.size.x-q.x)*(p.y-q.y+min(BLOCK,g.size.y-q.y)*(p.z-q.z))]=value
}

// Writes into a page of a grid of either shape that already holds its values (grid_prepare).
grid_write :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int,value:T) #no_bounds_check {
    i,at:=grid_page_at(g,p)
    g.pages[i].values[at]=value
}

// The page that holds sample p, and where p is among its values.
grid_page_at :: #force_inline proc "contextless" (g:^Grid($T),p:[3]int) -> (page,at:int) {
    q:=p/g.side
    low:=q*g.side
    r:=p-low
    extent:=linalg_min(g.side,g.size-low)
    return q.x+g.counts.x*(q.y+g.counts.y*q.z),r.x+extent.x*(r.y+extent.y*r.z)
}

@(private="file")
linalg_min :: #force_inline proc "contextless" (a,b:[3]int) -> [3]int {return {min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)}}

// The samples of page i along each axis, and how many it holds: those of a
// whole page, or at a far edge those of the grid there.
grid_page_extent :: #force_inline proc "contextless" (g:^Grid($T),i:int) -> (extent:[3]int,count:int) {
    low,high:=grid_page_region(g,i)
    extent=high-low+1
    return extent,extent.x*extent.y*extent.z
}

// A value of a grid of either shape.
grid_value :: proc "contextless" (g:^Grid($T),p:[3]int) -> T #no_bounds_check {
    if len(g.pages)==0 {return {}}
    i,at:=grid_page_at(g,p)
    page:=&g.pages[i]
    if page.values==nil {return page.fill}
    return page.values[at]
}

// The first sample of page i, and its last within the grid.
grid_page_region :: proc "contextless" (g:^Grid($T),i:int) -> (low,high:[3]int) {
    low=[3]int{i%g.counts.x,i/g.counts.x%g.counts.y,i/(g.counts.x*g.counts.y)}*g.side
    for axis in 0..<3 {high[axis]=min(low[axis]+g.side[axis],g.size[axis])-1}
    return
}

// The pages of g over the inclusive region of samples, as page coordinates;
// an X/Z grid takes its row whatever the region is along Y.
grid_pages :: proc "contextless" (g:^Grid($T),low,high:[3]int) -> (from,to:[3]int) {
    for axis in 0..<3 {
        if g.size[axis]==1 {continue}
        from[axis],to[axis]=max(low[axis],0)/g.side[axis],min(high[axis],g.size[axis]-1)/g.side[axis]
    }
    return
}

// Whether page i of a grid read by pages has its values in its block, not in memory.
grid_absent :: #force_inline proc "contextless" (g:^Grid($T),i:int) -> bool {
    return len(g.blocks)>0 && g.pages[i].values==nil && g.blocks[i].size>0
}

// Gives each page of the inclusive region values of its own that no other
// grid holds (grid_page_own), so grid_set and block_set can write there. What
// fails leaves pages that read the same. A page whose values are in its
// block fails: it is read first.
grid_prepare :: proc(g:^Grid($T),low,high:[3]int,allocator:runtime.Allocator) -> bool {
    if len(g.pages)==0 {return false}
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        i:=px+g.counts.x*(py+g.counts.y*pz)
        if grid_absent(g,i) {return false}
        if len(g.blocks)>0 {g.blocks[i].edited=true}
        page:=&g.pages[i]
        page.altered=true
        if page.values!=nil {
            if !grid_page_own(g,i,allocator) {return false}
            continue
        }
        _,count:=grid_page_extent(g,i)
        values,ok:=shared_make(T,count,allocator)
        if !ok {return false}
        for &value in values {value=page.fill}
        page.values=values
    }}}
    return true
}

// Writes one value, giving its page its own values when needed.
grid_put :: proc(g:^Grid($T),p:[3]int,value:T,allocator:runtime.Allocator) -> bool {
    if grid_value(g,p)==value {return true}
    if !grid_prepare(g,p,p,allocator) {return false}
    i,at:=grid_page_at(g,p)
    g.pages[i].values[at]=value
    return true
}

// The values the pages hold in memory of their own, the memory the grid costs.
grid_dense :: proc "contextless" (g:^Grid($T)) -> (count:int) {
    for page in g.pages {count+=len(page.values)}
    return
}

// Whether the values of a page are all equal.
@(private)
page_uniform :: proc "contextless" (values:[]$T) -> bool {
    for value in values {if value!=values[0] {return false}}
    return true
}

// The pages of the inclusive region that hold values of their own, all
// equal, take them as their fill: a block all air or all solid stores none.
grid_settle :: proc(g:^Grid($T),low,high:[3]int,allocator:runtime.Allocator) {
    if len(g.pages)==0 {return}
    from,to:=grid_pages(g,low,high)
    for pz in from.z..=to.z {for py in from.y..=to.y {for px in from.x..=to.x {
        i:=px+g.counts.x*(py+g.counts.y*pz)
        page:=&g.pages[i]
        if page.values==nil || !page_uniform(page.values) {continue}
        if len(g.blocks)>0 {shared_free(g.blocks[i].own);g.blocks[i]={}}
        page.fill=page.values[0]
        shared_free(page.values)
        page.values=nil
    }}}
}

// A copy of a grid holds the values of its pages and its own blocks with
// src: it allocates only its tables, and a page is copied when one of them
// writes it (grid_prepare).
grid_clone :: proc(dst,src:^Grid($T),allocator:runtime.Allocator) -> bool {
    if len(src.pages)==0 {grid_destroy(dst,allocator);return true}
    next:Grid(T)
    if !grid_init(&next,src.size,T{},allocator) {return false}
    if len(src.blocks)>0 {
        error:runtime.Allocator_Error
        if next.blocks,error=make([]Page_Block,len(src.blocks),allocator);error!=nil {grid_destroy(&next,allocator);return false}
        for block,i in src.blocks {next.blocks[i]=block;shared_hold(block.own)}
    }
    for page,i in src.pages {next.pages[i]=page_share(page)}
    grid_destroy(dst,allocator)
    dst^=next
    return true
}

// Copies src over dst, a grid of the same pages, without allocating: dst
// lets go of the values it held that src does not, and holds those of src.
grid_copy :: proc(dst,src:^Grid($T),allocator:runtime.Allocator) -> bool {
    if dst.size!=src.size || len(dst.pages)!=len(src.pages) || len(dst.blocks)!=len(src.blocks) {return grid_clone(dst,src,allocator)}
    for &page,i in src.pages {
        target:=&dst.pages[i]
        if raw_data(target.values)!=raw_data(page.values) {
            shared_free(target.values)
            target.values=shared_hold(page.values)
        }
        target.fill,target.altered=page.fill,page.altered
    }
    for &block,i in src.blocks {
        target:=&dst.blocks[i]
        if raw_data(target.own)!=raw_data(block.own) {
            shared_free(target.own)
            shared_hold(block.own)
        }
        target^=block
    }
    return true
}

// The inclusive region whose values differ; changed false for none. Both
// grids hold every page in memory.
grid_diff :: proc(a,b:^Grid($T)) -> (low,high:[3]int,changed:bool) {
    if a.size!=b.size || len(a.pages)!=len(b.pages) {
        for axis in 0..<3 {high[axis]=max(a.size[axis],b.size[axis])-1}
        return {},high,true
    }
    low,high=a.size,{-1,-1,-1}
    for page,i in a.pages {
        other:=b.pages[i]
        if page.values==nil && other.values==nil && page.fill==other.fill || page.values!=nil && raw_data(page.values)==raw_data(other.values) {continue}
        first,last:=grid_page_region(a,i)
        for z in first.z..=last.z {for y in first.y..=last.y {for x in first.x..=last.x {
            p:=[3]int{x,y,z}
            if grid_value(a,p)==grid_value(b,p) {continue}
            for axis in 0..<3 {low[axis]=min(low[axis],p[axis]);high[axis]=max(high[axis],p[axis])}
            changed=true
        }}}
    }
    return
}

// The block of a page: its own, or the one in file read into out.
@(private)
page_block_read :: proc(block:Page_Block,file:string,out:[]u8) -> (bytes:[]u8,ok:bool) {
    if block.own!=nil {return block.own,true}
    if file=="" || int(block.size)>len(out) {return}
    if serial.file_read_range(file,i64(block.offset),out[:block.size])!=.None {return}
    return out[:block.size],true
}

// The pages of a grid as a table of records and a column of the LZ blocks
// of the pages that are not uniform, stored as they are so that one page is
// read alone. A page in its block in file is copied from there. valid checks
// each value. quantize stores f32 values on the lattice of HEIGHT_STEP
// (page_code): a page in a block of its own, which keeps them as they were,
// is coded again.
// With keep, the grid keeps each block it makes (encoded), and a page that
// still holds the values of its kept block is not compressed again.
@(private)
grid_put_document :: proc(document:^asset.Document,types:^asset.Types,g:^Grid($T),pages_name,blocks_name:string,valid:proc "contextless" (value:T) -> bool,file:string,allocator:runtime.Allocator,keep:=false,quantize:=false) -> asset.Error where size_of(T)<=4 {
    if keep && len(g.encoded)!=len(g.pages) {
        for encoded in g.encoded {delete(encoded.block,allocator)}
        delete(g.encoded,allocator)
        error:runtime.Allocator_Error
        if g.encoded,error=make([]Page_Encoded,len(g.pages),allocator);error!=nil {return .Out_Of_Memory}
    }
    records,records_error:=make([]Page_Record,len(g.pages),allocator)
    if records_error!=nil {return .Out_Of_Memory}
    defer delete(records,allocator)
    blocks:=make([dynamic]u8,allocator)
    defer delete(blocks)
    reader:Page_Reader
    if !page_reader_init(&reader,allocator) {return .Out_Of_Memory}
    defer page_reader_destroy(&reader,allocator)
    writer:Page_Writer
    if !page_writer_init(&writer,allocator) {return .Out_Of_Memory}
    defer page_writer_destroy(&writer)
    decoded,decoded_error:=make([]T,PAGE_VALUES,allocator)
    if decoded_error!=nil {return .Out_Of_Memory}
    defer delete(decoded,allocator)
    for page,i in g.pages {
        if !valid(page.fill) {return .Invalid}
        values:=page.values
        block:[]u8
        extent,count:=grid_page_extent(g,i)
        if grid_absent(g,i) {
            read,read_ok:=page_block_read(g.blocks[i],file,reader.block)
            if !read_ok || !page_decode(read,g.blocks[i].hash,mem.slice_to_bytes(decoded[:count]),&reader.decoder,reader.coded) {return .IO}
            values=decoded[:count]
            if !quantize || g.blocks[i].own==nil {block=read}
        }
        fill:=page.fill
        when T==f32 {
            if quantize {
                fill=height_quantize(fill)
                if values!=nil {
                    for value,k in values {
                        if !valid(value) {return .Invalid}
                        decoded[k]=height_quantize(value)
                    }
                    values=decoded[:count]
                }
            }
        }
        if values!=nil {
            for value in values {if !valid(value) {return .Invalid}}
            fill=values[0]
            if page_uniform(values) {values=nil}
        }
        bits:u32
        (^T)(&bits)^=fill
        records[i]={fill=bits}
        if values==nil {continue}
        if block==nil && keep {
            raw:=base.hash64(mem.slice_to_bytes(values))
            kept:=&g.encoded[i]
            if kept.block==nil || kept.raw!=raw {
                encoded,ok:=page_encode(&writer,values,extent.x,quantize)
                if !ok {return .Out_Of_Memory}
                delete(kept.block,allocator)
                copied,error:=make([]u8,len(encoded),allocator)
                if error!=nil {kept^={};return .Out_Of_Memory}
                copy(copied,encoded)
                kept^={raw=raw,block=copied}
            }
            block=kept.block
        }
        if block==nil {
            ok:bool
            if block,ok=page_encode(&writer,values,extent.x,quantize);!ok {return .Out_Of_Memory}
        }
        records[i].offset,records[i].size,records[i].hash=u64(len(blocks)),u32(len(block)),base.hash64(block)
        if append(&blocks,..block)!=len(block) {return .Out_Of_Memory}
    }
    asset.document_put(document,types,pages_name,records) or_return
    asset.document_put(document,types,blocks_name,blocks[:],{.Bulk},.None) or_return
    return .None
}

// The pages a .terrain holds. paged leaves the values of the pages in their
// blocks in the file, read when they are needed (paging.odin); otherwise
// every page comes into memory now.
@(private)
grid_read_document :: proc(g:^Grid($T),file:^asset.Asset,types:^asset.Types,size:[3]int,pages_name,blocks_name:string,valid:proc "contextless" (value:T) -> bool,allocator:runtime.Allocator,paged:=false) -> bool where size_of(T)<=4 {
    records,e0:=asset.asset_rows(file,types,pages_name,"",Page_Record)
    counts:=grid_page_counts(size)
    if e0!=.None || len(records)!=counts.x*counts.y*counts.z {return false}
    table,found:=asset.asset_table(file,blocks_name)
    if !found || len(table.columns)!=1 {return false}
    entry:=asset.blob_chunk(&file.blob,table.columns[0].chunk)
    if entry.compression!=.None {return false}
    stored:=u64(entry.uncompressed_size)
    blocks:[]u8
    if !paged {
        e1:asset.Error
        if blocks,e1=asset.asset_rows(file,types,blocks_name,"",u8);e1!=.None || u64(len(blocks))!=stored {return false}
    }
    next:Grid(T)
    if !grid_init(&next,size,T{},allocator) {return false}
    ok:=false
    defer if !ok {grid_destroy(&next,allocator)}
    coded:[]u8
    error:runtime.Allocator_Error
    if paged {
        if next.blocks,error=make([]Page_Block,len(records),allocator);error!=nil {return false}
    } else {
        if coded,error=make([]u8,PAGE_BYTES_MAX,allocator);error!=nil {return false}
    }
    defer delete(coded,allocator)
    for record,i in records {
        bits:=record.fill
        fill:=(^T)(&bits)^
        if !valid(fill) {return false}
        next.pages[i].fill=fill
        if record.size==0 {continue}
        if record.offset>stored || u64(record.size)>stored-record.offset || int(record.size)>asset.pack_bound(PAGE_BYTES_MAX) {return false}
        if paged {
            next.blocks[i]={offset=entry.offset+record.offset,size=record.size,hash=record.hash}
            continue
        }
        _,count:=grid_page_extent(&next,i)
        page,made:=shared_make(T,count,allocator)
        if !made {return false}
        next.pages[i].values=page
        decoder,decoder_error:=asset.asset_decoder(file)
        if decoder_error!=.None || !page_decode(blocks[record.offset:][:record.size],record.hash,mem.slice_to_bytes(page),&decoder.lz,coded) {return false}
        for value in page {if !valid(value) {return false}}
    }
    grid_destroy(g,allocator)
    g^=next
    ok=true
    return true
}
