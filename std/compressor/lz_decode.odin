package compressor

import "base:intrinsics"
import "core:simd"
import "core:sys/info"

@(private="file")
LZ_Arrays :: struct {
    offsets:[^]i32,
    offsets_count:int,
    excesses:[^]u32,
    excesses_count:int,
    packets:[^]u8,
    packets_count:int,
    literals:[^]u8,
    literals_count:int,
}

// Scratch kept ahead of a chunk's arrays; the chunk's scratch limit counts it.
@(private) LZ_ARRAYS_HEADER :: 80
@(private="file") EXTRA_SCRATCH :: 64

@(private="file")
lz_phase1 :: proc "contextless" (
    chunk_type:int,comp,comp_end:[^]u8,chunk:[^]u8,chunk_len,chunk_pos:int,
    scratch,scratch_end:[^]u8,a:^LZ_Arrays,
) -> bool #no_bounds_check {
    if chunk_type>1 {return false}
    overlap:=uintptr(comp)<=uintptr(chunk[chunk_len:]) && uintptr(chunk)<=uintptr(comp_end)
    if ptr_diff(comp_end,comp)<13 {return false}
    p:=comp
    if chunk_pos==0 {
        copy8(chunk,p)
        p=p[8:]
    }
    excess_header:u8
    excess_stream:=0
    if uintptr(p)<uintptr(comp_end) && p[0]>=LZ_EXCESS_HEADER {
        excess_header=p[0];p=p[1:]
        if excess_header&0xc0!=0x80 {return false}
        excess_stream=int(excess_header&0x3f)
        if excess_stream>=32 {
            if p==comp_end {return false}
            excess_stream+=int(p[0])<<5;p=p[1:]
        }
    }
    sp:=scratch
    literals:=sp
    literals_count:int
    used:=get_array(&literals,p,comp_end,&literals_count,min(chunk_len,ptr_diff(scratch_end,sp)),
        overlap,sp,scratch_end)
    if used<0 {return false}
    p=p[used:]
    sp=sp[literals_count:]
    packets:=sp
    packets_count:int
    used=get_array(&packets,p,comp_end,&packets_count,min(chunk_len,ptr_diff(scratch_end,sp)),
        overlap,sp,scratch_end)
    if used<0 {return false}
    p=p[used:]
    sp=sp[packets_count:]
    offs_u8:=sp
    offs_u8_2:[^]u8
    offs_count:=0
    alt_modulo:u32
    if ptr_diff(comp_end,p)<3 {return false}
    if p[0]>=LZ_ALT_OFFSETS {
        alt_modulo=u32(p[0])-0x80+1
        p=p[1:]
        used=get_array(&offs_u8,p,comp_end,&offs_count,min(packets_count,ptr_diff(scratch_end,
            sp)),false,sp,scratch_end)
        if used<0 {return false}
        p=p[used:]
        sp=sp[offs_count:]
        if alt_modulo!=1 {
            offs_u8_2=sp
            count2:int
            used=get_array(&offs_u8_2,p,comp_end,&count2,min(offs_count,ptr_diff(scratch_end,
                sp)),false,sp,scratch_end)
            if used<0 {return false}
            p=p[used:]
            sp=sp[offs_count:]
            if offs_count!=count2 {return false}
        }
    } else {
        used=get_array(&offs_u8,p,comp_end,&offs_count,min(packets_count,ptr_diff(scratch_end,
            sp)),false,sp,scratch_end)
        if used<0 {return false}
        p=p[used:]
        sp=sp[offs_count:]
    }
    excess_u8:=sp
    excess_count:int
    used=get_array(&excess_u8,p,comp_end,&excess_count,min(chunk_len/4,ptr_diff(scratch_end,sp)),
        false,sp,scratch_end)
    if used<0 {return false}
    p=p[used:]
    sp=sp[excess_count:]
    u32_space:=align_up(sp,16)
    offsets:=([^]i32)(u32_space)
    excesses:=([^]u32)(align_up(u32_space[4*offs_count:],16))
    if ptr_diff(scratch_end,([^]u8)(excesses))<excess_count*4+EXTRA_SCRATCH {return false}
    intrinsics.mem_zero(&excesses[excess_count],EXTRA_SCRATCH)
    job:=Offsets_Job{
        comp=p,comp_end=comp_end,
        offs_u8=offs_u8,offs_u8_2=offs_u8_2,offs_count=offs_count,alt_modulo=alt_modulo,
        excess_u8=excess_u8,excess_count=excess_count,
        offsets=offsets,excesses=excesses,
        excess_header=excess_header,excess_stream=excess_stream,
    }
    if !get_offsets_excesses(&job) {return false}
    a^={offsets,offs_count,excesses,excess_count,packets,packets_count,literals,literals_count}
    return true
}

@(private="file") PACKETS_PER_CHECK :: 8
@(private="file") BIG_LRL :: 24
@(private="file") BIG_ML :: 16
@(private="file") LITS_PER_CHECK :: BIG_LRL*PACKETS_PER_CHECK+BIG_LRL
@(private="file") OUT_PER_CHECK :: (BIG_LRL+BIG_ML)*PACKETS_PER_CHECK
@(private="file") EXCESS_OVERRUN :: PACKETS_PER_CHECK*2

@(private="file")
sub_saturate :: #force_inline proc "contextless" (p:[^]u8,n:int,base:[^]u8) -> [^]u8 {
    return ptr_diff(p,base)<n ? base : p[-n:]
}

@(private="file")
LZ_Parse :: struct {
    to:[^]u8,
    lits:[^]u8,
    lit_end:[^]u8,
    lit_check:[^]u8,
    offsets:[^]i32,
    excesses:[^]u32,
    packets:[^]u8,
    last0,last1,last2:int,
    lo:#simd[4]i32, // last offsets 0..2 and the new offset in lane 3, for SIMD
}

// Byte shuffles that move last offset i (or the new one, 3) to the front.
@(private="file", rodata)
LO_SHUFFLES := [4]#simd[16]u8{
    {0,1,2,3, 4,5,6,7, 8,9,10,11, 12,13,14,15},
    {4,5,6,7, 0,1,2,3, 8,9,10,11, 12,13,14,15},
    {8,9,10,11, 0,1,2,3, 4,5,6,7, 12,13,14,15},
    {12,13,14,15, 0,1,2,3, 4,5,6,7, 8,9,10,11},
}

// One packet; false on a bad stream. Ends the checkpoint group by moving check.
@(private="file")
lz_packet :: #force_inline proc "contextless" (
    st:^LZ_Parse,check:^[^]u8,match_zone_end,match_end,output_safe_end,window_base:[^]u8,
    $SUB,$CAREFUL,$SIMD:bool,
) -> bool #no_bounds_check {
    packet:=uint(st.packets[0])
    st.packets=st.packets[1:]
    lrl:=int(packet&3)
    ml_code:=int((packet>>2)&0xF)
    off_index:=int(packet>>6)
    to:=st.to
    lits:=st.lits
    neg:=st.last0
    e:=int(st.excesses[0])
    is_excess:=lrl==LZ_LRL_MAX
    lrl=is_excess ? e : lrl
    st.excesses=is_excess ? st.excesses[1:] : st.excesses
    when CAREFUL {
        if ptr_diff(match_zone_end,to)<lrl {return false}
    }
    when CAREFUL {
        literals_copy8(to,to[neg:],lits,SUB)
        if lrl>8 {
            literals_copy8(to[8:],to[8+neg:],lits[8:],SUB)
            if lrl>16 {literals_copy8(to[16:],to[16+neg:],lits[16:],SUB)}
        }
    } else {
        // The checkpoint margins of output and literals cover 24 bytes.
        when SUB {
            copy_add8(to,to[neg:],lits)
            copy_add8(to[8:],to[8+neg:],lits[8:])
            copy_add8(to[16:],to[16+neg:],lits[16:])
        } else {
            copy16(to,lits)
            copy8(to[16:],lits[16:])
        }
    }
    {
        {
            if intrinsics.expect(lrl>BIG_LRL,false) {
                if ptr_diff(st.lit_check,lits)<=lrl {
                    when !CAREFUL {check^=st.packets}
                    if ptr_diff(st.lit_end,lits)<lrl {return false}
                }
                when !CAREFUL {
                    if ptr_diff(output_safe_end,to)<lrl {
                        check^=st.packets
                        if ptr_diff(match_zone_end,to)<lrl {return false}
                    }
                }
                to=to[24:];lits=lits[24:];lrl-=24
                for {
                    literals_copy8(to,to[neg:],lits,SUB)
                    to=to[8:];lits=lits[8:];lrl-=8
                    if lrl<=0 {break}
                }
            }
        }
    }
    to=to[lrl:]
    lits=lits[lrl:]
    when SIMD {
        lo:=simd.replace(st.lo,3,st.offsets[0])
        lo=transmute(#simd[4]i32)simd.runtime_swizzle(transmute(#simd[16]u8)lo,
            LO_SHUFFLES[off_index])
        st.lo=lo
        neg=int(simd.extract(lo,0))
        st.last0=neg
    } else {
        // Move-to-front of the last offsets; index 3 takes the next new offset.
        l0,l1,l2:=st.last0,st.last1,st.last2
        n:=int(st.offsets[0])
        top:=(l0&-int(off_index==0))|(l1&-int(off_index==1))
        top|=(l2&-int(off_index==2))|(n&-int(off_index==3))
        st.last2=l2~((l1~l2)&-int(off_index>=2))
        st.last1=l1~((l0~l1)&-int(off_index>=1))
        st.last0=top
        neg=top
    }
    st.offsets=st.offsets[((off_index+1)&4)>>2:]
    if intrinsics.expect(uint(neg)<uint(ptr_diff(window_base,to)),false) {return false}
    mp:=to[neg:]
    if intrinsics.expect(ml_code==LZ_ML_MAX,false) {
        ml:=LZ_ML_MAX+LZ_LOMML-LZ_LRL_MAX+int(st.excesses[0])
        st.excesses=st.excesses[1:]
        if ptr_diff(match_end,to)<ml {return false}
        to_end:=to[ml:]
        copy8(to,mp);copy8(to[8:],mp[8:]);copy8(to[16:],mp[16:])
        to=to[24:];mp=mp[24:]
        for uintptr(to)<uintptr(to_end) {
            copy8(to,mp)
            to=to[8:];mp=mp[8:]
        }
        to=to_end
        when !CAREFUL {
            if uintptr(to)>=uintptr(output_safe_end) {check^=st.packets}
        }
    } else {
        copy8(to,mp);copy8(to[8:],mp[8:])
        to=to[ml_code+LZ_LOMML:]
    }
    st.to=to
    st.lits=lits
    return true
}

@(private="file")
lz_parse_impl :: #force_inline proc "contextless" (
    a:^LZ_Arrays,to,chunk_base,chunk_end,window_base:[^]u8,$SUB,$SIMD:bool,
) -> bool #no_bounds_check {
    if ptr_diff(chunk_end,chunk_base)<LZ_NO_MATCH_ZONE {return false}
    st:LZ_Parse
    st.to=to
    st.lits=a.literals
    st.offsets=a.offsets
    st.excesses=a.excesses
    st.packets=a.packets
    st.last0,st.last1,st.last2=-MIN_OFFSET,-MIN_OFFSET,-MIN_OFFSET
    st.lo=-MIN_OFFSET
    packets_end:=a.packets[a.packets_count:]
    match_zone_end:=sub_saturate(chunk_end,LZ_NO_MATCH_ZONE,chunk_base)
    match_end:=chunk_end[-LZ_MATCH_END_PAD:]
    output_safe_end:=sub_saturate(chunk_end,OUT_PER_CHECK+LZ_NO_MATCH_ZONE,chunk_base)
    st.lit_end=a.literals[a.literals_count:]
    excesses_end:=a.excesses[a.excesses_count:]
    for i in 0..<EXCESS_OVERRUN {excesses_end[i]=LZ_LRL_MAX}
    lit_scratch:[LITS_PER_CHECK*2]u8 = ---
    {
        n:=min(LITS_PER_CHECK,a.literals_count)
        st.lit_check=st.lit_end[-n:]
        intrinsics.mem_copy_non_overlapping(&lit_scratch[LITS_PER_CHECK-n],st.lit_check,n)
        intrinsics.mem_zero(&lit_scratch[LITS_PER_CHECK],LITS_PER_CHECK)
    }
    lit_scratch_end:=([^]u8)(&lit_scratch[LITS_PER_CHECK])
    check_literals :: #force_inline proc "contextless" (
        st:^LZ_Parse,scratch_end:[^]u8,
    ) -> bool {
        if uintptr(st.lits)>=uintptr(st.lit_check) {
            if uintptr(st.lits)>uintptr(st.lit_end) {return false}
            st.lits=scratch_end[-ptr_diff(st.lit_end,st.lits):]
            st.lit_end=scratch_end
            st.lit_check=scratch_end
        }
        return true
    }
    excesses_bytes_end:=uintptr(excesses_end)
    for uintptr(st.packets)<uintptr(packets_end) && uintptr(st.to)<uintptr(output_safe_end) {
        if !check_literals(&st,lit_scratch_end) {return false}
        check:=st.packets[PACKETS_PER_CHECK:]
        if ptr_diff(packets_end,st.packets)<PACKETS_PER_CHECK {check=packets_end}
        for uintptr(st.packets)<uintptr(check) {
            if !lz_packet(&st,&check,match_zone_end,match_end,output_safe_end,window_base,
                SUB,false,SIMD) {return false}
        }
        if uintptr(st.offsets)>excesses_bytes_end {return false}
        if uintptr(st.excesses)>excesses_bytes_end {return false}
    }
    for uintptr(st.packets)<uintptr(packets_end) {
        if !check_literals(&st,lit_scratch_end) {return false}
        if !lz_packet(&st,nil,match_zone_end,match_end,output_safe_end,window_base,SUB,true,
            SIMD) {return false}
        if uintptr(st.offsets)>excesses_bytes_end {return false}
        if uintptr(st.excesses)>excesses_bytes_end {return false}
    }
    if st.offsets!=a.offsets[a.offsets_count:] || st.excesses!=excesses_end {return false}
    to_ptr:=st.to
    if uintptr(to_ptr)<uintptr(chunk_end) {
        lrl:=ptr_diff(chunk_end,to_ptr)
        if ptr_diff(st.lit_end,st.lits)!=lrl {return false}
        lits:=st.lits
        when SUB {
            neg:=st.last0
            for lrl>=8 {
                copy_add8(to_ptr,to_ptr[neg:],lits)
                to_ptr=to_ptr[8:];lits=lits[8:];lrl-=8
            }
            for lrl>0 {
                to_ptr[0]=lits[0]+to_ptr[neg]
                to_ptr=to_ptr[1:];lits=lits[1:];lrl-=1
            }
        } else {
            intrinsics.mem_copy_non_overlapping(to_ptr,lits,lrl)
            to_ptr=to_ptr[lrl:]
        }
    }
    return to_ptr==chunk_end
}

// Decodes one LZ quantum into dst[pos:end]. Returns the compressed bytes
// used, or -1.
@(private)
lz_decode_quantum :: proc "contextless" (
    dst:[^]u8,pos,end:int,comp:[^]u8,comp_len:int,pos_since_reset:int,scratch:[^]u8,scratch_len:int,
) -> int #no_bounds_check {
    raw:=pos
    p:=comp
    comp_end:=comp[comp_len:]
    scratch_end:=scratch[scratch_len:]
    for raw<end {
        chunk_len:=min(CHUNK_LEN,end-raw)
        chunk_pos:=raw-pos+pos_since_reset
        chunk:=dst[raw:]
        if ptr_diff(comp_end,p)<4 {return -1}
        header:=int(load24be(p))
        chunk_comp_len:int
        if header>=CHUNK_COMPRESSED {
            chunk_type:=(header>>CHUNK_TYPE_SHIFT)&CHUNK_TYPE_MASK
            chunk_comp_len=header&CHUNK_COMP_LEN_MASK
            p=p[3:]
            if chunk_comp_len>ptr_diff(comp_end,p) {return -1}
            if chunk_comp_len>=chunk_len {
                if chunk_comp_len>chunk_len || chunk_type!=0 {return -1}
                intrinsics.mem_copy(chunk,p,chunk_len)
            } else {
                if chunk_len<MIN_CHUNK_LEN {return -1}
                expected:=scratch_size(chunk_len)
                if scratch_len<expected {return -1}
                a:LZ_Arrays
                cs:=scratch[LZ_ARRAYS_HEADER:]
                ce:=scratch[expected:]
                if !lz_phase1(chunk_type,p,p[chunk_comp_len:],chunk,chunk_len,chunk_pos,cs,
                    ce,&a) {return -1}
                start:=chunk_pos==0 ? MIN_OFFSET : 0
                window:=chunk[-chunk_pos:]
                ok:bool
                if chunk_type==CHUNK_LITERALS_RAW {
                    ok=lz_parse(&a,chunk[start:],chunk,chunk[chunk_len:],window,false)
                } else {
                    ok=lz_parse(&a,chunk[start:],chunk,chunk[chunk_len:],window,true)
                }
                if !ok {return -1}
            }
        } else {
            n:int
            lits:=chunk
            overlap:=uintptr(p)<=uintptr(chunk[chunk_len:]) && uintptr(chunk)<=uintptr(comp_end)
            if overlap {
                lits=scratch
                chunk_comp_len=get_array(&lits,p,comp_end,&n,chunk_len,false,scratch,scratch_end)
                if lits!=scratch {return -1}
                if chunk_comp_len>=0 {intrinsics.mem_copy(chunk,scratch,chunk_len)}
            } else {
                chunk_comp_len=get_array(&lits,p,comp_end,&n,chunk_len,false,scratch,scratch_end)
                if lits!=chunk {return -1}
            }
            if chunk_comp_len<0 || chunk_comp_len>=chunk_len || n!=chunk_len {return -1}
        }
        p=p[chunk_comp_len:]
        raw+=chunk_len
    }
    return ptr_diff(p,comp)
}

@(private="file") parse_raw :: #force_no_inline proc "contextless" (
    a:^LZ_Arrays,to,base,end,window:[^]u8,
) -> bool {return lz_parse_impl(a,to,base,end,window,false,false)}
@(private="file") parse_sub :: #force_no_inline proc "contextless" (
    a:^LZ_Arrays,to,base,end,window:[^]u8,
) -> bool {return lz_parse_impl(a,to,base,end,window,true,false)}

when ODIN_ARCH==.amd64 {
    // The last offsets in one register, moved to the front by a byte shuffle.
    @(private="file", enable_target_feature="ssse3,sse4.1")
    parse_raw_simd :: #force_no_inline proc "contextless" (
        a:^LZ_Arrays,to,base,end,window:[^]u8,
    ) -> bool {return lz_parse_impl(a,to,base,end,window,false,true)}
    @(private="file", enable_target_feature="ssse3,sse4.1")
    parse_sub_simd :: #force_no_inline proc "contextless" (
        a:^LZ_Arrays,to,base,end,window:[^]u8,
    ) -> bool {return lz_parse_impl(a,to,base,end,window,true,true)}
} else when ODIN_ARCH==.arm64 {
    @(private="file") parse_raw_simd :: #force_no_inline proc "contextless" (
        a:^LZ_Arrays,to,base,end,window:[^]u8,
    ) -> bool {return lz_parse_impl(a,to,base,end,window,false,true)}
    @(private="file") parse_sub_simd :: #force_no_inline proc "contextless" (
        a:^LZ_Arrays,to,base,end,window:[^]u8,
    ) -> bool {return lz_parse_impl(a,to,base,end,window,true,true)}
}

@(private="file")
lz_parse :: proc "contextless" (a:^LZ_Arrays,to,base,end,window:[^]u8,sub:bool) -> bool {
    when ODIN_ARCH==.amd64 {
        features:=info.cpu_features()
        if !FORCE_GENERIC && .ssse3 in features && .sse41 in features {
            return sub ? parse_sub_simd(a,to,base,end,window) : parse_raw_simd(a,to,base,end,window)
        }
    } else when ODIN_ARCH==.arm64 {
        return sub ? parse_sub_simd(a,to,base,end,window) : parse_raw_simd(a,to,base,end,window)
    }
    return sub ? parse_sub(a,to,base,end,window) : parse_raw(a,to,base,end,window)
}
