package compressor

import "base:intrinsics"

// Decodes an entropy array at from and returns the bytes it used, or -1.
// to^ is where a compressed array is written; an uncompressed one is pointed
// at in place unless force_copy. When to^ is scratch, scratch is skipped past
// the output.
@(private)
get_array :: #force_inline proc "contextless" (
    to:^[^]u8,from,from_end:[^]u8,to_len:^int,to_len_max:int,force_copy:bool,
    scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    avail:=ptr_diff(from_end,from)
    if avail<2 {return -1}
    first:=from[0]
    if first>=ARRAY_SMALL_FLAG {
        if (first>>4)&7==ARRAY_TYPE_UNCOMPRESSED {
            n:=int(load16be(from)&0xFFF)
            if n>to_len_max || n>avail-2 {return -1}
            if force_copy {intrinsics.mem_copy(to^,from[2:],n)} else {to^=from[2:]}
            to_len^=n
            return n+2
        }
    } else {
        if avail<4 {
            if avail==3 {
                if load24be(from)!=0 {return -1}
                to^=nil
                to_len^=0
                return 3
            }
            return -1
        }
        if first>>4==ARRAY_TYPE_UNCOMPRESSED {
            header:=load24be(from)
            n:=int(header&ARRAY_SIZE_MASK)
            if header>>ARRAY_SIZE_BITS!=0 {return -1}
            if n>to_len_max || n>avail-3 {return -1}
            if force_copy {intrinsics.mem_copy(to^,from[3:],n)} else {to^=from[3:]}
            to_len^=n
            return n+3
        }
    }
    return get_array_comp(u32(first>>4)&(first>=ARRAY_SMALL_FLAG ? 7 : 15),to,from,from_end,
        to_len,to_len_max,scratch,scratch_end)
}

// The raw and compressed sizes of the array at from, without decoding it.
@(private)
get_arraylens :: proc "contextless" (
    from,from_end:[^]u8,to_len:^int,to_len_max:int,
) -> int #no_bounds_check {
    avail:=ptr_diff(from_end,from)
    if avail<2 {return -1}
    first:=from[0]
    kind:=u32(first>>4)
    if first>=ARRAY_SMALL_FLAG {
        kind&=7
        if kind==ARRAY_TYPE_UNCOMPRESSED {
            n:=int(load16be(from)&0xFFF)
            if n>to_len_max || n>avail-2 {return -1}
            to_len^=n
            return n+2
        }
        if avail<4 {return -1}
        header:=load24be(from)
        if kind>=ARRAY_TYPE_COUNT {return -1}
        comp_len:=int(header&ARRAY_SMALL_SIZE_MASK)
        if comp_len>avail-3 {return -1}
        n:=int((header>>ARRAY_SMALL_SIZE_BITS)&ARRAY_SMALL_SIZE_MASK)+comp_len+1
        if n>to_len_max {return -1}
        to_len^=n
        return comp_len+3
    }
    if avail<4 {
        if avail==3 {
            if load24be(from)!=0 {return -1}
            to_len^=0
            return 3
        }
        return -1
    }
    if kind==ARRAY_TYPE_UNCOMPRESSED {
        header:=load24be(from)
        n:=int(header&ARRAY_SIZE_MASK)
        if header>>ARRAY_SIZE_BITS!=0 {return -1}
        if n>to_len_max || n>avail-3 {return -1}
        to_len^=n
        return n+3
    }
    if kind>=ARRAY_TYPE_COUNT {return -1}
    if avail<5 {return -1}
    header:=u64(from[0])<<32|u64(load32be(from[1:]))
    comp_len:=int(header&ARRAY_SIZE_MASK)
    if comp_len>avail-5 {return -1}
    n:=int((header>>ARRAY_SIZE_BITS)&ARRAY_SIZE_MASK)+1
    if n>to_len_max || comp_len>=n {return -1}
    to_len^=n
    return comp_len+5
}

@(private)
get_array_comp :: proc "contextless" (
    kind:u32,to:^[^]u8,from,from_end:[^]u8,to_len:^int,to_len_max:int,scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    if kind>=ARRAY_TYPE_COUNT {return -1}
    scratch:=scratch
    avail:=ptr_diff(from_end,from)
    p:=from
    comp_len,n:int
    if from[0]>=ARRAY_SMALL_FLAG {
        if avail<4 {return -1}
        header:=load24be(from)
        p=from[3:]
        comp_len=int(header&ARRAY_SMALL_SIZE_MASK)
        if comp_len>avail-3 {return -1}
        n=int((header>>ARRAY_SMALL_SIZE_BITS)&ARRAY_SMALL_SIZE_MASK)+comp_len+1
        if n>to_len_max {return -1}
    } else {
        if avail<5 {return -1}
        header:=u64(from[0])<<32|u64(load32be(from[1:]))
        p=from[5:]
        comp_len=int(header&ARRAY_SIZE_MASK)
        if comp_len>avail-5 {return -1}
        n=int((header>>ARRAY_SIZE_BITS)&ARRAY_SIZE_MASK)+1
        if n>to_len_max || comp_len>=n {return -1}
    }
    if to^==scratch {
        if ptr_diff(scratch_end,scratch)<n {return -1}
        scratch=scratch[n:]
    }
    used:int
    switch kind {
    case ARRAY_TYPE_SPLIT: used=get_array_split(p,comp_len,to^,n,scratch,scratch_end)
    case ARRAY_TYPE_RLE: used=get_array_rle(p,comp_len,to^,n,scratch,scratch_end)
    case ARRAY_TYPE_TANS: used=get_array_tans(p,comp_len,to^,n,scratch,scratch_end)
    case: used=get_array_huff(p,comp_len,to^,n,kind==ARRAY_TYPE_HUFF6)
    }
    if used!=comp_len {return -1}
    to_len^=n
    return ptr_diff(p,from)+comp_len
}

@(private="file")
get_array_split :: proc "contextless" (
    comp:[^]u8,comp_len:int,to:[^]u8,to_len:int,scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    if comp_len<6 {return -1}
    end:=comp[comp_len:]
    splits:=int(comp[0])
    indexed:=splits&0x80!=0
    splits&=0x7f
    if splits<2 {return -1}
    if indexed {
        ptrs:[1][^]u8
        lens:[1]int
        total:int
        used:=get_multiarray(comp,end,to,to[to_len:],ptrs[:],lens[:],&total,true,scratch,
            scratch_end)
        if used<0 || lens[0]!=to_len {return -1}
        return used
    }
    p:=comp[1:]
    out:=to
    out_end:=to[to_len:]
    for _ in 0..<splits {
        n:int
        used:=get_array(&out,p,end,&n,ptr_diff(out_end,out),true,scratch,scratch_end)
        if used<0 {return -1}
        out=out[n:]
        p=p[used:]
    }
    if out!=out_end {return -1}
    return ptr_diff(p,comp)
}

// Arrays spliced from intervals of entropy arrays (indexed splits).
@(private="file")
get_multiarray :: proc "contextless" (
    comp,comp_end:[^]u8,to_mem,to_mem_end:[^]u8,to_ptrs:[][^]u8,to_lens:[]int,total_len:^int,
    force_copy:bool,scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    if ptr_diff(comp_end,comp)<3 {return -1}
    scratch:=scratch
    to_mem_end:=to_mem_end
    p:=comp
    control:=int(p[0])
    p=p[1:]
    if control<0x80 {return -1}
    num_entropy:=control&63
    identity:=num_entropy==0
    num_arrays:=len(to_ptrs)
    if identity {num_entropy=num_arrays}
    if to_mem==scratch {
        space:=(ptr_diff(scratch_end,scratch)-ARRAY_INTERNAL_MAX_SCRATCH)/2
        scratch=scratch[space:]
        to_mem_end=scratch
    }
    out,out_end:[^]u8
    out_is_scratch:bool
    if identity {
        out,out_end=to_mem,to_mem_end
    } else {
        out,out_end=scratch,scratch_end
        out_is_scratch=true
    }
    total:=0
    entropy_ptrs:[MULTIARRAY_MAX_ARRAYS+1][^]u8 = ---
    entropy_lens:[MULTIARRAY_MAX_ARRAYS+1]int = ---
    for i in 0..<num_entropy {
        n:int
        lit:=out
        used:=get_array(&lit,p,comp_end,&n,ptr_diff(out_end,out),identity && force_copy,scratch,
            scratch_end)
        if used<0 {return -1}
        entropy_ptrs[i]=lit
        entropy_lens[i]=n
        out=out[n:]
        if out_is_scratch {scratch=scratch[n:]}
        total+=n
        p=p[used:]
    }
    total_len^=total
    if identity {
        for i in 0..<num_arrays {
            to_ptrs[i]=entropy_ptrs[i]
            to_lens[i]=entropy_lens[i]
        }
        return ptr_diff(p,comp)
    }
    if ptr_diff(comp_end,p)<3 {return -1}
    varbits_len:=int(load16(p))
    p=p[2:]
    packed_flag:=varbits_len&(1<<15)!=0
    varbits_len&=0x3FFF
    num_indices:int
    if get_arraylens(p,comp_end,&num_indices,total)<=0 {return -1}
    num_intervals:=num_indices-num_arrays
    if num_intervals<1 {return -1}
    lenlog2_space:=scratch
    if ptr_diff(scratch_end,scratch)<num_indices {return -1}
    scratch=scratch[num_indices:]
    indices_space:=scratch
    if ptr_diff(scratch_end,scratch)<num_indices {return -1}
    scratch=scratch[num_indices:]
    indices:=indices_space
    lenlog2:=lenlog2_space
    num_lens:int
    if !packed_flag {
        n:int
        used:=get_array(&indices,p,comp_end,&n,num_indices,false,scratch,scratch_end)
        if used<0 || n!=num_indices {return -1}
        p=p[used:]
        used=get_array(&lenlog2,p,comp_end,&n,num_intervals,false,scratch,scratch_end)
        if used<0 || n!=num_intervals {return -1}
        p=p[used:]
        num_lens=num_intervals
        for i in 0..<num_lens {
            if lenlog2[i]>16 {return -1}
        }
    } else {
        packed:=indices
        n:int
        used:=get_array(&packed,p,comp_end,&n,num_indices,false,scratch,scratch_end)
        if used<0 || n!=num_indices {return -1}
        p=p[used:]
        for i in 0..<num_indices {
            v:=packed[i]
            lenlog2[i]=v>>4
            indices[i]=v&0xF
        }
        num_lens=num_indices
    }
    if ptr_diff(scratch_end,scratch)<4 {return -1}
    scratch=align_up(scratch,4)
    if ptr_diff(scratch_end,scratch)<4*num_lens {return -1}
    lens:=([^]u32)(scratch)
    scratch=scratch[4*num_lens:]
    {
        if ptr_diff(comp_end,p)<varbits_len {return -1}
        varbits_end:=p[varbits_len:]
        fb:Front_Back(8)
        front_back_reset(&fb,p,varbits_end)
        b1,b2:Bits
        bits_open_no_refill(&b1,p,comp_end)
        bits_open_no_refill(&b2,varbits_end,varbits_end)
        li:=0
        for li+6<=num_lens {
            if !front_back_safe(&fb,&b1.cur,&b2.cur) {return -1}
            bits_refill(&b1)
            bits_refill_back(&b2)
            lens[li+0]=bits_get_plus_top(&b1,int(lenlog2[li+0]))
            lens[li+1]=bits_get_plus_top(&b2,int(lenlog2[li+1]))
            lens[li+2]=bits_get_plus_top(&b1,int(lenlog2[li+2]))
            lens[li+3]=bits_get_plus_top(&b2,int(lenlog2[li+3]))
            lens[li+4]=bits_get_plus_top(&b1,int(lenlog2[li+4]))
            lens[li+5]=bits_get_plus_top(&b2,int(lenlog2[li+5]))
            li+=6
        }
        for li+2<=num_lens {
            if !front_back_safe(&fb,&b1.cur,&b2.cur) {return -1}
            bits_refill(&b1)
            bits_refill_back(&b2)
            lens[li+0]=bits_get_plus_top(&b1,int(lenlog2[li+0]))
            lens[li+1]=bits_get_plus_top(&b2,int(lenlog2[li+1]))
            li+=2
        }
        if li<num_lens {
            if !front_back_safe(&fb,&b1.cur,&b2.cur) {return -1}
            bits_refill(&b1)
            lens[li]=bits_get_plus_top(&b1,int(lenlog2[li]))
        }
        p=varbits_end
    }
    out=to_mem
    out_end=to_mem_end
    li,ii:=0,0
    eof_inc:=packed_flag ? 1 : 0
    if indices[num_indices-1]!=0 {return -1}
    for dest in 0..<num_arrays {
        to_ptrs[dest]=out
        if ii>=num_indices {return -1}
        for {
            source:=int(indices[ii]);ii+=1
            if source==0 {
                li+=eof_inc
                break
            }
            if source>num_entropy {return -1}
            source-=1
            if li>=num_lens {return -1}
            n:=int(lens[li]);li+=1
            if n>entropy_lens[source] || n>ptr_diff(out_end,out) {return -1}
            intrinsics.mem_copy(out,entropy_ptrs[source],n)
            out=out[n:]
            entropy_ptrs[source]=entropy_ptrs[source][n:]
            entropy_lens[source]-=n
        }
        to_lens[dest]=ptr_diff(out,to_ptrs[dest])
    }
    if ii!=num_indices || li!=num_lens {return -1}
    for i in 0..<num_entropy {
        if entropy_lens[i]!=0 {return -1}
    }
    return ptr_diff(p,comp)
}

// Copies a forward/backward stream pair into a padded local buffer once the
// cursors get close, so refills never read outside the stream.
@(private)
Front_Back :: struct($HALF:int) {
    space:[2*HALF+2*(HALF+16)]u8,
    start,end:[^]u8,
    done:bool,
}

@(private)
front_back_reset :: #force_inline proc "contextless" (fb:^Front_Back($H),start,end:[^]u8) {
    fb.start=start;fb.end=end;fb.done=false
}

@(private)
front_back_safe :: #force_inline proc "contextless" (
    fb:^Front_Back($H),f,b:^[^]u8,
) -> bool #no_bounds_check {
    PAD :: H+16
    if uintptr(b^)>uintptr(f^)+uintptr(2*H) {return true}
    if !fb.done {
        fb.done=true
        if uintptr(b^)<uintptr(f^) {return false}
        size:=ptr_diff(b^,f^)
        head:=min(ptr_diff(f^,fb.start),PAD)
        tail:=min(ptr_diff(fb.end,b^),PAD)
        fb.space={}
        newf:=([^]u8)(&fb.space[PAD])
        intrinsics.mem_copy_non_overlapping(newf[-head:],f^[-head:],size+head+tail)
        f^=newf
        b^=newf[size:]
        return true
    }
    if uintptr(b^)+16<uintptr(f^) {return false}
    base:=uintptr(&fb.space[0])
    if uintptr(b^)<base+uintptr(H) {return false}
    if uintptr(f^)>base+uintptr(size_of(fb.space)-H) {return false}
    return true
}
