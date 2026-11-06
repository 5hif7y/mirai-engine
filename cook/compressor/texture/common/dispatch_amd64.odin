#+build amd64
package common

import "base:intrinsics"
import "core:simd"
import x86 "core:simd/x86"
import "core:sys/info"

// The AVX2 and AVX-512 kernels run the same bodies compiled for those
// instruction sets; those with an AVX-512 variant of their own take a whole block per vector.
// Every build gives the same result.

AVX2 :: "avx,avx2"
AVX512 :: "avx,avx2,avx512f,avx512bw,avx512vl,avx512dq"

cpu_avx2 :: #force_inline proc "contextless" () -> bool {return .avx2 in info.cpu_features()}

// The AVX-512 kernels run the cores with VBMI2, which keep their
// clock with 512-bit vectors.
cpu_avx512 :: #force_inline proc "contextless" () -> bool {
    f:=info.cpu_features()
    return f>={.avx512f,.avx512bw,.avx512vl,.avx512dq,.avx512vbmi2}
}

// Best index per texel (ties to the lower index); error is the sum of the RGB SSD of the
// choices (plus the alpha penalty, 0 for canonical input).
bc1_find_indices_palette :: proc "contextless" (b:^Color_Block,palette:^[4]Color,
    err:^u32=nil) -> u32 {
    if cpu_avx512() {return bc1_find_indices_avx512(b,palette,err)}
    if cpu_avx2() {return bc1_find_indices_avx2(b,palette,err)}
    return bc1_find_indices_body(b,palette,err)
}

bc1_eval_palettes :: proc "contextless" (ctx:^BC1_Find_Errors_Context,out_ssds:[]u32,
    palettes:[][4]Color) {
    if cpu_avx512() {bc1_eval_palettes_avx512(ctx,out_ssds,palettes);return}
    if cpu_avx2() {bc1_eval_palettes_avx2(ctx,out_ssds,palettes);return}
    bc1_eval_palettes_body(ctx,out_ssds,palettes)
}

// (best error << 8) | index of the best of up to 256 palettes; max(u32) when there are none.
bc1_find_best_palette :: proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palettes:[][4]Color) -> u32 {
    if cpu_avx512() {return bc1_find_best_palette_avx512(ctx,palettes)}
    if cpu_avx2() {return bc1_find_best_palette_avx2(ctx,palettes)}
    return bc1_find_best_palette_body(ctx,palettes)
}

// dest_ssd[i]: the best error of colors against vqendpoints[inds[i]&0xffff].palette.
batch_find_best_errors :: proc "contextless" (dest_ssd:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block) {
    if cpu_avx512() {batch_find_best_errors_avx512(dest_ssd,vqendpoints,inds,colors);return}
    if cpu_avx2() {batch_find_best_errors_avx2(dest_ssd,vqendpoints,inds,colors);return}
    batch_find_best_errors_body(dest_ssd,vqendpoints,inds,colors)
}

// dest_vqd[2i], dest_vqd[2i+1]: the VQD of colors against first_palette and second_palette
// with the indices vqindices[inds[i]].dw.
batch_compute_vqds :: proc "contextless" (dest_vqd:[]f32,vqindices:[]BC1_VQ_Entry,inds:[]i32,
    colors:^Color_Block,first_palette,second_palette:^[4]Color,activity:^Float_Block) {
    if cpu_avx512() {
        batch_compute_vqds_avx512(dest_vqd,vqindices,inds,colors,first_palette,second_palette,
            activity)
        return
    }
    if cpu_avx2() {
        batch_compute_vqds_avx2(dest_vqd,vqindices,inds,colors,first_palette,second_palette,
            activity)
        return
    }
    batch_compute_vqds_body(dest_vqd,vqindices,inds,colors,first_palette,second_palette,activity)
}

// chunk_sads[i] = SAD of pair_colors[indices[i]] against colors.
compute_chunk_sads_indirect :: proc "contextless" (chunk_sads:[]i32,indices:[]u16,
    pair_colors:[]Color_Block,colors:^Color_Block) {
    if cpu_avx512() {chunk_sads_avx512(chunk_sads,indices,pair_colors,colors);return}
    if cpu_avx2() {chunk_sads_avx2(chunk_sads,indices,pair_colors,colors);return}
    chunk_sads_from(chunk_sads,indices,pair_colors,colors,0)
}

// Positions i (in order) of the groups of 16 bytes of index_batch whose SAD to ref_inds is
// below threshold; returns how many. positions is written up to count.
filter_by_index_sad :: proc "contextless" (positions:[]i32,count:int,index_batch:[]u8,
    ref_inds:^[16]u8,threshold:i32) -> int {
    if cpu_avx512() {
        return filter_by_index_sad_avx512(positions,count,index_batch,ref_inds,threshold)
    }
    if cpu_avx2() {return filter_by_index_sad_avx2(positions,count,index_batch,ref_inds,threshold)}
    return filter_by_index_sad_from(positions,count,index_batch,ref_inds,threshold,0,0)
}

// Writes (i<<16)|inds[i] for the candidates not rejected by the color box test (nor, with
// require_3c, for being four color); returns how many.
filter_endpoint_color_bbox :: proc "contextless" (dest_inds:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,bbox:^[2]Color,bbox_min_d:u32,require_3c:bool) -> int {
    if cpu_avx512() {
        return filter_endpoint_color_bbox_avx512(dest_inds,vqendpoints,inds,bbox,bbox_min_d,
            require_3c)
    }
    if cpu_avx2() {
        return filter_endpoint_color_bbox_avx2(dest_inds,vqendpoints,inds,bbox,bbox_min_d,
            require_3c)
    }
    return filter_endpoint_color_bbox_from(dest_inds,vqendpoints,inds,bbox,bbox_min_d,require_3c,
        0,0)
}

// Activity weighted SSD of the RGBA of colors against what the indices pick from palette.
vqd_bc1 :: proc "contextless" (colors:^Color_Block,palette:^[4]Color,in_indices:u32,
    activity:^Float_Block) -> f32 {
    if cpu_avx2() {return vqd_bc1_avx2(colors,palette,in_indices,activity)}
    return vqd_bc1_body(colors,palette,in_indices,activity)
}

// bc4_change_distortion_batch_from from the first candidate.
bc4_change_distortion_batch :: proc "contextless" (dest:[]i32,pixels:^[16]i16,pal:^[8]i16,
    index8:[]u8,inds:[]i32) {
    if cpu_avx2() {bc4_change_distortion_batch_avx2(dest,pixels,pal,index8,inds);return}
    bc4_change_distortion_batch_from(dest,pixels,pal,index8,inds,0)
}

// out_d[i]: the distortion of in_indices[i]; returns the lowest, for early outs.
any_index_d_batch_lookup :: proc "contextless" (out_d:[]i32,aid:^Any_Index_D,
    in_indices:[]u32) -> i32 {
    if cpu_avx2() {return any_index_d_batch_lookup_avx2(out_d,aid,in_indices)}
    return any_index_d_batch_lookup_from(out_d,aid,in_indices,0,0x7fffffff)
}

// Four candidates at a time: the table holds the SSD of each index for two texels per vector,
// even texels in the low half and odd in the high, and vpermd picks them by the index bits.
@(private="file",enable_target_feature=AVX2)
any_index_d_batch_lookup_avx2 :: proc "contextless" (out_d:[]i32,aid:^Any_Index_D,
    in_indices:[]u32) -> i32 #no_bounds_check {
    n:=min(len(out_d),len(in_indices))
    if n<4 {return any_index_d_batch_lookup_from(out_d,aid,in_indices,0,0x7fffffff)}
    rows:=([^]V8u32)(&aid.ssd)
    errs:[8]x86.__m256i
    for h in 0..<2 {
        r0,r1:=intrinsics.unaligned_load(&rows[h]),intrinsics.unaligned_load(&rows[2+h])
        r2,r3:=intrinsics.unaligned_load(&rows[4+h]),intrinsics.unaligned_load(&rows[6+h])
        u01:=simd.shuffle(r0,r1,0,8,1,9,2,10,3,11)
        u23:=simd.shuffle(r2,r3,0,8,1,9,2,10,3,11)
        v01:=simd.shuffle(r0,r1,4,12,5,13,6,14,7,15)
        v23:=simd.shuffle(r2,r3,4,12,5,13,6,14,7,15)
        errs[h*4]=transmute(x86.__m256i)simd.shuffle(u01,u23,0,1,8,9,2,3,10,11)
        errs[h*4+1]=transmute(x86.__m256i)simd.shuffle(u01,u23,4,5,12,13,6,7,14,15)
        errs[h*4+2]=transmute(x86.__m256i)simd.shuffle(v01,v23,0,1,8,9,2,3,10,11)
        errs[h*4+3]=transmute(x86.__m256i)simd.shuffle(v01,v23,4,5,12,13,6,7,14,15)
    }
    min_d:=V4i32(0x7fffffff)
    i:=0
    for ; i+4<=n; i+=4 {
        q:=intrinsics.unaligned_load((^V4u32)(&in_indices[i]))
        v:=simd.shr(transmute(V8u32)[2]V4u32{q,q},V8u32{0,0,0,0,2,2,2,2})&V8u32(0x33333333)
        v|=V8u32{0,0,0,0,0x44444444,0x44444444,0x44444444,0x44444444}
        acc:=x86._mm256_permutevar8x32_epi32(errs[0],transmute(x86.__m256i)v)
        #unroll for k in 1..<8 {
            v=simd.shr(v,V8u32(4))
            acc=x86._mm256_add_epi32(acc,x86._mm256_permutevar8x32_epi32(errs[k],
                transmute(x86.__m256i)v))
        }
        a:=transmute(V8i32)acc
        d:=simd.shuffle(a,a,0,1,2,3)+simd.shuffle(a,a,4,5,6,7)
        intrinsics.unaligned_store((^V4i32)(&out_d[i]),d)
        min_d=simd.min(min_d,d)
    }
    return any_index_d_batch_lookup_from(out_d,aid,in_indices,i,simd.reduce_min(min_d))
}

// out_d[i]: the distortion of candidate i of packs, for count of them.
any_index_8d64_batch_lookup_packed :: proc "contextless" (out_d:[]i64,aid:^Any_Index_8D64,
    packs:[]Any_Index_8D64_Pack,count:int) {
    if cpu_avx2() {any_index_8d64_lookup_packed_avx2(out_d,aid,packs,count);return}
    any_index_8d64_lookup_packed_from(out_d,aid,packs,count,0)
}

// Eight candidates at a time with the low halves of the table in 32-bit lanes, when every
// entry is below 2^28 so that the sums of 16 fit.
@(private="file",enable_target_feature=AVX2)
any_index_8d64_lookup_packed_avx2 :: proc "contextless" (out_d:[]i64,aid:^Any_Index_8D64,
    packs:[]Any_Index_8D64_Pack,count:int) #no_bounds_check {
    n:=min(count,len(out_d),len(packs)*8)
    tabs:[16]x86.__m256i
    V4u64 :: #simd[4]u64
    high:V4u64
    rows:=([^]V4u64)(&aid.ssdx)
    for c in 0..<16 {
        a,b:=intrinsics.unaligned_load(&rows[2*c]),intrinsics.unaligned_load(&rows[2*c+1])
        high|=a|b
        tabs[c]=transmute(x86.__m256i)simd.shuffle(transmute(V8u32)a,transmute(V8u32)b,0,2,4,6,8,
            10,12,14)
    }
    if simd.reduce_or(simd.shr(high,V4u64(28)))!=0 {
        any_index_8d64_lookup_packed_from(out_d,aid,packs,count,0)
        return
    }
    i:=0
    for ; i+8<=n; i+=8 {
        p:=([^]x86.__m256i)(&packs[i>>3])
        acc:x86.__m256i
        #unroll for g in 0..<4 {
            v:=intrinsics.unaligned_load(&p[g])
            #unroll for j in 0..<4 {
                idx:=transmute(x86.__m256i)simd.shr(transmute(V8u32)v,V8u32(8*j))
                acc=x86._mm256_add_epi32(acc,x86._mm256_permutevar8x32_epi32(tabs[4*g+j],idx))
            }
        }
        d:=transmute([8]u32)acc
        for k in 0..<8 {out_d[i+k]=i64(d[k])}
    }
    any_index_8d64_lookup_packed_from(out_d,aid,packs,count,i)
}

@(private="file",default_calling_convention="none")
foreign _ {
    @(link_name="llvm.x86.avx2.psad.bw")
    psadbw256 :: proc(a,b:V32u8) -> #simd[4]u64 ---
    @(link_name="llvm.x86.avx512.psad.bw.512")
    psadbw512 :: proc(a,b:#simd[64]u8) -> #simd[8]u64 ---
    @(link_name="llvm.x86.avx512.pshuf.b.512")
    pshufb512 :: proc(a,b:#simd[64]u8) -> #simd[64]u8 ---
    @(link_name="llvm.x86.avx512.permvar.sf.512")
    permps512 :: proc(a:#simd[16]f32,b:#simd[16]i32) -> #simd[16]f32 ---
}

// base+k for each set bit k of the low eight bits of m, packed into to[0:8] (all eight are
// written); returns how many.
@(private="file",enable_target_feature=AVX2)
store_active_lanes8 :: #force_inline proc "contextless" (to:[^]i32,base:i32,
    m:u32) -> int #no_bounds_check {
    t:=ACTIVE_LANE_TABLE8[m&255]
    v:=transmute(V8i32)(simd.shr(V8u32(t),V8u32{0,4,8,12,16,20,24,28})&V8u32(15))+V8i32(base)
    intrinsics.unaligned_store((^V8i32)(to),v)
    return int(intrinsics.count_ones(m&255))
}

@(private="file",enable_target_feature=AVX2)
filter_by_index_sad_avx2 :: proc "contextless" (positions:[]i32,count:int,index_batch:[]u8,
    ref_inds:^[16]u8,threshold:i32) -> int #no_bounds_check {
    n:=min(count,len(positions),len(index_batch)/16)
    r:=load_u8x16(ref_inds)
    ref:=transmute(V32u8)[2]V16u8{r,r}
    thr:=V8i32(threshold)
    p:=raw_data(index_batch)
    i,out:=0,0
    for ; i+8<=n; i+=8 {
        g:=([^]V32u8)(&p[i*16])
        s0:=transmute(V8u32)psadbw256(ref,intrinsics.unaligned_load(&g[0]))
        s1:=transmute(V8u32)psadbw256(ref,intrinsics.unaligned_load(&g[1]))
        s2:=transmute(V8u32)psadbw256(ref,intrinsics.unaligned_load(&g[2]))
        s3:=transmute(V8u32)psadbw256(ref,intrinsics.unaligned_load(&g[3]))
        a:=simd.shuffle(s0,s1,0,2,4,6,8,10,12,14)
        b:=simd.shuffle(s2,s3,0,2,4,6,8,10,12,14)
        s:=simd.shuffle(a,b,0,2,4,6,8,10,12,14)+simd.shuffle(a,b,1,3,5,7,9,11,13,15)
        m:=u32(transmute(u8)simd.extract_msbs(simd.lanes_lt(transmute(V8i32)s,thr)))
        out+=store_active_lanes8(raw_data(positions[out:]),i32(i),m)
    }
    return filter_by_index_sad_from(positions,count,index_batch,ref_inds,threshold,i,out)
}

@(private="file",enable_target_feature=AVX512)
filter_by_index_sad_avx512 :: proc "contextless" (positions:[]i32,count:int,index_batch:[]u8,
    ref_inds:^[16]u8,threshold:i32) -> int #no_bounds_check {
    n:=min(count,len(positions),len(index_batch)/16)
    r:=load_u8x16(ref_inds)
    ref:=transmute(V64u8)[4]V16u8{r,r,r,r}
    thr:=V16i32(threshold)
    p:=raw_data(index_batch)
    i,out:=0,0
    for ; i+16<=n; i+=16 {
        g:=([^]V64u8)(&p[i*16])
        s0:=transmute(V16u32)psadbw512(ref,intrinsics.unaligned_load(&g[0]))
        s1:=transmute(V16u32)psadbw512(ref,intrinsics.unaligned_load(&g[1]))
        s2:=transmute(V16u32)psadbw512(ref,intrinsics.unaligned_load(&g[2]))
        s3:=transmute(V16u32)psadbw512(ref,intrinsics.unaligned_load(&g[3]))
        a:=simd.shuffle(s0,s1,0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30)
        b:=simd.shuffle(s2,s3,0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30)
        s:=simd.shuffle(a,b,0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30)+
            simd.shuffle(a,b,1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31)
        m:=u32(transmute(u16)simd.extract_msbs(simd.lanes_lt(transmute(V16i32)s,thr)))
        out+=store_active_lanes8(raw_data(positions[out:]),i32(i),m)
        out+=store_active_lanes8(raw_data(positions[out:]),i32(i+8),m>>8)
    }
    return filter_by_index_sad_from(positions,count,index_batch,ref_inds,threshold,i,out)
}

@(private="file",enable_target_feature=AVX2)
dist_to_bbox8 :: #force_inline proc "contextless" (v,lo,hi:V32u8) -> V8i32 {
    d:=simd.saturating_sub(lo,v)+simd.saturating_sub(v,hi)
    e:=transmute(x86.__m256i)(transmute(V16u16)d&V16u16(0xff))
    o:=transmute(x86.__m256i)simd.shr(transmute(V16u16)d,V16u16(8))
    return transmute(V8i32)x86._mm256_add_epi32(x86._mm256_madd_epi16(e,e),
        x86._mm256_madd_epi16(o,o))
}

// vqd_bc1_body two rows per vector, with the same order of the sums.
@(private="file",enable_target_feature=AVX2)
vqd_bc1_avx2 :: proc "contextless" (colors:^Color_Block,palette:^[4]Color,in_indices:u32,
    activity:^Float_Block) -> f32 #no_bounds_check {
    p:=load_u8x16(palette)
    pal:=transmute(x86.__m256i)[2]V16u8{p,p}
    c:=([^]x86.__m256i)(colors)
    a:=([^]V8f32)(activity)
    rows:[2]V8f32
    #unroll for h in 0..<2 {
        sel:=simd.shr(V8u32(in_indices>>uint(16*h)),V8u32{0,2,4,6,8,10,12,14})&V8u32(3)
        ctrl:=transmute(x86.__m256i)(simd.shl(sel,V8u32(2))*V8u32(0x01010101)+V8u32(0x03020100))
        px:=transmute(V32u8)x86._mm256_shuffle_epi8(pal,ctrl)
        col:=transmute(V32u8)intrinsics.unaligned_load(&c[h])
        d:=transmute(V16u16)(simd.max(col,px)-simd.min(col,px))
        lo:=transmute(x86.__m256i)(d&V16u16(0xff))
        hi:=transmute(x86.__m256i)simd.shr(d,V16u16(8))
        sq:=transmute(V8i32)x86._mm256_add_epi32(x86._mm256_madd_epi16(lo,lo),
            x86._mm256_madd_epi16(hi,hi))
        rows[h]=cast(V8f32)sq*intrinsics.unaligned_load(&a[h])
    }
    lanes:=((simd.shuffle(rows[0],rows[0],0,1,2,3)+simd.shuffle(rows[0],rows[0],4,5,6,7))+
        simd.shuffle(rows[1],rows[1],0,1,2,3))+simd.shuffle(rows[1],rows[1],4,5,6,7)
    l:=simd.to_array(lanes)
    return (l[0]+l[1])+(l[2]+l[3])
}

// Two candidates per vector.
@(private="file",enable_target_feature=AVX2)
bc4_change_distortion_batch_avx2 :: proc "contextless" (dest:[]i32,pixels:^[16]i16,pal:^[8]i16,
    index8:[]u8,inds:[]i32) #no_bounds_check {
    n:=min(len(dest),len(inds))
    m:=len(index8)/16
    t:=load_u8x16(pal)
    pal_lo:=transmute(V32u8)[2]V16u8{t,t}
    pal_hi:=simd.shuffle(pal_lo,pal_lo,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0,
        17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,16)
    px:=transmute([2]V8i16)pixels^
    p0:=transmute(V16i16)[2]V8i16{px[0],px[0]}
    p1:=transmute(V16i16)[2]V8i16{px[1],px[1]}
    k:=0
    for ; k+2<=n; k+=2 {
        j0,j1:=int(inds[k]),int(inds[k+1])
        if j0<0 || j0>=m || j1<0 || j1>=m {break}
        q:=transmute(x86.__m256i)([2]V16u8{load_u8x16(&index8[j0*16]),load_u8x16(&index8[j1*16])})&
            x86._mm256_set1_epi8(14)
        l:=x86._mm256_shuffle_epi8(transmute(x86.__m256i)pal_lo,q)
        h:=x86._mm256_shuffle_epi8(transmute(x86.__m256i)pal_hi,q)
        r0:=transmute(V16i16)x86._mm256_unpacklo_epi8(l,h)
        r1:=transmute(V16i16)x86._mm256_unpackhi_epi8(l,h)
        d0:=transmute(x86.__m256i)(r0-p0)
        d1:=transmute(x86.__m256i)(r1-p1)
        s:=transmute(V8i32)x86._mm256_add_epi32(x86._mm256_madd_epi16(d0,d0),
            x86._mm256_madd_epi16(d1,d1))
        dest[k]=simd.reduce_add_ordered(simd.shuffle(s,s,0,1,2,3))
        dest[k+1]=simd.reduce_add_ordered(simd.shuffle(s,s,4,5,6,7))
    }
    bc4_change_distortion_batch_from(dest,pixels,pal,index8,inds,k)
}

@(private="file",enable_target_feature=AVX512)
dist_to_bbox16 :: #force_inline proc "contextless" (v,lo,hi:V64u8) -> V16i32 {
    d:=transmute(V32u16)(simd.saturating_sub(lo,v)+simd.saturating_sub(v,hi))
    e:=transmute(V32i16)(d&V32u16(0xff))
    o:=transmute(V32i16)simd.shr(d,V32u16(8))
    return madd32(e,e)+madd32(o,o)
}

// filter_endpoint_color_bbox_avx2 sixteen candidates at a time, with gathers and a compressing
// store, as the reference AVX-512 kernel.
@(private="file",enable_target_feature=AVX512)
filter_endpoint_color_bbox_avx512 :: proc "contextless" (dest_inds:[]i32,
    vqendpoints:[]BC1_VQ_Entry,inds:[]i32,bbox:^[2]Color,bbox_min_d:u32,
    require_3c:bool) -> int #no_bounds_check {
    n:=min(len(inds),len(dest_inds),65535)
    i,out:=0,0
    if len(vqendpoints)>0 {
        V8u64 :: #simd[8]u64
        last:=V16u32(u32(min(len(vqendpoints)-1,int(max(u32)))))
        count:=V16u32(u32(min(len(vqendpoints),int(max(u32)))))
        base:=V8u64(u64(uintptr(&vqendpoints[0].palette)))
        lo:=transmute(V64u8)V16u32(color_dw(bbox[0]))
        hi:=transmute(V64u8)V16u32(color_dw(bbox[1]))
        min_d:=V16i32(i32(bbox_min_d))
        all:=#simd[8]bool{0..<8=true}
        for ; i+16<=n; i+=16 {
            iv:=intrinsics.unaligned_load((^V16i32)(&inds[i]))
            at:=simd.min(transmute(V16u32)iv,last)
            off0:=simd.shl(cast(V8u64)simd.shuffle(at,at,0,1,2,3,4,5,6,7),V8u64(5))
            off1:=simd.shl(cast(V8u64)simd.shuffle(at,at,8,9,10,11,12,13,14,15),V8u64(5))
            g0:=transmute(V16u32)simd.gather(transmute(#simd[8]rawptr)(base+off0),V8u64(0),all)
            g1:=transmute(V16u32)simd.gather(transmute(#simd[8]rawptr)(base+off1),V8u64(0),all)
            e0:=simd.shuffle(g0,g1,0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30)
            e1:=simd.shuffle(g0,g1,1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31)
            b0,b1:=transmute(V64u8)e0,transmute(V64u8)e1
            avg:=cast(V64u8)simd.shr(cast(#simd[64]u16)b0+cast(#simd[64]u16)b1+1,1)
            d:=simd.min(simd.min(dist_to_bbox16(b0,lo,hi),dist_to_bbox16(b1,lo,hi)),
                dist_to_bbox16(avg,lo,hi))
            accept:=simd.lanes_le(d,min_d)
            if require_3c {
                // Alpha 255 in both makes the signed compare order them as unsigned.
                accept&=~simd.lanes_gt(transmute(V16i32)e0,transmute(V16i32)e1)
            }
            accept&=simd.lanes_lt(transmute(V16u32)iv,count)
            values:=simd.shl(V16i32{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}+V16i32(i32(i)),
                V16u32(16))|iv
            simd.masked_compress_store(&dest_inds[out],values,accept)
            out+=int(intrinsics.count_ones(u32(transmute(u16)simd.extract_msbs(accept))))
        }
    }
    return filter_endpoint_color_bbox_from(dest_inds,vqendpoints,inds,bbox,bbox_min_d,require_3c,
        i,out)
}

@(private="file",enable_target_feature=AVX2)
filter_endpoint_color_bbox_avx2 :: proc "contextless" (dest_inds:[]i32,
    vqendpoints:[]BC1_VQ_Entry,inds:[]i32,bbox:^[2]Color,bbox_min_d:u32,
    require_3c:bool) -> int #no_bounds_check {
    n:=min(len(inds),len(dest_inds),65535)
    i,out:=0,0
    if len(vqendpoints)>0 {
        last:=uint(len(vqendpoints)-1)
        count:=V8u32(u32(min(len(vqendpoints),int(max(u32)))))
        lo:=transmute(V32u8)V8u32(color_dw(bbox[0]))
        hi:=transmute(V32u8)V8u32(color_dw(bbox[1]))
        min_d:=V8i32(i32(bbox_min_d))
        for ; i+8<=n; i+=8 {
            iv:=intrinsics.unaligned_load((^V8i32)(&inds[i]))
            qa:=#simd[4]u64{endpoint_pair(vqendpoints,inds[i],last),
                endpoint_pair(vqendpoints,inds[i+1],last),endpoint_pair(vqendpoints,inds[i+2],last),
                endpoint_pair(vqendpoints,inds[i+3],last)}
            qb:=#simd[4]u64{endpoint_pair(vqendpoints,inds[i+4],last),
                endpoint_pair(vqendpoints,inds[i+5],last),endpoint_pair(vqendpoints,inds[i+6],last),
                endpoint_pair(vqendpoints,inds[i+7],last)}
            e0:=simd.shuffle(transmute(V8u32)qa,transmute(V8u32)qb,0,2,4,6,8,10,12,14)
            e1:=simd.shuffle(transmute(V8u32)qa,transmute(V8u32)qb,1,3,5,7,9,11,13,15)
            b0,b1:=transmute(V32u8)e0,transmute(V32u8)e1
            avg:=transmute(V32u8)x86._mm256_avg_epu8(transmute(x86.__m256i)b0,
                transmute(x86.__m256i)b1)
            d:=simd.min(simd.min(dist_to_bbox8(b0,lo,hi),dist_to_bbox8(b1,lo,hi)),
                dist_to_bbox8(avg,lo,hi))
            accept:=transmute(V8i32)simd.lanes_le(d,min_d)
            if require_3c {
                // Alpha 255 in both makes the signed compare order them as unsigned.
                accept&=~transmute(V8i32)simd.lanes_gt(transmute(V8i32)e0,transmute(V8i32)e1)
            }
            accept&=transmute(V8i32)simd.lanes_lt(transmute(V8u32)iv,count)
            m:=u32(transmute(u8)simd.extract_msbs(accept))
            values:=simd.shl(V8i32{0,1,2,3,4,5,6,7}+V8i32(i32(i)),V8u32(16))|iv
            lanes:=simd.shr(V8u32(ACTIVE_LANE_TABLE8[m]),V8u32{0,4,8,12,16,20,24,28})
            // A 32-byte runtime_swizzle is scalar code (odin-lang/Odin#8199).
            packed:=x86._mm256_permutevar8x32_epi32(transmute(x86.__m256i)values,
                transmute(x86.__m256i)lanes)
            intrinsics.unaligned_store((^x86.__m256i)(&dest_inds[out]),packed)
            out+=int(intrinsics.count_ones(m))
        }
    }
    return filter_endpoint_color_bbox_from(dest_inds,vqendpoints,inds,bbox,bbox_min_d,require_3c,
        i,out)
}

@(private="file",enable_target_feature=AVX2)
chunk_sad_avx2 :: #force_inline proc "contextless" (p:^Color_Block,c0,c1:V32u8) -> V4u32 {
    r:=([^]V32u8)(p)
    s:=transmute(V8u32)(psadbw256(intrinsics.unaligned_load(&r[0]),c0)+
        psadbw256(intrinsics.unaligned_load(&r[1]),c1))
    return simd.shuffle(s,s,0,1,2,3)+simd.shuffle(s,s,4,5,6,7)
}

@(private="file",enable_target_feature=AVX2)
chunk_sads_avx2 :: proc "contextless" (chunk_sads:[]i32,indices:[]u16,pair_colors:[]Color_Block,
    colors:^Color_Block) #no_bounds_check {
    n:=min(len(chunk_sads),len(indices))
    if len(pair_colors)==0 {return}
    last:=len(pair_colors)-1
    cp:=([^]V32u8)(colors)
    c0,c1:=intrinsics.unaligned_load(&cp[0]),intrinsics.unaligned_load(&cp[1])
    i:=0
    for ; i+4<=n; i+=4 {
        s0:=chunk_sad_avx2(&pair_colors[min(int(indices[i]),last)],c0,c1)
        s1:=chunk_sad_avx2(&pair_colors[min(int(indices[i+1]),last)],c0,c1)
        s2:=chunk_sad_avx2(&pair_colors[min(int(indices[i+2]),last)],c0,c1)
        s3:=chunk_sad_avx2(&pair_colors[min(int(indices[i+3]),last)],c0,c1)
        intrinsics.unaligned_store((^V4i32)(&chunk_sads[i]),sad_sum4(s0,s1,s2,s3))
    }
    chunk_sads_from(chunk_sads,indices,pair_colors,colors,i)
}

@(private="file",enable_target_feature=AVX512)
chunk_sad_avx512 :: #force_inline proc "contextless" (p:^Color_Block,c:V64u8) -> V4u32 {
    s:=transmute(V16u32)psadbw512(intrinsics.unaligned_load((^V64u8)(p)),c)
    h:=simd.shuffle(s,s,0,1,2,3,4,5,6,7)+simd.shuffle(s,s,8,9,10,11,12,13,14,15)
    return simd.shuffle(h,h,0,1,2,3)+simd.shuffle(h,h,4,5,6,7)
}

@(private="file",enable_target_feature=AVX512)
chunk_sads_avx512 :: proc "contextless" (chunk_sads:[]i32,indices:[]u16,
    pair_colors:[]Color_Block,colors:^Color_Block) #no_bounds_check {
    n:=min(len(chunk_sads),len(indices))
    if len(pair_colors)==0 {return}
    last:=len(pair_colors)-1
    c:=intrinsics.unaligned_load((^V64u8)(colors))
    i:=0
    for ; i+4<=n; i+=4 {
        s0:=chunk_sad_avx512(&pair_colors[min(int(indices[i]),last)],c)
        s1:=chunk_sad_avx512(&pair_colors[min(int(indices[i+1]),last)],c)
        s2:=chunk_sad_avx512(&pair_colors[min(int(indices[i+2]),last)],c)
        s3:=chunk_sad_avx512(&pair_colors[min(int(indices[i+3]),last)],c)
        intrinsics.unaligned_store((^V4i32)(&chunk_sads[i]),sad_sum4(s0,s1,s2,s3))
    }
    chunk_sads_from(chunk_sads,indices,pair_colors,colors,i)
}

@(private="file",enable_target_feature=AVX2)
batch_compute_vqds_avx2 :: proc "contextless" (dest_vqd:[]f32,vqindices:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block,first_palette,second_palette:^[4]Color,activity:^Float_Block) {
    batch_compute_vqds_body256(dest_vqd,vqindices,inds,colors,first_palette,second_palette,
        activity)
}

@(private="file",enable_target_feature=AVX2)
bc1_find_indices_avx2 :: proc "contextless" (b:^Color_Block,palette:^[4]Color,err:^u32) -> u32 {
    return bc1_find_indices_body(b,palette,err)
}

@(private="file",enable_target_feature=AVX2)
bc1_eval_palettes_avx2 :: proc "contextless" (ctx:^BC1_Find_Errors_Context,out_ssds:[]u32,
    palettes:[][4]Color) {
    bc1_eval_palettes_body(ctx,out_ssds,palettes)
}

@(private="file",enable_target_feature=AVX2)
bc1_find_best_palette_avx2 :: proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palettes:[][4]Color) -> u32 {
    return bc1_find_best_palette_body(ctx,palettes)
}

@(private="file",enable_target_feature=AVX2)
batch_find_best_errors_avx2 :: proc "contextless" (dest_ssd:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block) {
    batch_find_best_errors_body(dest_ssd,vqendpoints,inds,colors)
}

// batch_compute_vqds_body for eight candidates at a time; the tables of the texels are
// repeated in both 128-bit halves so the shuffles stay within them.
// A body of its own: no polymorphic #simd width (odin-lang/Odin#8198).
// _mm256_shuffle_epi8: a 32-byte runtime_swizzle is scalar code (odin-lang/Odin#8199).
@(private="file",enable_target_feature=AVX2)
batch_compute_vqds_body256 :: #force_inline proc "contextless" (dest_vqd:[]f32,
    vqindices:[]BC1_VQ_Entry,inds:[]i32,colors:^Color_Block,first_palette,second_palette:^[4]Color,
    activity:^Float_Block) #no_bounds_check {
    errs:[16][2]V32u8
    pal:=x86._mm256_set_m128i(transmute(x86.__m128i)load_u8x16(second_palette),
        transmute(x86.__m128i)load_u8x16(first_palette))
    for i in 0..<16 {
        px:=x86._mm256_set1_epi32(transmute(i32)colors[i])
        d:=transmute(V32u8)x86._mm256_or_si256(x86._mm256_subs_epu8(px,pal),
            x86._mm256_subs_epu8(pal,px))
        lo:=transmute(x86.__m256i)(transmute(V16u16)d&V16u16(0xff))
        hi:=transmute(x86.__m256i)simd.shr(transmute(V16u16)d,V16u16(8))
        sq:=transmute(V8i32)x86._mm256_add_epi32(x86._mm256_madd_epi16(lo,lo),
            x86._mm256_madd_epi16(hi,hi))
        e:=cast(V8f32)sq*V8f32(activity[i])
        errs[i][0]=transmute(V32u8)simd.shuffle(e,e,0,1,2,3,0,1,2,3)
        errs[i][1]=transmute(V32u8)simd.shuffle(e,e,4,5,6,7,4,5,6,7)
    }
    n:=min(len(inds),len(dest_vqd)/2)
    for i:=0; i<n; i+=8 {
        dw:[8]u32
        for k in 0..<8 {
            j:=int(inds[min(i+k,n-1)])
            dw[k]=j>=0 && j<len(vqindices) ? vqindices[j].dw : 0
        }
        idx:=transmute(V8u32)dw
        // Columns sum down the rows: texel t adds to column t&3.
        col:[2][4]V8f32
        cur:=idx
        #unroll for t in 0..<16 {
            s4:=transmute(V32u8)simd.shl(cur&V8u32(3),V8u32(2))
            cur=simd.shr(cur,V8u32(2))
            ctrl:=simd.shuffle(s4,s4,0,0,0,0,4,4,4,4,8,8,8,8,12,12,12,12,16,16,16,16,20,20,20,20,
                24,24,24,24,28,28,28,28)+V32u8{0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3,0,1,
                2,3,0,1,2,3}
            e0:=transmute(V8f32)x86._mm256_shuffle_epi8(transmute(x86.__m256i)errs[t][0],
                transmute(x86.__m256i)ctrl)
            e1:=transmute(V8f32)x86._mm256_shuffle_epi8(transmute(x86.__m256i)errs[t][1],
                transmute(x86.__m256i)ctrl)
            if t<4 {col[0][t&3]=e0; col[1][t&3]=e1} else {col[0][t&3]+=e0; col[1][t&3]+=e1}
        }
        r0:=transmute([8]f32)((col[0][0]+col[0][1])+(col[0][2]+col[0][3]))
        r1:=transmute([8]f32)((col[1][0]+col[1][1])+(col[1][2]+col[1][3]))
        for k in 0..<min(8,n-i) {
            j:=int(inds[i+k])
            ok:=j>=0 && j<len(vqindices)
            dest_vqd[(i+k)*2]=ok ? r0[k] : max(f32)
            dest_vqd[(i+k)*2+1]=ok ? r1[k] : max(f32)
        }
    }
}

// batch_compute_vqds_body for four candidates at a time, as the reference AVX-512 kernel: the
// weighted errors of texels 2i and 2i+1 against both palettes stay in eight registers, lanes
// 0-7 for the even texel and 8-15 for the odd one, and the indices permute them.
@(private="file",enable_target_feature=AVX512)
batch_compute_vqds_avx512 :: proc "contextless" (dest_vqd:[]f32,vqindices:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block,first_palette,second_palette:^[4]Color,
    activity:^Float_Block) #no_bounds_check {
    V16f :: #simd[16]f32
    n:=min(len(inds),len(dest_vqd)/2)
    if n<1 {return}
    p0:=load_u8x16(first_palette)
    p1:=load_u8x16(second_palette)
    pal:=transmute(V64u8)[4]V16u8{p0,p1,p0,p1}
    errs:[8]V16f
    #unroll for i in 0..<8 {
        c:=V16u32{0..<8=color_dw(colors[2*i]),8..<16=color_dw(colors[2*i+1])}
        px:=transmute(V64u8)c
        d:=transmute(V32u16)(simd.max(px,pal)-simd.min(px,pal))
        lo:=transmute(V32i16)(d&V32u16(0xff))
        hi:=transmute(V32i16)simd.shr(d,V32u16(8))
        sq:=madd32(lo,lo)+madd32(hi,hi)
        errs[i]=cast(V16f)sq*V16f{0..<8=activity[2*i],8..<16=activity[2*i+1]}
    }
    SELECT :: V16u32{0,0x44444444,0,0x44444444,0,0x44444444,0,0x44444444,
        0x88888888,0xcccccccc,0x88888888,0xcccccccc,0x88888888,0xcccccccc,0x88888888,0xcccccccc}
    PRESHIFT :: V16u32{0,0,0,0,0,0,0,0,2,2,2,2,2,2,2,2}
    for i:=0; i<n; i+=4 {
        dw:[4]u32
        bad:[4]bool
        for k in 0..<4 {
            j:=int(inds[min(i+k,n-1)])
            ok:=j>=0 && j<len(vqindices)
            dw[k]=ok ? vqindices[j].dw : 0
            bad[k]=!ok
        }
        v:=V16u32{dw[0],dw[0],dw[1],dw[1],dw[2],dw[2],dw[3],dw[3],
            dw[0],dw[0],dw[1],dw[1],dw[2],dw[2],dw[3],dw[3]}
        v=(simd.shr(v,PRESHIFT)&V16u32(0x33333333))|SELECT
        // Columns sum down the rows, then (c0+c1)+(c2+c3).
        sum01:=permps512(errs[0],transmute(V16i32)v)
        sum01+=permps512(errs[2],transmute(V16i32)simd.shr(v,V16u32(8)))
        sum01+=permps512(errs[4],transmute(V16i32)simd.shr(v,V16u32(16)))
        sum01+=permps512(errs[6],transmute(V16i32)simd.shr(v,V16u32(24)))
        v4:=simd.shr(v,V16u32(4))
        sum23:=permps512(errs[1],transmute(V16i32)v4)
        sum23+=permps512(errs[3],transmute(V16i32)simd.shr(v4,V16u32(8)))
        sum23+=permps512(errs[5],transmute(V16i32)simd.shr(v4,V16u32(16)))
        sum23+=permps512(errs[7],transmute(V16i32)simd.shr(v4,V16u32(24)))
        red01:=simd.shuffle(sum01,sum01,0,1,2,3,4,5,6,7)+
            simd.shuffle(sum01,sum01,8,9,10,11,12,13,14,15)
        red23:=simd.shuffle(sum23,sum23,0,1,2,3,4,5,6,7)+
            simd.shuffle(sum23,sum23,8,9,10,11,12,13,14,15)
        r:=transmute([8]f32)(red01+red23)
        for k in 0..<min(4,n-i) {
            dest_vqd[(i+k)*2]=bad[k] ? max(f32) : r[2*k]
            dest_vqd[(i+k)*2+1]=bad[k] ? max(f32) : r[2*k+1]
        }
    }
}

// ---- AVX-512: the 16 texels of a block in one vector.

@(private="file")
V64u8 :: #simd[64]u8
@(private="file")
V32i16 :: #simd[32]i16
@(private="file")
V32u16 :: #simd[32]u16
@(private="file")
V16i32 :: #simd[16]i32
@(private="file")
V16u32 :: #simd[16]u32

// pmaddwd itself: the generic form loses the instruction when a shuffle follows it.
@(private="file",default_calling_convention="none")
foreign _ {
    @(link_name="llvm.x86.avx512.pmaddw.d.512")
    madd32 :: proc(a,b:V32i16) -> V16i32 ---
}

@(private="file",enable_target_feature=AVX512)
unpack16 :: #force_inline proc "contextless" (v:V64u8,$scale:i16) -> (br,ga:V32i16) {
    u:=transmute(V32u16)v
    S :: scale
    br=transmute(V32i16)(u&V32u16(0xff))*V32i16(S)
    ga=transmute(V32i16)simd.shr(u,V32u16(8))*V32i16{S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,
        S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S,S,2*S}
    return
}

// The 128-bit quadrant k of v in all four.
@(private="file",enable_target_feature=AVX512)
quadrant :: #force_inline proc "contextless" (v:V32i16,$k:int) -> V32i16 {
    x:=transmute(#simd[8]u64)v
    return transmute(V32i16)simd.shuffle(x,x,2*k,2*k+1,2*k,2*k+1,2*k,2*k+1,2*k,2*k+1)
}

// dst[i] = v[(i+k)&3] in every quadrant.
@(private="file",enable_target_feature=AVX512)
rot32 :: #force_inline proc "contextless" (v:V16i32,$k:int) -> V16i32 {
    return simd.shuffle(v,v,k,(k+1)&3,(k+2)&3,(k+3)&3,4+k,4+((k+1)&3),4+((k+2)&3),4+((k+3)&3),
        8+k,8+((k+1)&3),8+((k+2)&3),8+((k+3)&3),12+k,12+((k+1)&3),12+((k+2)&3),12+((k+3)&3))
}

@(private="file",enable_target_feature=AVX512)
rot16 :: #force_inline proc "contextless" (v:V32i16,$k:int) -> V32i16 {
    return transmute(V32i16)rot32(transmute(V16i32)v,k)
}

@(private="file",enable_target_feature=AVX512)
delta512 :: #force_inline proc "contextless" (x_br,x_ga,y_br,y_ga:V32i16) -> V16i32 {
    dbr:=y_br-x_br
    dga:=y_ga-x_ga
    return madd32(dbr,dbr)+madd32(dga,dga)
}

// The texels rotated left by 0..3 within each row: comparing them with an unrotated palette
// and rotating the errors back compares every texel with every entry.
@(private="file")
Prerot :: [4][2]V32i16

@(private="file",enable_target_feature=AVX512)
prerot_make :: #force_inline proc "contextless" (br,ga:V32i16) -> (p:Prerot) {
    p[0]={br,ga}
    p[1]={rot16(br,3),rot16(ga,3)}
    p[2]={rot16(br,2),rot16(ga,2)}
    p[3]={rot16(br,1),rot16(ga,1)}
    return
}

@(private="file",enable_target_feature=AVX512)
best_errors_prerot :: #force_inline proc "contextless" (p:^Prerot,pal_br,pal_ga:V32i16) -> V16i32 {
    best:=delta512(pal_br,pal_ga,p[0][0],p[0][1])
    best=simd.min(best,rot32(delta512(pal_br,pal_ga,p[1][0],p[1][1]),1))
    best=simd.min(best,rot32(delta512(pal_br,pal_ga,p[2][0],p[2][1]),2))
    best=simd.min(best,rot32(delta512(pal_br,pal_ga,p[3][0],p[3][1]),3))
    return best
}

// The sums of a, b, c and d.
@(private="file",enable_target_feature=AVX512)
sum4x :: #force_inline proc "contextless" (a,b,c,d:V16i32) -> #simd[4]i32 {
    t0:=simd.shuffle(a,c,0,16,1,17,4,20,5,21,8,24,9,25,12,28,13,29)
    t1:=simd.shuffle(b,d,0,16,1,17,4,20,5,21,8,24,9,25,12,28,13,29)
    t2:=simd.shuffle(a,c,2,18,3,19,6,22,7,23,10,26,11,27,14,30,15,31)
    t3:=simd.shuffle(b,d,2,18,3,19,6,22,7,23,10,26,11,27,14,30,15,31)
    u0:=t0+t2
    u1:=t1+t3
    w:=simd.shuffle(u0,u1,0,16,1,17,4,20,5,21,8,24,9,25,12,28,13,29)+
        simd.shuffle(u0,u1,2,18,3,19,6,22,7,23,10,26,11,27,14,30,15,31)
    x:=simd.shuffle(w,w,0,1,2,3,4,5,6,7)+simd.shuffle(w,w,8,9,10,11,12,13,14,15)
    return simd.shuffle(x,x,0,1,2,3)+simd.shuffle(x,x,4,5,6,7)
}

@(private="file",enable_target_feature=AVX512)
load_palette512 :: #force_inline proc "contextless" (palette:^[4]Color) -> (br,ga:V32i16) {
    p:=load_u8x16(palette)
    return unpack16(transmute(V64u8)[4]V16u8{p,p,p,p},1)
}

@(private="file",enable_target_feature=AVX512)
ctx_prerot :: #force_inline proc "contextless" (ctx:^BC1_Find_Errors_Context) -> Prerot {
    br:=intrinsics.unaligned_load((^V32i16)(&ctx.br))
    ga:=intrinsics.unaligned_load((^V32i16)(&ctx.ga))
    return prerot_make(br,ga)
}

// The errors of the four palettes at palettes.
@(private="file",enable_target_feature=AVX512)
eval4_512 :: #force_inline proc "contextless" (p:^Prerot,palettes:[^][4]Color) -> #simd[4]i32 {
    br,ga:=unpack16(intrinsics.unaligned_load((^V64u8)(palettes)),1)
    e0:=best_errors_prerot(p,quadrant(br,0),quadrant(ga,0))
    e1:=best_errors_prerot(p,quadrant(br,1),quadrant(ga,1))
    e2:=best_errors_prerot(p,quadrant(br,2),quadrant(ga,2))
    e3:=best_errors_prerot(p,quadrant(br,3),quadrant(ga,3))
    return sum4x(e0,e1,e2,e3)
}

@(private="file",enable_target_feature=AVX512)
eval1_512 :: #force_inline proc "contextless" (p:^Prerot,palette:^[4]Color) -> u32 {
    br,ga:=load_palette512(palette)
    return u32(simd.reduce_add_pairs(best_errors_prerot(p,br,ga)))
}

@(private="file",enable_target_feature=AVX512)
bc1_eval_palettes_avx512 :: proc "contextless" (ctx:^BC1_Find_Errors_Context,out_ssds:[]u32,
    palettes:[][4]Color) #no_bounds_check {
    p:=ctx_prerot(ctx)
    n:=min(len(out_ssds),len(palettes))
    i:=0
    for ; i+4<=n; i+=4 {
        e:=transmute([4]i32)eval4_512(&p,raw_data(palettes[i:]))
        for k in 0..<4 {out_ssds[i+k]=u32(e[k])}
    }
    for ; i<n; i+=1 {out_ssds[i]=eval1_512(&p,&palettes[i])}
}

@(private="file",enable_target_feature=AVX512)
bc1_find_best_palette_avx512 :: proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palettes:[][4]Color) -> u32 #no_bounds_check {
    count:=min(len(palettes),BC1_FIND_ERRORS_COUNT_LIMIT)
    if count==0 {return ~u32(0)}
    p:=ctx_prerot(ctx)
    best:=V4u32(~u32(0))
    i:=0
    for ; i+4<=count; i+=4 {
        e:=transmute(#simd[4]u32)eval4_512(&p,raw_data(palettes[i:]))
        best=simd.min(best,simd.shl(e,V4u32(BC1_FIND_ERRORS_COUNT_SHIFT))|(V4u32{0,1,2,3}+
            V4u32(u32(i))))
    }
    b:=simd.reduce_min(best)
    for ; i<count; i+=1 {
        b=min(b,(eval1_512(&p,&palettes[i])<<BC1_FIND_ERRORS_COUNT_SHIFT)|u32(i))
    }
    return b
}

@(private="file",enable_target_feature=AVX512)
batch_find_best_errors_avx512 :: proc "contextless" (dest_ssd:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block) #no_bounds_check {
    n:=min(len(inds),len(dest_ssd))
    br,ga:=unpack16(intrinsics.unaligned_load((^V64u8)(colors)),1)
    p:=prerot_make(br,ga)
    @(enable_target_feature=AVX512)
    palette :: #force_inline proc "contextless" (vq:[]BC1_VQ_Entry,ind:i32) -> (br,ga:V32i16,
        ok:bool) {
        j:=int(ind&0xffff)
        if j>=len(vq) {return}
        br,ga=load_palette512(&vq[j].palette)
        return br,ga,true
    }
    i:=0
    for ; i+4<=n; i+=4 {
        e:[4]V16i32
        ok:[4]bool
        for k in 0..<4 {
            pbr,pga,o:=palette(vqendpoints,inds[i+k])
            ok[k]=o
            e[k]=best_errors_prerot(&p,pbr,pga)
        }
        s:=transmute([4]i32)sum4x(e[0],e[1],e[2],e[3])
        for k in 0..<4 {dest_ssd[i+k]=ok[k] ? s[k] : max(i32)}
    }
    for ; i<n; i+=1 {
        pbr,pga,o:=palette(vqendpoints,inds[i])
        dest_ssd[i]=o ? simd.reduce_add_pairs(best_errors_prerot(&p,pbr,pga)) : max(i32)
    }
}

@(private="file",enable_target_feature=AVX512)
bc1_find_indices_avx512 :: proc "contextless" (b:^Color_Block,palette:^[4]Color,err:^u32) -> u32 {
    p:=load_u8x16(palette)
    pal_br,pal_ga:=unpack16(transmute(V64u8)[4]V16u8{p,p,p,p},2)
    br,ga:=unpack16(intrinsics.unaligned_load((^V64u8)(b)),2)
    @(enable_target_feature=AVX512)
    bc :: #force_inline proc "contextless" (v:V32i16,$k:int) -> V32i16 {
        x:=transmute(V16i32)v
        return transmute(V32i16)simd.shuffle(x,x,k,k,k,k,4+k,4+k,4+k,4+k,8+k,8+k,8+k,8+k,12+k,12+k,
            12+k,12+k)
    }
    d0:=delta512(br,ga,bc(pal_br,0),bc(pal_ga,0))
    d1:=delta512(br,ga,bc(pal_br,1),bc(pal_ga,1))
    d2:=delta512(br,ga,bc(pal_br,2),bc(pal_ga,2))
    d3:=delta512(br,ga,bc(pal_br,3),bc(pal_ga,3))
    best:=simd.min(simd.min(d0,d1+V16i32(1)),simd.min(d2,d3+V16i32(1))+V16i32(2))
    // Bit 0 of the index of texel i lands in bit 2i, bit 1 in bit 2i+1.
    h:=transmute(V32i16)best
    ONE :: V32i16{1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0,1,0}
    bit0:=transmute(u32)simd.extract_msbs(simd.lanes_ne(h&ONE,V32i16(0)))
    bit1:=transmute(u32)simd.extract_msbs(simd.lanes_ne(h&(ONE*2),V32i16(0)))
    if err!=nil {
        err^=u32(simd.reduce_add_pairs(transmute(V16i32)simd.shr(transmute(V16u32)best,
            V16u32(2))))
    }
    return bit0+2*bit1
}
