package parse

import "base:runtime"
import "core:slice"
import "mirai:std/compressor/lz/entropy"
import "mirai:std/compressor"

// Offsets are sent as a u8 code (entropy coded) plus raw bits. Offsets44: 4 bits of log2 and the
// bottom 4 bits in the code, the rest raw; offsets from ESCAPE_OFFSET_MIN use codes 0xF0+. Alt
// offsets split off/modulo (raw log2 part) and off%modulo (a second entropy array).

OFFSET_ALT_BIAS :: 1<<compressor.OFFSET_ALT_UNDER_BITS

offset44_pack_low_u8 :: #force_inline proc "contextless" (off:i32) -> u8 {
    o:=u32(off)+(1<<(4+compressor.OFFSET_RAW_BITS))-compressor.MIN_OFFSET
    bot:=o&0xF
    top:=entropy.bit_level_nonzero(o)-(1+4+compressor.OFFSET_RAW_BITS)
    return u8((top<<4)|bot)
}

offset44_pack_high_u8 :: #force_inline proc "contextless" (off:i32) -> u8 {
    o:=u32(off)-compressor.ESCAPE_OFFSET_BIAS
    return u8(0xF0|(entropy.bit_level_nonzero(o)-1))
}

offset44_pack_u8 :: #force_inline proc "contextless" (off:i32) -> u8 {
    return off<ESCAPE_OFFSET_MIN ? offset44_pack_low_u8(off) : offset44_pack_high_u8(off)
}

offset44_unpack_low_numrawbits :: #force_inline proc "contextless" (c:u8) -> u32 {
    return u32(c>>4)+compressor.OFFSET_RAW_BITS
}
offset44_unpack_high_numrawbits :: #force_inline proc "contextless" (c:u8) -> u32 {
    return 16+u32(c-0xF0)
}
offset44_unpack_numrawbits :: #force_inline proc "contextless" (c:u8) -> u32 {
    return c<0xF0 ? offset44_unpack_low_numrawbits(c) : offset44_unpack_high_numrawbits(c)
}

offset44_pack_low_rawbits :: #force_inline proc "contextless" (off:u32,num_raw:u32) -> u32 {
    o:=(off+(1<<(4+compressor.OFFSET_RAW_BITS))-compressor.MIN_OFFSET)>>4
    return o-(1<<num_raw)
}

offset44_pack_high_rawbits :: #force_inline proc "contextless" (off:u32,num_raw:u32) -> u32 {
    return off-compressor.ESCAPE_OFFSET_BIAS-(1<<num_raw)
}

alt_offset_pack_u8s :: #force_inline proc "contextless" (off:u32,modulo:u32) -> (top:u8,bot:u8) {
    t:=off/modulo
    bot=u8(off%modulo)
    t+=OFFSET_ALT_BIAS
    log2:=entropy.bit_level_nonzero(t)-1
    log2-=compressor.OFFSET_ALT_UNDER_BITS
    under:=(t>>log2)~(1<<compressor.OFFSET_ALT_UNDER_BITS)
    top=u8((log2<<compressor.OFFSET_ALT_UNDER_BITS)|under)
    return
}

alt_offset_pack_u8_modulo1 :: #force_inline proc "contextless" (off:u32) -> u8 {
    t:=off+OFFSET_ALT_BIAS
    log2:=entropy.bit_level_nonzero(t)-1-compressor.OFFSET_ALT_UNDER_BITS
    under:=(t>>log2)~(1<<compressor.OFFSET_ALT_UNDER_BITS)
    return u8((log2<<compressor.OFFSET_ALT_UNDER_BITS)|under)
}

alt_offset_unpack_numrawbits :: #force_inline proc "contextless" (top:u8) -> u32 {
    return u32(top)>>compressor.OFFSET_ALT_UNDER_BITS
}

alt_offset_pack_high_rawbits :: #force_inline proc "contextless" (off:u32,num_raw:u32,
    modulo:u32) -> u32 {
    o:=off/modulo+OFFSET_ALT_BIAS
    return o&((1<<num_raw)-1)
}

@(private)
put_exp_golomb :: #force_inline proc "contextless" (vb:^entropy.Var_Bits,val:u32,rshift:u32,
    back:bool) {
    head:=(val>>rshift)+1
    topbit:=entropy.bit_level_nonzero(head)-1
    out :: #force_inline proc "contextless" (vb:^entropy.Var_Bits,back:bool) {
        if back {entropy.varbits_output_back(vb)} else {entropy.varbits_output(vb)}
    }
    entropy.varbits_put(vb,1,int(topbit+1));out(vb,back)
    if topbit>0 {
        head-=1<<topbit
        entropy.varbits_put(vb,u64(head),int(topbit));out(vb,back)
    }
    entropy.varbits_put(vb,u64(val&((1<<rshift)-1)),int(rshift));out(vb,back)
}

// Puts the u32 excesses at comp_end (front and back streams packed together there).
// Returns their length, -1 on failure.
put_excesses_u32_separate :: proc(comp_ptr,comp_end:[^]u8, excess_u32s:[^]u32, count:int) -> int {
    if pdiff(comp_end,comp_ptr)<16 {return -1}
    if count==0 {return 0}
    vb1,vb2:entropy.Var_Bits
    entropy.varbits_open(&vb1,comp_ptr,comp_end)
    entropy.varbits_open(&vb2,comp_end,comp_ptr)
    for xi in 0..<count {
        x:=excess_u32s[xi]
        if xi&1==0 {put_exp_golomb(&vb1,x,compressor.EXCESS_EXPGOLOMB_SHIFT,false)}
        else {put_exp_golomb(&vb2,x,compressor.EXCESS_EXPGOLOMB_SHIFT,true)}
        if pdiff(vb2.cur,vb1.cur)<=8 {return -1}
    }
    entropy.varbits_put_flush8(&vb1)
    entropy.varbits_put_flush8_back(&vb2)
    front_end:=entropy.varbits_put_end_ptr(&vb1)
    back_end:=vb2.cur
    if pdiff(back_end,front_end)<=8 {return -1}
    front_len:=pdiff(front_end,comp_ptr)
    start:=padd(back_end,-front_len)
    runtime.mem_copy(start,comp_ptr,front_len)
    return pdiff(comp_end,start)
}

// Raw bits of the offsets and (without a separate excess stream) the u32 excesses, as a front
// and a back varbits stream. Returns the length including excess_stream_bytes, -1 on failure.
put_offsets_excesses :: proc(comp_ptr,comp_end:[^]u8, offsets_u8s:[^]u8, offsets:[^]u32,
    offsets_count:int,
    offset_alt_modulo:int, excess_u32s:[^]u32, excesses_u32_count:int,
    excesses_u32_hdr_size:int, excess_stream_bytes:int) -> int #no_bounds_check {
    if 16>=pdiff(comp_end,comp_ptr) {return -1}
    vb1,vb2:entropy.Var_Bits
    entropy.varbits_open(&vb1,comp_ptr,comp_end)
    entropy.varbits_open(&vb2,comp_end,comp_ptr)
    if excesses_u32_hdr_size==0 {
        put_exp_golomb(&vb2,u32(excesses_u32_count),EXCESS_U32_COUNT_EXPGOLOMB_SHIFT,true)
        entropy.varbits_output_back(&vb2)
    }
    if offset_alt_modulo==0 {
        offi:=0
        for ;offi<offsets_count-3;offi+=4 {
            if pdiff(vb2.cur,vb1.cur)<=8 {return -1}
            four:=load32(offsets_u8s[offi:])
            large:=four&0x80808080
            large&=(~four)-0x10101010
            if large!=0 {break}
            for k in 0..<4 {
                nr:=offset44_unpack_low_numrawbits(u8(four))
                four>>=8
                raw:=offset44_pack_low_rawbits(offsets[offi+k],nr)
                if k&1==0 {entropy.varbits_put(&vb1,u64(raw),int(nr))}
                else {entropy.varbits_put(&vb2,u64(raw),int(nr))}
            }
            entropy.varbits_output(&vb1)
            entropy.varbits_output_back(&vb2)
        }
        for ;offi<offsets_count;offi+=1 {
            if pdiff(vb2.cur,vb1.cur)<=8 {return -1}
            c:=offsets_u8s[offi]
            off:=offsets[offi]
            nr,raw:u32
            if c>=0xF0 {
                nr=offset44_unpack_high_numrawbits(c)
                raw=offset44_pack_high_rawbits(off,nr)
            } else {
                nr=offset44_unpack_low_numrawbits(c)
                raw=offset44_pack_low_rawbits(off,nr)
            }
            if offi&1==0 {entropy.varbits_put(&vb1,u64(raw),int(nr));entropy.varbits_output(&vb1)}
            else {entropy.varbits_put(&vb2,u64(raw),int(nr));entropy.varbits_output_back(&vb2)}
        }
    } else {
        mod:=u32(offset_alt_modulo)
        for offi in 0..<offsets_count {
            if pdiff(vb2.cur,vb1.cur)<=8 {return -1}
            nr:=alt_offset_unpack_numrawbits(offsets_u8s[offi])
            raw:=alt_offset_pack_high_rawbits(offsets[offi],nr,mod)
            if offi&1==0 {entropy.varbits_put(&vb1,u64(raw),int(nr));entropy.varbits_output(&vb1)}
            else {entropy.varbits_put(&vb2,u64(raw),int(nr));entropy.varbits_output_back(&vb2)}
        }
    }
    if excesses_u32_hdr_size==0 {
        for xi in 0..<excesses_u32_count {
            x:=excess_u32s[xi]
            if xi&1==0 {put_exp_golomb(&vb1,x,compressor.EXCESS_EXPGOLOMB_SHIFT,false)}
            else {put_exp_golomb(&vb2,x,compressor.EXCESS_EXPGOLOMB_SHIFT,true)}
            if pdiff(vb2.cur,vb1.cur)<=8 {return -1}
        }
    }
    entropy.varbits_put_flush8(&vb1)
    entropy.varbits_put_flush8_back(&vb2)
    p:=entropy.varbits_put_end_ptr(&vb1)
    back_start:=vb2.cur
    if pdiff(back_start,p)<=8 {return -1}
    back_len:=pdiff(comp_end,back_start)
    runtime.mem_copy(p,back_start,back_len)
    p=padd(p,back_len)
    if excess_stream_bytes>0 {
        runtime.mem_copy(p,comp_end,excess_stream_bytes)
        p=padd(p,excess_stream_bytes)
    }
    return pdiff(p,comp_ptr)
}

@(private)
cost_alt_offset_modulo :: proc(mod:int, offsets:[^]u32, count:int,
    lambda:f32) -> f32 #no_bounds_check {
    top_histo:[256]u32
    bottom_histo:[compressor.ALT_OFFSET_MAX_MOD]u32
    raw_bits:i32
    for s in 0..<count {
        top,bot:=alt_offset_pack_u8s(offsets[s],u32(mod))
        raw_bits+=i32(alt_offset_unpack_numrawbits(top))
        top_histo[top]+=1
        bottom_histo[bot]+=1
    }
    top_bytes:=(raw_bits+7)/8
    top_bytes+=ent_estimate_complen_bytes(top_histo[:],u32(count))
    J:=f32(top_bytes)
    if mod>1 {
        J+=lambda*entropy.speedfit_simd_mul_s32_sub_u8(count)
        bottom_bytes:=ent_estimate_complen_bytes(bottom_histo[:],u32(count))
        J+=f32(bottom_bytes)
        J+=lambda*entropy.speedfit_estimate_entropy_array_time(count)
    }
    return J
}

@(private)
choose_alt_offset_modulo_brute :: proc(offsets:[^]u32, count:int, lambda:f32) -> int {
    if count<compressor.HUFF_ARRAY_MIN_SIZE {return 1}
    best_mod:=0
    best_J:=entropy.LAGRANGE_COST_INVALID
    for mod in 1..=compressor.ALT_OFFSET_MAX_MOD {
        J:=cost_alt_offset_modulo(mod,offsets,count,lambda)
        if J<best_J {best_J=J;best_mod=mod}
    }
    return best_mod
}

@(private)
choose_alt_offset_modulo_fast :: proc(offsets:[^]u32, count:int,
    lambda:f32) -> int #no_bounds_check {
    histo:[compressor.ALT_OFFSET_MAX_MOD+1]u32
    for o in 0..=compressor.ALT_OFFSET_MAX_MOD {histo[o]=u32(o)}
    for s in 0..<count {
        off:=offsets[s]
        if off>compressor.ALT_OFFSET_MAX_MOD {continue}
        histo[off]+=1<<8
    }
    // entries are distinct (the low byte is the index), so any sort gives the same order
    slice.sort_by(histo[:],proc(a,b:u32) -> bool {return a>b})
    best_mod:=1
    best_J:=cost_alt_offset_modulo(1,offsets,count,lambda)
    for s in 0..<4 {
        mod:=int(histo[s]&0xFF)
        if mod<=1 {continue}
        J:=cost_alt_offset_modulo(mod,offsets,count,lambda)
        if J<best_J {best_J=J;best_mod=mod}
    }
    return best_mod
}

put_alt_offset_u8_arrays :: proc "contextless" (offsets:[^]u32, count:int, top_out,bot_out:[^]u8,
    modulo:int, offset44_u8s:[^]u8) -> (alt_extrabits,o44_extrabits:int) #no_bounds_check {
    if modulo==1 {
        for i in 0..<count {
            o44_extrabits+=int(offset44_unpack_numrawbits(offset44_u8s[i]))
            top:=alt_offset_pack_u8_modulo1(offsets[i])
            top_out[i]=top
            alt_extrabits+=int(alt_offset_unpack_numrawbits(top))
        }
    } else {
        for i in 0..<count {
            o44_extrabits+=int(offset44_unpack_numrawbits(offset44_u8s[i]))
            top,bot:=alt_offset_pack_u8s(offsets[i],u32(modulo))
            top_out[i]=top
            bot_out[i]=bot
            alt_extrabits+=int(alt_offset_unpack_numrawbits(top))
        }
    }
    return
}

// Entropy arrays of the offset codes: offsets44, or alt offsets when try_alt wins on J.
// Rewrites offsets_u8_44 to the alt tops when alt is chosen. Returns the length, -1 on failure.
put_offset_44_or_alt_arrays :: proc(comp_ptr,comp_end:[^]u8, offsets_u8_44:[^]u8, offsets:[^]u32,
    offsets_count:int, entropy_flags:u32, lambda:f32, pJ:^f32, deadline:f32, min_offset_8:bool,
    try_alt:bool, p_modulo:^int, arena:^entropy.Arena, level:i32, histo1,histo2:[^]u32) -> int {
    modulo:=0
    comp_len:=int(max(i32))
    pJ^=entropy.LAGRANGE_COST_INVALID
    if min_offset_8 {
        comp_len=ent_put_array(comp_ptr,comp_end,offsets_u8_44,offsets_count,entropy_flags,lambda,
            pJ,
            deadline,arena,level,histo1)
        if comp_len<0 {return -1}
        pJ^+=lambda*entropy.speedfit_get_offsets44(offsets_count)
    }
    if try_alt {
        space_needed:=offsets_count*4+16
        scratch:=entropy.arena_alloc(arena,u8,space_needed)
        if scratch==nil {return -1}
        defer entropy.arena_free(arena,scratch)
        s:=raw_data(scratch)
        alt_top:=s
        alt_bot:=s[offsets_count:]
        sc_comp:=s[offsets_count*2:]
        sc_end:=s[space_needed:]
        modulo=1
        if level>=compressor.LEVEL_OPTIMAL4 {modulo=choose_alt_offset_modulo_brute(offsets,offsets_count,
            lambda)}
        else if level>=compressor.LEVEL_NORMAL {
            modulo=choose_alt_offset_modulo_fast(offsets,offsets_count,lambda)
        }
        extrabits_alt,extrabits_44:=put_alt_offset_u8_arrays(offsets,offsets_count,alt_top,alt_bot,
            modulo,offsets_u8_44)
        p:=sc_comp
        p[0]=u8(0x80+modulo-1)
        p=p[1:]
        temp_histo1:[256]u32
        ptemp:[^]u32=histo1!=nil ? raw_data(temp_histo1[:]) : nil
        J1:=entropy.LAGRANGE_COST_INVALID
        len1:=ent_put_array_small_allowed(p,sc_end,alt_top,offsets_count,entropy_flags,lambda,&J1,
            entropy.ARRAY_DEADLINE_HUGE,arena,level,ptemp)
        if len1<0 {return -1}
        p=p[len1:]
        J2:=f32(0)
        len2:=0
        if modulo>1 {
            J2=entropy.LAGRANGE_COST_INVALID
            len2=ent_put_array_small_allowed(p,sc_end,alt_bot,offsets_count,entropy_flags,lambda,
                &J2,
                entropy.ARRAY_DEADLINE_HUGE,arena,level,histo2)
            if len2<0 {return -1}
            p=p[len2:]
        }
        alt_J:=1+J1+J2
        alt_J+=lambda*entropy.speedfit_get_offsets_time(offsets_count,modulo)
        test_J:=pJ^+f32((extrabits_44+7)/8)
        test_alt_J:=alt_J+f32((extrabits_alt+7)/8)
        alt_len:=pdiff(p,sc_comp)
        if test_alt_J<test_J {
            if alt_len>pdiff(comp_end,comp_ptr) {return -1}
            runtime.mem_copy(comp_ptr,sc_comp,alt_len)
            pJ^=alt_J
            comp_len=alt_len
            runtime.mem_copy(offsets_u8_44,alt_top,offsets_count)
            if histo1!=nil {runtime.mem_copy(histo1,ptemp,256*size_of(u32))}
        } else {
            modulo=0
        }
    }
    p_modulo^=modulo
    return comp_len
}
