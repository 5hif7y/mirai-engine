package entropy

import "base:intrinsics"
import "mirai:std/compressor"

// RLE arrays: a literal sub-array (one 0 byte and raw literals, or an entropy array) followed
// by packets written backward from the end of the output.

@(private="file") RLE7_MRL_NEWV :: 8
@(private="file") RUN_SAFETY_MARGIN :: 16+2

@(private="file")
emit_short_packets :: proc "contextless" (pkt:[^]u8, pk:^int, lrl,rl:int) #no_bounds_check {
    if lrl<=15 {
        if rl<=15 {
            pk^-=1;pkt[pk^]=u8((rl<<4)|(15-lrl))
        } else {
            lo:=rl>>1
            hi:=rl-lo
            pk^-=1;pkt[pk^]=u8((lo<<4)|(15-lrl))
            pk^-=1;pkt[pk^]=u8((hi<<4)|15)
        }
    } else {
        pk^-=1;pkt[pk^]=0x00
        pk^-=1;pkt[pk^]=u8((rl<<4)|(15-(lrl-15)))
    }
}

// pk is the packet position (decreasing), lit the literal end; false when they would meet.
@(private="file")
emit_long_packet :: proc "contextless" (pkt:[^]u8, pk:^int, lit:int, lrl,
    rl:int) -> bool #no_bounds_check {
    lrl,rl:=lrl,rl
    if lrl>=64 && lrl<79 {
        pk^-=1;pkt[pk^]=0x00
        lrl-=15
    }
    for lrl>=64 {
        this:=min(lrl>>6,7*256)
        if pk^-lit<2+2 {return false}
        v:=u32(this-1)
        pk^-=1;pkt[pk^]=u8(2+(v>>8))
        pk^-=1;pkt[pk^]=u8(v)
        lrl-=this<<6
    }
    rl_rem:=rl&0x7f
    if rl_rem<3 || lrl>30 || (rl_rem>15 && lrl>15) || rl_rem>30 {
        if (lrl|rl_rem)!=0 {
            v:=u32(lrl|(rl_rem<<6))
            pk^-=1;pkt[pk^]=u8((v>>8)+0x10)
            pk^-=1;pkt[pk^]=u8(v)
        }
    } else {
        emit_short_packets(pkt,pk,lrl,rl_rem)
    }
    for rl>=128 {
        this:=min(rl>>7,7*256)
        if pk^-lit<2 {return false}
        v:=u32(this-1)
        pk^-=1;pkt[pk^]=u8(9+(v>>8))
        pk^-=1;pkt[pk^]=u8(v)
        rl-=this<<7
    }
    return true
}

// First position >= p (and < safe_end, else >= safe_end) where three equal bytes start.
// safe_end+10 <= len of src.
@(private="file")
skip_to_next_run3 :: #force_inline proc "contextless" (src:[^]u8, p:int,
    safe_end:int) -> int #no_bounds_check {
    p:=p
    SPLAT :: u64(0x0101010101010101)
    for p<safe_end {
        b0:=intrinsics.unaligned_load((^u64)(&src[p]))
        b1:=intrinsics.unaligned_load((^u64)(&src[p+1]))
        b2:=intrinsics.unaligned_load((^u64)(&src[p+2]))
        r:=(b0~b1)|(b0~b2)
        z:=(r-SPLAT)&(SPLAT*0x80)&~r
        if z!=0 {return p+int(intrinsics.count_trailing_zeros(z)>>3)}
        p+=8
    }
    return p
}

// Returns the size; failure returns len(from)+1 with *pJ untouched.
put_array_rle :: proc(out:[^]u8, out_end:[^]u8, from:[]u8, lambda:f32, pJ:^f32, arena:^Arena,
    flags:u32, compression_level:int) -> int #no_bounds_check {
    in_len:=len(from)
    cap:=ptr_diff(out_end,out)
    if in_len<=0 || cap<5 {return in_len+1}
    src:=raw_data(from)
    lit:=0
    pk:=cap
    ip:=0
    lit_start:=0
    safe_end:=max(in_len-RUN_SAFETY_MARGIN,0)
    last_v:u8=0
    out[lit]=0;lit+=1
    first_lit:=lit
    for ip<safe_end {
        ip=skip_to_next_run3(src,ip,safe_end)
        if ip>=safe_end {break}
        v:=src[ip]
        re:=ip+1
        for re<in_len && src[re]==v {re+=1}
        lrl:=ip-lit_start
        run_len:=re-ip
        ip=re
        if pk-lit<lrl+2+16 {return in_len+1}
        if v!=last_v {
            if run_len<RLE7_MRL_NEWV {continue}
            pk-=1;out[pk]=1
            out[lit]=v;lit+=1
            last_v=v
        }
        copy_bytes(out[lit:],src[lit_start:],lrl)
        lit+=lrl
        lit_start=ip
        if lrl>30 || (run_len>15 && lrl>15) || run_len>30 {
            if !emit_long_packet(out,&pk,lit,lrl,run_len) {return in_len+1}
        } else {
            emit_short_packets(out,&pk,lrl,run_len)
        }
    }
    if lrl:=in_len-lit_start;lrl!=0 {
        if pk-lit<lrl+16 {return in_len+1}
        copy_bytes(out[lit:],src[lit_start:],lrl)
        lit+=lrl
        if !emit_long_packet(out,&pk,lit,lrl,0) {return in_len+1}
    }
    lit_bytes:=lit-first_lit
    pkt_bytes:=cap-pk
    J_raw:=f32(1+lit_bytes)
    J_comp:=LAGRANGE_COST_INVALID
    array_type:=compressor.ARRAY_TYPE_UNCOMPRESSED
    comp_buf:[]u8
    comp_len:=0
    final_size:=0
    defer arena_free(arena,comp_buf)
    if flags&ARRAY_FLAG_ALLOW_RLEHUFF!=0 && lit_bytes>=compressor.HUFF_ARRAY_MIN_SIZE &&
        lit_bytes+pkt_bytes<=compressor.ARRAY_INTERNAL_MAX_SCRATCH {
        comp_buf=arena_alloc(arena,u8,lit_bytes)
        if comp_buf==nil {return in_len+1}
        histo:[256]u32
        lits:=out[first_lit:][:lit_bytes]
        count_histo_array_u8(lits,histo[:])
        if find_max_u32_256(&histo)==u32(lit_bytes) {
            array_type=compressor.ARRAY_TYPE_RLE
            comp_len=1
            J_comp=6+lambda*speedfit_memcpy(lit_bytes)
            comp_buf[0]=lits[0]
        } else {
            huff_J:=J_raw
            huff_type:u32=0
            n:=put_array_huff(raw_data(comp_buf),raw_data(comp_buf)[lit_bytes:],lits,&histo,
                lambda,&huff_J,
                ARRAY_DEADLINE_HUGE,&huff_type,flags,arena,compression_level)
            if n>=0 && n<lit_bytes {
                array_type=int(huff_type)
                comp_len=n
                J_comp=huff_J
            }
        }
    }
    if J_raw<=J_comp {
        copy_bytes(out[lit:],out[pk:],pkt_bytes)
        final_size=1+lit_bytes+pkt_bytes
        pJ^=J_raw+f32(pkt_bytes)
    } else {
        put_array_comp_header(out,array_type,lit_bytes,comp_len)
        copy_bytes(out[5:],raw_data(comp_buf),comp_len)
        n:=reput_array_small(out,comp_len+5,&J_comp)
        copy_bytes(out[n:],out[pk:],pkt_bytes)
        final_size=n+pkt_bytes
        pJ^=J_comp+f32(pkt_bytes)
    }
    pJ^+=5+lambda*speedfit_rle(in_len)
    return final_size
}
