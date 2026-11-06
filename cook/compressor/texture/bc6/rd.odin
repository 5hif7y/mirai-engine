package bc6

import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Rate-distortion optimization of BC6H: each block tries the endpoints of
// recent blocks with new indices, and their indices with new endpoints, and
// keeps what lowers D + lambda*R, where D is the activity weighted MRSSE of
// the encoder and R the bits an LZ match would leave.

@(private="file")
LAMBDA_SCALE :: 1.5*common.GLOBAL_LAMBDA_SCALE

// Window sizes of the endpoint and index passes per effort.
@(rodata,private="file")
WINDOW_SIZES := [5][2]int{{256,256},{80,40},{150,70},{256,256},{256,256}}

@(private="file")
Window_Entry :: struct {
    st:Block_State,
    most_recent_bi:int,
}

@(private="file")
Window :: struct {
    slots:[]Window_Entry, // in no order, reached through inds
    inds:[]u16,           // slot of the i-th most recent entry
    count:int,
}

@(private="file")
window_at :: #force_inline proc "contextless" (w:^Window,i:int) -> ^Window_Entry {
    return &w.slots[w.inds[i]]
}

// Block bi took entry found (or a new one when -1): to the front.
@(private="file")
window_update :: proc "contextless" (w:^Window,bi,found:int,st:^Block_State) {
    found:=found
    if found<0 {
        if w.count<len(w.inds) {
            found=w.count
            w.count+=1
        } else {
            found=len(w.inds)-1
        }
        w.slots[w.inds[found]].st=st^
    }
    slot:=w.inds[found]
    for k:=found;k>0;k-=1 {w.inds[k]=w.inds[k-1]}
    w.inds[0]=slot
    w.slots[slot].most_recent_bi=bi
}

// The mean length in bits of a byte-wise LZ match of matched_bits.
@(private="file")
matched_bits_to_lz_bits :: #force_inline proc "contextless" (matched_bits:int) -> f32 {
    bytes:=matched_bits/8
    frac:=matched_bits-bytes*8
    p:=f32(int(256)>>uint(8-frac))/256.0
    return (f32(bytes)+p)*8.0
}

@(private="file")
matched_R :: #force_inline proc "contextless" (matched_bits,offset:int) -> f32 {
    lz_bits:=matched_bits_to_lz_bits(matched_bits)
    raw_bits:=128-lz_bits
    match_bits:=10+entropy.rrlog2_bk(u32(offset+32))
    return raw_bits+match_bits
}

// A float to half bits, rounding to nearest even; overflow gives infinity
// and float subnormals 0.
f32_to_half :: proc "contextless" (v:f32) -> u16 {
    bits:=transmute(u32)v
    sign:=bits>>31
    exponent:=(bits>>23)&0xff
    mantissa:=bits&0x007fffff
    o:u32
    if exponent==0 {
        o=0
    } else if exponent==255 {
        o=(31<<10)|(mantissa!=0 ? 0x200 : 0)|(mantissa>>13)
    } else {
        e:=int(exponent)-127+15
        if e>=31 {
            o=31<<10
        } else if e<=0 {
            shift:=uint(14-e)
            if shift<=24 {
                mant:=mantissa|0x800000
                o=mant>>shift
                mask:=u32(1)<<shift
                low:=mant&(mask-1)
                if low+(o&1)>(mask>>1) {o+=1}
            }
        } else {
            o=(u32(e)<<10)|(mantissa>>13)
            if (mantissa&0x1fff)+(o&1)>0x1000 {o+=1}
        }
    }
    return u16(o|(sign<<15))
}

// RDO of a slice of BC6U blocks: `baseline` holds their non-RDO encode, 16
// bytes per block like `to`, and `activity` one Float_Block per block.
rd :: proc(to:[]u8,from:[]common.Float4_Block,baseline:[]u8,activity:[]common.Float_Block,
    lambda:int,
    options:common.Options,rd_options:common.RD_Options,
    allocator:=context.allocator) -> common.Error {
    n:=len(from)
    if len(to)<n*16 || len(baseline)<n*16 || len(activity)!=n || lambda<0 {return .Invalid}
    if int(rd_options.effort)>=len(WINDOW_SIZES) {return .Invalid}
    if n==0 {return .None}
    sizes:=WINDOW_SIZES[rd_options.effort]
    flambda:=f32(lambda)*LAMBDA_SCALE

    windows:[2]Window
    for &w,k in windows {
        slots,e1:=make([]Window_Entry,sizes[k],allocator)
        if e1!=nil {return .Out_Of_Memory}
        inds,e2:=make([]u16,sizes[k],allocator)
        if e2!=nil {
            delete(slots,allocator)
            return .Out_Of_Memory
        }
        for &x,i in inds {x=u16(i)}
        w={slots,inds,0}
    }
    defer for w in windows {
        delete(w.slots,allocator)
        delete(w.inds,allocator)
    }
    ep_window:=&windows[0]
    ind_window:=&windows[1]

    opt:=options_init(rd_options.effort,options)
    for bi in 0..<n {
        blk:[16][4]u16
        for t in 0..<16 {for c in 0..<4 {blk[t][c]=f32_to_half(from[bi][t][c])}}
        canonicalize_pixels(&blk)
        // No randomized refinement here: the seed is unused.
        input:Input
        input_init(&input,&blk,{},opt.flags)
        for i in 0..<16 {input.weightf32[i]*=activity[bi][i]}

        baseline_st:Block_State
        if !state_from_bits(&baseline_st,(^[16]u8)(&baseline[bi*16])) {return .Invalid}
        best_J:=f32(eval_error(&baseline_st,&input))+flambda*128
        best_st:=baseline_st
        best_ep,best_ind:=-1,-1

        for i in 0..<ep_window.count {
            w:=window_at(ep_window,i)
            st:=w.st
            D:=reindex_block(&st,&input)
            // Header and endpoints: 82 bits with two subsets, 65 with one.
            bits:=MODE_DESC[st.mode&15].is_two_subset ? 83 : 65
            J:=f32(D)+flambda*matched_R(bits,bi-w.most_recent_bi)
            if J<best_J {
                best_J=J
                best_st=st
                best_ep,best_ind=i,-1
            }
        }
        for i in 0..<ind_window.count {
            w:=window_at(ind_window,i)
            st:=w.st
            D:=new_endpoints_with_indices_fixed(&st,&input)
            // Partition and indices: 5+46 bits with two subsets, 63 with one.
            bits:=MODE_DESC[st.mode&15].is_two_subset ? 5+46 : 63
            J:=f32(D)+flambda*matched_R(bits,bi-w.most_recent_bi)
            if J<best_J {
                best_J=J
                best_st=st
                best_ep,best_ind=-1,i
            }
        }
        emit((^[16]u8)(&to[bi*16]),&best_st)
        window_update(ep_window,bi,best_ep,&best_st)
        window_update(ind_window,bi,best_ind,&best_st)
    }
    return .None
}
