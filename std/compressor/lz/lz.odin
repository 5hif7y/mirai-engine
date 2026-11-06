package lz

import "base:intrinsics"
import "core:mem"
import "mirai:std/compressor"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor/lz/parse"
import "mirai:std/compressor/lz/match"

// LZ encoder: the output is the standard stream, the same bytes the reference encoder
// writes with default options. This file is the block framing: blocks of
// BLOCK_LEN raw bytes with one large quantum each, split into chunks the codec encodes; the
// find-all match finders of the optimal levels run here, one block ahead of the parse.

Level :: enum i8 {
    SuperFast=1, VeryFast, Fast, Normal, Optimal1, Optimal2, Optimal3, Optimal4, Optimal5,
}

Error :: enum u8 {None, Output_Too_Small, Out_Of_Memory, Invalid}

// Scratch reused across calls: the padded copy of the input and the output staging buffer. A
// zero Encoder takes the context allocator on its first call.
Encoder :: struct {
    allocator:mem.Allocator,
    input:[]u8,
    output:[]u8,
}

@(private) PAD :: 64
// Inputs up to this size are stored: the library does not compress them (RR_LZH_MIN_RAW_LEN and
// the default spaceSpeedTradeoffBytes).
@(private) STORED_MAX :: 256
@(private) MAX_LOCAL_DICTIONARY :: 16<<20

encoder_init :: proc(e:^Encoder, allocator:=context.allocator) -> Error {
    if e==nil {return .Invalid}
    e^=Encoder{allocator=allocator}
    return .None
}

encoder_destroy :: proc(e:^Encoder) {
    if e==nil {return}
    delete(e.input,e.allocator)
    delete(e.output,e.allocator)
    e.input,e.output=nil,nil
}

// The largest stream compress can write for size raw bytes.
compress_bound :: proc "contextless" (size:int) -> int {
    if size<=0 {return 0}
    blocks:=(size+compressor.BLOCK_LEN-1)/compressor.BLOCK_LEN
    return size+blocks*(compressor.BLOCK_HEADER_SIZE+compressor.QUANTUM_HEADER_MAX_SIZE+
        2*compressor.CHUNK_HEADER_SIZE)
}

// Compresses src into dst. Single-threaded and deterministic; an empty src writes nothing.
// piece_len, a multiple of BLOCK_LEN, cuts src into pieces of that many bytes, each a stream of
// its own that decodes without the others: the library's seekChunkReset with seekChunkLen.
compress :: proc(e:^Encoder, level:Level, src:[]u8, dst:[]u8, piece_len:=0) -> (size:int, error:Error) {
    if e==nil || level<.SuperFast || level>.Optimal5 {return 0,.Invalid}
    if piece_len<0 || piece_len%compressor.BLOCK_LEN!=0 {return 0,.Invalid}
    if e.allocator.procedure==nil {e.allocator=context.allocator}
    n:=len(src)
    if n==0 {return 0,.None}
    if n>=1<<30 {return 0,.Invalid}
    if n<=STORED_MAX {
        if len(dst)<n+compressor.BLOCK_HEADER_SIZE {return 0,.Output_Too_Small}
        put_block_header(raw_data(dst),compressor.DECODE_TYPE_LZ,true,true)
        copy(dst[compressor.BLOCK_HEADER_SIZE:],src)
        return n+compressor.BLOCK_HEADER_SIZE,.None
    }
    step:=piece_len>0 ? piece_len : n
    for at:=0;at<n;at+=step {
        size+=compress_piece(e,level,src[at:min(n,at+step)],dst[size:]) or_return
    }
    return size,.None
}

// One piece of a stream compress writes in pieces, past the check the reference
// encoder makes for small inputs: the pieces of a src of more
// than STORED_MAX bytes, each compressed apart and in order, are the bytes compress writes.
compress_piece :: proc(e:^Encoder, level:Level, src:[]u8, dst:[]u8) -> (size:int, error:Error) {
    if e==nil || level<.SuperFast || level>.Optimal5 || len(src)==0 || len(src)>=1<<30 {return 0,.Invalid}
    if e.allocator.procedure==nil {e.allocator=context.allocator}
    n:=len(src)
    bound:=compress_bound(n)
    if !grow(e,&e.input,n+PAD) || !grow(e,&e.output,bound+PAD) {return 0,.Out_Of_Memory}
    copy(e.input,src)
    mem.zero_slice(e.input[n:n+PAD])
    raw:=e.input[:n]
    arena:=entropy.arena_make(e.allocator)
    f:Framing
    f.arena=&arena
    f.level=i32(level)
    ok:=parse.setup(&f.parser,f.level,raw,&arena)
    if ok {configure(&f,&f.parser)}
    total:=-1
    if ok {
        f.huff_space=entropy.arena_alloc(&arena,u8,huff_space_size(f.chunk_len)+PAD)
        if f.huff_space!=nil {total=compress_whole(&f,raw,raw_data(e.output))}
    }
    parse.destroy(&f.parser,&arena)
    entropy.arena_free(&arena,f.huff_space)
    if arena.failed {return 0,.Out_Of_Memory}
    if total<=0 {return 0,.Invalid}
    if total>len(dst) {return 0,.Output_Too_Small}
    copy(dst,e.output[:total])
    return total,.None
}

@(private)
grow :: proc(e:^Encoder, buffer:^[]u8, size:int) -> bool {
    if len(buffer^)>=size {return true}
    delete(buffer^,e.allocator)
    buffer^=nil
    b,err:=make([]u8,size,e.allocator)
    if err!=nil || len(b)<size {return false}
    buffer^=b
    return true
}

// The fields of newlz_vtable the framing reads, and the LZ encoder they come from.
@(private)
Framing :: struct {
    arena:^entropy.Arena,
    level:i32, lambda:f32, entropy_flags:u32, chunk_len:int, try_huff_chunks:bool,
    decode_type:i32, finder:match.Finder_Kind, num_pairs:int, wants_dic_limit_splits:bool,
    parser:parse.Encoder,
    huff_space:[]u8,
}

@(private)
configure :: proc(f:^Framing, c:^parse.Encoder) {
    f.lambda=c.lambda
    f.entropy_flags=c.entropy_flags
    f.chunk_len=c.chunk_len
    f.try_huff_chunks=c.try_huff_chunks
    f.decode_type=c.decode_type
    f.finder=c.finder
    f.num_pairs=c.find_all_matches_num_pairs
    f.wants_dic_limit_splits=c.wants_dic_limit_splits
}

// newlz_literal_space_reserve_size: the scratch the whole-chunk entropy array is written to.
@(private)
huff_space_size :: proc "contextless" (chunk_len:int) -> int {return chunk_len+(chunk_len>>4)+256}

@(private)
padd :: #force_inline proc "contextless" (p:[^]u8, n:int) -> [^]u8 {
    return ([^]u8)(uintptr(p)+uintptr(n))
}
@(private)
pdiff :: #force_inline proc "contextless" (a, b:[^]u8) -> int {
    return int(uintptr(a))-int(uintptr(b))
}

@(private)
put24 :: #force_inline proc "contextless" (p:[^]u8, v:u32) {
    p[0],p[1],p[2]=u8(v>>16),u8(v>>8),u8(v)
}

@(private)
put_block_header :: proc "contextless" (p:[^]u8, decode_type:int, memcpy,reset:bool) {
    b:=u8(compressor.BLOCK_HEADER_VERSION_NIBBLE)
    if memcpy {b|=compressor.BLOCK_HEADER_MEMCPY}
    if reset {b|=compressor.BLOCK_HEADER_RESET}
    p[0]=b
    p[1]=u8(decode_type)
}

@(private)
is_memset :: proc "contextless" (p:[^]u8, n:int) -> bool #no_bounds_check {
    if n<=0 {return true}
    c:=p[0]
    for i in 1..<n {if p[i]!=c {return false}}
    return true
}

@(private)
encode_chunk :: proc(f:^Framing, dictionary_base:[^]u8, chunk_ptr:[^]u8, chunk_len:int,
    comp,comp_end:[^]u8, chunk_pos:int, chunk_type:^i32, J:^f32,
    deadlines:^entropy.LZ_Chunk_Deadlines, pairs:[^]match.Unpacked_Match_Pair) -> int {
    return parse.encode_chunk(&f.parser,f.arena,dictionary_base,chunk_ptr,chunk_len,comp,
        comp_end,chunk_pos,chunk_type,J,deadlines,pairs)
}

// newLZ_encode_block_vtable: the chunks of one block after its headers. Returns more than
// block_len when the block is better stored.
@(private)
encode_block :: proc(f:^Framing, dictionary_base:[^]u8, block_ptr:[^]u8, block_len:int,
    comp,comp_end:[^]u8, block_pos:int, pJ:^f32, matches:[^]match.Unpacked_Match_Pair) -> int {
    if block_len<compressor.MIN_CHUNK_LEN {return block_len+1}
    lambda:=f.lambda
    comp_ptr:=comp
    total_J:f32=0
    deadlines:entropy.LZ_Chunk_Deadlines
    for done:=0;done<block_len; {
        chunk_ptr:=padd(block_ptr,done)
        chunk_len:=min(block_len-done,f.chunk_len)
        pairs:[^]match.Unpacked_Match_Pair
        if matches!=nil {pairs=matches[done*f.num_pairs:]}
        if pdiff(comp_end,comp_ptr)<chunk_len+compressor.CHUNK_HEADER_SIZE {return block_len+1}
        raw_J:=compressor.CHUNK_HEADER_SIZE+entropy.speedfit_memcpy_array_j(lambda,chunk_len)
        entropy.speedfit_deadlines_lz(&deadlines,chunk_len)
        if chunk_len<compressor.HUFF_ARRAY_MIN_SIZE {
            put24(comp_ptr,u32(chunk_len)|compressor.CHUNK_COMPRESSED)
            intrinsics.mem_copy_non_overlapping(padd(comp_ptr,3),chunk_ptr,chunk_len)
            comp_ptr=padd(comp_ptr,3+chunk_len)
            total_J+=raw_J
            done+=chunk_len
            continue
        }
        if is_memset(chunk_ptr,chunk_len) {
            memset_J:=entropy.LAGRANGE_COST_INVALID
            n:=entropy.put_array_memset(comp_ptr,comp_end,chunk_ptr[:chunk_len],f.entropy_flags,
                lambda,&memset_J)
            if n<=0 {return block_len+1}
            total_J+=memset_J
            comp_ptr=padd(comp_ptr,n)
            done+=chunk_len
            continue
        }
        chunk_pos:=block_pos+done
        header_ptr:=comp_ptr
        comp_ptr=padd(comp_ptr,compressor.CHUNK_HEADER_SIZE)
        chunk_type:i32=-1
        chunk_J:=entropy.LAGRANGE_COST_INVALID
        chunk_comp_len:=encode_chunk(f,dictionary_base,chunk_ptr,chunk_len,comp_ptr,comp_end,
            chunk_pos,&chunk_type,&chunk_J,&deadlines,pairs)
        if f.arena.failed {return block_len+1}
        chunk_J+=compressor.CHUNK_HEADER_SIZE
        huff_len:=chunk_len
        huff_J:=entropy.LAGRANGE_COST_INVALID
        if f.try_huff_chunks {
            huff_J=min(chunk_J,raw_J)
            space:=raw_data(f.huff_space)
            huff_len=entropy.put_array(space,padd(space,huff_space_size(f.chunk_len)),
                chunk_ptr[:chunk_len],f.entropy_flags,lambda,&huff_J,deadlines.literals_only,
                f.arena,int(f.level))
            if huff_len<=0 || huff_len>=chunk_len {huff_J=entropy.LAGRANGE_COST_INVALID}
        }
        if chunk_J<raw_J && chunk_J<=huff_J && chunk_comp_len<chunk_len {
            put24(header_ptr,u32(chunk_comp_len)|compressor.CHUNK_COMPRESSED|
                u32(chunk_type)<<compressor.CHUNK_TYPE_SHIFT)
            total_J+=chunk_J
        } else if huff_J<raw_J {
            comp_ptr=header_ptr
            intrinsics.mem_copy_non_overlapping(comp_ptr,raw_data(f.huff_space),huff_len)
            chunk_comp_len=huff_len
            total_J+=huff_J
        } else {
            chunk_comp_len=chunk_len
            intrinsics.mem_copy_non_overlapping(comp_ptr,chunk_ptr,chunk_len)
            put24(header_ptr,u32(chunk_len)|compressor.CHUNK_COMPRESSED)
            total_J+=raw_J
        }
        comp_ptr=padd(comp_ptr,chunk_comp_len)
        done+=chunk_len
    }
    pJ^=total_J
    return pdiff(comp_ptr,comp)
}

// newlz_compress_vtable_block_outer: block header, large quantum header and the chunks, or a
// memset quantum, or the stored block when compressing does not pay.
@(private)
compress_block :: proc(f:^Framing, comp:[^]u8, raw_ptr:[^]u8, block_pos:int, block_len:int,
    reset:bool, dictionary_base:[^]u8, matches:[^]match.Unpacked_Match_Pair) -> int {
    comp_end:=padd(comp,compress_bound(block_len))
    put_block_header(comp,int(f.decode_type),false,reset)
    qh:=padd(comp,compressor.BLOCK_HEADER_SIZE)
    if is_memset(raw_ptr,block_len) {
        put24(qh,compressor.QUANTUM_SPECIAL_MEMSET<<compressor.QUANTUM_FLAG_SHIFT|compressor.QUANTUM_COMP_LEN_MASK)
        qh[3]=raw_ptr[0]
        return compressor.BLOCK_HEADER_SIZE+4
    }
    body:=padd(qh,compressor.QUANTUM_HEADER_SIZE)
    block_J:=entropy.LAGRANGE_COST_INVALID
    comp_len:=encode_block(f,dictionary_base,raw_ptr,block_len,body,comp_end,block_pos,&block_J,
        matches)
    raw_J:=compressor.CHUNK_HEADER_SIZE+entropy.speedfit_memcpy_array_j(f.lambda,block_len)
    if comp_len>=block_len || block_J>=raw_J {
        put_block_header(comp,int(f.decode_type),true,reset)
        intrinsics.mem_copy_non_overlapping(padd(comp,compressor.BLOCK_HEADER_SIZE),raw_ptr,block_len)
        return compressor.BLOCK_HEADER_SIZE+block_len
    }
    put24(qh,u32(comp_len-1))
    return compressor.BLOCK_HEADER_SIZE+compressor.QUANTUM_HEADER_SIZE+comp_len
}

// newlz_compress_vtable_sub: the blocks of raw[0:raw_len), with the finder (if any) filling the
// match pairs of each block just before it is parsed. Returns the comp length or -1.
@(private)
compress_sub :: proc(f:^Framing, raw:[^]u8, raw_len:int, comp:[^]u8, dictionary_base:[^]u8,
    zero_pos:[^]u8, finder:match.Incremental_Finder) -> int {
    matches:[]match.Unpacked_Match_Pair
    if finder!=nil {
        matches=entropy.arena_alloc(f.arena,match.Unpacked_Match_Pair,
            min(compressor.BLOCK_LEN,raw_len)*f.num_pairs)
        if matches==nil {return -1}
    }
    defer entropy.arena_free(f.arena,matches)
    comp_ptr:=comp
    for done:=0;done<raw_len; {
        block_len:=min(compressor.BLOCK_LEN,raw_len-done)
        if finder!=nil {
            if match.incremental_process_chunk(finder,block_len,matches,f.num_pairs)<0 {return -1}
        }
        raw_ptr:=padd(raw,done)
        reset:=pdiff(raw_ptr,dictionary_base)==0
        n:=compress_block(f,comp_ptr,raw_ptr,pdiff(raw_ptr,zero_pos),block_len,reset,
            dictionary_base,raw_data(matches))
        if f.arena.failed {return -1}
        comp_ptr=padd(comp_ptr,n)
        done+=block_len
    }
    return pdiff(comp_ptr,comp)
}

// newlz_compress_vtable for an input without dictionary. Above the local dictionary size the
// suffix trie is rebuilt over windows of half of it, with a long range matcher for what the
// window no longer sees. The parse still takes the whole input as its dictionary base, as the
// library does (its source passes the window start).
@(private)
compress_whole :: proc(f:^Framing, raw:[]u8, comp:[^]u8) -> int {
    base:=raw_data(raw)
    n:=len(raw)
    if f.finder==.None {return compress_sub(f,base,n,comp,base,base,nil)}
    if n<=compressor.BLOCK_LEN {
        finder:=match.incremental_create(f.finder,base,n,0,nil,f.arena)
        if finder==nil {return -1}
        defer match.incremental_release(&finder,f.arena)
        return compress_sub(f,base,n,comp,base,base,finder)
    }
    max_local:=MAX_LOCAL_DICTIONARY
    if !f.wants_dic_limit_splits {max_local=max(max_local,1<<26)}
    max_sub:=n
    cascade:^match.Lrm_Cascade
    if max_local<n {
        max_sub=max_local/2
        if f.level>=i32(Level.Optimal1) {
            chunks:=(n+max_sub-1)/max_sub
            last_chunk_dic_start:=chunks*max_sub-max_local
            cascade=match.lrm_create_cascade_incremental(base,last_chunk_dic_start,match.LRM_STEP,
                match.LRM_JUMP_BITS,0,max_sub,match.LRM_HASH_LENGTH,f.arena)
            if cascade==nil {return -1}
        }
    }
    defer match.lrm_destroy_cascade(cascade)
    total:=0
    for pos:=0;pos<n; {
        remaining:=n-pos
        cur:=min(remaining,max_sub)
        if pos==0 {cur=min(remaining,max_local)}
        if remaining<=(max_sub*5)/4 {cur=remaining}
        backup:=0
        if cur<max_local {backup=min(pos,max_sub,max_local-cur)}
        raw_ptr:=padd(base,pos)
        start:=padd(raw_ptr,-backup)
        set:match.Lrm_Set
        lrm_set:^match.Lrm_Set
        if cascade!=nil && backup<pos {
            if !match.lrm_cascade_get_set_align_update_incremental(cascade,&set,start,raw_ptr) {
                return -1
            }
            lrm_set=&set
        }
        finder:=match.incremental_create(f.finder,start,backup+cur,backup,lrm_set,f.arena)
        if finder==nil {return -1}
        k:=compress_sub(f,raw_ptr,cur,padd(comp,total),base,base,finder)
        match.incremental_release(&finder,f.arena)
        if k<0 {return -1}
        total+=k
        pos+=cur
    }
    return total
}
