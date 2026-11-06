#+build !amd64
package common

import "core:simd"

// Round to nearest, ties to even; NaN and values out of the i32 range give min(i32), as the
// conversion instruction does.
round_to_int :: #force_inline proc "contextless" (x:f32) -> i32 {
    if !(abs(x)<2147483648.0) {return min(i32)}
    return i32(simd.extract(simd.nearest(#simd[4]f32{x,0,0,0}),0))
}

// round_to_int of each lane.
round_to_int4 :: #force_inline proc "contextless" (x:V4f32) -> V4i32 {
    ok:=simd.lanes_ge(x,V4f32(-2147483648.0))&simd.lanes_lt(x,V4f32(2147483648.0))
    q:=cast(V4i32)simd.nearest(simd.select(ok,x,V4f32(0)))
    return simd.select(ok,q,V4i32(min(i32)))
}

// The sums of the absolute differences of bytes 0-7 and 8-15, in lanes 0 and 2 (psadbw).
// Not reduce_add_bisect: it keeps half of the sum (llvm/llvm-project#239204).
sad_halves :: #force_inline proc "contextless" (a,b:V16u8) -> V4u32 {
    d:=simd.max(a,b)-simd.min(a,b)
    lo:=simd.reduce_add_ordered(cast(#simd[8]u32)simd.shuffle(d,d,0,1,2,3,4,5,6,7))
    hi:=simd.reduce_add_ordered(cast(#simd[8]u32)simd.shuffle(d,d,8,9,10,11,12,13,14,15))
    return V4u32{lo,0,hi,0}
}

// The dot products of each four bytes of a with those of b, b at most 64.
dot4_u8 :: #force_inline proc "contextless" (a,b:V16u8) -> V4i32 {
    p:=transmute(#simd[16]i32)((cast(#simd[16]u32)a)*(cast(#simd[16]u32)b))
    return (simd.shuffle(p,p,0,4,8,12)+simd.shuffle(p,p,1,5,9,13))+
        (simd.shuffle(p,p,2,6,10,14)+simd.shuffle(p,p,3,7,11,15))
}

// a[2i]*b[2i]+a[2i+1]*b[2i+1] in 32 bits.
madd_i16 :: #force_inline proc "contextless" (a,b:V8i16) -> V4i32 {
    p:=(cast(#simd[8]i32)a)*(cast(#simd[8]i32)b)
    return simd.shuffle(p,p,0,2,4,6)+simd.shuffle(p,p,1,3,5,7)
}

when ODIN_ARCH==.arm64 {
    @(private="file",default_calling_convention="none")
    foreign _ {
        @(link_name="llvm.aarch64.neon.sqrdmulh.v8i16")
        sqrdmulh :: proc(a,b:V8i16) -> V8i16 ---
    }

    // (a*b+(1<<14))>>15, rounded high half of the product (saturated only for -32768^2).
    mulhrs_i16 :: #force_inline proc "contextless" (a,b:V8i16) -> V8i16 {return sqrdmulh(a,b)}
} else {
    mulhrs_i16 :: #force_inline proc "contextless" (a,b:V8i16) -> V8i16 {
        V8i32x :: #simd[8]i32
        V8u32x :: #simd[8]u32
        p:=(cast(V8i32x)a)*(cast(V8i32x)b)+V8i32x(1<<14)
        return cast(V8i16)simd.shr(p,V8u32x(15))
    }
}
