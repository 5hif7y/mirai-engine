package bc7split

import "base:intrinsics"
import "core:simd"

// The per-mode transforms back to BC7 bits, written once over T: u64 for one block, or
// Lanes for LANES blocks side by side. Every step stays inside a 64-bit lane:
// shifts, masks, adds, xors and byte shuffles.

@(private) LANES :: 4
// An array, not a #simd vector, until #force_inline is honored at -o:none and -o:minimal
// (odin-lang/Odin#7780): a 256-bit vector passed by value between code built with and without AVX2
// changes registers. Arrays go through memory; at -o:speed it is all vector code again.
@(private) Lanes :: [LANES]u64
@(private) Vector :: #simd[LANES]u64

@(private)
shl :: #force_inline proc "contextless" (x:$T,$n:u64) -> T {
    when intrinsics.type_is_array(T) {
        return transmute(T)simd.shl_masked(transmute(Vector)x,Vector(n))
    } else {return x<<n}
}

@(private)
shr :: #force_inline proc "contextless" (x:$T,$n:u64) -> T {
    when intrinsics.type_is_array(T) {
        return transmute(T)simd.shr_masked(transmute(Vector)x,Vector(n))
    } else {return x>>n}
}

// Shift by a per-lane amount below 64.
@(private)
shlv :: #force_inline proc "contextless" (x,n:$T) -> T {
    when intrinsics.type_is_array(T) {
        return transmute(T)simd.shl_masked(transmute(Vector)x,transmute(Vector)n)
    } else {return x<<(n&63)}
}

@(private)
shrv :: #force_inline proc "contextless" (x,n:$T) -> T {
    when intrinsics.type_is_array(T) {
        return transmute(T)simd.shr_masked(transmute(Vector)x,transmute(Vector)n)
    } else {return x>>(n&63)}
}

// Adds the fields of a and b, each ending at a bit of msb, without carries between fields.
@(private)
packed_add :: #force_inline proc "contextless" (a,b:$T,$msb,$nonmsb:u64) -> T {
    return ((a&T(nonmsb))+(b&T(nonmsb)))~((a~b)&T(msb))
}

// (G, R-G, B-G) back to (R, G, B), field by field.
@(private)
decorr :: #force_inline proc "contextless" (r,g,b:^$T,$msb:u64) {
    y,cr,cb:=r^,g^,b^
    r^=packed_add(y,cr,msb,~msb)
    g^=y
    b^=packed_add(y,cb,msb,~msb)
}

@(private)
compact16to1_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=x&0x0001000100010001
    return (x|shr(x,15)|shr(x,30)|shr(x,45))&0xf
}

@(private)
compact16to1_2x :: #force_inline proc "contextless" (x:$T) -> T {
    return (x&1)|(shr(x,15)&2)
}

@(private)
compact16to5_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=x&0x001f001f001f001f
    x=(shr(x,11)|x)&0x000003ff000003ff
    return (shr(x,22)|x)&0xfffff
}

@(private)
compact16to5_2x :: #force_inline proc "contextless" (x:$T) -> T {
    return (x&0x1f)|(shr(x,11)&0x3e0)
}

// Bits other than the low 6 of each 16 must be clear.
@(private)
compact16to6_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=(shr(x,10)|x)&0x00000fff00000fff
    return (shr(x,20)|x)&0xffffff
}

@(private)
compact24to7_3x :: #force_inline proc "contextless" (x:$T) -> T {
    return (x&0x7f)|(shr(x,17)&0x3f80)|(shr(x,34)&0x1fc000)
}

@(private)
compact24to7_2x :: #force_inline proc "contextless" (x:$T) -> T {
    return (x&0x7f)|(shr(x,17)&0x3f80)
}

@(private)
compact32to7_2x :: #force_inline proc "contextless" (x:$T) -> T {
    return (x&0x7f)|(shr(x,25)&0x3f80)
}

@(private)
compact8to1_8x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=x&0x0101010101010101
    x|=shr(x,7)
    x|=shr(x,14)
    x|=shr(x,28)
    return x&0xff
}

// Bytes 0 4 1 5 2 6 3 7 of each 64-bit lane.
@(private)
zip_bytes :: #force_inline proc "contextless" (x:$T) -> T {
    when intrinsics.type_is_array(T) {
        #assert(LANES==4)
        b:=transmute(#simd[32]u8)x
        return transmute(T)simd.shuffle(b,b,
            0,4,1,5,2,6,3,7,8,12,9,13,10,14,11,15,16,20,17,21,18,22,19,23,24,28,25,29,26,30,27,31)
    } else {
        t:=(shr(x,16)~x)&0x00000000ffff0000
        x:=x~(t|shl(t,16))
        t=(shr(x,8)~x)&0x0000ff000000ff00
        return x~(t|shl(t,8))
    }
}

@(private)
compact8to7_8x :: #force_inline proc "contextless" (x:$T) -> T {
    STAY1 :: u64(0x007f007f007f007f)
    STAY2 :: u64(0x00003fff00003fff)
    STAY4 :: u64(0x000000000fffffff)
    x:=shr(x&(STAY1<<8),1)|(x&STAY1)
    x=shr(x&~STAY2,2)|(x&STAY2)
    return shr(x&~STAY4,4)|(x&STAY4)
}

@(private)
compact8to7_6x :: #force_inline proc "contextless" (x:$T) -> T {
    STAY1 :: u64(0x007f007f007f)
    x:=shr(x&(STAY1<<8),1)|(x&STAY1)
    return (x&0xffff)|(shr(x,2)&0x0000fffc000)|(shr(x,4)&0x3fff0000000)
}

@(private)
expand4to5_12x :: #force_inline proc "contextless" (x:$T) -> T {
    STAY2 :: u64(0x0000ff000ff000ff)
    x:=shl(x&0x0000ffff00000000,8)|shl(x&0x00000000ffff0000,4)|(x&0xffff)
    x=shl(x&~STAY2,2)|(x&STAY2)
    return x+(x&0x03c0f03c0f03c0f0)
}

@(private)
expand4to5_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=shl(x&0x0ff00,2)|(x&0x000ff)
    return x+(x&0x3c0f0)
}

@(private)
expand2to6_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=(shl(x,8)|x)&0x0f00f
    return (shl(x,4)|x)&0xc30c3
}

@(private)
expand1to5_12x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=x&0xfff
    x=(x|shl(x,16)|shl(x,32))&0xf0000f0000f
    return (x|shl(x,4)|shl(x,8)|shl(x,12))&0x084210842108421
}

@(private)
expand1to5_4x :: #force_inline proc "contextless" (x:$T) -> T {
    x:=x&0xf
    return (x|shl(x,4)|shl(x,8)|shl(x,12))&0x8421
}

@(private)
mode0 :: #force_inline proc "contextless" (in_lo,in_hi:$T,$cs:bool) -> (lo,hi:T) {
    r:=in_lo&0xffffff
    g:=shr(in_lo,24)&0xffffff
    b:=shr(in_lo,48)|shl(in_hi&0xff,16)
    part:=shr(in_hi,8)&0xf
    when cs {decorr(&r,&g,&b,0x888888)}
    lo=1|shl(part,1)|shl(r,5)|shl(g,29)|shl(b,53)
    hi=shr(b,11)|(in_hi&~u64(0x1fff))
    return
}

@(private)
mode1 :: #force_inline proc "contextless" (rgbs,extra:$T,$cs:bool) -> (lo,hi:T) {
    r:=compact16to6_4x(rgbs&0x003f003f003f003f)
    g:=compact16to6_4x(shr(rgbs,5)&0x003e003e003e003e)
    b:=compact16to6_4x(shr(rgbs,10)&0x003e003e003e003e)
    gb:=expand2to6_4x(extra&0xff)
    g|=gb&0x41041
    b|=shr(gb,1)&0x41041
    when cs {decorr(&r,&g,&b,0x820820)}
    lo=2|(shr(extra,6)&0xfc)|shl(r,8)|shl(g,32)|shl(b,56)
    hi=shr(b,8)|(extra&~u64(0xffff))
    return
}

@(private)
mode2 :: #force_inline proc "contextless" (e0,e1,index:$T,$cs:bool) -> (lo,hi:T) {
    r:=compact16to5_4x(shr(e0,1))|shl(compact16to5_2x(shr(e1,1)),20)
    g:=compact16to5_4x(shr(e0,6))|shl(compact16to5_2x(shr(e1,6)),20)
    b:=compact16to5_4x(shr(e0,11))|shl(compact16to5_2x(shr(e1,11)),20)
    part:=compact16to1_4x(e0)|shl(compact16to1_2x(e1),4)
    when cs {decorr(&r,&g,&b,0x21084210)}
    lo=4|shl(part,3)|shl(r,9)|shl(g,39)
    // The 3 bits below the index are unused; whatever they hold, the block gets zeros.
    hi=shr(g,25)|shl(b,5)|shl(index&0xfffffff8,32)
    return
}

@(private)
mode3 :: #force_inline proc "contextless" (e0,e1,index:$T,$cs:bool) -> (lo,hi:T) {
    r:=compact24to7_3x(e0)|shl(e1&0x007f00,13)
    g:=compact24to7_3x(shr(e0,8))|shl(e1&0x7f0000,5)
    b:=compact24to7_2x(shr(e0,16))|shl(compact24to7_2x(e1),14)
    part:=compact8to1_8x(shr(e0,7))
    when cs {decorr(&r,&g,&b,0x8102040)}
    lo=8|shl(part&0x3f,4)|shl(r,10)|shl(g,38)
    hi=shr(g,26)|shl(b,2)|shl(part&0xc0,24)|shl(index,32)
    return
}

@(private)
mode4 :: #force_inline proc "contextless" (in_lo,in_hi0,in_hi1:$T,$cs:bool) -> (lo,hi:T) {
    rgba:=shr(in_lo,2)&0xffffffffff
    when cs {
        y:=rgba&0x3ff
        ybroad:=y|shl(y,10)|shl(y,20)
        crcba:=(shr(rgba,10)&0x3ff)|(rgba&0xfffff00000)
        rgba=packed_add(ybroad,crcba,0x8421084210,~u64(0x8421084210))
    }
    crot:=in_hi0&3
    // Swaps alpha back with the rotated channel.
    rot:=(0-crot)&3
    shift:=shl(rot,3)+shl(rot,1)
    swap:=(rgba~shlv(rgba,shift))&0xffc0000000
    rgba~=swap
    rgba~=shrv(swap,shift)
    // Room for the low alpha bits, then the bits themselves.
    rgba+=rgba&0x0ffc0000000
    rgba+=rgba&0x1f000000000
    a:=in_lo&3
    rgba|=shl((a|shl(a,5))&0x41,30)
    lo=0x10|shl(crot,5)|shl(shr(in_lo,42)&1,7)|shl(rgba,8)|shl(shr(in_hi0,2)&0x3fff,50)
    hi=in_hi1
    return
}

@(private)
mode5 :: #force_inline proc "contextless" (endpoints,indices:$T,$cs:bool) -> (lo,hi:T) {
    e:=endpoints
    crot:=indices&3
    rot:=(0-crot)&3
    lo=0x20|shl(crot,6)
    when cs {
        r:=e&0x000000fe000000fe
        g:=shr(e,8)&0x000000fe000000fe
        b:=shr(e,16)&0x000000fe000000fe
        y,cr,cb:=r,g,b
        r=packed_add(y,cr,0x8000000080,0x7e0000007e)
        g=y
        b=packed_add(y,cb,0x8000000080,0x7e0000007e)
        e=r|shl(g,8)|shl(b,16)|(e&0xff010101ff010101)
        shift:=shl(rot,3)
        swap:=(e~shlv(e,shift))&0xff000000ff000000
        e~=swap
        e~=shrv(swap,shift)
        lo|=shl(compact32to7_2x(shr(e,1)),8)
        lo|=shl(compact32to7_2x(shr(e,9)),22)
        lo|=shl(compact32to7_2x(shr(e,17)),36)
        lo|=shl(shr(e,24)&0xff,50)
    } else {
        shift:=shl(rot,4)
        swap:=(e~shlv(e,shift))&0xffff000000000000
        e~=swap
        e~=shrv(swap,shift)
        lo|=shl(compact8to7_6x(shr(e,1)),8)
        lo|=shl(shr(e,48)&0xff,50)
    }
    lo|=shl(shr(e,56)&0x3f,58)
    hi=(shr(e,62)&3)|(indices&~u64(3))
    return
}

@(private)
mode6 :: #force_inline proc "contextless" (endpoints,indices:$T,$cs:bool) -> (lo,hi:T) {
    // One 7-bit value per byte, endpoint by endpoint: r0 g0 b0 a0 r1 g1 b1 a1, here with
    // (G, R-G, B-G) in place of (R, G, B). A byte never carries into the next.
    e:=endpoints
    when cs {
        y:=e&0x0000007f0000007f
        rg:=((shr(e,8)&0x0000007f0000007f)+y)|shl(y,8)
        e=rg|((e&0xff7f0000ff7f0000)+shl(y,16))
        e=zip_bytes(e)
    }
    lo=0x40|shl(compact8to7_8x(e),7)|(endpoints&(1<<63))
    hi=indices
    return
}

@(private)
mode7 :: #force_inline proc "contextless" (prgbs,rest:$T,$cs:bool) -> (lo,hi:T) {
    lo=0x80|shl(shr(rest,28)&0x3f,8)
    when cs {
        r:=compact16to5_4x(shr(prgbs,1))
        g:=compact16to5_4x(shr(prgbs,6))
        b:=compact16to5_4x(shr(prgbs,11))
        p:=compact16to1_4x(prgbs)
        a:=shr(rest,8)&0xfffff
        decorr(&r,&g,&b,0x84210)
        lo|=shl(r,14)|shl(g,34)|shl(b,54)
        hi=shr(b,10)|shl(a,10)|shl(p,30)
    } else {
        p:=shr(rest,8)&0xf
        rgb:=shl(expand4to5_12x(prgbs),1)|expand1to5_12x(shr(rest,12))
        a:=shl(expand4to5_4x(shr(prgbs,48)),1)|expand1to5_4x(shr(rest,24))
        lo|=shl(rgb,14)
        hi=shr(rgb,50)|shl(a,10)|shl(p,30)
    }
    hi|=rest&~u64(0x3ffffffff)
    return
}

// A solid color as the low half of its mode 5 block; the high half is always 0xaaaaaaac.
@(private)
mode9 :: #force_inline proc "contextless" (color:$T,$cs:bool) -> T {
    BIT6 :: u64(0x40<<8|0x40<<22|0x40<<36)
    LO7 :: u64(0x7f<<8|0x7f<<22|0x7f<<36)
    r,g,b:=color&0xff,shr(color,8)&0xff,shr(color,16)&0xff
    when cs {
        y:=r
        r=(y+g)&0xff
        g=y
        b=(y+b)&0xff
    }
    bits:=shl(r,8)|shl(g,22)|shl(b,36)
    t:=shl(bits,6)
    bits=(shr(bits,1)&LO7)-(bits&~LO7)
    bits+=t+(t&BIT6)
    return bits|shl(shr(color,24),50)|0x20
}
