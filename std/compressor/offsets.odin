package compressor

import "base:intrinsics"
import "core:sys/info"

// Offsets are entropy-coded bytes plus raw bits in a forward/backward stream
// pair; excess lengths are bytes, 255 escaping to Exp-Golomb codes in the
// same pair (old format) or in a pair of their own at the end of the chunk.

@(private="file")
offsets44_count :: #force_inline proc "contextless" (x:u32) -> u32 {
    if x<0xf0 {return (x>>4)+OFFSET_RAW_BITS}
    if x>=0xfe {return 0}
    return x-0xf0+16
}

@(private="file")
offsets44_bias :: #force_inline proc "contextless" (x:u32) -> i32 {
    if x<0xf0 {
        n:=(x>>4)+OFFSET_RAW_BITS
        return -(i32(x&0xf)+(i32(1)<<(n+4))-(1<<(OFFSET_RAW_BITS+4))+MIN_OFFSET)
    }
    if x>=0xfe {return -MAX_OFFSET}
    return -(ESCAPE_OFFSET_BIAS+(i32(1)<<(x-0xf0+16)))
}

@(private="file")
offsets_alt_bias :: #force_inline proc "contextless" (x:u32) -> i32 {
    n:=x>>OFFSET_ALT_UNDER_BITS
    if n>26 {return -MAX_OFFSET}
    top:=i32((x&((1<<OFFSET_ALT_UNDER_BITS)-1))|(1<<OFFSET_ALT_UNDER_BITS))
    return (1<<OFFSET_ALT_UNDER_BITS)-(top<<n)
}

@(private="file")
Offset_State :: struct {
    offs:[^]u8,
    offs_end:[^]u8,
    out:[^]i32,
    bitp:[2][^]u8, // forward: next byte; backward: one past it
    bitc:[2]u32,   // bits consumed of the current byte
}

@(private="file")
offset44_finish :: proc "contextless" (s:^Offset_State) -> bool #no_bounds_check {
    TAIL :: 8
    tail:[TAIL*2]u8
    final_in:=0
    offs,offs_end,out:=s.offs,s.offs_end,s.out
    bitp0,bitp1:=s.bitp[0],s.bitp[1]
    pre_switch:[^]u8
    bitc0,bitc1:=s.bitc[0],s.bitc[1]
    if uintptr(bitp0)>uintptr(bitp1) {return false}
    for offs!=offs_end {
        left:=ptr_diff(bitp1,bitp0)
        if left<TAIL {
            if final_in!=0 {return false}
            pre_switch=bitp0
            intrinsics.mem_copy_non_overlapping(&tail[0],bitp0,left)
            intrinsics.mem_copy_non_overlapping(&tail[len(tail)-left],bitp0,left)
            bitp0=([^]u8)(&tail[0])
            bitp1=bitp0[len(tail):]
            final_in=len(tail)-left
        }
        bits0:=load64be(bitp0)
        bits1:=load64(bitp1[-8:])
        for k in 0..<2 {
            if k==1 && offs==offs_end {break}
            bits:=k==0 ? bits0 : bits1
            bitc:=k==0 ? &bitc0 : &bitc1
            packed:=u32(offs[0]);offs=offs[1:]
            o:i32
            if packed<0xf0 {
                n:=(packed>>4)+OFFSET_RAW_BITS
                m:=mask32(n)
                bitc^+=n
                raw:=i32(bits>>((64-bitc^)&63))&i32(m)
                o=((raw+i32(m))<<4)+(1<<4)+i32(packed&0xf)-(1<<(OFFSET_RAW_BITS+4))+MIN_OFFSET
            } else {
                n:=packed-0xf0+16
                if n>=30 {return false}
                m:=mask32(n)
                bitc^+=n
                raw:=i32(bits>>((64-bitc^)&63))&i32(m)
                o=raw+i32(m)+1+ESCAPE_OFFSET_BIAS
                if o>=MAX_OFFSET {return false}
            }
            out[0]=-o;out=out[1:]
        }
        bitp0=bitp0[bitc0>>3:];bitc0&=7
        bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
    }
    left:=ptr_diff(bitp1,bitp0)-int(bitc0>0)-int(bitc1>0)
    if left<final_in {return false}
    if final_in!=0 {
        pre1:=pre_switch[len(tail)-final_in:]
        s.bitp[0]=([^]u8)(uintptr(pre_switch)+uintptr(ptr_diff(bitp0,([^]u8)(&tail[0]))))
        s.bitp[1]=([^]u8)(uintptr(pre1)-uintptr(ptr_diff(([^]u8)(&tail[0])[len(tail):],bitp1)))
    } else {
        s.bitp[0]=([^]u8)(uintptr(bitp0))
        s.bitp[1]=([^]u8)(uintptr(bitp1))
    }
    s.bitc[0]=bitc0
    s.bitc[1]=bitc1
    s.offs=offs
    s.out=out
    return true
}

@(private="file") rotl64 :: #force_inline proc "contextless" (
    x:u64,n:u32,
) -> u64 {return x<<(n&63)|x>>((64-n)&63)}

@(private="file")
offset44_decode :: #force_inline proc "contextless" (s:^Offset_State) -> bool #no_bounds_check {
    offs,offs_end:=s.offs,s.offs_end
    if ptr_diff(offs_end,offs)>=8 && ptr_diff(s.bitp[1],s.bitp[0])>=8 {
        offs_end=offs_end[-7:]
        out:=s.out
        bitp0:=s.bitp[0]
        bitp1:=s.bitp[1][-8:]
        bitc0,bitc1:=s.bitc[0],s.bitc[1]
        SPLAT :: ~u64(0)/255
        for uintptr(offs)<uintptr(offs_end) {
            bitp0=bitp0[bitc0>>3:];bitc0&=7
            bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
            if uintptr(bitp0)>uintptr(bitp1) {break}
            bits0:=load64be(bitp0)
            bits1:=load64(bitp1)
            next:=load64(offs)
            hi:=next&0x808080808080
            if (0xef*SPLAT-next)&hi==0 {
                #unroll for i in 0..<6 {
                    packed:=u32(offs[i])
                    n:=(packed>>4)+OFFSET_RAW_BITS
                    raw:u32
                    if i&1==0 {raw=rotl_grab(bits0,&bitc0,n)} else {raw=rotl_grab(bits1,&bitc1,n)}
                    out[i]=offsets44_bias(packed)-(i32(raw)<<4)
                }
                offs=offs[6:];out=out[6:]
            } else {
                if (0xfd*SPLAT-next)&hi!=0 {return false}
                done:=6
                #unroll for i in 0..<6 {
                    if done==6 {
                        packed:=u32(offs[i])
                        n:=offsets44_count(packed)
                        raw:u32
                        if i&1==0 {raw=rotl_grab(bits0,&bitc0,n)} else {raw=rotl_grab(bits1,
                            &bitc1,n)}
                        out[i]=offsets44_bias(packed)-(packed>=0xf0 ? i32(raw) : i32(raw)<<4)
                        if i&1==1 && i<5 && (bitc0>=64-30 || bitc1>=64-30) {done=i+1}
                    }
                }
                offs=offs[done:];out=out[done:]
            }
        }
        s.offs=offs
        s.out=out
        bitp0=bitp0[bitc0>>3:];bitc0&=7
        bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
        s.bitp[0]=([^]u8)(uintptr(bitp0))
        s.bitp[1]=bitp1[8:]
        s.bitc[0]=bitc0
        s.bitc[1]=bitc1
    }
    return offset44_finish(s)
}

@(private="file")
rotl_grab :: #force_inline proc "contextless" (bits:u64,bitc:^u32,count:u32) -> u32 {
    bitc^+=count
    return u32(rotl64(bits,bitc^))&mask32(count)
}

@(private="file")
offset_alt_finish :: proc "contextless" (s:^Offset_State) -> bool #no_bounds_check {
    TAIL :: 8
    tail:[TAIL*2]u8
    final_in:=0
    offs,offs_end,out:=s.offs,s.offs_end,s.out
    bitp0,bitp1:=s.bitp[0],s.bitp[1]
    pre_switch:[^]u8
    bitc0,bitc1:=s.bitc[0],s.bitc[1]
    if uintptr(bitp0)>uintptr(bitp1) {return false}
    for offs!=offs_end {
        left:=ptr_diff(bitp1,bitp0)
        if left<TAIL {
            if final_in!=0 {return false}
            pre_switch=bitp0
            intrinsics.mem_copy_non_overlapping(&tail[0],bitp0,left)
            intrinsics.mem_copy_non_overlapping(&tail[len(tail)-left],bitp0,left)
            bitp0=([^]u8)(&tail[0])
            bitp1=bitp0[len(tail):]
            final_in=len(tail)-left
        }
        bits0:=load64be(bitp0)
        bits1:=load64(bitp1[-8:])
        for k in 0..<2 {
            if k==1 && offs==offs_end {break}
            bits:=k==0 ? bits0 : bits1
            bitc:=k==0 ? &bitc0 : &bitc1
            packed:=u32(offs[0]);offs=offs[1:]
            n:=packed>>OFFSET_ALT_UNDER_BITS
            if n>26 {return false}
            bitc^+=n
            lo:=i32(bits>>((64-bitc^)&63))&i32(mask32(n))
            hi:=i32((packed&((1<<OFFSET_ALT_UNDER_BITS)-1))|(1<<OFFSET_ALT_UNDER_BITS))
            out[0]=(1<<OFFSET_ALT_UNDER_BITS)-(lo|(hi<<n));out=out[1:]
        }
        bitp0=bitp0[bitc0>>3:];bitc0&=7
        bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
    }
    left:=ptr_diff(bitp1,bitp0)-int(bitc0>0)-int(bitc1>0)
    if left<final_in {return false}
    if final_in!=0 {
        pre1:=pre_switch[len(tail)-final_in:]
        s.bitp[0]=([^]u8)(uintptr(pre_switch)+uintptr(ptr_diff(bitp0,([^]u8)(&tail[0]))))
        s.bitp[1]=([^]u8)(uintptr(pre1)-uintptr(ptr_diff(([^]u8)(&tail[0])[len(tail):],bitp1)))
    } else {
        s.bitp[0]=([^]u8)(uintptr(bitp0))
        s.bitp[1]=([^]u8)(uintptr(bitp1))
    }
    s.bitc[0]=bitc0
    s.bitc[1]=bitc1
    s.offs=offs
    s.out=out
    return true
}

@(private="file")
offset_alt_decode :: #force_inline proc "contextless" (s:^Offset_State) -> bool #no_bounds_check {
    offs,offs_end:=s.offs,s.offs_end
    if ptr_diff(offs_end,offs)>=8 && ptr_diff(s.bitp[1],s.bitp[0])>=8 {
        offs_end=offs_end[-7:]
        out:=s.out
        bitp0:=s.bitp[0]
        bitp1:=s.bitp[1][-8:]
        bitc0,bitc1:=s.bitc[0],s.bitc[1]
        SPLAT :: ~u64(0)/255
        FIRST_LARGE :: 19<<OFFSET_ALT_UNDER_BITS
        FIRST_ILLEGAL :: 27<<OFFSET_ALT_UNDER_BITS
        for uintptr(offs)<uintptr(offs_end) {
            bitp0=bitp0[bitc0>>3:];bitc0&=7
            bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
            if uintptr(bitp0)>uintptr(bitp1) {break}
            bits0:=load64be(bitp0)
            bits1:=load64(bitp1)
            next:=load64(offs)
            hi:=next&0x808080808080
            if ((FIRST_LARGE-1)*SPLAT-next)&hi==0 {
                #unroll for i in 0..<6 {
                    packed:=u32(next>>(uint(i)*8))&0xff
                    n:=packed>>OFFSET_ALT_UNDER_BITS
                    raw:u32
                    if i&1==0 {raw=rotl_grab(bits0,&bitc0,n)} else {raw=rotl_grab(bits1,&bitc1,n)}
                    out[i]=offsets_alt_bias(packed)-i32(raw)
                }
                offs=offs[6:];out=out[6:]
            } else {
                if ((FIRST_ILLEGAL-1)*SPLAT-next)&hi!=0 {return false}
                done:=6
                #unroll for i in 0..<6 {
                    if done==6 {
                        packed:=u32(next>>(uint(i)*8))&0xff
                        n:=packed>>OFFSET_ALT_UNDER_BITS
                        raw:u32
                        if i&1==0 {raw=rotl_grab(bits0,&bitc0,n)} else {raw=rotl_grab(bits1,
                            &bitc1,n)}
                        out[i]=offsets_alt_bias(packed)-i32(raw)
                        if i&1==1 && i<5 && (bitc0>=64-26 || bitc1>=64-26) {done=i+1}
                    }
                }
                offs=offs[done:];out=out[done:]
            }
        }
        s.offs=offs
        s.out=out
        bitp0=bitp0[bitc0>>3:];bitc0&=7
        bitp1=bitp1[-int(bitc1>>3):];bitc1&=7
        s.bitp[0]=([^]u8)(uintptr(bitp0))
        s.bitp[1]=bitp1[8:]
        s.bitc[0]=bitc0
        s.bitc[1]=bitc1
    }
    return offset_alt_finish(s)
}

// Eight offsets at a time, four from each stream: a prefix sum of the raw bit
// counts gives where each field ends, a byte shuffle gathers the 32 bits that
// end there and a multiply aligns them. A group with a field too wide for
// that takes the scalar path.
@(private="file")
offsets_simd :: #force_inline proc "contextless" (
    s:^Offset_State,$ALT:bool,
) -> bool #no_bounds_check {
    U8x16 :: #simd[16]u8
    offs,offs_end:=s.offs,s.offs_end
    if ptr_diff(offs_end,offs)<8 || ptr_diff(s.bitp[1],s.bitp[0])<16 {return true}
    offs_end=offs_end[-7:]
    out:=s.out
    bitp0:=s.bitp[0]
    bitp1:=s.bitp[1][-16:]
    r0,r1:=uint(s.bitc[0]),uint(s.bitc[1])
    Z :: 16
    // Bit positions in the first byte of each stream, in lanes 0 and 1.
    start:=transmute(U8x16)#simd[2]u64{u64(r0|r1<<8),0}
    for uintptr(offs)<uintptr(offs_end) && uintptr(bitp0)<=uintptr(bitp1) {
        x:=transmute(U8x16)#simd[2]u64{load64(offs),0}
        // Widest field the 32-bit window holds: 24 bits.
        WIDE :: U8x16(25<<3) when ALT else U8x16(0xf0)
        if intrinsics.simd_reduce_or(intrinsics.simd_lanes_ge(x,WIDE))!=0 {
            // Four fields of up to 29 bits read 19 bytes ahead of stream 0.
            if ptr_diff(bitp1,bitp0)<8 {break}
            for i in 0..<8 {
                packed:=u32(offs[i])
                n:uint
                when ALT {
                    n=uint(packed>>OFFSET_ALT_UNDER_BITS)
                    if n>26 {return false}
                } else {
                    if packed>=0xfe {return false}
                    n=uint(offsets44_count(packed))
                }
                raw:u32
                if i&1==0 {
                    r0=uint(intrinsics.simd_extract(start,0))
                    raw=u32(((load64be(bitp0)<<r0)>>1)>>(63-n))
                    r0+=n
                    bitp0=bitp0[r0>>3:]
                    r0&=7
                    start=intrinsics.simd_replace(start,0,u8(r0))
                } else {
                    r1=uint(intrinsics.simd_extract(start,1))
                    raw=u32(((load64(bitp1[8:])<<r1)>>1)>>(63-n))
                    r1+=n
                    bitp1=bitp1[-int(r1>>3):]
                    r1&=7
                    start=intrinsics.simd_replace(start,1,u8(r1))
                }
                when ALT {
                    out[i]=offsets_alt_bias(packed)-i32(raw)
                } else {
                    out[i]=offsets44_bias(packed)-(packed>=0xf0 ? i32(raw) : i32(raw)<<4)
                }
            }
            offs=offs[8:];out=out[8:]
            continue
        }
        n:U8x16
        when ALT {
            n=intrinsics.simd_shr(x,U8x16(OFFSET_ALT_UNDER_BITS))
        } else {
            n=intrinsics.simd_shr(x,U8x16(4))+OFFSET_RAW_BITS
        }
        end:=n+start
        end+=intrinsics.simd_shuffle(U8x16{},end,0,0,16,17,18,19,20,21,0,0,0,0,0,0,0,0)
        end+=intrinsics.simd_shuffle(U8x16{},end,0,0,0,0,16,17,18,19,0,0,0,0,0,0,0,0)
        byte_end:=intrinsics.simd_shr(end,U8x16(3))
        shift:=end&7
        // One 256-bit row: stream 0 (offsets 0,2,4,6) below, stream 1 (1,3,5,7)
        // above. The byte gathers stay 128-bit: those are what every target
        // has for runtime indices.
        U32x8 :: #simd[8]u32
        idx0:=intrinsics.simd_shuffle(byte_end,byte_end,0,0,0,0,2,2,2,2,4,4,4,4,6,6,6,6)
        idx0-=U8x16{0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3}
        idx1:=U8x16{15,16,17,18,15,16,17,18,15,16,17,18,15,16,17,18}-
            intrinsics.simd_shuffle(byte_end,byte_end,1,1,1,1,3,3,3,3,5,5,5,5,7,7,7,7)
        w0:=intrinsics.simd_runtime_swizzle(intrinsics.unaligned_load((^U8x16)(bitp0)),idx0)
        w1:=intrinsics.simd_runtime_swizzle(intrinsics.unaligned_load((^U8x16)(bitp1)),idx1)
        w:=transmute(U32x8)intrinsics.simd_shuffle(w0,w1,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
            16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31)
        widen :: #force_inline proc "contextless" (v:U8x16) -> U32x8 {
            return transmute(U32x8)intrinsics.simd_shuffle(v,U8x16{},0,Z,Z,Z,2,Z,Z,Z,4,Z,Z,Z,6,Z,
                Z,Z,1,Z,Z,Z,3,Z,Z,Z,5,Z,Z,Z,7,Z,Z,Z)
        }
        n32:=widen(n)
        top:=intrinsics.simd_shl(U32x8(1),n32)
        v:=intrinsics.simd_shr(intrinsics.simd_shl(w,widen(shift)),U32x8(8))&(top-1)
        low:=widen(x&(U8x16(7) when ALT else U8x16(0xf)))
        o:U32x8
        when ALT {
            o=U32x8(1<<OFFSET_ALT_UNDER_BITS)-(v|intrinsics.simd_shl(low|8,n32))
        } else {
            BIAS :: (1<<(OFFSET_RAW_BITS+4))-MIN_OFFSET
            o=U32x8(BIAS)-intrinsics.simd_shl(v|top,U32x8(4))-low
        }
        intrinsics.unaligned_store((^U32x8)(out),intrinsics.simd_shuffle(o,o,0,4,1,5,2,6,3,7))
        bitp0=bitp0[intrinsics.simd_extract(byte_end,6):]
        bitp1=bitp1[-int(intrinsics.simd_extract(byte_end,7)):]
        start=intrinsics.simd_shuffle(shift,U8x16{},6,7,Z,Z,Z,Z,Z,Z,Z,Z,Z,Z,Z,Z,Z,Z)
        offs=offs[8:];out=out[8:]
    }
    s.offs=offs
    s.out=out
    s.bitp[0]=bitp0
    s.bitp[1]=bitp1[16:]
    s.bitc[0]=u32(intrinsics.simd_extract(start,0))
    s.bitc[1]=u32(intrinsics.simd_extract(start,1))
    return true
}

// Exp-Golomb excesses from a forward/backward pair until the cursors cross.
// end needs 4 writable entries past it. Returns the count, or -1.
@(private="file")
get_excesses :: proc "contextless" (
    vb1,vb2:^Bits,base,end:[^]u32,expected:int,
) -> int #no_bounds_check {
    b1,b2:=vb1^,vb2^
    init1:=bits_end_ptr(&b1)
    init2:=bits_back_end_ptr(&b2)
    if uintptr(init1)>uintptr(init2) {return -1}
    out:=base
    LOOP_BYTES :: 32
    for ptr_diff(b2.cur,b1.cur)>LOOP_BYTES {
        if uintptr(out)>uintptr(end) {return -1}
        for _ in 0..<2 {
            bits_refill(&b1)
            bits_refill_back(&b2)
            e1,ok1:=bits_get_expgolomb(&b1,EXCESS_EXPGOLOMB_SHIFT)
            if !ok1 {return -1}
            e2,ok2:=bits_get_expgolomb(&b2,EXCESS_EXPGOLOMB_SHIFT)
            if !ok2 {return -1}
            out[0]=e1;out[1]=e2
            out=out[2:]
        }
    }
    PAD :: 8
    PRE_PAD :: 2*PAD
    tail:[PRE_PAD+LOOP_BYTES+2*PAD]u8
    {
        rem:=ptr_diff(b2.cur,b1.cur)
        head:=min(ptr_diff(b1.cur,init1),PAD)
        tail_pad:=min(ptr_diff(init2,b2.cur),PAD)
        newf:=([^]u8)(&tail[PRE_PAD+PAD])
        n:=rem+head+tail_pad
        if n<0 || head<0 || tail_pad<0 {return -1}
        intrinsics.mem_copy_non_overlapping(newf[-head:],b1.cur[-head:],n)
        b1.cur=newf
        b2.cur=newf[rem:]
    }
    consumed1:=bits_end_ptr(&b1)
    consumed2:=bits_back_end_ptr(&b2)
    MAX_LZ :: 18-EXCESS_EXPGOLOMB_SHIFT
    minval:=u64(1)<<(63-MAX_LZ)
    for {
        if uintptr(out)>uintptr(end) {return -1}
        bits_refill(&b1)
        if b1.bits<minval {
            bits_use(&b1,MAX_LZ+1)
            consumed1=bits_end_ptr(&b1)
            if uintptr(consumed1)>uintptr(consumed2) {break}
            return -1
        }
        e,_:=bits_get_expgolomb(&b1,EXCESS_EXPGOLOMB_SHIFT)
        consumed1=bits_end_ptr(&b1)
        if uintptr(consumed1)>uintptr(consumed2) {break}
        out[0]=e;out=out[1:]
        bits_refill_back(&b2)
        if b2.bits<minval {
            bits_use(&b2,MAX_LZ+1)
            consumed2=bits_back_end_ptr(&b2)
            if uintptr(consumed1)>uintptr(consumed2) {break}
            return -1
        }
        e,_=bits_get_expgolomb(&b2,EXCESS_EXPGOLOMB_SHIFT)
        consumed2=bits_back_end_ptr(&b2)
        if uintptr(consumed1)>uintptr(consumed2) {break}
        out[0]=e;out=out[1:]
    }
    if uintptr(out)>uintptr(end) {return -1}
    count:=ptr_diff(([^]u8)(out),([^]u8)(base))/4
    if expected!=0 && expected!=count {return -1}
    return count
}

// The arrays get_offsets_excesses decodes from and into.
@(private)
Offsets_Job :: struct {
    comp,comp_end:[^]u8,
    offs_u8,offs_u8_2:[^]u8, // entropy-coded offset bytes; second: alt low parts
    offs_count:int,
    alt_modulo:u32, // 0: 4+4 offsets
    excess_u8:[^]u8,
    excess_count:int,
    offsets:[^]i32,
    excesses:[^]u32,
    excess_header:u8,
    excess_stream:int, // bytes of the excess stream pair at the end of comp
}

// Decodes the raw bits of the offsets into negative distances and the excess
// lengths (biased by LZ_LRL_MAX). Returns false on a bad stream.
@(private)
get_offsets_excesses :: proc "contextless" (j:^Offsets_Job) -> bool {
    if uintptr(j.comp)>=uintptr(j.comp_end) && j.excess_header==0 {return false}
    if j.excess_stream>ptr_diff(j.comp_end,j.comp) {return false}
    when ODIN_ARCH==.amd64 {
        features:=info.cpu_features()
        if !FORCE_GENERIC && .bmi2 in features && .avx2 in features {
            return offsets_excesses_avx2(j)
        }
    }
    return offsets_excesses_generic(j)
}

@(private="file")
offsets_excesses_generic :: proc "contextless" (j:^Offsets_Job) -> bool {
    return offsets_excesses(j,!FORCE_GENERIC)
}

// Variable shifts in the scalar paths and 256-bit rows in the SIMD one.
@(private="file", enable_target_feature="bmi,bmi2,avx2")
offsets_excesses_avx2 :: proc "contextless" (j:^Offsets_Job) -> bool {
    return offsets_excesses(j,true)
}

@(private="file")
offsets_excesses :: #force_inline proc "contextless" (
    j:^Offsets_Job,$SIMD:bool,
) -> bool #no_bounds_check {
    comp,comp_end:=j.comp,j.comp_end
    offs_u8,offs_u8_2,offs_count,alt_modulo:=j.offs_u8,j.offs_u8_2,j.offs_count,j.alt_modulo
    excess_u8,excess_count:=j.excess_u8,j.excess_count
    offsets,excesses:=j.offsets,j.excesses
    excess_header,excess_stream:=j.excess_header,j.excess_stream
    fb:Front_Back(32)
    front_back_reset(&fb,comp,comp_end)
    ptr_end:=comp_end[-excess_stream:]
    b1,b2:Bits
    bits_open_no_refill(&b1,comp,ptr_end)
    bits_open_no_refill(&b2,ptr_end,ptr_end)
    if !front_back_safe(&fb,&b1.cur,&b2.cur) {return false}
    bits_refill(&b1)
    bits_refill_back(&b2)
    u32_count:=0
    if excess_header==0 {
        v,ok:=bits_get_expgolomb(&b2,0)
        if !ok {return false}
        u32_count=int(v)
        bits_refill_back(&b2)
    }
    if offs_count>0 {
        len1:=uint(bits_len(&b1))
        len2:=uint(bits_len(&b2))
        s:=Offset_State{
            offs=offs_u8,
            offs_end=offs_u8[offs_count:],
            out=offsets,
            bitp={b1.cur[-int((len1+7)>>3):],b2.cur[(len2+7)>>3:]},
            bitc={u32((0-len1)&7),u32((0-len2)&7)},
        }
        ok:bool
        if alt_modulo==0 {
            when SIMD {if !offsets_simd(&s,false) {return false}}
            ok=offset44_decode(&s)
        } else {
            when SIMD {if !offsets_simd(&s,true) {return false}}
            ok=offset_alt_decode(&s)
        }
        if !ok {return false}
        bits_open_no_refill(&b1,s.bitp[0],ptr_end)
        bits_open_no_refill(&b2,s.bitp[1],ptr_end)
        if !front_back_safe(&fb,&b1.cur,&b2.cur) {return false}
        bits_refill(&b1)
        bits_refill_back(&b2)
        bits_use(&b1,int(s.bitc[0]))
        bits_use(&b2,int(s.bitc[1]))
        if alt_modulo>1 {
            m:=i32(alt_modulo)
            for i in 0..<offs_count {offsets[i]=offsets[i]*m-i32(offs_u8_2[i])}
        }
    }
    if excess_header!=0 {
        if bits_end_ptr(&b1)!=bits_back_end_ptr(&b2) {return false}
        if excess_stream!=0 {
            start:=comp_end[-excess_stream:]
            front_back_reset(&fb,start,comp_end)
            bits_open_no_refill(&b1,start,comp_end)
            bits_open_no_refill(&b2,comp_end,comp_end)
        }
    }
    if u32_count>0 || excess_stream>0 {
        EXCESS_MAX :: CHUNK_LEN/256
        big:[EXCESS_MAX+8]u32 = ---
        decoded:=get_excesses(&b1,&b2,&big[0],([^]u32)(&big[0])[EXCESS_MAX:],u32_count)
        if decoded<0 || decoded>excess_count {return false}
        bi:=0
        for i in 0..<excess_count {
            x:=u32(excess_u8[i])
            if x==255 {
                if bi>=decoded {return false}
                x+=big[bi];bi+=1
            }
            excesses[i]=x+LZ_LRL_MAX
        }
        if bi!=decoded {return false}
    } else {
        if bits_end_ptr(&b1)!=bits_back_end_ptr(&b2) {return false}
        for i in 0..<excess_count {excesses[i]=u32(excess_u8[i])+LZ_LRL_MAX}
    }
    return true
}
