package bc7

import "base:runtime"
import "core:math/bits"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Late passes of the BC7 RDO: shared-index and shared-endpoint optimization,
// the static rate model and the final matrix.

@(private)
block_bits_at :: #force_inline proc "contextless" (blocks:[]u8,bi:int) -> ^[16]u8 {
    return (^[16]u8)(&blocks[bi*16])
}

// Total SSD of a set of blocks with the bits in mask replaced by new_bits.
@(private)
final_optimize_blockset_d :: proc "contextless" (blocks:[]u8,infos:[]Block_Info,flags:Flags,
    set:[]common.Bits128_And_Count,new_bits,mask:Bits) -> f32 {
    tot:f32
    for s in set {
        bi:=int(s.count)
        bits:=bits_load(block_bits_at(blocks,bi))
        bits=(bits&~mask)|new_bits
        colors:common.Color_Block
        decode_bits4x4a(&colors,bits,flags)
        tot+=f32(common.color_block_ssd_rgba(&colors,&infos[bi].colors))
    }
    return tot
}

@(private)
final_optimize_blockset_indices :: proc "contextless" (mode:int,blocks:[]u8,infos:[]Block_Info,
    flags:Flags,
    set:[]common.Bits128_And_Count,mask:Bits) -> Bits {
    NUM_CLASSES :: 14
    ns:=int(bc67.BC7_MODES[mode].ns)
    cls_counts:[NUM_CLASSES]int
    cur_max_cls,cur_max_count,cls_repr:int
    index_constraints:[2]Constraints
    for s in set {
        bi:=int(s.count)
        block:=block_bits_at(blocks,bi)
        part:=read_partition_id(block,mode)
        cls:=int(bc67.ANCHOR_EQV[ns-1][part])
        if cls>=NUM_CLASSES {cls=NUM_CLASSES-1}
        cls_counts[cls]+=1
        if cls_counts[cls]>cur_max_count {
            cur_max_count=cls_counts[cls]
            cur_max_cls=cls
            cls_repr=bi
        }
        if !may_merge_indices(block,mode,&infos[bi],&index_constraints) {
            return bits_load(block)&mask
        }
    }
    if index_constraints[0]!=0 || index_constraints[1]!=0 {
        IMPOSSIBLE :: Constraints(0x10000)
        if !constraints_feasible(index_constraints[0]) ||
            !constraints_feasible(index_constraints[1]) ||
            constraints_intersects(index_constraints[0],IMPOSSIBLE) ||
            constraints_intersects(index_constraints[1],IMPOSSIBLE) {
            return bits_load(block_bits_at(blocks,cls_repr))&mask
        }
    }
    errs:[2]Index_Errors
    for s in set {
        bi:=int(s.count)
        block:=block_bits_at(blocks,bi)
        part:=read_partition_id(block,mode)
        cls:=int(bc67.ANCHOR_EQV[ns-1][part])
        if cls!=cur_max_cls {continue}
        st:Block_State
        state_from_bits(&st,block,infos[bi].flags)
        input:Input
        input_get_state(&input,&infos[bi].colors,&st)
        accumulate_index_errors(&errs,&st,&input)
    }
    st:Block_State
    state_from_bits(&st,block_bits_at(blocks,cls_repr),infos[cls_repr].flags)
    for sel in 0..<2 {
        if index_constraints[sel]==0 {continue}
        cur:=&errs[sel]
        ib:=sel!=0 ? int(bc67.BC7_MODES[mode].ib2) : int(bc67.BC7_MODES[mode].ib)
        max_ind:=(1<<uint(ib))-1
        cmask:=u32(index_constraints[sel])
        pixel_mask:=(cmask&0xffff)|(cmask>>16)
        for pixel_mask!=0 {
            pixel:=int(bits.count_trailing_zeros(pixel_mask))
            pixel_mask&=pixel_mask-1
            if cmask&(u32(1)<<uint(pixel))!=0 {
                target:=cur.err[pixel][0]
                for i in 1..=max_ind {cur.err[pixel][i]=target+1}
            } else {
                target:=cur.err[pixel][max_ind]
                for i in 0..<max_ind {cur.err[pixel][i]=target+1}
            }
        }
    }
    reindex_for_min_error(&st,&errs)
    out:[16]u8
    emit(&out,&st)
    return bits_load(&out)&mask
}

// Storage of the multi-block solves, grown geometrically.
@(private)
Multi_Storage :: struct {
    data:[]Block_And_Input,
    allocator:runtime.Allocator,
}

@(private)
multi_storage_acquire :: proc(s:^Multi_Storage,count:int) -> ([]Block_And_Input,bool) {
    if len(s.data)<count {
        new_cap:=max(len(s.data)*2,count,4)
        delete(s.data,s.allocator)
        s.data=nil
        d,err:=make([]Block_And_Input,new_cap,s.allocator)
        if err!=nil {return nil,false}
        s.data=d
    }
    return s.data[:count],true
}

@(private)
final_optimize_blockset_endpoints :: proc(mode:int,blocks:[]u8,infos:[]Block_Info,flags:Flags,
    set:[]common.Bits128_And_Count,mask:Bits,storage:^Multi_Storage) -> (Bits,bool) {
    st:Block_State
    combined_flags:=flags&~(PRESERVE_EXTREMES|AEP0_CONSTRAINED)
    data,ok:=multi_storage_acquire(storage,len(set))
    if !ok {return {},false}
    multi:=Multi_Blocks{data=data}
    for i in 0..<len(set) {
        bi:=int(set[i].count)
        multi_blocks_set(&multi,i,block_bits_at(blocks,bi),&infos[bi].colors,infos[bi].flags)
        combined_flags|=infos[bi].flags&PRESERVE_EXTREMES
        if infos[bi].flags&PRESERVE_EXTREMES!=0 && mode>=4 {
            block:=block_bits_at(blocks,bi)
            valid:=true
            state_from_bits(&st,block,infos[bi].flags)
            if !are_endpoints_permitted(&st,&infos[bi]) {valid=false}
            if mode<=5 {
                sst:=&st.subsets[0]
                block_constraints:=infos[bi].constraints
                diff:=int(sst.endpoints[0][3])-int(sst.endpoints[1][3])
                if diff!=0 {
                    combined_flags|=diff<0 ? AEP0_LO : AEP0_HI
                    ib:=(st.mode==5 || sst.isbit==1) ? 2 : 3
                    satisfiable:=constraints_from_indices(&sst.idxs[(sst.isbit&1)~1],ib)
                    if diff<0 && !constraints_superset_of(satisfiable,
                        block_constraints) {valid=false}
                    if diff>0 && !constraints_superset_of(constraints_flip(satisfiable),
                        block_constraints) {
                        valid=false
                    }
                } else {
                    valid=false
                }
            } else {
                valid=false
            }
            if !valid {return bits_load(block)&mask,true}
        }
    }
    if combined_flags&PRESERVE_EXTREMES!=0 {
        if combined_flags&AEP0_CONSTRAINED==AEP0_CONSTRAINED {
            return bits_load(block_bits_at(blocks,int(set[0].count)))&mask,true
        }
    }
    bi:=int(set[len(set)/2].count)
    state_from_bits(&st,block_bits_at(blocks,bi),infos[bi].flags)
    find_endpoints_multi(&st,&multi,combined_flags,false,true)
    out:[16]u8
    emit(&out,&st)
    return bits_load(&out)&mask,true
}

@(private)
final_optimize :: proc(blocks:[]u8,infos:[]Block_Info,flags:Flags,do_indices:bool,
    allocator:runtime.Allocator) -> common.Error {
    nb:=len(infos)
    bits_and_index:=make([dynamic]common.Bits128_And_Count,0,nb,allocator)
    if cap(bits_and_index)<nb {return .Out_Of_Memory}
    defer delete(bits_and_index)
    storage:=Multi_Storage{allocator=allocator}
    defer delete(storage.data,allocator)
    for mode in 0..<8 {
        clear(&bits_and_index)
        mask:=do_indices ? BITRANGE_INDICES_MASK[mode] : BITRANGE_ENDPOINTS_MASK[mode]
        for bi in 0..<nb {
            block:=block_bits_at(blocks,bi)
            bits:=bits_load(block)
            if bits_get_mode(bits)!=mode {continue}
            if mode==5 && is_encoded_single_color_block(block) {continue}
            append(&bits_and_index,common.Bits128_And_Count{bits&mask,u32(bi)})
        }
        if len(bits_and_index)==0 {continue}
        common.sort_bits128_and_count_compare_bits(bits_and_index[:])
        begin:=0
        for begin<len(bits_and_index) {
            bits_before:=bits_and_index[begin].val
            end:=begin+1
            for end<len(bits_and_index) && bits_and_index[end].val==bits_before {end+=1}
            set:=bits_and_index[begin:end]
            new_bits:Bits
            if do_indices {
                new_bits=final_optimize_blockset_indices(mode,blocks,infos,flags,set,mask)
            } else {
                ok:bool
                new_bits,ok=final_optimize_blockset_endpoints(mode,blocks,infos,flags,set,mask,
                    &storage)
                if !ok {return .Out_Of_Memory}
            }
            if new_bits!=bits_before {
                d_before:=final_optimize_blockset_d(blocks,infos,flags,set,{},{})
                d_after:=final_optimize_blockset_d(blocks,infos,flags,set,new_bits,mask)
                if d_after<d_before {
                    for s in set {
                        block:=block_bits_at(blocks,int(s.count))
                        bits:=(bits_load(block)&~mask)|new_bits
                        bits_store(block,bits)
                    }
                }
            }
            begin=end
        }
    }
    return .None
}

@(private)
Static_Rater_Portion :: struct {
    hash:map[Bits]f32,
    escape_code_len:f32,
}

@(private)
static_rater_portion_get_rate :: #force_inline proc(p:^Static_Rater_Portion,bits:Bits) -> f32 {
    if r,ok:=p.hash[bits]; ok {return r}
    return p.escape_code_len
}

@(private)
static_rater_portion_init :: proc(p:^Static_Rater_Portion,vc:[]common.Bits128_And_Count,
    portion_bits,
    mode_block_count:int,allocator:runtime.Allocator) -> common.Error {
    if mode_block_count==0 {
        p.escape_code_len=f32(portion_bits)
        return .None
    }
    non_singleton_count:=0
    for non_singleton_count<len(vc) && vc[non_singleton_count].count>1 {non_singleton_count+=1}
    if non_singleton_count==0 {
        p.escape_code_len=f32(portion_bits)
        return .None
    }
    probability_denom:=mode_block_count+1+non_singleton_count
    log2_denom:=entropy.rrlog2neg_bk_32(u32(probability_denom))
    p.hash=make(map[Bits]f32,allocator)
    if reserve(&p.hash,non_singleton_count)!=nil {return .Out_Of_Memory}
    non_singleton_tot:=0
    for vci in 0..<non_singleton_count {
        c:=int(vc[vci].count)
        non_singleton_tot+=c+1
        rate:=entropy.rrlog2neg_bk_32(u32(c+1))-log2_denom
        rate+=f32(portion_bits)/f32(c)
        p.hash[vc[vci].val]=rate
    }
    escape_count:=probability_denom-non_singleton_tot
    escape_rate:=entropy.rrlog2neg_bk_32(u32(escape_count))-log2_denom
    escape_rate+=f32(portion_bits)
    p.escape_code_len=escape_rate
    return .None
}

@(private)
Static_Rater_One_Mode :: struct {
    mode:int,
    end_pb_rate,ind_rate,end_rate,ind_pb_rate:Static_Rater_Portion,
}

@(private)
Static_Rater :: struct {
    mode_rates:[8]f32,
    raters:[8]Static_Rater_One_Mode,
}

@(private)
static_rater_get_block_rate :: proc(r:^Static_Rater,bits:Bits) -> f32 {
    mode:=bits_get_mode(bits)&7
    ret:=r.mode_rates[mode]
    m:=&r.raters[mode]
    mask_ind:=BITRANGE_INDICES_MASK[mode]
    mask_ind_pb:=BITRANGE_INDICES_WITH_PBITS_MASK[mode]
    r_ep_i:=static_rater_portion_get_rate(&m.ind_rate,bits&mask_ind)
    r_ep_i+=static_rater_portion_get_rate(&m.end_pb_rate,bits&~mask_ind)
    r_e_pi:=static_rater_portion_get_rate(&m.ind_pb_rate,bits&mask_ind_pb)
    r_e_pi+=static_rater_portion_get_rate(&m.end_rate,bits&~mask_ind_pb)
    return ret+(r_ep_i<r_e_pi ? r_ep_i : r_e_pi)
}

@(private)
static_rater_destroy :: proc(r:^Static_Rater) {
    for &m in r.raters {
        delete(m.end_pb_rate.hash); delete(m.ind_rate.hash)
        delete(m.end_rate.hash); delete(m.ind_pb_rate.hash)
    }
}

@(private)
u32_less :: proc(a,b:u32) -> bool {return a<b}

@(private)
block_mode_ctz32 :: #force_inline proc "contextless" (b0:u8) -> int {
    return int(bits.count_trailing_zeros(u32(b0)|0x100))
}

@(private)
static_rater_init :: proc(r:^Static_Rater,blocks:[]u8,allocator:runtime.Allocator) -> common.Error {
    num_blocks:=len(blocks)/16
    mode_and_bi,err:=make([]u32,num_blocks,allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(mode_and_bi,allocator)
    mode_count:[9]int
    for bi in 0..<num_blocks {
        mode:=block_mode_ctz32(blocks[bi*16])
        mode_and_bi[bi]=(u32(mode)<<24)|u32(bi)
        mode_count[mode]+=1
    }
    common.stdsort(mode_and_bi,u32_less)
    max_mode_block_count:=0
    for m in 0..<8 {max_mode_block_count=max(max_mode_block_count,mode_count[m])}
    input_bits,err2:=make([]Bits,max_mode_block_count,allocator)
    if err2!=nil {return .Out_Of_Memory}
    defer delete(input_bits,allocator)
    counts:=make([dynamic]common.Bits128_And_Count,0,max_mode_block_count,allocator)
    defer delete(counts)
    cur:=0
    for mode in 0..<8 {
        mode_block_count:=mode_count[mode]
        r.mode_rates[mode]=entropy.rrlog2neg_bk_32(u32(mode_block_count+1))-
            entropy.rrlog2neg_bk_32(u32(num_blocks+8))
        r.raters[mode].mode=mode
        mask_ind:=BITRANGE_INDICES_MASK[mode]
        mask_ind_pb:=BITRANGE_INDICES_WITH_PBITS_MASK[mode]
        ind_bits:=BITS_INDICES[mode]
        pbit_bits:=BITS_PBITS[mode]
        end_bits:=128-ind_bits-pbit_bits-(mode+1)
        Rater_Desc :: struct {portion:^Static_Rater_Portion, mask:Bits, portion_bits:int}
        descs:=[4]Rater_Desc{
            {&r.raters[mode].ind_rate,mask_ind,ind_bits},
            {&r.raters[mode].ind_pb_rate,mask_ind_pb,ind_bits+pbit_bits},
            {&r.raters[mode].end_rate,~mask_ind_pb,end_bits},
            {&r.raters[mode].end_pb_rate,~mask_ind,end_bits+pbit_bits},
        }
        for d in descs {
            for i in 0..<mode_block_count {
                bi:=int(mode_and_bi[cur+i]&0xffffff)
                input_bits[i]=bits_load(block_bits_at(blocks,bi))&d.mask
            }
            if e:=common.sort_and_count_uniques_bits128(&counts,
                input_bits[:mode_block_count]); e!=.None {return e}
            common.sort_bits128_and_count_compare_count_highest_first(counts[:])
            if e:=static_rater_portion_init(d.portion,counts[:],d.portion_bits,mode_block_count,
                allocator); e!=.None {
                return e
            }
        }
        cur+=mode_block_count
    }
    return .None
}

@(private)
recompute_rates_static_model :: proc(blocks:[]u8,infos:[]Block_Info,lambda:f32,
    allocator:runtime.Allocator) -> common.Error {
    rater:Static_Rater
    defer static_rater_destroy(&rater)
    if e:=static_rater_init(&rater,blocks,allocator); e!=.None {return e}
    for bi in 0..<len(infos) {
        new_r:=static_rater_get_block_rate(&rater,bits_load(block_bits_at(blocks,bi)))
        infos[bi].j=infos[bi].d+lambda*new_r
    }
    return .None
}

@(private)
Final_State :: struct {
    cur_j:f32,
    cur_d:f32,
    must_beat_sad:u32,
    max_rate:f32,
    best_possible_d:f32,
}

@(private)
product_count :: #force_inline proc "contextless" (c1,c2:int) -> int {return (2*c1+1)*(2*c2+1)}

// rr_ftoi_round: half away from zero, then truncation.
@(private)
froundint :: #force_inline proc "contextless" (v:f32) -> i32 {
    return v>=0 ? i32(v+0.5) : i32(v-0.5)
}

FINAL_MATRIX_SAD_INCREASE_TOLERANCE :: f32(2.5)

@(private)
final_matrix :: proc(blocks:[]u8,activity:[]common.Float_Block,infos:[]Block_Info,lambda:f32,
    flags:Flags,
    config:^RD_Config,allocator:runtime.Allocator) -> common.Error {
    one_over_lambda:=1.0/lambda
    nb:=len(infos)
    combined:=make([dynamic]common.Bits128_And_Count,0,nb,allocator)
    defer delete(combined)
    {
        mode_and_bi,err:=make([]u32,nb,allocator)
        if err!=nil {return .Out_Of_Memory}
        defer delete(mode_and_bi,allocator)
        mode_count:[9]int
        for bi in 0..<nb {
            mode:=bits_get_mode(bits_load(block_bits_at(blocks,bi)))
            mode_and_bi[bi]=(u32(mode)<<24)|u32(bi)
            mode_count[mode]+=1
        }
        common.stdsort(mode_and_bi,u32_less)
        max_mode_block_count:=0
        for m in 0..<8 {max_mode_block_count=max(max_mode_block_count,mode_count[m])}
        v_indices,e1:=make([dynamic]Bits,0,max_mode_block_count,allocator)
        if e1!=nil {return .Out_Of_Memory}
        defer delete(v_indices)
        v_endpoints_pb,e2:=make([dynamic]Bits,0,max_mode_block_count,allocator)
        if e2!=nil {return .Out_Of_Memory}
        defer delete(v_endpoints_pb)
        vc_indices:=make([dynamic]common.Bits128_And_Count,0,max_mode_block_count,allocator)
        defer delete(vc_indices)
        vc_endpoints_pb:=make([dynamic]common.Bits128_And_Count,0,max_mode_block_count,allocator)
        defer delete(vc_endpoints_pb)
        index_or_zero :: proc(v:[]common.Bits128_And_Count,i:int) -> int {
            if len(v)==0 {return 0}
            return int(v[clamp(i,0,len(v)-1)].count)
        }
        i:=0
        for i<nb {
            mode:=int(mode_and_bi[i]>>24)
            clear(&v_indices)
            clear(&v_endpoints_pb)
            for i<nb && int(mode_and_bi[i]>>24)==mode {
                bi:=int(mode_and_bi[i]&0xffffff)
                bits:=bits_load(block_bits_at(blocks,bi))
                ind:=bits_extract_indices(bits,false)
                append(&v_indices,ind)
                append(&v_endpoints_pb,bits~ind)
                i+=1
            }
            if e:=common.sort_and_count_uniques_bits128(&vc_indices,
                v_indices[:]); e!=.None {return e}
            common.sort_bits128_and_count_compare_count_highest_first(vc_indices[:])
            if e:=common.sort_and_count_uniques_bits128(&vc_endpoints_pb,
                v_endpoints_pb[:]); e!=.None {return e}
            common.sort_bits128_and_count_compare_count_highest_first(vc_endpoints_pb[:])
            CUTOFF_PRODUCT_INDEX :: 55
            cutoff_product:=product_count(index_or_zero(vc_indices[:],CUTOFF_PRODUCT_INDEX),
                index_or_zero(vc_endpoints_pb[:],CUTOFF_PRODUCT_INDEX))
            outer: for a in vc_indices {
                if a.count<=1 {break}
                for b in vc_endpoints_pb {
                    if b.count<=1 {break}
                    product:=product_count(int(a.count),int(b.count))
                    if product<=cutoff_product {break}
                    if _,e:=append(&combined,common.Bits128_And_Count{a.val|b.val,
                        u32(product)}); e!=nil {
                        return .Out_Of_Memory
                    }
                }
            }
        }
    }
    if len(combined)==0 {return .None}
    common.sort_bits128_and_count_compare_count_highest_first(combined[:])
    lim:=config.fm_combined_size_limit_sqrt
    matrix_size:=min(len(combined),lim*lim)
    resize(&combined,matrix_size)
    matrix_decoded,e3:=make([]common.Color_Block,matrix_size,allocator)
    if e3!=nil {return .Out_Of_Memory}
    defer delete(matrix_decoded,allocator)
    matrix_rate,e4:=make([]f32,matrix_size,allocator)
    if e4!=nil {return .Out_Of_Memory}
    defer delete(matrix_rate,allocator)
    log2_denom:=entropy.rrlog2neg_bk_32(u32(product_count(nb,nb)))
    for mi in 0..<matrix_size {
        decode_bits4x4a(&matrix_decoded[mi],combined[mi].val,flags)
        pc:=combined[mi].count
        r:=entropy.rrlog2neg_bk_32(pc)-log2_denom
        r+=(f32(product_count(1,1))*128.0)/f32(pc)
        if r>=28.0 && mi>1000 {
            matrix_size=mi
            break
        }
        matrix_rate[mi]=r
    }
    final_st,e5:=make([]Final_State,nb,allocator)
    if e5!=nil {return .Out_Of_Memory}
    defer delete(final_st,allocator)
    for bi in 0..<nb {
        cur_j:=infos[bi].j
        cur_d:=infos[bi].d
        if cur_j==0 {continue}
        cur_colors:common.Color_Block
        decode_block4x4a(&cur_colors,block_bits_at(blocks,bi),flags)
        cur_sad:=common.color_block_sad_rgba(&infos[bi].colors,&cur_colors)
        best_possible_d:=cur_d<infos[bi].baseline_d ? cur_d : infos[bi].baseline_d
        max_rate:=(cur_j-best_possible_d)*one_over_lambda
        must_beat_sad:=u32(froundint(f32(cur_sad)+lambda*FINAL_MATRIX_SAD_INCREASE_TOLERANCE))
        must_beat_sad=min(must_beat_sad,16*4*255)
        final_st[bi]={cur_j,cur_d,must_beat_sad,max_rate,best_possible_d}
    }
    CHUNK :: common.FINAL_MATRIX_CHUNK_SIZE
    index:common.Final_Matrix_L1_Index
    chunk_sads:[CHUNK+1]i32
    for chunk_begin:=0; chunk_begin<matrix_size; chunk_begin+=CHUNK {
        chunk_end:=min(chunk_begin+CHUNK,matrix_size)
        chunk:=matrix_decoded[chunk_begin:chunk_end]
        common.final_matrix_l1_index_build(&index,chunk)
        for bi in 0..<nb {
            st:=&final_st[bi]
            if st.cur_j==0 {continue}
            initial_max_rate:=st.max_rate
            if matrix_rate[chunk_begin]>=initial_max_rate {continue}
            culled:=common.final_matrix_l1_index_lookup(&index,&infos[bi].colors,
                i32(st.must_beat_sad))
            if len(culled)<=0 {continue}
            if st.must_beat_sad==0 {continue}
            target_constraints:=infos[bi].constraints
            common.compute_chunk_sads_indirect(chunk_sads[:len(culled)],culled,chunk,
                &infos[bi].colors)
            chunk_sads[len(culled)]=-1
            colors:=infos[bi].colors
            i:=0
            for ;; i+=1 {
                i=common.find_next_below_i32(chunk_sads[:len(culled)+1],i,i32(st.must_beat_sad)+1)
                if i>=len(culled) {break}
                mi:=chunk_begin+int(culled[i])
                matrix_sad:=u32(chunk_sads[i])
                if matrix_rate[mi]>=st.max_rate {continue}
                if target_constraints!=0 {
                    subst:=constraints_from_pixels(&matrix_decoded[mi])
                    if !constraints_superset_of(subst,target_constraints) {continue}
                }
                st.must_beat_sad=matrix_sad
                matrix_d:=common.vqd(&colors,&matrix_decoded[mi],&activity[bi])
                matrix_j:=rd_j(matrix_d,matrix_rate[mi],lambda)
                if matrix_j<st.cur_j {
                    st.cur_j=matrix_j
                    st.cur_d=matrix_d
                    bits_store(block_bits_at(blocks,bi),combined[mi].val)
                    if matrix_sad==0 {break}
                    st.max_rate=(st.cur_j-st.best_possible_d)*one_over_lambda
                }
            }
            infos[bi].j=st.cur_j
            infos[bi].d=st.cur_d
        }
    }
    return .None
}
