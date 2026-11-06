package bc1

import "base:runtime"
import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Rate-distortion optimization of BC1 (and the color half of BC3): endpoint and index
// palettes (vector quantization) found by greedy merging under J = D + lambda*R, with D the
// activity weighted squared error and R an estimate of what LZ pays for each block.

@(private)
VQ_Config :: struct {
    endpoints_vq_palette_search_limit:int,
    max_num_added_entries_to_try_endpoints:int,
    index_vq_palette_search_limit:int,
    max_num_added_entries_to_try_indices:int,
    final_pass_matrix_dim_initial:int,
    final_pass_matrix_dim_search:int,
    early_out_index_diff_times_lambda:int,
    early_out_index_diff_plus_constant:int,
    early_out_color_endpoint_distance:int,
    early_out_endpoints_ssd_max_increase_scaled_by_lambda:int,
    do_index_diff_early_out:bool,
    num_vq_iterations:int,
}

@(private,rodata)
VQ_CONFIGS := [5]VQ_Config{
    {256,64,64,32,60,30,9,55,20,3,true,1},
    {500,120,120,50,140,70,9,55,20,3,true,1},
    {800,200,200,100,160,80,9,55,20,3,true,1},
    {1024,256,256,128,200,100,9,55,20,3,true,2},
    {1024,256,256,128,200,100,9,55,20,3,true,2},
}

@(private)
VQ_Block :: struct {
    colors:Color_Block,
    color_bbox:[2]Color,
    has_any_transparency:bool,
    has_any_black3c:bool,
    degenerate_all_black_or_transparent:bool,
    mask_1bt:u32,
    activity:^common.Float_Block,
    baseline:BC1_Block,
    baseline_vqd:f32,
    cur:BC1_Block,
    second_best:BC1_Block,
    cur_vqd:f32,
    cur_J:f32,
    vq_entry_index:i32,
    vq_entry_link:i32,
}

@(private)
Codelen_Help :: struct {
    codelen_2count:f32,
    codelen_escape:f32,
    codelen_denom:i32,
}

@(private)
DC :: common.Dword_And_Count

@(private)
ERROR_BIG :: common.DXTC_ERROR_BIG

@(private)
vqd_block :: #force_inline proc "contextless" (colors:^Color_Block,b:BC1_Block,
    activity:^common.Float_Block,mode:Palette_Mode) -> f32 {
    palette:[4]Color
    common.bc1_palette(b.endpoints,&palette,mode)
    return common.vqd_bc1(colors,&palette,b.indices,activity)
}

@(private)
vq_J :: #force_inline proc "contextless" (D,R,lambda:f32) -> f32 {return D+lambda*R}

@(private)
vq_codelen_lz :: proc "contextless" (lzi:int) -> f32 {
    offset_bits:=2*entropy.rrlog2_bk(u32(lzi+2))+1
    return 10+offset_bits
}

@(private)
vq_codelen_palette_count :: proc "contextless" (count:u32,help:^Codelen_Help) -> f32 {
    bits_log2one:=entropy.log2tabled_bk_32(count+1)-help.codelen_denom
    bits:=f32(bits_log2one)*(1.0/f32(entropy.LOG2TABLE_ONE))
    bits+=32.0/f32(count)
    return bits
}

@(private)
hacky_clamp_counts :: proc "contextless" (counting:[]DC,nblocks:int) {
    if len(counting)<2 {return}
    max_count:=u32((uint(nblocks)*50+999)/1000)
    if max_count<5 {return}
    for i in 0..<len(counting) {
        if counting[i].count<=max_count {break}
        counting[i].count=max_count
    }
}

@(private)
setup_palette_and_codelen_help :: proc(help:^Codelen_Help,counting:^[dynamic]DC,nblocks:int,
    is_indices,reduce:bool) {
    common.sort_dword_and_count_compare_count_highest_first(counting[:])
    all_unique:=len(counting)
    for len(counting)>0 && counting[len(counting)-1].count==1 {pop(counting)}
    if len(counting)>2 {
        if is_indices {hacky_clamp_counts(counting[:],nblocks)}
        if reduce {
            max_palette_size:=nblocks/8
            max_palette_size=min(max_palette_size,all_unique/2)
            if len(counting)>max_palette_size {resize(counting,max(max_palette_size,0))}
        }
    }
    help.codelen_denom=entropy.log2tabled_bk_32(u32(nblocks))
    help.codelen_2count=vq_codelen_palette_count(2,help)
    help.codelen_escape=vq_codelen_palette_count(1,help)
}

@(private)
indices_are_flat :: #force_inline proc "contextless" (indices:u32) -> bool {
    return indices==((indices<<2)|(indices>>30))
}

@(private)
update_mtf_window :: proc "contextless" (new_val:i32,window:[]i32,size:^int,max_size:int) {
    found:=-1
    for i in 0..<size^ {
        if window[i]==new_val {found=i; break}
    }
    if found<0 {
        if size^<max_size {size^+=1}
        found=size^-1
    }
    if found<0 {return}
    for k:=found;k>0;k-=1 {window[k]=window[k-1]}
    window[0]=new_val
}

@(private)
Block_And_Codelen :: struct {
    block:BC1_Block,
    codelen:f32,
}

@(private)
block_and_codelen_less :: proc(a,b:Block_And_Codelen) -> bool {return a.codelen<b.codelen}

@(private)
Final_State :: struct {
    cur_J:f32,
    min_vqd:f32,
    maximum_codelen:f32,
    must_beat_sad:u32,
}

@(private)
final_matrix :: proc(blocks:[]VQ_Block,endpoint_counting,index_counting:^[dynamic]DC,lambda:f32,
    lambdai:int,mode:Palette_Mode,config:^VQ_Config,
    allocator:runtime.Allocator) -> common.Error {
    nblocks:=len(blocks)
    ep_help,ind_help:Codelen_Help
    setup_palette_and_codelen_help(&ep_help,endpoint_counting,nblocks,false,false)
    setup_palette_and_codelen_help(&ind_help,index_counting,nblocks,true,false)
    num_endpoints:=min(len(endpoint_counting),config.final_pass_matrix_dim_initial)
    num_indices:=min(len(index_counting),config.final_pass_matrix_dim_initial)
    codelen_endpoints:[256]f32
    codelen_indices:[256]f32
    for i in 0..<num_endpoints {
        codelen_endpoints[i]=vq_codelen_palette_count(endpoint_counting[i].count,&ep_help)
    }
    for i in 0..<num_indices {codelen_indices[i]=vq_codelen_palette_count(index_counting[i].count,
        &ind_help)}
    pairs,e1:=make([]Block_And_Codelen,num_indices*num_endpoints,allocator)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(pairs,allocator)
    for epi in 0..<num_endpoints {
        for indi in 0..<num_indices {
            i:=epi+indi*num_endpoints
            pairs[i]={{endpoint_counting[epi].dw,index_counting[indi].dw},
                codelen_endpoints[epi]+codelen_indices[indi]}
        }
    }
    common.stdsort(pairs,block_and_codelen_less)
    num_pairs:=min(config.final_pass_matrix_dim_search*config.final_pass_matrix_dim_search,
        len(pairs))
    pair_colors,e2:=make([]Color_Block,num_pairs,allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(pair_colors,allocator)
    for i in 0..<num_pairs {common.bc1_decompress(&pair_colors[i],pairs[i].block,mode)}
    final_st,e3:=make([]Final_State,nblocks,allocator)
    if e3!=nil {return .Out_Of_Memory}
    defer delete(final_st,allocator)
    for bi in 0..<nblocks {
        b:=&blocks[bi]
        cur_colors:Color_Block
        common.bc1_decompress(&cur_colors,b.cur,mode)
        cur_sad:=common.color_block_sad_rgba(&b.colors,&cur_colors)
        cur_J:=b.cur_J
        cur_vqd:=common.vqd(&b.colors,&cur_colors,b.activity)
        cur_J-=b.cur_vqd
        cur_J+=cur_vqd
        min_vqd:=min(cur_vqd,b.baseline_vqd)
        final_st[bi]={cur_J,min_vqd,(cur_J-min_vqd)/lambda,cur_sad+u32(lambdai)*1}
    }
    CHUNK :: common.FINAL_MATRIX_CHUNK_SIZE
    index:=new(common.Final_Matrix_L1_Index,allocator)
    if index==nil {return .Out_Of_Memory}
    defer free(index,allocator)
    chunk_sads:[CHUNK+8]i32
    for i in 0..<len(chunk_sads) {chunk_sads[i]=-1}
    for chunk_begin:=0;chunk_begin<num_pairs;chunk_begin+=CHUNK {
        chunk_end:=min(chunk_begin+CHUNK,num_pairs)
        common.final_matrix_l1_index_build(index,pair_colors[chunk_begin:chunk_end])
        for bi in 0..<nblocks {
            b:=&blocks[bi]
            st:=&final_st[bi]
            if pairs[chunk_begin].codelen>=st.maximum_codelen {continue}
            culled:=common.final_matrix_l1_index_lookup(index,&b.colors,i32(st.must_beat_sad))
            if len(culled)<=0 {continue}
            common.compute_chunk_sads_indirect(chunk_sads[:],culled,
                pair_colors[chunk_begin:chunk_end],&b.colors)
            chunk_sads[len(culled)]=-1
            for i:=0;;i+=1 {
                i=common.find_next_below_i32(chunk_sads[:],i,i32(st.must_beat_sad))
                if i>=len(culled) {break}
                pair_i:=chunk_begin+int(culled[i])
                this_sad:=u32(chunk_sads[i])
                if mode==.Alpha {
                    pb:=pairs[pair_i].block
                    if !common.bc1_one_bit_transparent_mask_same(b.mask_1bt,pb.endpoints,
                        pb.indices) {continue}
                }
                if pairs[pair_i].codelen>=st.maximum_codelen {continue}
                st.must_beat_sad=this_sad
                vqd:=common.vqd(&b.colors,&pair_colors[pair_i],b.activity)
                J:=vq_J(vqd,pairs[pair_i].codelen,lambda)
                if J<st.cur_J {
                    st.cur_J=J
                    b.cur=pairs[pair_i].block
                    st.maximum_codelen=(st.cur_J-st.min_vqd)/lambda
                }
            }
        }
    }
    return .None
}

@(private)
override_vqds_on_transparency_mismatch :: proc "contextless" (vqds:[]f32,
    vqindices:[]common.BC1_VQ_Entry,inds:[]i32,first_endpoints,second_endpoints,mask_1bt:u32) {
    first_3c_mask:u32=common.bc1_is_4color(first_endpoints,.Alpha)?0:0x55555555
    second_3c_mask:u32=common.bc1_is_4color(second_endpoints,.Alpha)?0:0x55555555
    for i in 0..<len(inds) {
        ind:=vqindices[inds[i]].dw
        idx3:=ind&(ind>>1)
        if idx3&first_3c_mask!=mask_1bt {vqds[i*2]=f32(ERROR_BIG)}
        if idx3&second_3c_mask!=mask_1bt {vqds[i*2+1]=f32(ERROR_BIG)}
    }
}

@(private)
optimize_endpoints_multi_block :: proc "contextless" (out:^u32,fourc:bool,blocks:[]VQ_Block,
    dcv:[]DC,mode:Palette_Mode) -> bool {
    s:Endpoint_LLS_Solver
    lls_solver_init(&s,fourc)
    any_index3_mask:u32
    for d in dcv {
        b:=&blocks[d.dw]
        any_index3_mask|=common.bc1_one_bit_transparent_mask_from_indices(true,b.cur.indices)
        lls_solver_accumulate(&s,&b.colors,b.cur.indices)
    }
    qa,qb,ok:=lls_solver_solve(&s)
    if !ok {return false}
    if qa<qb {qa,qb=qb,qa}
    if !fourc {qa,qb=qb,qa}
    if mode==.Alpha {
        new_is_fourc:=qa>qb
        if any_index3_mask!=0 && new_is_fourc!=fourc {return false}
    }
    out^=common.bc1_make_endpoints(qa,qb)
    return true
}

@(private)
optimize_endpoints_for_assigned_blocks :: proc(blocks:[]VQ_Block,dcv:[]DC,mode:Palette_Mode) {
    nblocks:=len(blocks)
    for b in 0..<nblocks {dcv[b]={u32(b),blocks[b].cur.endpoints}}
    common.sort_dword_and_count_compare_count_highest_first(dcv[:nblocks])
    start:=0
    for start<nblocks {
        bi_start:=int(dcv[start].dw)
        endpoints:=blocks[bi_start].cur.endpoints
        end:=start+1
        for end<nblocks && blocks[dcv[end].dw].cur.endpoints==endpoints {end+=1}
        if end-start==1 {
            b:=&blocks[bi_start]
            if b.cur!=b.baseline {
                err:=common.bc1_compute_ssd_rgba(&b.colors,b.cur,mode)
                optimize_endpoints_from_indices_inherit_no_reindex(&b.cur,&err,&b.colors,mode)
            }
        } else {
            oldep:=endpoints
            fourc:=common.bc1_is_4color(oldep,mode)
            newep:u32
            if optimize_endpoints_multi_block(&newep,fourc,blocks,dcv[start:end],
                mode) && newep!=oldep {
                oldpal,newpal:[4]Color
                common.bc1_palette(oldep,&oldpal,mode)
                common.bc1_palette(newep,&newpal,mode)
                before,after:u64
                for d in dcv[start:end] {
                    b:=&blocks[d.dw]
                    before+=u64(common.bc1_palette_ssd_rgba(&b.colors,&oldpal,b.cur.indices))
                    after+=u64(common.bc1_palette_ssd_rgba(&b.colors,&newpal,b.cur.indices))
                }
                if after<before {
                    for d in dcv[start:end] {blocks[d.dw].cur.endpoints=newep}
                }
            }
        }
        start=end
    }
}

@(private)
any_index_d_add :: proc "contextless" (aid:^common.Any_Index_D,colors:^Color_Block,
    palette:^[4]Color) {
    for c in 0..<16 {
        for p in 0..<4 {aid.ssd[p][c]+=common.delta_sqr_rgba(colors[c],palette[p])}
    }
}

@(private)
any_index_d_add_with_1bt :: proc "contextless" (aid:^common.Any_Index_D,colors:^Color_Block,
    palette:^[4]Color) -> u64 {
    illegal:u64
    for c in 0..<16 {
        cur:=colors[c]
        for p in 0..<4 {
            err:=common.delta_sqr_rgb(cur,palette[p])
            if cur[A]!=palette[p][A] {err+=4*255*255}
            aid.ssd[p][c]+=err
            if err>3*255*255 {illegal|=u64(1)<<(u64(p)*16+u64(c))}
        }
    }
    return illegal
}

@(private)
any_index_d_find_indices :: proc "contextless" (aid:^common.Any_Index_D,d:^u32) -> u32 {
    indices,ssd:u32
    for c in 0..<16 {
        md:=min((aid.ssd[0][c]<<2)+0,(aid.ssd[1][c]<<2)+1,(aid.ssd[2][c]<<2)+2,(aid.ssd[3][c]<<2)+3)
        ssd+=md>>2
        indices=(indices>>2)|(md<<30)
    }
    d^=ssd
    return indices
}

@(private)
any_index_d_best_index_pair_d :: proc "contextless" (a,b:^common.Any_Index_D) -> u32 {
    ssd:u32
    for c in 0..<16 {
        ssd+=min(a.ssd[0][c]+b.ssd[0][c],a.ssd[1][c]+b.ssd[1][c],a.ssd[2][c]+b.ssd[2][c],
            a.ssd[3][c]+b.ssd[3][c])
    }
    return ssd
}

@(private)
any_index_d_add_then_find_indices :: proc "contextless" (to,fm:^common.Any_Index_D,d:^u32) -> u32 {
    for p in 0..<4 {for c in 0..<16 {to.ssd[p][c]+=fm.ssd[p][c]}}
    return any_index_d_find_indices(to,d)
}

@(private)
find_indices_multi_block :: proc "contextless" (new_indices:^u32,old_indices:u32,blocks:[]VQ_Block,
    dcv:[]DC,mode:Palette_Mode) -> bool {
    old_err:u32
    illegal:u64
    aid:common.Any_Index_D
    for d in dcv {
        b:=&blocks[d.dw]
        palette:[4]Color
        common.bc1_palette(b.cur.endpoints,&palette,mode)
        old_err+=common.bc1_palette_ssd_rgba(&b.colors,&palette,old_indices)
        if mode!=.Alpha {
            any_index_d_add(&aid,&b.colors,&palette)
        } else {
            illegal|=any_index_d_add_with_1bt(&aid,&b.colors,&palette)
        }
    }
    if illegal!=0 {
        for p in 0..<4 {
            for c in 0..<16 {
                aid.ssd[p][c]=min(aid.ssd[p][c],0x3ffffffe)
                if illegal&(u64(1)<<(u64(p)*16+u64(c)))!=0 {aid.ssd[p][c]=0x3fffffff}
            }
        }
    }
    new_err:u32
    new_indices^=any_index_d_find_indices(&aid,&new_err)
    return new_err<old_err
}

@(private)
optimize_indices_for_assigned_blocks :: proc(blocks:[]VQ_Block,dcv:[]DC,mode:Palette_Mode) {
    nblocks:=len(blocks)
    for b in 0..<nblocks {dcv[b]={u32(b),blocks[b].cur.indices}}
    common.sort_dword_and_count_compare_count_highest_first(dcv[:nblocks])
    start:=0
    for start<nblocks {
        bi_start:=int(dcv[start].dw)
        old_indices:=blocks[bi_start].cur.indices
        end:=start+1
        for end<nblocks && blocks[dcv[end].dw].cur.indices==old_indices {end+=1}
        count:=end-start
        if count==1 {
            b:=&blocks[bi_start]
            if b.cur!=b.baseline {
                old_err:=common.bc1_compute_ssd_rgba(&b.colors,b.cur,mode)
                new_err:u32=INIT_ERROR
                new_indices:=common.bc1_find_indices(&b.colors,b.cur.endpoints,mode,&new_err)
                if new_err<old_err {b.cur.indices=new_indices}
            }
        } else {
            new_indices:=old_indices
            if count<common.ANY_INDEX_D_MAX_BLOCKS_FOR_S32 && find_indices_multi_block(&new_indices,
                old_indices,blocks,dcv[start:end],mode) {
                for d in dcv[start:end] {blocks[d.dw].cur.indices=new_indices}
            }
        }
        start=end
    }
}

@(private)
COLOR3_INDEX_MAP :: 5

// The 16 indices as positions along the line between the endpoints.
@(private)
unpack_indices_16x8 :: proc "contextless" (dest:^[16]u8,indices:u32,is3c:bool) {
    MAP_4C :: [4]u8{0,3,1,2}
    MAP_3C :: [4]u8{0,2,1,COLOR3_INDEX_MAP}
    m4:=MAP_4C
    m3:=MAP_3C
    for i in 0..<16 {
        k:=(indices>>(u32(i)*2))&3
        dest[i]=is3c?m3[k]:m4[k]
    }
}

@(private)
Index_VQ_Entry :: struct {
    unpacked_16x8:[16]u8,
    indices:u32,
    is3c:bool,
    distortion_sum:u32,
    count:u32,
    count_log2_count:u32,
    block_link:i32,
    merged_onto:i32,
    best_distortion:i32,
    sad_bound_good_until:i32,
    sad_bound:i32,
}

@(private)
Index_Heap_Entry :: struct {
    fm,to:i32,
    dj:f32,
    pair_count_save:i32,
}

@(private)
heap_less :: proc(a,b:Index_Heap_Entry) -> bool {return a.dj<b.dj}
@(private)
heap_greater :: proc(a,b:Index_Heap_Entry) -> bool {return b.dj<a.dj}

@(private)
index_merge_dj :: proc "contextless" (from,to:^Index_VQ_Entry,delta_D:i32,lambda:f32) -> f32 {
    D:=f32(delta_D)
    merged_count:=from.count+to.count
    log2one_merged:=merged_count*u32(entropy.log2tabled_bk_32(merged_count))
    log2one_delta:=from.count_log2_count+to.count_log2_count-log2one_merged
    rate_delta:=f32(log2one_delta)*(1.0/f32(entropy.LOG2TABLE_ONE))
    rate_delta+=30.0
    return vq_J(-D,rate_delta,lambda)
}

@(private)
block_link_to_any_index_d :: proc "contextless" (entry:^Index_VQ_Entry,blocks:[]VQ_Block,
    aid:^common.Any_Index_D,mode:Palette_Mode) {
    aid^={}
    link:=entry.block_link
    guard:=len(blocks)
    for link>=0 && guard>0 {
        b:=&blocks[link]
        palette:[4]Color
        common.bc1_palette(b.cur.endpoints,&palette,mode)
        any_index_d_add(aid,&b.colors,&palette)
        link=b.vq_entry_link
        guard-=1
    }
}

@(private)
compute_index_sad_bound :: proc "contextless" (fm:^common.Any_Index_D,ssd_limit:i32,is3c:bool,
    indices:^[16]u8,out_ssd_limit:^i32) -> i32 {
    ind_limit:=is3c?COLOR3_INDEX_MAP:3
    scratch:[24]i32
    for i in 0..<8 {scratch[i]=0x7fffffff}
    for i in 8+ind_limit+1..<24 {scratch[i]=0x7fffffff}
    deltas:[16][8]i32
    for i in 0..<16 {for j in 0..<8 {deltas[i][j]=0x7fffffff}}
    total_ssd:i32
    for p in 0..<16 {
        ind:=int(indices[p])
        n:=max(ind,ind_limit-ind)
        if is3c {
            scratch[8+0]=i32(fm.ssd[0][p])
            scratch[8+1]=i32(fm.ssd[2][p])
            scratch[8+2]=i32(fm.ssd[1][p])
            for i in 3..=COLOR3_INDEX_MAP {scratch[8+i]=i32(fm.ssd[3][p])}
        } else {
            scratch[8+0]=i32(fm.ssd[0][p])
            scratch[8+1]=i32(fm.ssd[2][p])
            scratch[8+2]=i32(fm.ssd[3][p])
            scratch[8+3]=i32(fm.ssd[1][p])
        }
        prev:=scratch[8+ind]
        total_ssd+=prev
        for i in 1..=n {
            cur:=min(scratch[8+ind-i],scratch[8+ind+i])
            delta:=max(cur-prev,0)
            deltas[p][i-1]=delta
            prev+=delta
        }
    }
    return common.compute_sad_bound_for_ssd_threshold(&deltas,total_ssd,ssd_limit,out_ssd_limit)
}

// What the entry struct of the original weighed; it sets how many targets one pass scans.
@(private)
ENTRY_CHUNK_SIZE :: (16*1024)/56

@(private)
indices_vq_reduce :: proc(out:^[dynamic]DC,indices_in:[]DC,vqd_lambda:f32,blocks:[]VQ_Block,
    mode:Palette_Mode,config:^VQ_Config,
    allocator:runtime.Allocator) -> common.Error {
    lambda:=vqd_lambda*(f32(1.2549)/2.0)
    nblocks:=len(blocks)
    clear(out)
    if len(indices_in)<=4 {
        if _,e:=append(out,..indices_in);e!=nil {return .Out_Of_Memory}
        return .None
    }
    entries,e1:=make([dynamic]Index_VQ_Entry,0,len(indices_in),allocator)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(entries)
    raw,e2:=make([]u32,nblocks,allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(raw,allocator)
    sorted,e3:=make([dynamic]DC,0,nblocks,allocator)
    if e3!=nil {return .Out_Of_Memory}
    defer delete(sorted)
    num_per_mode:[2]int
    for loop_is3c in 0..<2 {
        nraw:=0
        for b in 0..<nblocks {
            is3c:=!common.bc1_is_4color(blocks[b].cur.endpoints,mode)
            if int(is3c)!=loop_is3c {continue}
            raw[nraw]=blocks[b].cur.indices
            nraw+=1
        }
        if nraw==0 {continue}
        if e:=common.sort_and_count_uniques(&sorted,raw[:nraw]);e!=.None {return e}
        common.sort_dword_and_count_compare_count_highest_first(sorted[:])
        num_per_mode[loop_is3c]=len(sorted)
        base:=len(entries)
        if resize(&entries,base+len(sorted))!=nil {return .Out_Of_Memory}
        for i in 0..<len(sorted) {
            en:=&entries[base+i]
            en^={}
            en.is3c=loop_is3c==1
            en.indices=sorted[i].dw
            en.count=sorted[i].count
            en.count_log2_count=en.count*u32(entropy.log2tabled_bk_32(en.count))
            unpack_indices_16x8(&en.unpacked_16x8,en.indices,en.is3c)
            en.merged_onto=-1
            en.block_link=-1
        }
        for i in 0..<len(sorted) {sorted[i].count=u32(base+i)}
        common.stdsort(sorted[:],common.dword_and_count_compare_dword)
        for b in 0..<nblocks {
            is3c:=!common.bc1_is_4color(blocks[b].cur.endpoints,mode)
            if int(is3c)!=loop_is3c {continue}
            lookup:=DC{blocks[b].cur.indices,~u32(0)}
            pos:=common.lower_bound(sorted[:],lookup,common.dword_and_count_compare_dword)
            if pos>=len(sorted) || sorted[pos].dw!=lookup.dw {continue}
            ei:=sorted[pos].count
            blocks[b].vq_entry_link=entries[ei].block_link
            entries[ei].block_link=i32(b)
        }
    }
    num_entries:=len(entries)
    max_distortion_increase:=i32(vq_J(0,32.0,lambda)+0.5)
    heap_limit:=max(num_entries,64)*8
    heap,e4:=make([dynamic]Index_Heap_Entry,0,heap_limit+1,allocator)
    if e4!=nil {return .Out_Of_Memory}
    defer delete(heap)
    aids,e5:=make([]common.Any_Index_D,num_entries,allocator)
    if e5!=nil {return .Out_Of_Memory}
    defer delete(aids,allocator)
    for fm in 0..<num_entries {
        block_link_to_any_index_d(&entries[fm],blocks,&aids[fm],mode)
        entries[fm].distortion_sum=common.any_index_d_lookup(&aids[fm],entries[fm].indices)
        entries[fm].best_distortion=i32(entries[fm].distortion_sum)+max_distortion_increase
        entries[fm].sad_bound_good_until=0x7fffffff
        entries[fm].sad_bound=0
    }
    Chunk :: struct {
        filtered_elems:[ENTRY_CHUNK_SIZE]i32,
        filtered_entry_inds:[ENTRY_CHUNK_SIZE]u32,
        candidate_distortions:[ENTRY_CHUNK_SIZE+8]i32,
        masks_1bt:[ENTRY_CHUNK_SIZE]u32,
        packed_inds:[ENTRY_CHUNK_SIZE]u32,
        inds:[ENTRY_CHUNK_SIZE*16]u8,
    }
    ch:=new(Chunk,allocator)
    if ch==nil {return .Out_Of_Memory}
    defer free(ch,allocator)
    for i in 0..<len(ch.candidate_distortions) {ch.candidate_distortions[i]=-1}
    for mode_is3c in 0..=1 {
        mode_begin:=mode_is3c==1?num_per_mode[0]:0
        mode_end:=mode_is3c==1?num_entries:num_per_mode[0]
        for to_begin:=mode_begin;to_begin<mode_end;to_begin+=ENTRY_CHUNK_SIZE {
            to_end:=min(to_begin+ENTRY_CHUNK_SIZE,mode_end)
            to_len:=to_end-to_begin
            for i in 0..<to_len {
                copy(ch.inds[i*16:][:16],entries[to_begin+i].unpacked_16x8[:])
                ch.packed_inds[i]=entries[to_begin+i].indices
                e:=&entries[to_begin+i]
                ch.masks_1bt[i]=0
                if mode==.Alpha {
                    m:=common.bc1_one_bit_transparent_mask_from_indices(e.is3c,e.indices)
                    ch.masks_1bt[i]=m
                }
            }
            for fm in mode_begin..<mode_end {
                efm:=&entries[fm]
                if indices_are_flat(efm.indices) {continue}
                if efm.count>=common.ANY_INDEX_D_MAX_BLOCKS_FOR_S32 {continue}
                aid:=&aids[fm]
                fm_base:=efm.distortion_sum
                best_distortion:=efm.best_distortion
                fm_mask:u32
                if mode==.Alpha {fm_mask=common.bc1_one_bit_transparent_mask_from_indices(efm.is3c,
                    efm.indices)}
                limit:i32
                if !config.do_index_diff_early_out {
                    limit=256*16
                } else {
                    if best_distortion<efm.sad_bound_good_until {
                        efm.sad_bound=compute_index_sad_bound(aid,best_distortion,mode_is3c==1,
                            &efm.unpacked_16x8,&efm.sad_bound_good_until)
                    }
                    limit=efm.sad_bound
                }
                if limit<=0 {continue}
                filtered:=common.filter_by_index_sad_with_inds(ch.filtered_elems[:],
                    ch.filtered_entry_inds[:],to_len,ch.inds[:],ch.packed_inds[:],
                    &efm.unpacked_16x8,limit+1)
                best_possible:=common.any_index_d_batch_lookup(ch.candidate_distortions[:],aid,
                    ch.filtered_entry_inds[:filtered])
                if best_possible>best_distortion {continue}
                ch.candidate_distortions[filtered]=-1
                for i:=0;;i+=1 {
                    i=common.find_next_below_i32(ch.candidate_distortions[:],i,best_distortion+1)
                    if i>=filtered {break}
                    distortion:=ch.candidate_distortions[i]
                    if distortion<0 {continue}
                    rel:=int(ch.filtered_elems[i])
                    to:=to_begin+rel
                    if fm_mask!=ch.masks_1bt[rel] {continue}
                    if efm.indices==entries[to].indices {continue}
                    if indices_are_flat(entries[to].indices) {continue}
                    best_distortion=distortion
                    before_pair_D:=fm_base+entries[to].distortion_sum
                    after_D:=any_index_d_best_index_pair_d(aid,&aids[to])
                    delta_D:=i32(after_D-before_pair_D)
                    dj:=index_merge_dj(efm,&entries[to],delta_D,lambda)
                    if dj>0 {
                        if len(heap)>=heap_limit {
                            common.stdsort(heap[:],heap_greater)
                            resize(&heap,heap_limit/2)
                        }
                        if _,e:=append(&heap,Index_Heap_Entry{i32(fm),i32(to),dj,
                            i32(efm.count+entries[to].count)});e!=nil {return .Out_Of_Memory}
                    }
                }
                efm.best_distortion=best_distortion
            }
        }
    }
    common.heap_make(heap[:],heap_less)
    for len(heap)>0 {
        he:=heap[0]
        common.heap_popped(heap[:],heap_less)
        pop(&heap)
        fm:=int(he.fm)
        if entries[fm].merged_onto>=0 {continue}
        dirty:=false
        to:=int(he.to)
        if entries[to].merged_onto>=0 {
            for {
                to=int(entries[to].merged_onto)
                if entries[to].merged_onto<0 {break}
            }
            if to==fm {continue}
            dirty=true
        }
        dirty=dirty || he.pair_count_save!=i32(entries[fm].count+entries[to].count)
        if dirty {
            base:=entries[fm].distortion_sum+entries[to].distortion_sum
            after_D:=any_index_d_best_index_pair_d(&aids[fm],&aids[to])
            delta_D:=i32(after_D-base)
            dj:=index_merge_dj(&entries[fm],&entries[to],delta_D,lambda)
            if dj>0 {
                if _,e:=append(&heap,Index_Heap_Entry{i32(fm),i32(to),dj,
                    i32(entries[fm].count+entries[to].count)});e!=nil {return .Out_Of_Memory}
                common.heap_push(heap[:],heap_less)
            }
            continue
        }
        entries[fm].merged_onto=i32(to)
        entries[to].count+=entries[fm].count
        to_count:=entries[to].count
        entries[to].count_log2_count=to_count*u32(entropy.log2tabled_bk_32(to_count))
        link:=entries[fm].block_link
        guard:=nblocks
        for link>=0 && guard>0 {
            if blocks[link].vq_entry_link<0 {
                blocks[link].vq_entry_link=entries[to].block_link
                entries[to].block_link=entries[fm].block_link
                break
            }
            link=blocks[link].vq_entry_link
            guard-=1
        }
        new_D:u32
        new_indices:=any_index_d_add_then_find_indices(&aids[to],&aids[fm],&new_D)
        entries[to].distortion_sum=new_D
        entries[to].indices=new_indices
    }
    if reserve(out,num_entries)!=nil {return .Out_Of_Memory}
    for &en in entries {
        if en.merged_onto>=0 {continue}
        link:=en.block_link
        guard:=nblocks
        for link>=0 && guard>0 {
            blocks[link].cur.indices=en.indices
            link=blocks[link].vq_entry_link
            guard-=1
        }
        append(out,DC{en.indices,en.count})
    }
    common.sort_dword_and_count_compare_dword(out[:])
    toi:=1
    n:=len(out)
    for fmi in 1..<n {
        if out[fmi].dw==out[toi-1].dw {
            out[toi-1].count+=out[fmi].count
        } else {
            out[toi]=out[fmi]
            toi+=1
        }
    }
    if n>0 {resize(out,toi)}
    return .None
}

@(private)
codelen_or_escape :: #force_inline proc(dw:u32,m:^map[u32]f32,help:^Codelen_Help) -> f32 {
    if v,ok:=m^[dw];ok {return v}
    return help.codelen_escape
}

// Rate-distortion encode of one slice. from is RGBA; baseline holds the non-RDO encode of
// the same blocks (same stride and offset as to); block i is at [i*stride+offset:]. A stride
// other than 8 is the color half of BC2/BC3: four color blocks.
rd :: proc(to:[]u8,stride,offset:int,from:[]Color_Block,baseline:[]u8,activity:[]common.Float_Block,
    lambda:int,options:common.Options,rd_options:common.RD_Options,
    allocator:=context.allocator) -> common.Error {
    nblocks:=len(from)
    if stride<8 || offset<0 || offset+8>stride || lambda<0 || nblocks>65535 {return .Invalid}
    if nblocks==0 {return .None}
    need:=(nblocks-1)*stride+offset+8
    if len(to)<need || len(baseline)<need || len(activity)<nblocks {return .Invalid}
    config:=VQ_CONFIGS[min(int(rd_options.effort),len(VQ_CONFIGS)-1)]
    lambda_scale:=f32(1.7)
    lambda_scale*=common.GLOBAL_LAMBDA_SCALE
    lambdaf:=f32(lambda)*lambda_scale
    mode:Palette_Mode=stride==8?.No_Alpha:.Four_Color
    if .BC1_One_Bit_Alpha in options && stride==8 {mode=.Alpha}
    first:=(^u64)(raw_data(baseline[offset:]))^
    all_same:=true
    for bi in 1..<nblocks {
        if (^u64)(raw_data(baseline[bi*stride+offset:]))^!=first {all_same=false; break}
    }
    if all_same {
        for bi in 0..<nblocks {copy(to[bi*stride+offset:][:8],baseline[bi*stride+offset:][:8])}
        return .None
    }
    return rd_core(to,stride,offset,from,baseline,activity,lambda,lambdaf,mode,&config,allocator)
}

@(private)
rd_core :: proc(to:[]u8,stride,offset:int,from:[]Color_Block,baseline:[]u8,
    activity:[]common.Float_Block,lambdai:int,lambdaf:f32,mode:Palette_Mode,config:^VQ_Config,
    allocator:runtime.Allocator) -> common.Error {
    context.allocator=allocator
    nblocks:=len(from)
    blocks,e0:=make([]VQ_Block,nblocks)
    if e0!=nil {return .Out_Of_Memory}
    defer delete(blocks)
    endpoint_counting,e1:=make([dynamic]DC,0,nblocks)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(endpoint_counting)
    index_counting,e2:=make([dynamic]DC,0,nblocks)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(index_counting)
    reduced,e3:=make([dynamic]DC,0,nblocks)
    if e3!=nil {return .Out_Of_Memory}
    defer delete(reduced)
    dcv,e4:=make([]DC,nblocks)
    if e4!=nil {return .Out_Of_Memory}
    defer delete(dcv)
    endpoints,e5:=make([]u32,nblocks)
    if e5!=nil {return .Out_Of_Memory}
    defer delete(endpoints)
    indices,e6:=make([]u32,nblocks)
    if e6!=nil {return .Out_Of_Memory}
    defer delete(indices)
    codelen_hash:map[u32]f32
    if reserve(&codelen_hash,2*nblocks)!=nil {return .Out_Of_Memory}
    defer delete(codelen_hash)
    index_hash:map[u32]i32
    if reserve(&index_hash,2*nblocks)!=nil {return .Out_Of_Memory}
    defer delete(index_hash)
    vqendpoints,e7:=make([dynamic]common.BC1_VQ_Entry,0,2*nblocks+1)
    if e7!=nil {return .Out_Of_Memory}
    defer delete(vqendpoints)
    vqindices,e8:=make([dynamic]common.BC1_VQ_Entry,0,2*nblocks+1)
    if e8!=nil {return .Out_Of_Memory}
    defer delete(vqindices)
    max_window:=max(config.max_num_added_entries_to_try_indices,
        config.max_num_added_entries_to_try_endpoints)
    lz_tab,e9:=make([]f32,max_window)
    if e9!=nil {return .Out_Of_Memory}
    defer delete(lz_tab)
    for i in 0..<max_window {lz_tab[i]=vq_codelen_lz(i)}
    index_vqd_results,e10:=make([]f32,
        (config.index_vq_palette_search_limit+config.max_num_added_entries_to_try_indices)*2+8)
    if e10!=nil {return .Out_Of_Memory}
    defer delete(index_vqd_results)
    endpoint_filter_results,e11:=make([]i32,
        config.endpoints_vq_palette_search_limit+config.max_num_added_entries_to_try_endpoints)
    if e11!=nil {return .Out_Of_Memory}
    defer delete(endpoint_filter_results)
    endpoint_ssds,e12:=make([]i32,
        config.endpoints_vq_palette_search_limit+config.max_num_added_entries_to_try_endpoints+8)
    if e12!=nil {return .Out_Of_Memory}
    defer delete(endpoint_ssds)
    for i in 0..<len(endpoint_ssds) {endpoint_ssds[i]=-1}
    lz_window,e13:=make([]i32,max_window)
    if e13!=nil {return .Out_Of_Memory}
    defer delete(lz_window)
    UNIT :: 1024
    unit_map:[UNIT]i32
    for i in 0..<UNIT {unit_map[i]=i32(i)}

    for bi in 0..<nblocks {
        b:=&blocks[bi]
        b.colors=from[bi]
        common.swap_rb(&b.colors)
        any_transparency:=false
        mask_1bt:u32
        if mode==.Alpha {
            num_transparent:=0
            for i in 0..<16 {
                common.make_one_bit_transparent_canonical(&b.colors[i])
                if common.color_dw(b.colors[i])==0 {num_transparent+=1}
            }
            mask_1bt=common.bc1_one_bit_transparent_mask(&b.colors)
            any_transparency=num_transparent>0
        } else {
            common.kill_alpha(&b.colors)
        }
        lo:=Color{255,255,255,0}
        hi:=Color{0,0,0,0}
        hi_all:=Color{0,0,0,0}
        num_nonblack:=0
        for i in 0..<16 {
            c:=b.colors[i]
            if c[R]<12 && c[G]<12 && c[B]<12 && mode!=.Four_Color {
                for k in 0..<3 {hi_all[k]=max(hi_all[k],c[k])}
            } else {
                num_nonblack+=1
                for k in 0..<3 {
                    hi[k]=max(hi[k],c[k])
                    lo[k]=min(lo[k],c[k])
                }
            }
        }
        if num_nonblack==0 {
            lo={}
            hi=hi_all
        } else {
            for k in 0..<3 {hi_all[k]=max(hi[k],hi_all[k])}
        }
        lo[A]=255
        hi[A]=255
        b.color_bbox={lo,hi}
        b.has_any_transparency=any_transparency
        b.has_any_black3c=num_nonblack<16
        b.degenerate_all_black_or_transparent=common.color_dw(hi_all)==0
        b.mask_1bt=mask_1bt
        b.baseline=common.bc1_get_block(baseline[bi*stride+offset:])
        b.activity=&activity[bi]
        b.baseline_vqd=vqd_block(&b.colors,b.baseline,b.activity,mode)
        b.cur=b.baseline
        b.cur_vqd=b.baseline_vqd
        b.cur_J=0
        b.second_best=b.cur
        endpoints[bi]=b.baseline.endpoints
        indices[bi]=b.baseline.indices
    }
    if e:=common.sort_and_count_uniques(&endpoint_counting,endpoints);e!=.None {return e}
    if e:=common.sort_and_count_uniques(&index_counting,indices);e!=.None {return e}

    for vq_iterations in 0..<config.num_vq_iterations {
        index_help:Codelen_Help
        setup_palette_and_codelen_help(&index_help,&index_counting,nblocks,true,false)
        clear(&codelen_hash)
        for dc in index_counting {codelen_hash[dc.dw]=vq_codelen_palette_count(dc.count,
            &index_help)}
        endpoint_help:Codelen_Help
        setup_palette_and_codelen_help(&endpoint_help,&endpoint_counting,nblocks,false,true)
        clear(&vqendpoints)
        clear(&index_hash)
        for dc,i in endpoint_counting {
            vqp:common.BC1_VQ_Entry
            vqp.dw=dc.dw
            index_hash[dc.dw]=i32(i)
            common.bc1_palette(vqp.dw,&vqp.palette,mode)
            vqp.codelen=vq_codelen_palette_count(dc.count,&endpoint_help)
            vqp.block_link=-1
            append(&vqendpoints,vqp)
        }
        {
            num_to_search:=min(len(vqendpoints),config.endpoints_vq_palette_search_limit,UNIT)
            lz_size:=0
            ssd_max_scale:=config.early_out_endpoints_ssd_max_increase_scaled_by_lambda
            ssd_max_increase:=i32(ssd_max_scale*lambdai)
            for i in 0..<nblocks {
                b:=&blocks[i]
                best_ssd:=i32(ERROR_BIG)
                best_vqd:=f32(ERROR_BIG)
                best_J:=f32(ERROR_BIG)
                best_p:=-1
                best_block:=b.baseline
                best_block2:=best_block
                filtered_pal,filtered_wnd:int
                bbox_min_d:=u32(config.early_out_color_endpoint_distance*lambdai)
                requires_3c:=b.has_any_transparency && mode==.Alpha
                if !b.degenerate_all_black_or_transparent {
                    filtered_pal=common.filter_endpoint_color_bbox(endpoint_filter_results[:],
                        vqendpoints[:],unit_map[:num_to_search],&b.color_bbox,bbox_min_d,
                        requires_3c)
                    filtered_wnd=common.filter_endpoint_color_bbox(
                        endpoint_filter_results[filtered_pal:],vqendpoints[:],lz_window[:lz_size],
                        &b.color_bbox,bbox_min_d,requires_3c)
                }
                filtered:=filtered_pal+filtered_wnd
                common.batch_find_best_errors(endpoint_ssds[:],vqendpoints[:],
                    endpoint_filter_results[:filtered],&b.colors)
                endpoint_ssds[filtered]=-1
                for fi:=0;;fi+=1 {
                    fi=common.find_next_below_i32(endpoint_ssds[:],fi,best_ssd+ssd_max_increase)
                    if fi>=filtered {break}
                    ssd:=endpoint_ssds[fi]
                    fval:=endpoint_filter_results[fi]
                    vqp:=int(fval&0xffff)
                    ve:=&vqendpoints[vqp]
                    new_indices:=common.bc1_find_indices_palette(&b.colors,&ve.palette)
                    block:=BC1_Block{ve.dw,new_indices}
                    vqd:=common.vqd_bc1(&b.colors,&ve.palette,new_indices,b.activity)
                    ep_codelen:=ve.codelen
                    if fi>=filtered_pal {
                        lzi:=int(fval>>16)
                        ep_codelen=min(lz_tab[lzi],ep_codelen)
                    }
                    prelim_J:=vq_J(vqd,ep_codelen,lambdaf)
                    if prelim_J<best_J {
                        ind_codelen:=codelen_or_escape(new_indices,&codelen_hash,&index_help)
                        J:=vq_J(vqd,ep_codelen+ind_codelen,lambdaf)
                        if J<best_J {
                            best_J=J
                            best_vqd=vqd
                            best_block2=best_block
                            best_block=block
                            best_p=vqp
                            best_ssd=min(best_ssd,ssd)
                        }
                    }
                    if vq_iterations>0 {
                        cur_indices:=b.cur.indices
                        if cur_indices!=new_indices {
                            block.indices=cur_indices
                            vqd=common.vqd_bc1(&b.colors,&ve.palette,cur_indices,b.activity)
                            prelim_J=vq_J(vqd,ep_codelen,lambdaf)
                            if prelim_J<best_J {
                                ind_codelen:=codelen_or_escape(cur_indices,&codelen_hash,
                                    &index_help)
                                J:=vq_J(vqd,ep_codelen+ind_codelen,lambdaf)
                                if J<best_J {
                                    best_J=J
                                    best_vqd=vqd
                                    best_block2=best_block
                                    best_block=block
                                    best_p=vqp
                                    best_ssd=min(best_ssd,ssd)
                                }
                            }
                        }
                    }
                }
                candidates:[2]BC1_Block
                candidates_vqd:[2]f32
                candidates[0]=b.baseline
                candidates_vqd[0]=b.baseline_vqd
                ncand:=1
                if b.cur!=b.baseline {
                    b.cur_vqd=vqd_block(&b.colors,b.cur,b.activity,mode)
                    candidates[1]=b.cur
                    candidates_vqd[1]=b.cur_vqd
                    ncand=2
                }
                for ci in 0..<ncand {
                    cand:=candidates[ci]
                    cand_vqd:=candidates_vqd[ci]
                    ep_codelen:=endpoint_help.codelen_escape
                    found:=-1
                    if p,ok:=index_hash[cand.endpoints];ok {
                        found=int(p)
                        ep_codelen=vqendpoints[found].codelen
                    }
                    ind_codelen:=codelen_or_escape(cand.indices,&codelen_hash,&index_help)
                    J:=vq_J(cand_vqd,ep_codelen+ind_codelen,lambdaf)
                    if J<best_J {
                        if found<0 {
                            best_p=len(vqendpoints)
                            vqp:common.BC1_VQ_Entry
                            vqp.codelen=endpoint_help.codelen_2count
                            vqp.dw=cand.endpoints
                            common.bc1_palette(cand.endpoints,&vqp.palette,mode)
                            vqp.block_link=-1
                            if _,e:=append(&vqendpoints,vqp);e!=nil {return .Out_Of_Memory}
                            index_hash[cand.endpoints]=i32(best_p)
                        } else {
                            best_p=found
                        }
                        best_J=J
                        best_block2=best_block
                        best_block=cand
                        best_vqd=cand_vqd
                    }
                }
                if best_p<0 {return .Invalid}
                b.cur=best_block
                b.second_best=best_block2
                b.cur_vqd=best_vqd
                b.cur_J=best_J
                b.vq_entry_index=i32(best_p)
                b.vq_entry_link=vqendpoints[best_p].block_link
                vqendpoints[best_p].block_link=i32(i)
                vqendpoints[best_p].block_count+=1
                if best_p>=num_to_search {
                    update_mtf_window(i32(best_p),lz_window,&lz_size,
                        config.max_num_added_entries_to_try_endpoints)
                }
            }
        }
        clear(&endpoint_counting)
        for ve in vqendpoints {
            if ve.block_count==0 {continue}
            append(&endpoint_counting,DC{ve.dw,u32(ve.block_count)})
        }
        setup_palette_and_codelen_help(&endpoint_help,&endpoint_counting,nblocks,false,false)
        clear(&codelen_hash)
        for dc in endpoint_counting {codelen_hash[dc.dw]=vq_codelen_palette_count(dc.count,
            &endpoint_help)}
        for i in 0..<nblocks {indices[i]=blocks[i].cur.indices}
        if e:=common.sort_and_count_uniques(&index_counting,indices);e!=.None {return e}
        if lambdai>0 {
            common.sort_dword_and_count_compare_count_highest_first(index_counting[:])
            hacky_clamp_counts(index_counting[:],nblocks)
            if e:=indices_vq_reduce(&reduced,index_counting[:],lambdaf,blocks,mode,config,
                allocator);e!=.None {return e}
            index_counting,reduced=reduced,index_counting
        }
        setup_palette_and_codelen_help(&index_help,&index_counting,nblocks,true,false)
        clear(&vqindices)
        clear(&index_hash)
        for dc,i in index_counting {
            vqp:common.BC1_VQ_Entry
            vqp.dw=dc.dw
            vqp.codelen=vq_codelen_palette_count(dc.count,&index_help)
            vqp.block_link=-1
            append(&vqindices,vqp)
            index_hash[vqp.dw]=i32(i)
        }
        {
            num_to_search:=min(len(vqindices),config.index_vq_palette_search_limit,UNIT)
            lz_size:=0
            for block_i in 0..<nblocks {
                b:=&blocks[block_i]
                best_vqd:=f32(ERROR_BIG)
                best_J:=f32(ERROR_BIG)
                best_p:=-1
                try_ep:=[2]u32{b.cur.endpoints,b.second_best.endpoints}
                try_codelen:[2]f32
                palettes:[2][4]Color
                for k in 0..<2 {
                    try_codelen[k]=codelen_or_escape(try_ep[k],&codelen_hash,&endpoint_help)
                    common.bc1_palette(try_ep[k],&palettes[k],mode)
                }
                best_endpoints:=try_ep[0]
                common.batch_compute_vqds(index_vqd_results[:],vqindices[:],
                    unit_map[:num_to_search],&b.colors,&palettes[0],&palettes[1],b.activity)
                common.batch_compute_vqds(index_vqd_results[num_to_search*2:],vqindices[:],
                    lz_window[:lz_size],&b.colors,&palettes[0],&palettes[1],b.activity)
                if mode==.Alpha {
                    override_vqds_on_transparency_mismatch(index_vqd_results[:],vqindices[:],
                        unit_map[:num_to_search],try_ep[0],try_ep[1],b.mask_1bt)
                    override_vqds_on_transparency_mismatch(index_vqd_results[num_to_search*2:],
                        vqindices[:],lz_window[:lz_size],try_ep[0],try_ep[1],b.mask_1bt)
                }
                candidate_count:=num_to_search+lz_size
                vqd_count:=candidate_count*2
                index_vqd_results[vqd_count]=-1
                for si:=0;;si+=1 {
                    si=common.find_next_below_f32(index_vqd_results[:],si,best_vqd)
                    if si>=vqd_count {break}
                    vqd:=index_vqd_results[si]
                    search_i:=si>>1
                    ep_i:=si&1
                    vqp:int
                    codelen:f32
                    if search_i<num_to_search {
                        vqp=search_i
                        codelen=vqindices[vqp].codelen
                    } else {
                        lzi:=search_i-num_to_search
                        vqp=int(lz_window[lzi])
                        codelen=min(lz_tab[lzi],vqindices[vqp].codelen)
                    }
                    J:=vq_J(vqd,codelen+try_codelen[ep_i],lambdaf)
                    if J<best_J {
                        best_J=J
                        best_vqd=vqd
                        best_p=vqp
                        best_endpoints=try_ep[ep_i]
                    }
                }
                b.cur_vqd=vqd_block(&b.colors,b.cur,b.activity,mode)
                cur_indices:=b.cur.indices
                cur_codelen:=index_help.codelen_escape
                found:=-1
                if p,ok:=index_hash[cur_indices];ok {
                    found=int(p)
                    cur_codelen=vqindices[found].codelen
                }
                {
                    J:=vq_J(b.cur_vqd,cur_codelen+try_codelen[0],lambdaf)
                    if try_ep[0]!=try_ep[1] {
                        alt:=BC1_Block{try_ep[1],cur_indices}
                        alt_vqd:=vqd_block(&b.colors,alt,b.activity,mode)
                        alt_J:=vq_J(alt_vqd,cur_codelen+try_codelen[1],lambdaf)
                        if alt_J<J && alt_vqd<b.cur_vqd {
                            J=alt_J
                            b.cur_vqd=alt_vqd
                            try_ep[0]=try_ep[1]
                        }
                    }
                    if J<best_J {
                        best_J=J
                        best_vqd=b.cur_vqd
                        best_endpoints=try_ep[0]
                        if found<0 {
                            best_p=len(vqindices)
                            vqp:common.BC1_VQ_Entry
                            vqp.codelen=index_help.codelen_2count
                            vqp.dw=cur_indices
                            vqp.block_link=-1
                            if _,e:=append(&vqindices,vqp);e!=nil {return .Out_Of_Memory}
                            index_hash[cur_indices]=i32(best_p)
                        } else {
                            best_p=found
                        }
                    }
                }
                if best_p<0 {return .Invalid}
                b.cur.endpoints=best_endpoints
                b.cur.indices=vqindices[best_p].dw
                b.cur_vqd=best_vqd
                b.cur_J=best_J
                b.vq_entry_index=i32(best_p)
                b.vq_entry_link=vqindices[best_p].block_link
                vqindices[best_p].block_link=i32(block_i)
                vqindices[best_p].block_count+=1
                if best_p>=num_to_search {
                    update_mtf_window(i32(best_p),lz_window,&lz_size,
                        config.max_num_added_entries_to_try_indices)
                }
            }
        }
        clear(&index_counting)
        for vi in vqindices {
            if vi.block_count==0 {continue}
            append(&index_counting,DC{vi.dw,u32(vi.block_count)})
        }
        optimize_endpoints_for_assigned_blocks(blocks,dcv,mode)
        for i in 0..<nblocks {endpoints[i]=blocks[i].cur.endpoints}
        if e:=common.sort_and_count_uniques(&endpoint_counting,endpoints);e!=.None {return e}
    }
    if e:=final_matrix(blocks,&endpoint_counting,&index_counting,lambdaf,lambdai,mode,config,
        allocator);e!=.None {return e}
    optimize_indices_for_assigned_blocks(blocks,dcv,mode)
    optimize_endpoints_for_assigned_blocks(blocks,dcv,mode)
    for bi in 0..<nblocks {common.bc1_put_block(to[bi*stride+offset:],blocks[bi].cur)}
    return .None
}
