package bc7

import "base:intrinsics"
import "core:math"
import "core:simd"

// Per-subset statistics of a block: for every subset of the partitions an
// effort searches, its spread and principal axis.

Subset_Chan :: enum {
    Overall_Err, // squared error of replacing the subset by its mean
    Pca_Err,     // squared error the principal axis accounts for
    Pca_R,
    Pca_G,
    Pca_B,
    Pca_A,
}

ANALYSIS_STRIDE :: 248+8

Subset_Analysis :: struct {
    storage:[Subset_Chan][ANALYSIS_STRIDE]f32,
}

SUBSET_PCA_NITER :: 3

@(private) P2_60 :: f32(1152921504606846976.0)
@(private) P2_M60 :: f32(1.0/1152921504606846976.0)
@(private) P2_M68 :: f32(1.0/295147905179352825856.0)

@(private)
maxps :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a>b?a:b}
@(private)
minps :: #force_inline proc "contextless" (a,b:f32) -> f32 {return a<b?a:b}

@(private)
V4i :: #simd[4]i32
@(private)
V4f :: #simd[4]f32
@(private)
V4u :: #simd[4]u32
@(private)
V8i :: #simd[8]i32
@(private)
V8f :: #simd[8]f32
@(private)
V8u :: #simd[8]u32

@(private)
vcvt :: #force_inline proc "contextless" (v:V4i) -> V4f {return cast(V4f)v}

// Lanes 0..n-1 of the six channels into subsets first.. of a.
@(private)
analysis_store :: #force_inline proc "contextless" (a:^Subset_Analysis,first,n:int,
    v:[6]V8f) #no_bounds_check {
    if first+8<=ANALYSIS_STRIDE {
        for c in Subset_Chan {intrinsics.unaligned_store((^V8f)(&a.storage[c][first]),v[int(c)])}
    } else {
        for c in Subset_Chan {
            x:=transmute([8]f32)v[int(c)]
            for l in 0..<n {a.storage[c][first+l]=x[l]}
        }
    }
}

// finalize_rgba of 8 subsets at once, lane by lane the same operations.
@(private)
finalize_rgba8 :: #force_inline proc "contextless" (a:^Subset_Analysis,first,n:int,sumi:^[14]V8i,
    scale:^[8]f32) {
    sf:=transmute(V8f)scale^
    smr:=(cast(V8f)sumi[0]); smg:=(cast(V8f)sumi[1]); smb:=(cast(V8f)sumi[2]); sma:=(cast(V8f)sumi[3])
    cov:[10]V8f
    cov[0]=(cast(V8f)sumi[4])-sf*(smr*smr)
    cov[1]=(cast(V8f)sumi[5])-sf*(smg*smg)
    cov[2]=(cast(V8f)sumi[6])-sf*(smb*smb)
    cov[3]=(cast(V8f)sumi[7])-sf*(sma*sma)
    cov[4]=(cast(V8f)sumi[8])-sf*(smr*smg)
    cov[5]=(cast(V8f)sumi[9])-sf*(smg*smb)
    cov[6]=(cast(V8f)sumi[10])-sf*(smb*sma)
    cov[7]=(cast(V8f)sumi[11])-sf*(sma*smr)
    cov[8]=(cast(V8f)sumi[12])-sf*(smr*smb)
    cov[9]=(cast(V8f)sumi[13])-sf*(smg*sma)
    v:=[4]V8f{cov[0],cov[4],cov[8],cov[7]}
    v_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff))))
    v1_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff))))
    m1:=simd.lanes_gt(v1_norm,v_norm)
    v={simd.select(m1,cov[4],v[0]),simd.select(m1,cov[1],v[1]),simd.select(m1,cov[5],v[2]),
        simd.select(m1,cov[9],v[3])}
    v_norm=simd.select(simd.lanes_gt(v_norm,v1_norm),v_norm,v1_norm)
    v2_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[8])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff))))
    m2:=simd.lanes_gt(v2_norm,v_norm)
    v={simd.select(m2,cov[8],v[0]),simd.select(m2,cov[5],v[1]),simd.select(m2,cov[2],v[2]),
        simd.select(m2,cov[6],v[3])}
    v_norm=simd.select(simd.lanes_gt(v_norm,v2_norm),v_norm,v2_norm)
    v3_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),cov[3],(transmute(V8f)(transmute(V8u)(cov[7])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[9])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[6])&V8u(0x7fffffff))))
    m3:=simd.lanes_gt(v3_norm,v_norm)
    v={simd.select(m3,cov[7],v[0]),simd.select(m3,cov[9],v[1]),simd.select(m3,cov[6],v[2]),
        simd.select(m3,cov[3],v[3])}
    times4 :: #force_inline proc "contextless" (cov:^[10]V8f,v:[4]V8f) -> [4]V8f {
        return {
            cov[0]*v[0]+cov[4]*v[1]+cov[8]*v[2]+cov[7]*v[3],
            cov[1]*v[1]+cov[5]*v[2]+cov[9]*v[3]+cov[4]*v[0],
            cov[2]*v[2]+cov[6]*v[3]+cov[8]*v[0]+cov[5]*v[1],
            cov[3]*v[3]+cov[7]*v[0]+cov[9]*v[1]+cov[6]*v[2],
        }
    }
    for _ in 0..<SUBSET_PCA_NITER {v=times4(&cov,v)}
    overall_max:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[3])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[3])&V8u(0x7fffffff))))
    prescale:=simd.select(simd.lanes_gt(overall_max,V8f(P2_60)),V8f(P2_M68),V8f(1.0))
    v[0]*=prescale; v[1]*=prescale; v[2]*=prescale; v[3]*=prescale
    len_sq:=v[0]*v[0]+v[1]*v[1]+v[2]*v[2]+v[3]*v[3]
    rcp_len:=simd.sqrt(V8f(1.0)/len_sq)
    rcp_len=simd.select(simd.lanes_gt(len_sq,V8f(P2_M60)),rcp_len,V8f(0))
    v[0]*=rcp_len; v[1]*=rcp_len; v[2]*=rcp_len; v[3]*=rcp_len
    overall:=cov[0]+cov[1]+cov[2]+cov[3]
    vlast:=times4(&cov,v)
    pca:=v[0]*vlast[0]+v[1]*vlast[1]+v[2]*vlast[2]+v[3]*vlast[3]
    analysis_store(a,first,n,{overall,pca,v[0],v[1],v[2],v[3]})
}

@(private)
finalize_rgb8 :: #force_inline proc "contextless" (a:^Subset_Analysis,first,n:int,sumi:^[9]V8i,
    scale:^[8]f32) {
    sf:=transmute(V8f)scale^
    smr:=(cast(V8f)sumi[0]); smg:=(cast(V8f)sumi[1]); smb:=(cast(V8f)sumi[2])
    cov:[6]V8f
    cov[0]=(cast(V8f)sumi[3])-sf*(smr*smr)
    cov[1]=(cast(V8f)sumi[4])-sf*(smg*smg)
    cov[2]=(cast(V8f)sumi[5])-sf*(smb*smb)
    cov[3]=(cast(V8f)sumi[6])-sf*(smr*smg)
    cov[4]=(cast(V8f)sumi[7])-sf*(smg*smb)
    cov[5]=(cast(V8f)sumi[8])-sf*(smb*smr)
    v:=[3]V8f{cov[0],cov[3],cov[5]}
    v_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[0],(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff)))),cov[0],(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff))))
    v1_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[1],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),cov[1],(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[3])&V8u(0x7fffffff))))
    m1:=simd.lanes_gt(v1_norm,v_norm)
    v={simd.select(m1,cov[3],v[0]),simd.select(m1,cov[1],v[1]),simd.select(m1,cov[4],v[2])}
    v_norm=simd.select(simd.lanes_gt(v_norm,v1_norm),v_norm,v1_norm)
    v2_norm:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt(cov[2],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),cov[2],(transmute(V8f)(transmute(V8u)(cov[5])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(cov[4])&V8u(0x7fffffff))))
    m2:=simd.lanes_gt(v2_norm,v_norm)
    v={simd.select(m2,cov[5],v[0]),simd.select(m2,cov[4],v[1]),simd.select(m2,cov[2],v[2])}
    times3 :: #force_inline proc "contextless" (cov:^[6]V8f,v:[3]V8f) -> [3]V8f {
        return {
            cov[0]*v[0]+cov[3]*v[1]+cov[5]*v[2],
            cov[1]*v[1]+cov[4]*v[2]+cov[3]*v[0],
            cov[2]*v[2]+cov[5]*v[0]+cov[4]*v[1],
        }
    }
    for _ in 0..<SUBSET_PCA_NITER {v=times3(&cov,v)}
    overall_max:=simd.select(simd.lanes_gt(simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff)))),simd.select(simd.lanes_gt((transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[0])&V8u(0x7fffffff))),(transmute(V8f)(transmute(V8u)(v[1])&V8u(0x7fffffff)))),(transmute(V8f)(transmute(V8u)(v[2])&V8u(0x7fffffff))))
    prescale:=simd.select(simd.lanes_gt(overall_max,V8f(P2_60)),V8f(P2_M68),V8f(1.0))
    v[0]*=prescale; v[1]*=prescale; v[2]*=prescale
    len_sq:=v[0]*v[0]+v[1]*v[1]+v[2]*v[2]
    rcp_len:=simd.sqrt(V8f(1.0)/len_sq)
    rcp_len=simd.select(simd.lanes_gt(len_sq,V8f(P2_M60)),rcp_len,V8f(0))
    v[0]*=rcp_len; v[1]*=rcp_len; v[2]*=rcp_len
    overall:=cov[0]+cov[1]+cov[2]
    vlast:=times3(&cov,v)
    pca:=v[0]*vlast[0]+v[1]*vlast[1]+v[2]*vlast[2]
    analysis_store(a,first,n,{overall,pca,v[0],v[1],v[2],V8f(0)})
}

// acc += the madd of x and y; through pointers, as it may stay uninlined (odin-lang/Odin#7780).
@(private)
mad_acc :: #force_inline proc "contextless" (acc:^V8i,x,y:^#simd[16]i16) {
    p:=(cast(#simd[16]i32)x^)*(cast(#simd[16]i32)y^)
    acc^+=simd.shuffle(p,p,0,2,4,6,8,10,12,14)+simd.shuffle(p,p,1,3,5,7,9,11,13,15)
}

// Analysis of the 2- and 3-subset partition subsets [first,first+count), eight subsets at a
// time: the texels in pairs of 16-bit lanes, masked per subset, summed with madd.
@(private)
analysis_compute_body :: #force_inline proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,masks:[]u32,
    scale:[]f32,first,count:int,is_rgba:bool) #no_bounds_check {
    if first<0 || count<0 || first+count>len(masks) || first+count>len(scale) ||
        first+count>ANALYSIS_STRIDE {return}
    W :: #simd[16]i16
    WU :: #simd[16]u16
    prep:[4][8]u32
    for i in 0..<8 {
        for c in 0..<4 {prep[c][i]=u32(pixels[2*i][c])|(u32(pixels[2*i+1][c])<<16)}
    }
    end:=first+count
    for s:=first; s<end; s+=8 {
        n:=min(8,end-s)
        mk:[8]u32
        sf:[8]f32
        if s+8<=len(masks) && s+8<=len(scale) {
            mk=(^[8]u32)(&masks[s])^
            sf=(^[8]f32)(&scale[s])^
        } else {
            for l in 0..<n {mk[l]=masks[s+l]; sf[l]=scale[s+l]}
        }
        m32:=transmute(V8u)mk
        m32|=simd.shl(m32,V8u(16))
        cur:=transmute(W)V8u(0x00020001)
        mw:=transmute(W)m32
        if is_rgba {
            sumi:[14]V8i
            rs,gs,bs,as:W
            for i in 0..<8 {
                m:=transmute(W)simd.lanes_eq(mw&cur,cur)
                r:=transmute(W)V8u(prep[0][i])&m
                g:=transmute(W)V8u(prep[1][i])&m
                b:=transmute(W)V8u(prep[2][i])&m
                al:=transmute(W)V8u(prep[3][i])&m
                rs+=r; gs+=g; bs+=b; as+=al
                mad_acc(&sumi[4],&r,&r); mad_acc(&sumi[5],&g,&g); mad_acc(&sumi[6],&b,&b); mad_acc(&sumi[7],&al,&al)
                mad_acc(&sumi[8],&r,&g); mad_acc(&sumi[9],&g,&b); mad_acc(&sumi[10],&b,&al); mad_acc(&sumi[11],&al,&r)
                mad_acc(&sumi[12],&r,&b); mad_acc(&sumi[13],&g,&al)
                cur=simd.shl(cur,WU(2))
            }
            ones:=W(1)
            mad_acc(&sumi[0],&rs,&ones); mad_acc(&sumi[1],&gs,&ones); mad_acc(&sumi[2],&bs,&ones); mad_acc(&sumi[3],&as,&ones)
            finalize_rgba8(a,s,n,&sumi,&sf)
        } else {
            sumi:[9]V8i
            rs,gs,bs:W
            for i in 0..<8 {
                m:=transmute(W)simd.lanes_eq(mw&cur,cur)
                r:=transmute(W)V8u(prep[0][i])&m
                g:=transmute(W)V8u(prep[1][i])&m
                b:=transmute(W)V8u(prep[2][i])&m
                rs+=r; gs+=g; bs+=b
                mad_acc(&sumi[3],&r,&r); mad_acc(&sumi[4],&g,&g); mad_acc(&sumi[5],&b,&b)
                mad_acc(&sumi[6],&r,&g); mad_acc(&sumi[7],&g,&b); mad_acc(&sumi[8],&b,&r)
                cur=simd.shl(cur,WU(2))
            }
            ones:=W(1)
            mad_acc(&sumi[0],&rs,&ones); mad_acc(&sumi[1],&gs,&ones); mad_acc(&sumi[2],&bs,&ones)
            finalize_rgb8(a,s,n,&sumi,&sf)
        }
    }
}

// Analysis of the 1-subset cases at first..first+4: RGBA, then RGB with each
// channel rotation (the rotated-out channel in A, zeroed), one per lane.
@(private)
analysis_compute_1subset_body :: #force_inline proc "contextless" (a:^Subset_Analysis,
    pixels:^[16][4]u8,first:int) #no_bounds_check {
    if first<0 || first+5>ANALYSIS_STRIDE {return}
    sumi:[14]V8i
    for i in 0..<16 {
        p:=pixels[i]
        p0,p1,p2,p3:=i32(p[0]),i32(p[1]),i32(p[2]),i32(p[3])
        r:=V8i{p0,p0,p3,p0,p0,0,0,0}
        g:=V8i{p1,p1,p1,p3,p1,0,0,0}
        b:=V8i{p2,p2,p2,p2,p3,0,0,0}
        al:=V8i{p3,0,0,0,0,0,0,0}
        sumi[0]+=r; sumi[1]+=g; sumi[2]+=b; sumi[3]+=al
        sumi[4]+=r*r; sumi[5]+=g*g; sumi[6]+=b*b; sumi[7]+=al*al
        sumi[8]+=r*g; sumi[9]+=g*b; sumi[10]+=b*al; sumi[11]+=al*r
        sumi[12]+=r*b; sumi[13]+=g*al
    }
    sf:=[8]f32{0..<8=1.0/16.0}
    finalize_rgba8(a,first,5,&sumi,&sf)
}
