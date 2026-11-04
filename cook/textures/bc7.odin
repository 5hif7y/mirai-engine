package textures

import "base:intrinsics"
import "core:math"
import "mirai:asset"

// BC7 encoder (the format and its decoder are in asset/texture_bc7.odin).
// Each block tries the modes that may fit it: for the partitioned ones, a
// quick fit of every pattern picks the few worth compressing in full. A
// subset is fitted along the principal axis of its colors and refined by
// least squares from the indices that fit gave, every p-bit combination
// measured, with the error in linear RGBA.
//
// A port to Odin of bc7e.ispc, from github.com/richgel999/bc7enc_rdo at
// b9438627eef73a1157e84201b6fa6eb2ffd6d9f0:
//
//   Copyright (C) 2018-2021 Binomial LLC. Licensed under the Apache License,
//   Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
//
// Changed from it: scalar code instead of SPMD; the error in linear RGBA
// only, without the perceptual weights; one routine for the subsets of every
// partitioned mode; the least squares weights computed instead of tabled;
// the single color tables as constants (bc7_tables.odin); and the single
// color fit of mode 7 corrected, whose table kept endpoints of other p-bits
// and whose error read its 6-bit endpoints as 8-bit ones.

@(private="file")
Bc7_Color :: [4]i32

@(private)
Bc7_Endpoints :: struct {lo,hi:u8,error:u16}

// How hard the encoder looks: the profiles of bc7e.
@(private)
Bc7_Settings :: struct {
    max_partitions:[8]u32,   // of each partitioned mode, how many patterns the quick fit weighs
    tried:[8]u32,            // of modes 0, 1 (also for 3), 2 and 7: how many of the best patterns are compressed in full
    opaque_modes:bit_set[0..<8],
    alpha_modes:bit_set[0..<8],
    uber_level:u32,          // 0 to 4: more fits from indices moved around the first ones
    refinement_passes:u32,
    pbit_search:bool,        // every p-bit combination instead of the closest one
    mode4_rotations,mode4_indices,mode5_rotations:bit_set[0..<4],
    uber1:bit_set[0..<3],    // the three ways uber level 1 moves the extreme indices
}

// bc7e's "slow" profile: every mode, every pattern weighed, all p-bits.
@(private)
BC7_SETTINGS :: Bc7_Settings{
    max_partitions={16,64,64,64,0,0,0,64},
    tried={1,1,1,0,0,0,0,2},
    opaque_modes={0,1,2,3,4,5,6},
    alpha_modes={4,5,6,7},
    refinement_passes=1,
    pbit_search=true,
    mode4_rotations={0,1,2,3},
    mode4_indices={0,1},
    mode5_rotations={0,1,2,3},
    uber1={0,1,2},
}

@(private="file")
Bc7_Cell :: struct {
    weights:[]u32, // of the indices, out of 64
    comp_bits:i32, // of each endpoint channel, without the p-bit
    has_alpha,has_pbits,shared_pbit:bool,
}

@(private="file")
Bc7_Fit :: struct {
    error:u64,
    low,high:Bc7_Color, // endpoints in comp_bits, without p-bits
    pbits:[2]i32,
    selectors:[16]i32,
}

@(private)
Bc7_Block :: struct {
    mode,partition,rotation,index_selector:u32,
    selectors,alpha_selectors:[16]i32,
    low,high:[3]Bc7_Color,
    pbits:[3][2]i32,
}

@(private="file")
Bc7_Solution :: struct {
    partition:u32,
    error:u64,
}

// The pattern of two subsets after which, with the frequent ones before it,
// the quick fit stops if none after the first ones was better.
@(private="file")
CHECKERBOARD_PARTITION :: 34

@(private="file")
saturate4 :: proc "contextless" (v:[4]f32) -> [4]f32 {
    return {clamp(v[0],0,1),clamp(v[1],0,1),clamp(v[2],0,1),clamp(v[3],0,1)}
}

@(private="file")
normalize4 :: proc "contextless" (v:[4]f32) -> [4]f32 {
    s:=v[0]*v[0]+v[1]*v[1]+v[2]*v[2]+v[3]*v[3]
    if s==0 {return v}
    return v*(1/math.sqrt(s))
}

@(private="file")
dot4 :: proc "contextless" (a,b:[4]f32) -> f32 {return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3]}

@(private="file")
to_f32 :: proc "contextless" (c:Bc7_Color) -> [4]f32 {return {f32(c[0]),f32(c[1]),f32(c[2]),f32(c[3])}}

@(private="file")
F4 :: #simd[4]f32

@(private="file")
lanes_of :: #force_inline proc "contextless" (c:Bc7_Color) -> F4 {return {f32(c[0]),f32(c[1]),f32(c[2]),f32(c[3])}}

// The first channels lanes added from the first, as a loop over channels adds them.
@(private="file")
lanes_sum :: #force_inline proc "contextless" (v:F4,channels:int) -> f32 {
    sum:=intrinsics.simd_extract(v,0)+intrinsics.simd_extract(v,1)+intrinsics.simd_extract(v,2)
    return sum+intrinsics.simd_extract(v,3) if channels==4 else sum
}

// math.floor without its calls: exact, as any floor is.
@(private="file")
floor_f32 :: #force_inline proc "contextless" (x:f32) -> f32 {return intrinsics.simd_extract(intrinsics.simd_floor(F4(x)),0)}

// An endpoint of comp_bits (and its p-bit) widened to 8 bits.
@(private="file")
bc7_scale :: proc "contextless" (c:Bc7_Color,cell:^Bc7_Cell) -> (scaled:Bc7_Color) {
    n:=u32(cell.comp_bits+(1 if cell.has_pbits else 0))
    for v,i in c {
        x:=v<<(8-n)
        scaled[i]=x|x>>n
    }
    return
}

// Indices for the texels between the endpoints, and their error; fit keeps
// them when the error is lower than its own.
@(private="file")
bc7_evaluate :: proc(low,high:Bc7_Color,pbits:[2]i32,cell:^Bc7_Cell,fit:^Bc7_Fit,pixels:[]Bc7_Color) -> u64 #no_bounds_check {
    quant_min,quant_max:=low,high
    if cell.has_pbits {
        min_p:=pbits[0]
        max_p:=pbits[0] if cell.shared_pbit else pbits[1]
        for c in 0..<4 {
            quant_min[c]=low[c]<<1|min_p
            quant_max[c]=high[c]<<1|max_p
        }
    }
    n:=len(cell.weights)
    channels:=4 if cell.has_alpha else 3
    // Four values per operation, with the sums of channels in their order,
    // so the result is the one of a channel at a time.
    low_f,high_f:=lanes_of(bc7_scale(quant_min,cell)),lanes_of(bc7_scale(quant_max,cell))
    selectors:[16]i32
    total:f32
    if n==16 {
        // The projection on the line between the endpoints gives the index
        // or the one above it: only those two are measured.
        mask:=F4{1,1,1,1} if channels==4 else F4{1,1,1,0}
        palette:[16]F4
        for i in 0..<n {
            w:=f32(cell.weights[i])
            palette[i]=intrinsics.simd_floor((low_f*(64-w)+high_f*w+32)*(1.0/64))
        }
        line:=(palette[n-1]-palette[0])*mask
        length:=lanes_sum(line*line,4)
        f:=f32(n)/length if length>0 else 0
        for p,i in pixels {
            color:=lanes_of(p)*mask
            index:=clamp(floor_f32(lanes_sum((color-palette[0])*line,4)*f+0.5),1,f32(n-1))
            d0,d1:=palette[int(index)-1]-color,palette[int(index)]-color
            e0,e1:=lanes_sum(d0*d0,channels),lanes_sum(d1*d1,channels)
            if e0<=e1 {
                total+=e0
                selectors[i]=i32(index)-1
            } else {
                total+=e1
                selectors[i]=i32(index)
            }
        }
    } else {
        // The palette by channel, four entries per lane group (n is 4 or 8).
        groups:=n/4
        palette:[2][4]F4
        for g in 0..<groups {
            w:F4
            #unroll for k in 0..<4 {w=intrinsics.simd_replace(w,k,f32(cell.weights[g*4+k]))}
            #unroll for c in 0..<4 {palette[g][c]=intrinsics.simd_floor((F4(intrinsics.simd_extract(low_f,c))*(64-w)+F4(intrinsics.simd_extract(high_f,c))*w+32)*(1.0/64))}
        }
        for p,i in pixels {
            best,best_error:=0,f32(1e30)
            for g in 0..<groups {
                d:=palette[g][0]-F4(f32(p[0]))
                e:=d*d
                d=palette[g][1]-F4(f32(p[1]))
                e+=d*d
                d=palette[g][2]-F4(f32(p[2]))
                e+=d*d
                if channels==4 {
                    d=palette[g][3]-F4(f32(p[3]))
                    e+=d*d
                }
                #unroll for k in 0..<4 {
                    if v:=intrinsics.simd_extract(e,k);v<best_error {best,best_error=g*4+k,v}
                }
            }
            total+=best_error
            selectors[i]=i32(best)
        }
    }
    error:=u64(total)
    if error<fit.error {
        fit.error=error
        fit.low,fit.high,fit.pbits=low,high,pbits
        fit.selectors=selectors
    }
    return error
}

// When an endpoint channel rounds both ends to one level, modes 1 and 4 move
// one of them a level apart, so a ramp keeps some of its slope.
@(private="file")
bc7_fix_degenerate :: proc "contextless" (mode:u32,low,high:^Bc7_Color,xl,xh:[4]f32,iscale:i32) {
    if mode!=1 && mode!=4 {return}
    for i in 0..<3 {
        if low[i]!=high[i] || abs(xl[i]-xh[i])<=0 {continue}
        if low[i]>iscale>>1 {
            if low[i]>0 {low[i]-=1} else if high[i]<iscale {high[i]+=1}
        } else {
            if high[i]<iscale {high[i]+=1} else if low[i]>0 {low[i]-=1}
        }
        if mode==4 {
            if low[i]>iscale>>1 {
                if high[i]<iscale {high[i]+=1} else if low[i]>0 {low[i]-=1}
            } else {
                if low[i]>0 {low[i]-=1} else if high[i]<iscale {high[i]+=1}
            }
        }
    }
}

// Quantizes endpoints in 0..1 to the mode and evaluates them.
@(private="file")
bc7_find_optimal :: proc(mode:u32,xl_in,xh_in:[4]f32,cell:^Bc7_Cell,fit:^Bc7_Fit,pbit_search:bool,pixels:[]Bc7_Color) -> u64 {
    xl,xh:=saturate4(xl_in),saturate4(xh_in)
    if !cell.has_pbits {
        iscale:=i32(1)<<u32(cell.comp_bits)-1
        scale:=f32(iscale)
        low,high:Bc7_Color
        for c in 0..<4 {
            low[c]=clamp(i32(xl[c]*scale+0.5),0,255)
            high[c]=clamp(i32(xh[c]*scale+0.5),0,255)
        }
        bc7_fix_degenerate(mode,&low,&high,xl,xh,iscale)
        if fit.error==max(u64) || low!=fit.low || high!=fit.high {bc7_evaluate(low,high,{0,0},cell,fit,pixels)}
        return fit.error
    }
    // The level of each channel whose low bit is the p-bit p: with
    // 2^(bits+1) levels, p 0 is b*2 and p 1 is b*2+1.
    iscalep:=i32(1)<<u32(cell.comp_bits+1)-1
    scalep:=f32(iscalep)
    quantize :: proc "contextless" (x:[4]f32,p,iscalep:i32,scalep:f32) -> (q:Bc7_Color) {
        for c in 0..<4 {q[c]=clamp(i32((x[c]*scalep-f32(p))/2+0.5)*2+p,p,iscalep-1+p)}
        return
    }
    half :: proc "contextless" (q:Bc7_Color) -> Bc7_Color {return {q[0]>>1,q[1]>>1,q[2]>>1,q[3]>>1}}
    if pbit_search {
        lo,hi:[2]Bc7_Color
        for p in 0..<2 {
            lo[p]=half(quantize(xl,i32(p),iscalep,scalep))
            hi[p]=half(quantize(xh,i32(p),iscalep,scalep))
        }
        bc7_fix_degenerate(mode,&lo[0],&hi[0],xl,xh,iscalep>>1)
        bc7_fix_degenerate(mode,&lo[1],&hi[1],xl,xh,iscalep>>1)
        bc7_evaluate(lo[0],hi[0],{0,0},cell,fit,pixels)
        if !cell.shared_pbit {
            bc7_evaluate(lo[0],hi[1],{0,1},cell,fit,pixels)
            bc7_evaluate(lo[1],hi[0],{1,0},cell,fit,pixels)
        }
        bc7_evaluate(lo[1],hi[1],{1,1},cell,fit,pixels)
        return fit.error
    }
    // The p-bits whose levels come closest to the endpoints.
    channels:=4 if cell.has_alpha else 3
    best_pbits:[2]i32
    low,high:Bc7_Color
    if !cell.shared_pbit {
        best_low,best_high:=f32(1e9),f32(1e9)
        for p in i32(0)..<2 {
            q_low,q_high:=quantize(xl,p,iscalep,scalep),quantize(xh,p,iscalep,scalep)
            s_low,s_high:=bc7_scale(q_low,cell),bc7_scale(q_high,cell)
            e_low,e_high:f32
            for i in 0..<channels {
                e_low+=(f32(s_low[i])-xl[i]*255)*(f32(s_low[i])-xl[i]*255)
                e_high+=(f32(s_high[i])-xh[i]*255)*(f32(s_high[i])-xh[i]*255)
            }
            if e_low<best_low {best_low,best_pbits[0],low=e_low,p,half(q_low)}
            if e_high<best_high {best_high,best_pbits[1],high=e_high,p,half(q_high)}
        }
    } else {
        best:=f32(1e9)
        for p in i32(0)..<2 {
            q_low,q_high:=quantize(xl,p,iscalep,scalep),quantize(xh,p,iscalep,scalep)
            s_low,s_high:=bc7_scale(q_low,cell),bc7_scale(q_high,cell)
            e:f32
            for i in 0..<channels {
                e+=(f32(s_low[i])/255-xl[i])*(f32(s_low[i])/255-xl[i])+(f32(s_high[i])/255-xh[i])*(f32(s_high[i])/255-xh[i])
            }
            if e<best {
                best=e
                best_pbits={p,p}
                low,high=half(q_low),half(q_high)
            }
        }
    }
    bc7_fix_degenerate(mode,&low,&high,xl,xh,iscalep>>1)
    if fit.error==max(u64) || low!=fit.low || high!=fit.high || best_pbits!=fit.pbits {bc7_evaluate(low,high,best_pbits,cell,fit,pixels)}
    return fit.error
}

// The endpoints (0..255) that best explain the texels given their indices,
// by the normal equations of least squares.
@(private="file")
bc7_least_squares :: proc "contextless" (selectors:[]i32,weights:[]u32,pixels:[]Bc7_Color) -> (xl,xh:[4]f32) {
    z00,z10,z11:f32
    q00,t:F4
    for p,i in pixels {
        w:=f32(weights[selectors[i]])/64
        z00+=w*w
        z10+=(1-w)*w
        z11+=(1-w)*(1-w)
        color:=lanes_of(p)
        q00+=color*w
        t+=color
    }
    q10:=t-q00
    det:=z00*z11-z10*z10
    if det!=0 {det=1/det}
    xl=transmute([4]f32)(q00*(z11*det)+q10*(-z10*det))
    xh=transmute([4]f32)(q00*(-z10*det)+q10*(z00*det))
    return
}

// Every texel of one color: the endpoints of the table that come closest to
// it at one index. Replaces fit.
@(private="file")
bc7_one_color :: proc(mode:u32,cell:^Bc7_Cell,fit:^Bc7_Fit,color:Bc7_Color,pixels:[]Bc7_Color) -> u64 {
    low,high:Bc7_Color
    pbits:[2]i32
    index:i32
    switch mode {
    case 0,6,7:
        // Four p-bit pairs, by the error of the three or four channels.
        channels:=3 if mode==0 else 4
        best,best_p:=max(u32),0
        for p in 0..<4 {
            e:u32
            for c in 0..<channels {
                switch mode {
                case 0: e+=u32(BC7_ONE_COLOR_0[color[c]][p>>1][p&1].error)
                case 6: e+=u32(BC7_ONE_COLOR_6[color[c]][p>>1][p&1].error)
                case 7: e+=u32(BC7_ONE_COLOR_7[color[c]][p>>1][p&1].error)
                }
            }
            if e<best {best,best_p=e,p}
        }
        for c in 0..<channels {
            entry:Bc7_Endpoints
            switch mode {
            case 0: entry=BC7_ONE_COLOR_0[color[c]][best_p>>1][best_p&1]
            case 6: entry=BC7_ONE_COLOR_6[color[c]][best_p>>1][best_p&1]
            case 7: entry=BC7_ONE_COLOR_7[color[c]][best_p>>1][best_p&1]
            }
            low[c],high[c]=i32(entry.lo),i32(entry.hi)
        }
        pbits={i32(best_p&1),i32(best_p>>1)}
        index=2 if mode==0 else 5 if mode==6 else 1
    case 1:
        best,best_p:=max(u32),0
        for p in 0..<2 {
            e:=u32(BC7_ONE_COLOR_1[color[0]][p].error)+u32(BC7_ONE_COLOR_1[color[1]][p].error)+u32(BC7_ONE_COLOR_1[color[2]][p].error)
            if e<best {best,best_p=e,p}
        }
        for c in 0..<3 {low[c],high[c]=i32(BC7_ONE_COLOR_1[color[c]][best_p].lo),i32(BC7_ONE_COLOR_1[color[c]][best_p].hi)}
        pbits={i32(best_p),0}
        index=2
    case:
        // Modes 2 and 4: five bits, two or three bits of index.
        three:=len(cell.weights)==8
        for c in 0..<3 {
            entry:=BC7_ONE_COLOR_4_3[color[c]] if three else BC7_ONE_COLOR_4_2[color[c]]
            low[c],high[c]=i32(entry.lo),i32(entry.hi)
        }
        index=2 if three else 1
    }
    quant_min,quant_max:=low,high
    if cell.has_pbits {
        for c in 0..<4 {
            quant_min[c]=low[c]<<1|pbits[0]
            quant_max[c]=high[c]<<1|(pbits[0] if cell.shared_pbit else pbits[1])
        }
    }
    e0,e1:=bc7_scale(quant_min,cell),bc7_scale(quant_max,cell)
    channels:=4 if mode==6 || mode==7 else 3
    decoded:Bc7_Color
    for c in 0..<channels {decoded[c]=i32(asset.bc7_interpolate(u32(e0[c]),u32(e1[c]),cell.weights[index]))}
    // Whole integers: the order of the sum does not change it.
    error:u64
    I4 :: #simd[4]i32
    decoded_l:=I4{decoded[0],decoded[1],decoded[2],decoded[3]}
    mask:=I4{1,1,1,1} if channels==4 else I4{1,1,1,0}
    squares:I4
    for p in pixels {
        d:=(decoded_l-I4{p[0],p[1],p[2],p[3]})*mask
        squares+=d*d
    }
    #unroll for lane in 0..<4 {error+=u64(intrinsics.simd_extract(squares,lane))}
    fit.error=error
    fit.low,fit.high,fit.pbits=low,high,pbits
    for &s in fit.selectors {s=index}
    return error
}

// The best fit of a mode to a subset of texels; refinement adds the least
// squares and uber passes after the fit along the principal axis.
@(private="file")
bc7_cell :: proc(mode:u32,cell:^Bc7_Cell,fit:^Bc7_Fit,settings:^Bc7_Settings,pixels:[]Bc7_Color,refinement:bool) -> u64 {
    fit.error=max(u64)
    one_color:=mode<=2 || mode==4 || mode>=6
    if one_color {
        same:=true
        for p in pixels[1:] {
            if p!=pixels[0] {same=false;break}
        }
        if same {return bc7_one_color(mode,cell,fit,pixels[0],pixels)}
    }
    count:=f32(len(pixels))
    sum_l:F4
    for p in pixels {sum_l+=lanes_of(p)}
    sum:=transmute([4]f32)sum_l
    mean_l:=sum_l/F4(count)
    mean_scaled:=transmute([4]f32)mean_l
    mean:=saturate4(sum/(count*255))
    axis:[4]f32
    if cell.has_alpha {
        v:F4
        for p,i in pixels {
            color:=lanes_of(p)-mean_l
            x:=v if i>0 else color
            n:=x
            if s:=lanes_sum(x*x,4);s!=0 {n=x*F4(1/math.sqrt(s))}
            v+={
                lanes_sum(color*F4(intrinsics.simd_extract(color,0))*n,4),lanes_sum(color*F4(intrinsics.simd_extract(color,1))*n,4),
                lanes_sum(color*F4(intrinsics.simd_extract(color,2))*n,4),lanes_sum(color*F4(intrinsics.simd_extract(color,3))*n,4),
            }
        }
        axis=normalize4(transmute([4]f32)v)
    } else {
        covariance:[6]f32
        for p in pixels {
            r,g,b:=f32(p[0])-mean_scaled[0],f32(p[1])-mean_scaled[1],f32(p[2])-mean_scaled[2]
            covariance[0]+=r*r
            covariance[1]+=r*g
            covariance[2]+=r*b
            covariance[3]+=g*g
            covariance[4]+=g*b
            covariance[5]+=b*b
        }
        vf:=[3]f32{0.9,1,0.7}
        for _ in 0..<3 {
            next:=[3]f32{
                vf[0]*covariance[0]+vf[1]*covariance[1]+vf[2]*covariance[2],
                vf[0]*covariance[1]+vf[1]*covariance[3]+vf[2]*covariance[4],
                vf[0]*covariance[2]+vf[1]*covariance[4]+vf[2]*covariance[5],
            }
            if m:=max(abs(next[0]),abs(next[1]),abs(next[2]));m>1e-10 {next*=1/m}
            vf=next
        }
        if length:=vf[0]*vf[0]+vf[1]*vf[1]+vf[2]*vf[2];length>=1e-10 {
            vf*=1/math.sqrt(length)
            axis={vf[0],vf[1],vf[2],0}
        }
    }
    if dot4(axis,axis)<0.5 {axis=normalize4({1,1,1,1 if cell.has_alpha else 0})}
    l,h:=f32(1e9),f32(-1e9)
    axis_l:=F4{axis[0],axis[1],axis[2],axis[3]}
    for p in pixels {
        d:=lanes_sum((lanes_of(p)-mean_l)*axis_l,4)
        l,h=min(l,d),max(h,d)
    }
    min_color:=saturate4(mean+axis*(l/255))
    max_color:=saturate4(mean+axis*(h/255))
    if dot4(min_color,{1,1,1,1})>dot4(max_color,{1,1,1,1}) {min_color,max_color=max_color,min_color}
    if bc7_find_optimal(mode,min_color,max_color,cell,fit,settings.pbit_search,pixels)==0 {return 0}
    if !refinement {return fit.error}

    refit :: proc(mode:u32,selectors:[]i32,cell:^Bc7_Cell,fit:^Bc7_Fit,pbit_search:bool,pixels:[]Bc7_Color) -> u64 {
        xl,xh:=bc7_least_squares(selectors,cell.weights,pixels)
        if !cell.has_alpha {xl[3],xh[3]=255,255}
        return bc7_find_optimal(mode,xl/255,xh/255,cell,fit,pbit_search,pixels)
    }
    for _ in 0..<settings.refinement_passes {
        if refit(mode,fit.selectors[:len(pixels)],cell,fit,settings.pbit_search,pixels)==0 {return 0}
    }
    if settings.uber_level>0 {
        selectors:=fit.selectors
        moved:[16]i32
        last:=i32(len(cell.weights)-1)
        min_sel,max_sel:=i32(16),i32(0)
        for s in selectors[:len(pixels)] {min_sel,max_sel=min(min_sel,s),max(max_sel,s)}
        for way in 0..<3 {
            if way not_in settings.uber1 {continue}
            for s,i in selectors[:len(pixels)] {
                moved[i]=s
                if (way==0 || way==2) && s==min_sel && s<last {moved[i]=s+1}
                else if (way==1 || way==2) && s==max_sel && s>0 {moved[i]=s-1}
            }
            if refit(mode,moved[:len(pixels)],cell,fit,settings.pbit_search,pixels)==0 {return 0}
        }
        if settings.uber_level>=2 && fit.error>u64(len(pixels)*56)>>4 {
            q:=i32(settings.uber_level)-2 if settings.uber_level>=4 else 1
            for ly:=-q;ly<=1;ly+=1 {
                for hy:=last-1;hy<=last+q;hy+=1 {
                    if ly==0 && hy==last {continue}
                    for s,i in selectors[:len(pixels)] {
                        moved[i]=i32(clamp(math.floor(f32(last)*(f32(s)-f32(ly))/(f32(hy)-f32(ly))+0.5),0,f32(last)))
                    }
                    if refit(mode,moved[:len(pixels)],cell,fit,settings.pbit_search,pixels)==0 {return 0}
                }
            }
        }
    }
    if one_color {
        average:Bc7_Fit
        color:=Bc7_Color{i32(0.5+mean[0]*255),i32(0.5+mean[1]*255),i32(0.5+mean[2]*255),i32(0.5+mean[3]*255)}
        if bc7_one_color(mode,cell,&average,color,pixels)<fit.error {fit^=average}
    }
    return fit.error
}

// The error of the quick fit of a subset: its bounding box diagonal with the
// mode's number of indices, without quantizing the endpoints.
@(private="file")
// The texels of subset are those whose entry of subsets is it, in order.
bc7_estimate :: proc "contextless" (index_bits:u32,alpha:bool,colors:^[16]F4,subsets:^[16]u8,subset:u8) -> u64 #no_bounds_check {
    lo,hi:=F4(255),F4(0)
    for color,i in colors {
        if subsets[i]!=subset {continue}
        lo,hi=intrinsics.simd_min(lo,color),intrinsics.simd_max(hi,color)
    }
    line:=(hi-lo)*(F4{1,1,1,1} if alpha else F4{1,1,1,0})
    low,high:=lanes_sum(line*lo,4),lanes_sum(line*hi,4)
    if high<=low {return 0}
    n:=f32(u32(1)<<index_bits)
    scale:=(n-1)/(high-low)
    total:f32
    for color,i in colors {
        if subsets[i]!=subset {continue}
        s:=clamp(floor_f32((lanes_sum(line*color,4)-low)*scale+0.5)/(n-1),0,1)
        d:=lo+line*s-color
        d*=d
        // Added to the total one channel at a time, as the scalar loop did.
        total+=intrinsics.simd_extract(d,0)
        total+=intrinsics.simd_extract(d,1)
        total+=intrinsics.simd_extract(d,2)
        if alpha {total+=intrinsics.simd_extract(d,3)}
    }
    return u64(total)
}

@(private="file")
bc7_subset_of :: proc "contextless" (subsets,partition:u32,texel:int) -> u32 {
    switch subsets {
    case 2: return u32(asset.BC7_PARTITIONS_2[partition][texel])
    case 3: return u32(asset.BC7_PARTITIONS_3[partition][texel])
    }
    return 0
}

@(private="file")
bc7_partition_error :: proc(mode,partition:u32,colors:^[16]F4) -> (error:u64) {
    m:=asset.BC7_MODES[mode]
    subsets:=&asset.BC7_PARTITIONS_3[partition] if m.subsets==3 else &asset.BC7_PARTITIONS_2[partition]
    for s in 0..<m.subsets {error+=bc7_estimate(m.index_bits,mode==7,colors,subsets,u8(s))}
    return
}

@(private="file")
bc7_lanes :: proc "contextless" (pixels:^[16]Bc7_Color) -> (colors:[16]F4) {
    for p,i in pixels {colors[i]=lanes_of(p)}
    return
}

// The pattern of a mode whose subsets fit best by the quick fit.
@(private="file")
bc7_partition :: proc(mode:u32,pixels:^[16]Bc7_Color,settings:^Bc7_Settings) -> u32 {
    m:=asset.BC7_MODES[mode]
    total:=min(settings.max_partitions[mode],u32(1)<<m.partition_bits)
    best,best_error:=u32(0),max(u64)
    colors:=bc7_lanes(pixels)
    for partition in 0..<total {
        if error:=bc7_partition_error(mode,partition,&colors);error<best_error {
            best,best_error=partition,error
            if error==0 {break}
        }
        if m.subsets==2 && partition==CHECKERBOARD_PARTITION && best!=CHECKERBOARD_PARTITION {break}
    }
    return best
}

// The wanted best patterns of a mode by the quick fit, best first.
@(private="file")
bc7_partitions :: proc(mode:u32,pixels:^[16]Bc7_Color,settings:^Bc7_Settings,wanted:int,solutions:^[64]Bc7_Solution) -> int {
    m:=asset.BC7_MODES[mode]
    total:=int(min(settings.max_partitions[mode],u32(1)<<m.partition_bits))
    if total<=1 {
        solutions[0]={}
        return 1
    }
    if wanted>=total {
        for i in 0..<total {solutions[i]={u32(i),u64(i)}}
        return total
    }
    // Two subsets keep at least four, so the order among the best is right.
    kept:=max(wanted,4) if m.subsets==2 else wanted
    count:=0
    colors:=bc7_lanes(pixels)
    for partition in 0..<total {
        error:=bc7_partition_error(mode,u32(partition),&colors)
        i:=0
        for i<count && error>=solutions[i].error {i+=1}
        if i<count {
            moved:=min(kept-1-i,count-i)
            for j:=moved-1;j>=0;j-=1 {solutions[i+j+1]=solutions[i+j]}
        }
        if count<kept {count+=1}
        if i<count {solutions[i]={u32(partition),error}}
    }
    return min(count,wanted)
}

// The subsets of a pattern of a mode compressed each; the block takes them
// when their error is lower than best_error.
@(private="file")
bc7_subsets :: proc(mode,partition:u32,cell:^Bc7_Cell,settings:^Bc7_Settings,pixels:^[16]Bc7_Color,refinement:bool,best_error:^u64,best:^Bc7_Block) {
    m:=asset.BC7_MODES[mode]
    colors:[3][16]Bc7_Color
    texel:[3][16]int
    counts:[3]int
    for p,i in pixels {
        s:=bc7_subset_of(m.subsets,partition,i)
        colors[s][counts[s]]=p
        texel[s][counts[s]]=i
        counts[s]+=1
    }
    fits:[3]Bc7_Fit
    error:u64
    for s in 0..<m.subsets {
        error+=bc7_cell(mode,cell,&fits[s],settings,colors[s][:counts[s]],refinement)
        if error>best_error^ {return}
    }
    if error>=best_error^ {return}
    best_error^=error
    best.mode,best.partition,best.rotation,best.index_selector=mode,partition,0,0
    for s in 0..<m.subsets {
        for k in 0..<counts[s] {best.selectors[texel[s][k]]=fits[s].selectors[k]}
        best.low[s],best.high[s],best.pbits[s]=fits[s].low,fits[s].high,fits[s].pbits
    }
}

// The patterns of a partitioned mode. With more than two, fast ones go
// without refinement and the winner, if it is of this mode, is compressed
// again with it.
@(private="file")
bc7_partitioned :: proc(mode:u32,cell:^Bc7_Cell,settings:^Bc7_Settings,pixels:^[16]Bc7_Color,solutions:[]Bc7_Solution,fast:bool,best_error:^u64,best:^Bc7_Block) {
    refine:=!fast || len(solutions)<=2
    for solution in solutions {bc7_subsets(mode,solution.partition,cell,settings,pixels,refine,best_error,best)}
    if !refine && best.mode==mode {bc7_subsets(mode,best.partition,cell,settings,pixels,true,best_error,best)}
}

// The texels with the color channel of a rotation swapped with alpha, and
// the range of their alpha.
@(private="file")
bc7_rotate :: proc "contextless" (pixels:^[16]Bc7_Color,rotation:u32,lo_a,hi_a:i32) -> (rotated:[16]Bc7_Color,lo,hi:i32) {
    if rotation==0 {return pixels^,lo_a,hi_a}
    lo,hi=255,0
    for p,i in pixels {
        rotated[i]=p
        rotated[i][3],rotated[i][rotation-1]=p[rotation-1],p[3]
        lo,hi=min(lo,rotated[i][3]),max(hi,rotated[i][3])
    }
    return
}

// The indices of an alpha between two 8-bit endpoints, and their error.
@(private="file")
bc7_alpha_indices :: proc "contextless" (lo,hi:i32,weights:[]u32,pixels:^[16]Bc7_Color) -> (error:u64,selectors:[16]i32) {
    values:[8]i32
    for w,k in weights {values[k]=i32(asset.bc7_interpolate(u32(lo),u32(hi),w))}
    // Four texels per lane group; the first nearest value wins, as in order.
    I4 :: #simd[4]i32
    for g in 0..<4 {
        alpha:I4
        #unroll for lane in 0..<4 {alpha=intrinsics.simd_replace(alpha,lane,pixels[g*4+lane][3])}
        best:=intrinsics.simd_abs(alpha-I4(values[0]))
        s:I4
        for k in 1..<len(weights) {
            e:=intrinsics.simd_abs(alpha-I4(values[k]))
            closer:=intrinsics.simd_lanes_lt(e,best)
            best=intrinsics.simd_select(closer,e,best)
            s=intrinsics.simd_select(closer,I4(i32(k)),s)
        }
        squares:=best*best
        #unroll for lane in 0..<4 {
            error+=u64(intrinsics.simd_extract(squares,lane))
            selectors[g*4+lane]=intrinsics.simd_extract(s,lane)
        }
    }
    return
}

// Mode 4: color in 5 bits and alpha in 6, with two or three bits of index
// each; which one gets three is the index selector.
@(private="file")
bc7_mode4 :: proc(pixels:^[16]Bc7_Color,settings:^Bc7_Settings,lo_a,hi_a:i32,rotation:u32,best_error:^u64,best:^Bc7_Block) {
    expand :: proc "contextless" (v:i32) -> i32 {return v<<2|v>>4}
    for index_selector in 0..<2 {
        if index_selector not_in settings.mode4_indices {continue}
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_3[:] if index_selector==1 else asset.BC7_WEIGHTS_2[:],comp_bits=5}
        alpha_weights:=asset.BC7_WEIGHTS_2[:] if index_selector==1 else asset.BC7_WEIGHTS_3[:]
        fit:Bc7_Fit
        error:=bc7_cell(4,&cell,&fit,settings,pixels[:],true)
        la,ha:=min((lo_a+2)>>2,63),min((hi_a+2)>>2,63)
        if la==ha && lo_a!=hi_a {
            if ha!=63 {ha+=1} else if la!=0 {la-=1}
        }
        best_alpha:=max(u64)
        best_la,best_ha:i32
        best_selectors:[16]i32
        for pass in 0..<2 {
            alpha_error,selectors:=bc7_alpha_indices(expand(la),expand(ha),alpha_weights,pixels)
            if alpha_error<best_alpha {best_alpha,best_la,best_ha,best_selectors=alpha_error,la,ha,selectors}
            if pass==0 {
                xl,xh:=bc7_least_squares(selectors[:],alpha_weights,pixels[:])
                a0,a1:=min(xl[3],xh[3]),max(xl[3],xh[3])
                la=clamp(i32(math.floor(a0*(63.0/255)+0.5)),0,63)
                ha=clamp(i32(math.floor(a1*(63.0/255)+0.5)),0,63)
            }
        }
        if settings.uber_level>0 {
            d:=min(i32(settings.uber_level),3)
            for ld in -d..=d {
                for hd in -d..=d {
                    la,ha=clamp(best_la+ld,0,63),clamp(best_ha+hd,0,63)
                    alpha_error,selectors:=bc7_alpha_indices(expand(la),expand(ha),alpha_weights,pixels)
                    if alpha_error<best_alpha {best_alpha,best_la,best_ha,best_selectors=alpha_error,la,ha,selectors}
                }
            }
        }
        error+=best_alpha
        if error<best_error^ {
            best_error^=error
            best^={mode=4,index_selector=u32(index_selector),rotation=rotation,selectors=fit.selectors,alpha_selectors=best_selectors}
            best.low[0],best.high[0]=fit.low,fit.high
            best.low[0][3],best.high[0][3]=best_la,best_ha
        }
    }
}

// Mode 5: color in 7 bits and alpha in 8, two bits of index each.
@(private="file")
bc7_mode5 :: proc(pixels:^[16]Bc7_Color,settings:^Bc7_Settings,lo_a,hi_a:i32,rotation:u32,best_error:^u64,best:^Bc7_Block) {
    cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_2[:],comp_bits=7}
    fit:Bc7_Fit
    error:=bc7_cell(5,&cell,&fit,settings,pixels[:],true)
    block:=Bc7_Block{mode=5,rotation=rotation,selectors=fit.selectors}
    block.low[0],block.high[0]=fit.low,fit.high
    block.low[0][3],block.high[0][3]=lo_a,hi_a
    if lo_a!=hi_a {
        lo,hi:=lo_a,hi_a
        alpha_error:=max(u64)
        for pass in 0..<2 {
            trial,selectors:=bc7_alpha_indices(lo,hi,asset.BC7_WEIGHTS_2[:],pixels)
            if trial<alpha_error {
                alpha_error,block.alpha_selectors=trial,selectors
                block.low[0][3],block.high[0][3]=lo,hi
            }
            if pass==0 {
                xl,xh:=bc7_least_squares(selectors[:],asset.BC7_WEIGHTS_2[:],pixels[:])
                new_lo,new_hi:=clamp(i32(math.floor(xl[3]+0.5)),0,255),clamp(i32(math.floor(xh[3]+0.5)),0,255)
                if new_lo>new_hi {new_lo,new_hi=new_hi,new_lo}
                if new_lo==lo && new_hi==hi {break}
                lo,hi=new_lo,new_hi
            }
        }
        if settings.uber_level>0 {
            d:=min(i32(settings.uber_level),3)
            for ld in -d..=d {
                for hd in -d..=d {
                    lo,hi=clamp(block.low[0][3]+ld,0,255),clamp(block.high[0][3]+hd,0,255)
                    trial,selectors:=bc7_alpha_indices(lo,hi,asset.BC7_WEIGHTS_2[:],pixels)
                    if trial<alpha_error {
                        alpha_error,block.alpha_selectors=trial,selectors
                        block.low[0][3],block.high[0][3]=lo,hi
                    }
                }
            }
        }
        error+=alpha_error
    }
    if error<best_error^ {
        best_error^=error
        best^=block
    }
}

@(private="file")
bc7_alpha_block :: proc(pixels:^[16]Bc7_Color,settings:^Bc7_Settings,lo_a,hi_a:i32) -> (best:Bc7_Block,best_error:u64) {
    best_error=max(u64)
    if 4 in settings.alpha_modes {
        for rotation in 0..<4 {
            if rotation not_in settings.mode4_rotations {continue}
            rotated,lo,hi:=bc7_rotate(pixels,u32(rotation),lo_a,hi_a)
            bc7_mode4(&rotated,settings,lo,hi,u32(rotation),&best_error,&best)
        }
    }
    if 6 in settings.alpha_modes {
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_4[:],comp_bits=7,has_alpha=true,has_pbits=true}
        fit:Bc7_Fit
        if error:=bc7_cell(6,&cell,&fit,settings,pixels[:],true);error<best_error {
            best_error=error
            best={mode=6,selectors=fit.selectors}
            best.low[0],best.high[0],best.pbits[0]=fit.low,fit.high,fit.pbits
        }
    }
    if 5 in settings.alpha_modes {
        for rotation in 0..<4 {
            if rotation not_in settings.mode5_rotations {continue}
            rotated,lo,hi:=bc7_rotate(pixels,u32(rotation),lo_a,hi_a)
            bc7_mode5(&rotated,settings,lo,hi,u32(rotation),&best_error,&best)
        }
    }
    if 7 in settings.alpha_modes {
        solutions:[64]Bc7_Solution
        count:=bc7_partitions(7,pixels,settings,int(settings.tried[7]),&solutions)
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_2[:],comp_bits=5,has_alpha=true,has_pbits=true}
        bc7_partitioned(7,&cell,settings,pixels,solutions[:count],true,&best_error,&best)
    }
    return
}

@(private="file")
bc7_opaque_block :: proc(pixels:^[16]Bc7_Color,settings:^Bc7_Settings) -> (best:Bc7_Block,best_error:u64) {
    best_error=max(u64)
    if 6 in settings.opaque_modes {
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_4[:],comp_bits=7,has_pbits=true}
        fit:Bc7_Fit
        best_error=bc7_cell(6,&cell,&fit,settings,pixels[:],true)
        best={mode=6,selectors=fit.selectors}
        best.low[0],best.high[0],best.pbits[0]=fit.low,fit.high,fit.pbits
    }
    // Modes 1 and 3 share the patterns of two subsets.
    solutions:[64]Bc7_Solution
    count:=0
    if 1 in settings.opaque_modes || 3 in settings.opaque_modes {
        if settings.tried[1]==1 {
            solutions[0]={bc7_partition(1,pixels,settings),0}
            count=1
        } else {
            count=bc7_partitions(1,pixels,settings,int(settings.tried[1]),&solutions)
        }
    }
    if 1 in settings.opaque_modes {
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_3[:],comp_bits=6,has_pbits=true,shared_pbit=true}
        bc7_partitioned(1,&cell,settings,pixels,solutions[:count],true,&best_error,&best)
    }
    three :: proc(mode:u32,pixels:^[16]Bc7_Color,settings:^Bc7_Settings,solutions:^[64]Bc7_Solution) -> int {
        if settings.tried[mode]==1 {
            solutions[0]={bc7_partition(mode,pixels,settings),0}
            return 1
        }
        return bc7_partitions(mode,pixels,settings,int(settings.tried[mode]),solutions)
    }
    if 0 in settings.opaque_modes {
        others:[64]Bc7_Solution
        others_count:=three(0,pixels,settings,&others)
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_3[:],comp_bits=4,has_pbits=true}
        bc7_partitioned(0,&cell,settings,pixels,others[:others_count],false,&best_error,&best)
    }
    if 3 in settings.opaque_modes {
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_2[:],comp_bits=7,has_pbits=true}
        bc7_partitioned(3,&cell,settings,pixels,solutions[:count],true,&best_error,&best)
    }
    if 5 in settings.opaque_modes {
        for rotation in 0..<4 {
            if rotation not_in settings.mode5_rotations {continue}
            rotated,lo,hi:=bc7_rotate(pixels,u32(rotation),255,255)
            bc7_mode5(&rotated,settings,lo,hi,u32(rotation),&best_error,&best)
        }
    }
    if 2 in settings.opaque_modes {
        others:[64]Bc7_Solution
        others_count:=three(2,pixels,settings,&others)
        cell:=Bc7_Cell{weights=asset.BC7_WEIGHTS_2[:],comp_bits=5}
        bc7_partitioned(2,&cell,settings,pixels,others[:others_count],false,&best_error,&best)
    }
    if 4 in settings.opaque_modes {
        for rotation in 0..<4 {
            if rotation not_in settings.mode4_rotations {continue}
            rotated,lo,hi:=bc7_rotate(pixels,u32(rotation),255,255)
            bc7_mode4(&rotated,settings,lo,hi,u32(rotation),&best_error,&best)
        }
    }
    return
}

// The bits of a block: the anchors of each subset get the index whose top
// bit is zero, swapping their endpoints where it was not.
@(private)
bc7_pack :: proc "contextless" (b:^Bc7_Block) -> [16]u8 {
    m:=asset.BC7_MODES[b.mode]
    selectors,alpha_selectors:=b.selectors,b.alpha_selectors
    low,high,pbits:=b.low,b.high,b.pbits
    separate:=m.index_bits2>0
    color_bits,alpha_bits:=m.index_bits,m.index_bits2
    if b.index_selector==1 {color_bits,alpha_bits=alpha_bits,color_bits}
    anchors:=[3]int{-1,-1,-1}
    for k in 0..<m.subsets {
        anchor:=0
        switch {
        case k==1 && m.subsets==2: anchor=int(asset.BC7_ANCHORS_2[b.partition])
        case k>0 && m.subsets==3:  anchor=int(asset.BC7_ANCHORS_3[b.partition][k-1])
        }
        anchors[k]=anchor
        colors:=i32(1)<<color_bits
        if selectors[anchor]&(colors>>1)!=0 {
            for &s,i in selectors {
                if bc7_subset_of(m.subsets,b.partition,i)==k {s=colors-1-s}
            }
            if separate {
                for c in 0..<3 {low[k][c],high[k][c]=high[k][c],low[k][c]}
            } else {
                low[k],high[k]=high[k],low[k]
            }
            if !m.shared_pbits {pbits[k][0],pbits[k][1]=pbits[k][1],pbits[k][0]}
        }
        if separate {
            alphas:=i32(1)<<alpha_bits
            if alpha_selectors[anchor]&(alphas>>1)!=0 {
                for &s,i in alpha_selectors {
                    if bc7_subset_of(m.subsets,b.partition,i)==k {s=alphas-1-s}
                }
                low[k][3],high[k][3]=high[k][3],low[k][3]
            }
        }
    }
    bits:u128
    at:u32
    put :: proc "contextless" (bits:^u128,at:^u32,value:i32,count:u32) {
        bits^|=(u128(u32(value))&(u128(1)<<count-1))<<at^
        at^+=count
    }
    put(&bits,&at,i32(1)<<b.mode,b.mode+1)
    put(&bits,&at,i32(b.rotation),m.rotation_bits)
    put(&bits,&at,i32(b.index_selector),m.selector_bit)
    put(&bits,&at,i32(b.partition),m.partition_bits)
    channels:=4 if m.alpha_bits>0 else 3
    for c in 0..<channels {
        for s in 0..<m.subsets {
            n:=m.alpha_bits if c==3 else m.color_bits
            put(&bits,&at,low[s][c],n)
            put(&bits,&at,high[s][c],n)
        }
    }
    if m.endpoint_pbits || m.shared_pbits {
        for s in 0..<m.subsets {
            put(&bits,&at,pbits[s][0],1)
            if m.endpoint_pbits {put(&bits,&at,pbits[s][1],1)}
        }
    }
    anchored :: proc "contextless" (anchors:[3]int,i:int) -> bool {return i==anchors[0] || i==anchors[1] || i==anchors[2]}
    // The first set of indices is the alpha's when the index selector gives color the second.
    first,second:=selectors,alpha_selectors
    first_bits,second_bits:=color_bits,alpha_bits
    if b.index_selector==1 {first,second,first_bits,second_bits=alpha_selectors,selectors,alpha_bits,color_bits}
    for s,i in first {put(&bits,&at,s,first_bits-u32(anchored(anchors,i)))}
    if separate {
        for s,i in second {put(&bits,&at,s,second_bits-u32(anchored(anchors,i)))}
    }
    return transmute([16]u8)bits
}

// The block of 4x4 texels, as RGBA bytes row by row, and its squared error:
// in RGBA, or in RGB for an opaque block, whose alpha mode 6 may give 254.
@(private)
bc7_choose :: proc(texels:^[16][4]u8,settings:^Bc7_Settings) -> (block:Bc7_Block,error:u64) {
    pixels:[16]Bc7_Color
    lo:=Bc7_Color{255,255,255,255}
    hi:Bc7_Color
    for t,i in texels {
        pixels[i]={i32(t[0]),i32(t[1]),i32(t[2]),i32(t[3])}
        for c in 0..<4 {
            lo[c]=min(lo[c],pixels[i][c])
            hi[c]=max(hi[c],pixels[i][c])
        }
    }
    switch {
    case lo==hi:
        // One color: mode 5 holds any exactly.
        block.mode=5
        for c in 0..<3 {
            entry:=BC7_ONE_COLOR_5[lo[c]]
            block.low[0][c],block.high[0][c]=i32(entry.lo),i32(entry.hi)
        }
        block.low[0][3],block.high[0][3]=lo[3],lo[3]
        for &s in block.selectors {s=1}
    case lo[3]<255:
        block,error=bc7_alpha_block(&pixels,settings,lo[3],hi[3])
    case:
        block,error=bc7_opaque_block(&pixels,settings)
    }
    return
}

@(private)
bc7_encode_block :: proc(texels:^[16][4]u8,settings:^Bc7_Settings) -> [16]u8 {
    block,_:=bc7_choose(texels,settings)
    return bc7_pack(&block)
}
