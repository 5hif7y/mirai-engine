#+build amd64
package bc7

import "base:intrinsics"
import "core:simd"
import x86 "core:simd/x86"
import "core:sys/info"

// The AVX2 kernels: eight texels per vector, as texels 0,1,4,5 and 2,3,6,7
// in 16-bit lanes so the dot products come out in texel order. Every build gives the same
// result. Bodies of their own: no polymorphic #simd width (odin-lang/Odin#8198).
// x86 byte shuffles: a 32-byte runtime_swizzle is scalar code (odin-lang/Odin#8199).

@(private="file")
cpu_avx2 :: #force_inline proc "contextless" () -> bool {return .avx2 in info.cpu_features()}

@(private)
calc_vector_inds_linear :: #force_inline proc "contextless" (out_inds:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,n:int,$IB:int,$NC:int) -> Error {
    if cpu_avx2() {return vector_inds_linear_avx2(out_inds,in_,ep,n,IB,NC)}
    return vector_inds_linear_128(out_inds,in_,ep,n,IB,NC)
}

@(private)
calc_twoindex_linear :: #force_inline proc "contextless" (idx_v,idx_s:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,$IBV,$IBS:int) -> (vec_err,scalar_err:Error) {
    if cpu_avx2() {return twoindex_linear_avx2(idx_v,idx_s,in_,ep,IBV,IBS)}
    return twoindex_linear_128(idx_v,idx_s,in_,ep,IBV,IBS)
}

@(private)
calc_vector_err :: #force_inline proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int,$NC:int) -> Error {
    if cpu_avx2() {return vector_err_avx2(inds,in_,ep,IB,NC)}
    return vector_err_128(inds,in_,ep,IB,NC)
}

@(private)
analysis_compute :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,masks:[]u32,
    scale:[]f32,first,count:int,is_rgba:bool) {
    if cpu_avx2() {analysis_compute_avx2(a,pixels,masks,scale,first,count,is_rgba);return}
    analysis_compute_body(a,pixels,masks,scale,first,count,is_rgba)
}

@(private)
analysis_compute_1subset :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,first:int) {
    if cpu_avx2() {analysis_compute_1subset_avx2(a,pixels,first);return}
    analysis_compute_1subset_body(a,pixels,first)
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
analysis_compute_avx2 :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,masks:[]u32,
    scale:[]f32,first,count:int,is_rgba:bool) {
    analysis_compute_body(a,pixels,masks,scale,first,count,is_rgba)
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
analysis_compute_1subset_avx2 :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,
    first:int) {
    analysis_compute_1subset_body(a,pixels,first)
}

@(private="file")
M256 :: x86.__m256i
@(private="file")
V16s :: #simd[16]i16
@(private="file")
V4q :: #simd[4]u64

@(private="file",enable_target_feature="ssse3,avx,avx2")
m :: #force_inline proc "contextless" (v:$T) -> M256 {return transmute(M256)v}
@(private="file",enable_target_feature="ssse3,avx,avx2")
s16 :: #force_inline proc "contextless" (v:M256) -> V16s {return transmute(V16s)v}

// Byte shuffle that spreads, per 128-bit lane, the weight bytes a and b (low lane) or c and
// d (high lane) to the high bytes of four 16-bit lanes each.
@(private="file",enable_target_feature="ssse3,avx,avx2")
spread :: #force_inline proc "contextless" ($a,$b,$c,$d:i8) -> M256 {
    return transmute(M256)#simd[32]i8{-1,a,-1,a,-1,a,-1,a,-1,b,-1,b,-1,b,-1,b,-1,c,-1,c,-1,c,-1,
        c,-1,d,-1,d,-1,d,-1,d}
}

// The four channel weights in every texel, with A cleared for NC 3.
@(private="file",enable_target_feature="ssse3,avx,avx2")
weights16 :: #force_inline proc "contextless" (in_:^Subset_Input,$NC:int) -> V16s {
    w:=transmute(V16s)V4q(transmute(u64)in_.channel_weights)
    when NC==3 {w&=V16s{-1,-1,-1,0,-1,-1,-1,0,-1,-1,-1,0,-1,-1,-1,0}}
    return w
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
endpoints256 :: #force_inline proc "contextless" (ep:^[2]Color) -> (lo,hi:V16s) {
    e:=cast(V8s)transmute(#simd[8]u8)ep^
    lo=simd.shuffle(e,e,0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3)
    hi=simd.shuffle(e,e,4,5,6,7,4,5,6,7,4,5,6,7,4,5,6,7)
    return
}

// Texels 0,1,4,5 and 2,3,6,7 of the eight at p, channels in 16-bit lanes.
@(private="file",enable_target_feature="ssse3,avx,avx2")
texels8 :: #force_inline proc "contextless" (p:[^]Color) -> (a,b:V16s) {
    v:=intrinsics.unaligned_load((^M256)(p))
    z:M256
    return s16(x86._mm256_unpacklo_epi8(v,z)),s16(x86._mm256_unpackhi_epi8(v,z))
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
dot8 :: #force_inline proc "contextless" (a0,a1,b0,b1:V16s) -> V8i {
    return transmute(V8i)x86._mm256_hadd_epi32(x86._mm256_madd_epi16(m(a0),m(b0)),
        x86._mm256_madd_epi16(m(a1),m(b1)))
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
interp :: #force_inline proc "contextless" (lerpf,diff,base:V16s) -> V16s {
    return s16(x86._mm256_mulhrs_epi16(m(lerpf),m(diff)))+base
}

@(private,enable_target_feature="ssse3,avx,avx2")
vector_inds_linear_avx2 :: proc "contextless" (out_inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    n:int,$IB:int,$NC:int) -> Error {
    return vector_inds_linear_body(out_inds,in_,ep,n,IB,NC)
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
vector_inds_linear_body :: #force_inline proc "contextless" (out_inds:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,n:int,$IB:int,$NC:int) -> Error #no_bounds_check {
    tab:=x86._mm256_broadcastsi128_si256(transmute(x86.__m128i)LERP_NEG2X[IB])
    index_scale:=f32((int(1)<<uint(IB))-1)
    cw:=weights16(in_,NC)
    lo,hi:=endpoints256(ep)
    diff:=lo-hi
    diffw:=diff*cw
    dots:=transmute(V8i)x86._mm256_madd_epi16(m(diff),m(diffw))
    dots+=simd.shuffle(dots,dots,1,0,3,2,5,4,7,6)
    scalef:=V8f(index_scale)/cast(V8f)dots
    vmaxq:=V8f(index_scale)
    // The texels of group 8g on, their indices stored 8 at a time: the bytes past
    // the subset are not read.
    @(enable_target_feature="ssse3,avx,avx2")
    group :: #force_inline proc "contextless" (p:[^]Color,lo,diff,diffw,cw:V16s,scalef,
        vmaxq:V8f,tab:M256,out:^u64) -> V8i {
        p0,p1:=texels8(p)
        rel0:=lo-p0
        rel1:=lo-p1
        qf:=cast(V8f)dot8(rel0,rel1,diffw,diffw)*scalef
        qf=simd.select(simd.lanes_gt(qf,V8f(0)),qf,V8f(0))
        qf=simd.select(simd.lanes_lt(qf,vmaxq),qf,vmaxq)
        q:=transmute(V8i)x86._mm256_cvtps_epi32(transmute(x86.__m256)qf)
        // The low bytes of the indices, in texel order.
        qb:=transmute(V8i)x86._mm256_shuffle_epi8(m(q),m(V8i(0x0c080400)))
        intrinsics.unaligned_store(out,transmute(u64)simd.shuffle(qb,qb,0,4))
        wq:=x86._mm256_shuffle_epi8(tab,m(q))
        l0:=s16(x86._mm256_shuffle_epi8(wq,spread(0,4,0,4)))
        l1:=s16(x86._mm256_shuffle_epi8(wq,spread(8,12,8,12)))
        e0:=interp(l0,diff,rel0)
        e1:=interp(l1,diff,rel1)
        return dot8(e0,e1,e0*cw,e1*cw)
    }
    IOTA :: V8i{0,1,2,3,4,5,6,7}
    outs:=([^]u64)(out_inds)
    total:=group(in_.pixels,lo,diff,diffw,cw,scalef,vmaxq,tab,&outs[0])&
        transmute(V8i)simd.lanes_lt(IOTA,V8i(i32(n)))
    if n>8 {
        total+=group(in_.pixels[8:],lo,diff,diffw,cw,scalef,vmaxq,tab,&outs[1])&
            transmute(V8i)simd.lanes_lt(IOTA,V8i(i32(n-8)))
    }
    return Error(simd.reduce_add_ordered(total))
}

// The vector indices of a 16-texel subset with IBV bits and the scalar (A) ones with IBS bits
// (avx2_calc_inds_linear_twoindex); returns the vector error and the weighted scalar one.
@(private,enable_target_feature="sse2,ssse3,avx,avx2")
twoindex_linear_avx2 :: proc "contextless" (idx_v,idx_s:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IBV,$IBS:int) -> (vec_err,scalar_err:Error) #no_bounds_check {
    vec_err=vector_inds_linear_body(idx_v,in_,ep,16,IBV,3)
    lo:=i32(ep[0][3])
    diff:=lo-i32(ep[1][3])
    p0:=intrinsics.unaligned_load((^V8u)(in_.pixels))
    p1:=intrinsics.unaligned_load((^V8u)(in_.pixels[8:]))
    rel0:=m(V8i(lo)-transmute(V8i)simd.shr(p0,V8u(24)))
    rel1:=m(V8i(lo)-transmute(V8i)simd.shr(p1,V8u(24)))
    // Texels 0-3, 8-11, 4-7, 12-15.
    rel16:=x86._mm256_packs_epi32(rel0,rel1)
    e:M256
    if diff!=0 {
        scalef:=V8f(f32((1<<uint(IBS))-1)/f32(diff))
        q0:=x86._mm256_cvtps_epi32(transmute(x86.__m256)(cast(V8f)transmute(V8i)rel0*scalef))
        q1:=x86._mm256_cvtps_epi32(transmute(x86.__m256)(cast(V8f)transmute(V8i)rel1*scalef))
        q16:=x86._mm256_packs_epi32(q0,q1)
        q8:=x86._mm_packus_epi16(x86._mm256_castsi256_si128(q16),
            x86._mm256_extracti128_si256(q16,1))
        q8=x86._mm_min_epu8(q8,transmute(x86.__m128i)V16b(u8((1<<uint(IBS))-1)))
        intrinsics.unaligned_store((^x86.__m128i)(idx_s),x86._mm_shuffle_epi32(q8,0b11_01_10_00))
        w:=x86._mm_shuffle_epi8(transmute(x86.__m128i)LERP_NEG2X[IBS],q8)
        lerpf:=x86._mm256_slli_epi16(x86._mm256_cvtepi8_epi16(w),8)
        e=x86._mm256_add_epi16(x86._mm256_mulhrs_epi16(lerpf,x86._mm256_set1_epi16(i16(diff))),
            rel16)
    } else {
        idx_s^={}
        e=rel16
    }
    sum:=simd.reduce_add_ordered(transmute(V8i)x86._mm256_madd_epi16(e,e))
    scalar_err=Error(sum)*Error(in_.channel_weights[3])
    return
}

@(private,enable_target_feature="ssse3,avx,avx2")
vector_err_avx2 :: proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,$IB:int,
    $NC:int) -> Error #no_bounds_check {
    tab:=x86._mm256_broadcastsi128_si256(transmute(x86.__m128i)LERP_NEG2X[IB])
    lw:=x86._mm256_shuffle_epi8(tab,x86._mm256_broadcastsi128_si256(
        intrinsics.unaligned_load((^x86.__m128i)(inds))))
    cw:=weights16(in_,NC)
    lo,hi:=endpoints256(ep)
    diff:=lo-hi
    n:=in_.num_pixels
    total:V8i
    for g:=0; g<n; g+=8 {
        p0,p1:=texels8(in_.pixels[g:])
        l0,l1:V16s
        if g==0 {
            l0=s16(x86._mm256_shuffle_epi8(lw,spread(0,1,4,5)))
            l1=s16(x86._mm256_shuffle_epi8(lw,spread(2,3,6,7)))
        } else {
            l0=s16(x86._mm256_shuffle_epi8(lw,spread(8,9,12,13)))
            l1=s16(x86._mm256_shuffle_epi8(lw,spread(10,11,14,15)))
        }
        e0:=interp(l0,diff,lo-p0)
        e1:=interp(l1,diff,lo-p1)
        s:=dot8(e0,e1,e0*cw,e1*cw)
        if g+8>n {s&=transmute(V8i)simd.lanes_lt(V8i{0,1,2,3,4,5,6,7},V8i(i32(n-g)))}
        total+=s
    }
    return Error(simd.reduce_add_ordered(total))
}

@(private)
block_link_distortion :: #force_inline proc "contextless" (c:^Merge_Ctx,bi:int,
    blocks:[]Index_VQ_Block,infos:[]Block_Info,entry:int,must_beat_d:f32=LARGE_D) -> f32 {
    if cpu_avx2() {return block_link_distortion_avx2(c,bi,blocks,infos,entry,must_beat_d)}
    return block_link_distortion_128(c,bi,blocks,infos,entry,must_beat_d)
}

// merge_find_next_128, four texels per vector.
@(private)
merge_find_next :: #force_inline proc "contextless" (t:^Merge_Table,lerps:[]Merge_Lerps,
    from,count:int,thresh:u32,out_err:^u32) -> int {
    if cpu_avx2() {return merge_find_next_avx2(t,lerps,from,count,thresh,out_err)}
    return merge_find_next_128(t,lerps,from,count,thresh,out_err)
}

@(private="file")
Merge_Kernel :: struct {spread:[2]M256,diff,base:[4]M256}

@(private="file",enable_target_feature="ssse3,avx,avx2")
merge_kernel :: #force_inline proc "contextless" (t:^Merge_Table) -> (k:Merge_Kernel) {
    sp:=&MERGE_SPREAD[t.ind_sel&1]
    k.spread[0]=intrinsics.unaligned_load((^M256)(&sp[0]))
    k.spread[1]=intrinsics.unaligned_load((^M256)(&sp[2]))
    d:=([^]M256)(&t.diff)
    b:=([^]M256)(&t.base)
    for q in 0..<4 {
        k.diff[q]=intrinsics.unaligned_load(&d[q])
        k.base[q]=intrinsics.unaligned_load(&b[q])
    }
    return
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
merge_kernel_eval :: #force_inline proc "contextless" (k:^Merge_Kernel,lerps:^Merge_Lerps) -> u32 {
    l:=([^]x86.__m128i)(lerps)
    half:=[2]M256{x86._mm256_broadcastsi128_si256(intrinsics.unaligned_load(&l[0])),
        x86._mm256_broadcastsi128_si256(intrinsics.unaligned_load(&l[1]))}
    acc:M256
    #unroll for q in 0..<4 {
        f:=x86._mm256_shuffle_epi8(half[q>>1],k.spread[q&1])
        e:=x86._mm256_add_epi16(x86._mm256_mulhrs_epi16(f,k.diff[q]),k.base[q])
        acc=x86._mm256_add_epi32(acc,x86._mm256_madd_epi16(e,e))
    }
    return u32(simd.reduce_add_ordered(transmute(V8i)acc))
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
block_link_distortion_avx2 :: proc "contextless" (c:^Merge_Ctx,bi:int,blocks:[]Index_VQ_Block,
    infos:[]Block_Info,entry:int,must_beat_d:f32) -> f32 #no_bounds_check {
    d_sum:f32
    bi:=bi
    for bi>=0 {
        t:=merge_table(c,bi,blocks,infos)
        lerps:=merge_entry_lerps(c,t,bi,blocks,entry)
        k:=merge_kernel(t)
        d_sum+=f32(merge_kernel_eval(&k,lerps))*2.0
        if d_sum>must_beat_d {return LARGE_D}
        bi=blocks[bi].link
    }
    return d_sum
}

@(private="file",enable_target_feature="ssse3,avx,avx2")
merge_find_next_avx2 :: proc "contextless" (t:^Merge_Table,lerps:[]Merge_Lerps,from,count:int,
    thresh:u32,out_err:^u32) -> int #no_bounds_check {
    k:=merge_kernel(t)
    n:=min(count,len(lerps)-from)
    for i in 0..<n {
        e:=merge_kernel_eval(&k,&lerps[from+i])
        if e<=thresh {out_err^=e; return i}
    }
    return count
}
