package entropy

import "mirai:std/compressor"

// Entropy-coded byte arrays. Every put_array procedure writes a whole array (header included)
// at [to,to_end) and returns its size, or -1. *pJ carries the J to beat: an array is written
// only when its J = bytes + lambda*decode cycles is lower, and then *pJ is updated. Callers
// start *pJ at LAGRANGE_COST_INVALID. The uncompressed array always fits in from_len+3 bytes.

put_array_uncompressed :: proc "contextless" (to:[^]u8, to_end:[^]u8, from:[]u8) -> int {
    from_len:=len(from)
    if from_len>compressor.ARRAY_SIZE_MASK {return -1}
    if from_len+3>ptr_diff(to_end,to) {return -1}
    p:=put_array_uncomp_header(to,from_len)
    copy_bytes(p,raw_data(from),from_len)
    return from_len+3
}

put_array_memset :: proc "contextless" (to:[^]u8, to_end:[^]u8, from:[]u8, flags:u32, lambda:f32,
    pJ:^f32) -> int {
    from_len:=len(from)
    if from_len<6 {
        pJ^=f32(from_len)+3
        return put_array_uncompressed(to,to_end,from)
    }
    if flags&ARRAY_FLAG_ALLOW_RLE_MEMSET!=0 {
        RLE_MEMSET_COMPLEN :: 6
        if ptr_diff(to_end,to)<RLE_MEMSET_COMPLEN {return -1}
        J:=RLE_MEMSET_COMPLEN+lambda*speedfit_memcpy(from_len)
        if pJ^<=J {return -1}
        pJ^=J
        to[5]=from[0]
        p:=put_array_comp_header(to,compressor.ARRAY_TYPE_RLE,from_len,1)
        return ptr_diff(p,to)
    }
    HUFF_MEMSET_COMPLEN :: 8
    if ptr_diff(to_end,to)<HUFF_MEMSET_COMPLEN {return -1}
    J:=HUFF_MEMSET_COMPLEN+lambda*speedfit_memcpy(from_len)
    if pJ^<=J {return -1}
    pJ^=J
    p:=put_array_huff3_memset(to,from_len,from[0])
    return ptr_diff(p,to)
}

// put_array with the histogram of from already counted; from_len in [32, 1<<18].
put_array_histo :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, flags:u32,
    lambda:f32,
    pJ:^f32, deadline_t:f32, arena:^Arena, compression_level:int) -> int {
    from_len:=len(from)
    if from_len>compressor.ARRAY_SIZE_MASK+1 {return -1}
    if ptr_diff(to_end,to)<6 {return -1}
    highest:=find_max_u32_256(histogram)
    if from_len>0 && highest==u32(from_len) {
        return put_array_memset(to,to_end,from,flags,lambda,pJ)
    }
    J_raw:=f32(from_len)+3
    min_J:=pJ^<J_raw ? pJ^ : J_raw
    comp_len:=from_len
    array_type:=compressor.ARRAY_TYPE_UNCOMPRESSED
    J_comp:=LAGRANGE_COST_INVALID
    try_compression:=true
    if compression_level<3 && highest<u32(from_len>>7) {try_compression=false}
    if try_compression {
        if flags&ARRAY_FLAG_ALLOW_RLE!=0 {
            rle_J_add:=5+lambda*speedfit_rle(from_len)
            must_be_under:=int(min_J-rle_J_add)
            target:=ptr_diff(to_end,to)-5
            target=min(target,must_be_under)
            if target>0 {
                buf:=arena_alloc(arena,u8,target)
                if buf==nil {return -1}
                rleJ:=LAGRANGE_COST_INVALID
                n:=put_array_rle(raw_data(buf),raw_data(buf)[target:],from,lambda,&rleJ,arena,
                    flags,compression_level)
                if n>=0 && n<=target && rleJ<min_J {
                    copy_bytes(to[5:],raw_data(buf),n)
                    array_type=compressor.ARRAY_TYPE_RLE
                    comp_len=n
                    J_comp=rleJ
                    min_J=min(min_J,J_comp)
                }
                arena_free(arena,buf)
            }
        }
        if from_len>=compressor.HUFF_ARRAY_MIN_SIZE {
            {
                huff_J:=min_J
                huff_type:u32=0
                n:=put_array_huff(to[5:],to_end,from,histogram,lambda,&huff_J,deadline_t,
                    &huff_type,flags,arena,compression_level)
                if n>from_len {
                    J_comp=LAGRANGE_COST_INVALID
                } else if n>=0 {
                    array_type=int(huff_type)
                    comp_len=n
                    J_comp=huff_J
                    min_J=J_comp
                }
            }
            if flags&ARRAY_FLAG_ALLOW_TANS!=0 {
                tans_J:=min_J
                n:=put_array_tans(to[5:],to_end,from,histogram,lambda,&tans_J,arena)
                if n>=0 {
                    array_type=compressor.ARRAY_TYPE_TANS
                    comp_len=n
                    J_comp=tans_J
                    min_J=tans_J
                }
            }
            if flags&ARRAY_FLAG_ALLOW_SPLIT!=0 {
                if J_comp<pJ^ || from_len<128*1024 || compression_level>=9 {
                    split_J:=LAGRANGE_COST_INVALID
                    n:=put_array_sub_split(to[5:],to_end,from,histogram,arena,compression_level,
                        flags,lambda,min_J,&split_J)
                    if n>=0 {
                        array_type=compressor.ARRAY_TYPE_SPLIT
                        comp_len=n
                        J_comp=split_J
                        min_J=J_comp
                    }
                }
            }
        }
    }
    if J_raw<=J_comp {
        if pJ^<=J_raw {return -1}
        if from_len>compressor.ARRAY_SIZE_MASK {return -1}
        if from_len+3>ptr_diff(to_end,to) {return -1}
        p:=put_array_uncomp_header(to,from_len)
        copy_bytes(p,raw_data(from),from_len)
        pJ^=J_raw
        return from_len+3
    }
    p:=put_array_comp_header(to,array_type,from_len,comp_len)
    pJ^=J_comp
    return ptr_diff(p,to)
}

// Writes from as the cheapest array type the flags allow. optional_histo, when given, receives
// the histogram of from; it is left untouched when from is no longer than HUFF_ARRAY_MIN_SIZE.
put_array :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, flags:u32, lambda:f32, pJ:^f32, deadline_t:f32,
    arena:^Arena, compression_level:int, optional_histo:^[256]u32=nil) -> int {
    if len(from)<=compressor.HUFF_ARRAY_MIN_SIZE {
        pJ^=3+f32(len(from))
        return put_array_uncompressed(to,to_end,from)
    }
    histo:[256]u32
    count_histo_array_u8(from,histo[:])
    if optional_histo!=nil {optional_histo^=histo}
    return put_array_histo(to,to_end,from,&histo,flags,lambda,pJ,deadline_t,arena,compression_level)
}

// Rewrites an array just written at comp with the 2- or 3-byte small header when it fits.
// Returns the new size and lowers *pJ by the bytes saved.
reput_array_small :: proc "contextless" (comp:[^]u8, array_comp_len:int, pJ:^f32) -> int {
    if array_comp_len>0xFFF+5 || array_comp_len<3 {return array_comp_len}
    first:=comp[0]
    if first>=0x80 {return array_comp_len}
    array_type:=u32(first>>4)
    if array_type==compressor.ARRAY_TYPE_UNCOMPRESSED {
        raw_len:=int(u32(comp[0])<<16|u32(comp[1])<<8|u32(comp[2]))&compressor.ARRAY_SIZE_MASK
        if raw_len>0xFFF || raw_len+3!=array_comp_len {return array_comp_len}
        h:=u16(raw_len)|0x8000
        comp[0]=u8(h>>8);comp[1]=u8(h)
        copy_bytes(comp[2:],comp[3:],raw_len)
        pJ^-=1
        return raw_len+2
    }
    if array_comp_len<5 {return array_comp_len}
    h64:=u64(comp[0])<<32|u64(comp[1])<<24|u64(comp[2])<<16|u64(comp[3])<<8|u64(comp[4])
    data_comp_len:=int(h64&compressor.ARRAY_SIZE_MASK)
    raw_len:=int((h64>>compressor.ARRAY_SIZE_BITS)&compressor.ARRAY_SIZE_MASK)+1
    if data_comp_len+5!=array_comp_len || data_comp_len<=0 || raw_len<=data_comp_len {
        return array_comp_len
    }
    if data_comp_len>compressor.ARRAY_SMALL_SIZE_MASK {return array_comp_len}
    packed_raw_len:=raw_len-data_comp_len-1
    if packed_raw_len>compressor.ARRAY_SMALL_SIZE_MASK {return array_comp_len}
    header:=u32(0x80<<16)|(array_type<<20)|(u32(packed_raw_len)<<compressor.ARRAY_SMALL_SIZE_BITS)
    header|=u32(data_comp_len)
    comp[0]=u8(header>>16);comp[1]=u8(header>>8);comp[2]=u8(header)
    copy_bytes(comp[3:],comp[5:],data_comp_len)
    pJ^-=2
    return data_comp_len+3
}

put_array_small_allowed :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, flags:u32, lambda:f32, pJ:^f32,
    deadline_t:f32, arena:^Arena, compression_level:int, optional_histo:^[256]u32=nil) -> int {
    n:=put_array(to,to_end,from,flags,lambda,pJ,deadline_t,arena,compression_level,optional_histo)
    if n<0 {return -1}
    return reput_array_small(to,n,pJ)
}
