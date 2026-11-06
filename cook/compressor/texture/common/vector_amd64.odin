#+build amd64
package common

@(private="file",default_calling_convention="none")
foreign _ {
    @(link_name="llvm.x86.sse2.pmadd.wd")
    pmaddwd :: proc(a,b:V8i16) -> V4i32 ---
    @(link_name="llvm.x86.ssse3.pmul.hr.sw.128")
    pmulhrsw :: proc(a,b:V8i16) -> V8i16 ---
    @(link_name="llvm.x86.sse.cvtss2si")
    cvtss2si :: proc(a:V4f32) -> i32 ---
    @(link_name="llvm.x86.sse2.cvtps2dq")
    cvtps2dq :: proc(a:V4f32) -> V4i32 ---
    @(link_name="llvm.x86.ssse3.pmadd.ub.sw.128")
    pmaddubsw :: proc(a:V16u8,b:#simd[16]i8) -> V8i16 ---
    @(link_name="llvm.x86.sse2.psad.bw")
    psadbw :: proc(a,b:V16u8) -> #simd[2]u64 ---
}

// a[2i]*b[2i]+a[2i+1]*b[2i+1] in 32 bits.
madd_i16 :: #force_inline proc "contextless" (a,b:V8i16) -> V4i32 {return pmaddwd(a,b)}

// The dot products of each four bytes of a with those of b, b at most 64 (pmaddubsw, which
// saturates above).
dot4_u8 :: #force_inline proc "contextless" (a,b:V16u8) -> V4i32 {
    return pmaddwd(pmaddubsw(a,transmute(#simd[16]i8)b),V8i16(1))
}

// (a*b+(1<<14))>>15, rounded high half of the product.
mulhrs_i16 :: #force_inline proc "contextless" (a,b:V8i16) -> V8i16 {return pmulhrsw(a,b)}

// The sums of the absolute differences of bytes 0-7 and 8-15, in lanes 0 and 2 (psadbw).
sad_halves :: #force_inline proc "contextless" (a,b:V16u8) -> V4u32 {
    return transmute(V4u32)psadbw(a,b)
}

// Round to nearest, ties to even (cvtss2si); NaN and values out of the i32 range give
// min(i32).
round_to_int :: #force_inline proc "contextless" (x:f32) -> i32 {
    return cvtss2si(V4f32{x,0,0,0})
}

// round_to_int of each lane (cvtps2dq).
round_to_int4 :: #force_inline proc "contextless" (x:V4f32) -> V4i32 {
    return cvtps2dq(x)
}
