package compressor

import "base:intrinsics"
import "base:runtime"

// Decoder of LZ streams. Safe for any
// input: it never reads outside src nor writes outside dst, and never allocates.

Error :: enum u8 {
    None,
    Truncated,        // src ends before dst is full
    Corrupt,          // a header, table or match no encoder writes
    Unsupported,      // another codec, a legacy one or a newer header version
    Output_Too_Small, // a block holds more than what is left of dst
    Out_Of_Memory,
}

// All the scratch a chunk needs, allocated once.
Decoder :: struct {
    scratch:[]u8,
    allocator:runtime.Allocator,
}

@(private="file") SCRATCH_ALIGN :: 64

// Takes the paths without BMI2 or SSE4 on x64, to test them.
@(private) FORCE_GENERIC :: #config(COMPRESSOR_FORCE_GENERIC,false)

decoder_init :: proc(d:^Decoder,allocator:=context.allocator) -> Error {
    d^={}
    size:=scratch_size(CHUNK_LEN)+SCRATCH_ALIGN+256
    buf,err:=make([]u8,size,allocator)
    if err!=nil {return .Out_Of_Memory}
    d.scratch=buf
    d.allocator=allocator
    return .None
}

decoder_destroy :: proc(d:^Decoder) {
    if d==nil {return}
    if d.scratch!=nil {delete(d.scratch,d.allocator)}
    d^={}
}

@(private="file")
whole_match_offset :: proc "contextless" (p,end:[^]u8) -> (offset:int,used:int) #no_bounds_check {
    if ptr_diff(end,p)<2 {return 0,-1}
    MOD :: 1<<WHOLE_MATCH_BITS1
    UPPER :: (1<<16)-MOD
    word:=int(load16be(p))
    if word>=MOD {return word-MOD,2}
    q:=p[2:]
    top,shift:=0,0
    for {
        if uintptr(q)>=uintptr(end) {return 0,-1}
        b:=int(q[0])-(1<<WHOLE_MATCH_BITS2);q=q[1:]
        if b>=0 {
            top+=b<<uint(shift)
            break
        }
        top+=(b+256)<<uint(shift)
        shift+=WHOLE_MATCH_BITS2
        if shift>=56 {return 0,-1}
    }
    return (top<<WHOLE_MATCH_BITS1)+word+UPPER,ptr_diff(q,p)
}

// What the headers of a block say.
@(private)
Block :: struct {
    reset:bool,
    data:int, // where its payload starts in the stream
    size:int, // of its payload: block_len stored, 0 a whole match or a memset, else a quantum
    match_offset:int,
    memset_value:u8,
}

// The headers of the block at at of a stream of comp_len bytes, which decodes to block_len bytes
// (BLOCK_LEN, or what is left of dst). The first block of a stream resets.
@(private)
block_read :: proc "contextless" (
    comp:[^]u8,comp_len,at:int,block_len:int,first:bool,
) -> (b:Block,error:Error) #no_bounds_check {
    at:=at
    if comp_len-at<BLOCK_HEADER_SIZE {return b,.Truncated}
    h0,h1:=comp[at],comp[at+1]
    if h0&0xF!=BLOCK_HEADER_VERSION_NIBBLE {return b,.Unsupported}
    if (h0>>4)&3!=0 {return b,.Unsupported}
    decode_type:=int(h1&BLOCK_HEADER_TYPE_MASK)
    if decode_type>=DECODE_TYPE_COUNT {return b,.Corrupt}
    has_crc:=h1&BLOCK_HEADER_CRC!=0
    b.reset=h0&BLOCK_HEADER_RESET!=0
    if first && !b.reset {return b,.Corrupt}
    at+=BLOCK_HEADER_SIZE
    if h0&BLOCK_HEADER_MEMCPY!=0 {
        if comp_len-at<block_len {return b,.Truncated}
        b.data,b.size=at,block_len
        return b,.None
    }
    if decode_type!=DECODE_TYPE_LZ {return b,.Unsupported}
    // quantum header
    avail:=comp_len-at
    hdr_end:=comp[at+min(avail,QUANTUM_HEADER_MAX_SIZE):]
    q:=comp[at:]
    if avail<3 {return b,.Truncated}
    header:=int(load24be(q))
    hp:=q[3:]
    if header&QUANTUM_COMP_LEN_MASK==QUANTUM_COMP_LEN_MASK {
        switch header>>QUANTUM_FLAG_SHIFT {
        case QUANTUM_SPECIAL_WHOLE_MATCH:
            off,used:=whole_match_offset(hp,hdr_end)
            if used<0 {return b,avail<QUANTUM_HEADER_MAX_SIZE ? .Truncated : .Corrupt}
            hp=hp[used:]
            b.match_offset=off+1
            if b.match_offset<=1 {return b,.Corrupt}
        case QUANTUM_SPECIAL_MEMSET:
            if uintptr(hp)>=uintptr(hdr_end) {return b,.Truncated}
            b.memset_value=hp[0];hp=hp[1:]
        case QUANTUM_SPECIAL_MEMCPY:
            b.size=block_len
            if has_crc {
                if ptr_diff(hdr_end,hp)<3 {return b,.Truncated}
                hp=hp[3:]
            }
        case:
            return b,.Corrupt
        }
    } else {
        b.size=(header&QUANTUM_COMP_LEN_MASK)+1
        if has_crc {
            if ptr_diff(hdr_end,hp)<3 {return b,.Truncated}
            hp=hp[3:]
        }
    }
    at+=ptr_diff(hp,q)
    if b.size>block_len {return b,block_len<BLOCK_LEN ? .Output_Too_Small : .Corrupt}
    if b.size>comp_len-at {return b,.Truncated}
    b.data=at
    return b,.None
}

// Decodes a whole stream into dst, which is exactly its raw size.
decompress :: proc(d:^Decoder,src:[]u8,dst:[]u8) -> (written:int,error:Error) #no_bounds_check {
    if len(dst)==0 {return 0,.None}
    if d==nil || len(d.scratch)<scratch_size(
        CHUNK_LEN)+SCRATCH_ALIGN {return 0,.Out_Of_Memory}
    scratch:=align_up(raw_data(d.scratch),SCRATCH_ALIGN)
    out:=raw_data(dst)
    comp:=raw_data(src)
    pos,at,reset_pos:=0,0,0
    for pos<len(dst) {
        block_len:=min(BLOCK_LEN,len(dst)-pos)
        b,block_error:=block_read(comp,len(src),at,block_len,pos==0)
        if block_error!=.None {return pos,block_error}
        if b.reset {reset_pos=pos}
        at=b.data
        if b.size==block_len {
            intrinsics.mem_copy(out[pos:],comp[at:],block_len)
        } else if b.size==0 {
            if b.match_offset>0 {
                if b.match_offset>pos-reset_pos {return pos,.Corrupt}
                to:=out[pos:]
                from:=to[-b.match_offset:]
                if b.match_offset<block_len {
                    for i in 0..<block_len {to[i]=from[i]}
                } else {
                    intrinsics.mem_copy_non_overlapping(to,from,block_len)
                }
            } else {
                fill(out[pos:],b.memset_value,block_len)
            }
        } else {
            used:=lz_decode_quantum(out,pos,pos+block_len,comp[at:],b.size,
                pos-reset_pos,scratch,scratch_size(len(dst)))
            if used!=b.size {return pos,.Corrupt}
        }
        at+=b.size
        pos+=block_len
    }
    return pos,.None
}

// Where a stream restarts: a block with the reset flag, which decodes without the bytes before
// it, at src in the stream and at dst in what it decodes to.
Piece :: struct {src,dst:int}

// The pieces of a stream that decodes to dst_len bytes, from its first block, into out; count is
// how many it has, also when out holds fewer. Each decodes on its own with decompress, from its
// src to the next one's, into its bytes of dst: what the whole stream decodes to. Reads only the
// headers of the blocks.
pieces :: proc(src:[]u8,dst_len:int,out:[]Piece) -> (count:int,error:Error) {
    pos,at:=0,0
    for pos<dst_len {
        block_len:=min(BLOCK_LEN,dst_len-pos)
        b,block_error:=block_read(raw_data(src),len(src),at,block_len,pos==0)
        if block_error!=.None {return count,block_error}
        if b.reset {
            if count<len(out) {out[count]={at,pos}}
            count+=1
        }
        at=b.data+b.size
        pos+=block_len
    }
    return count,.None
}
