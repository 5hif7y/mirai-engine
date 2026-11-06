package bc7

import "mirai:cook/compressor/texture/common"

// Rate-distortion optimized BC7 encode of one slice (BC7_RD): blocks reuse the
// endpoints or indices of recent blocks when the bits saved are worth the
// distortion, then index merging, a final matrix of common combinations and
// shared-endpoint/index optimization lower the rate further.

@(rodata)
@(private)
AVERAGE_BLOCK_SIZE_BITS := [8]f32{94.28325,97.2345,94.66392,98.22575,83.168,84.9612,79.677,76.7255}

GOOD_ENDPOINT_MAX :: 16

// from: RGBA blocks; baseline: their non-RDO encode at the baseline effort;
// activity: the perceptual weight of each texel; to: 16 bytes per block.
rd :: proc(to:[]u8,from:[]common.Color_Block,baseline:[]u8,activity:[]common.Float_Block,lambda:int,
    options:common.Options,rd_options:common.RD_Options,
        allocator:=context.allocator) -> common.Error {
    nblocks:=len(from)
    if len(to)!=nblocks*16 || len(baseline)!=nblocks*16 || len(activity)!=nblocks || lambda<0 ||
        nblocks>=1<<24 || rd_options.effort>.Reference {return .Invalid}
    for bi in 0..<nblocks {
        if bits_get_mode(bits_load(block_bits_at(baseline,bi)))>7 {return .Invalid}
    }
    if nblocks==0 {return .None}
    lambda_f:=f32(lambda)*(0.8*common.GLOBAL_LAMBDA_SCALE)
    config:=&RD_CONFIG_LEVELS[rd_options.effort]
    opt:Enc_Options
    enc_options_set(&opt,config.block_encode_effort,options)

    infos,err:=make([]Block_Info,nblocks,allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(infos,allocator)

    mode_errbias:Mode_Err_Bias
    for m in 0..<8 {mode_errbias.ssd_err_bias[m]=bits_to_ssd_err_bias_j(AVERAGE_BLOCK_SIZE_BITS[m],
        lambda_f)}

    block_to_index:=make(map[Bits]int,allocator)
    defer delete(block_to_index)
    if reserve(&block_to_index,nblocks)!=nil {return .Out_Of_Memory}

    window_endpoints,window_indices:Window
    if e:=window_init(&window_endpoints,config.mtf_window_endpoints_size,
        allocator); e!=.None {return e}
    defer {delete(window_endpoints.backing_store,allocator); delete(window_endpoints.mtf,allocator)}
    if e:=window_init(&window_indices,config.mtf_window_indices_size,allocator); e!=.None {return e}
    defer {delete(window_indices.backing_store,allocator); delete(window_indices.mtf,allocator)}
    window_endpoint_extra,e1:=make([]Endpoint_Window_Extra,config.mtf_window_endpoints_size,
        allocator)
    if e1!=nil {return .Out_Of_Memory}
    defer delete(window_endpoint_extra,allocator)
    window_index_endpoint_cache,e2:=make([]Endpoint_Coeff_Cache,config.mtf_window_indices_size,
        allocator)
    if e2!=nil {return .Out_Of_Memory}
    defer delete(window_index_endpoint_cache,allocator)

    if config.mtf_window_seed_most_common {
        if e:=window_seed(&window_endpoints,baseline,opt.flags,window_endpoint_extra,
            allocator); e!=.None {
            return e
        }
    }
    histo_mode:[8]u32
    histogram_mode(&histo_mode,baseline)
    errbias:Mode_Err_Bias
    histogram_to_ssd_err_bias_j(&errbias,&histo_mode,lambda_f)
    expected_size_errbias:Mode_Err_Bias
    for m in 0..<8 {
        expected_size_errbias.ssd_err_bias[m]=mode_errbias.ssd_err_bias[m]+errbias.ssd_err_bias[m]
    }
    mode_and_count_sorted:[8]common.Dword_And_Count
    for m in 0..<8 {mode_and_count_sorted[m]={u32(m),expected_size_errbias.ssd_err_bias[m]}}
    common.stdsort(mode_and_count_sorted[:],common.dword_and_count_compare_count_lowest_first)

    prep:Prep
    for bi in 0..<nblocks {
        baseline_block:=block_bits_at(baseline,bi)
        output_bc7:=block_bits_at(to,bi)
        act:=&activity[bi]
        {
            baseline_mode:=bits_get_mode(bits_load(baseline_block))&7
            my_class:=MODE_CLASS[baseline_mode]
            for mode in 0..<8 {opt.enable_mode[mode]=MODE_CLASS[mode]<=my_class}
        }
        block:=prep_init(&prep,(^[16]Color)(&from[bi]),&opt,false)
        colors:=(^common.Color_Block)(block)
        info:=&infos[bi]
        info.flags=compute_effective_flags(opt.flags,&prep)
        info.constraints=opt.flags&PRESERVE_EXTREMES!=0 ? constraints_from_pixels(colors) : 0
        info.colors=colors^

        if config.core_fix_single_color_block && prep.single_color {
            output_bc7^=baseline_block^
            info.d=0; info.j=0; info.baseline_d=0
            continue
        }

        new_baseline_block:[16]u8
        if config.core_recompress_block_with_j_bias {
            old_bits:=bits_load(baseline_block)
            old_mode:=bits_get_mode(old_bits)&7
            old_mode_sort_pos:=0
            for mode_and_count_sorted[old_mode_sort_pos].dw!=u32(old_mode) {old_mode_sort_pos+=1}
            if old_mode_sort_pos>0 {
                cur_errbias:=expected_size_errbias
                old_mode_sort_pos=min(old_mode_sort_pos,3)
                for sort_pos in old_mode_sort_pos..<8 {
                    cur_errbias.ssd_err_bias[mode_and_count_sorted[sort_pos].dw]=max(u32)
                }
                if config.core_disable_less_common_modes {
                    for sort_pos in 1..<old_mode_sort_pos {
                        m:=mode_and_count_sorted[sort_pos].dw
                        if histo_mode[m]<=histo_mode[old_mode] {
                            cur_errbias.ssd_err_bias[m]=max(u32)
                        }
                    }
                }
                if compress_block_sub(&new_baseline_block,block,&opt,&prep,&cur_errbias) {
                    new_bits:=bits_load(&new_baseline_block)
                    new_mode:=bits_get_mode(new_bits)&7
                    old_d:=rd_ssd_bits(old_bits,colors,info.flags)
                    new_d:=rd_ssd_bits(new_bits,colors,info.flags)
                    old_j:=old_d+expected_size_errbias.ssd_err_bias[old_mode]
                    new_j:=new_d+expected_size_errbias.ssd_err_bias[new_mode]
                    if new_j<old_j {baseline_block=&new_baseline_block}
                }
            }
        }

        baseline_st:Block_State
        state_from_bits(&baseline_st,baseline_block,info.flags)
        baseline_d:=rd_d_state(&baseline_st,colors,act)
        BASELINE_R :: f32(128)
        baseline_j:=rd_j(baseline_d,BASELINE_R,lambda_f)
        info.baseline_d=baseline_d
        best_j:=baseline_j
        best_d:=baseline_d
        best_st:=baseline_st
        emit_flags:=info.flags
        best_endpoints_i:=-1
        best_indices_i:=-1

        {
            baseline_bits:=bits_load(baseline_block)
            if prev_bi,seen:=block_to_index[baseline_bits]; seen {
                prev_block:=block_bits_at(to,prev_bi)
                output_bc7^=prev_block^
                repeat_r:=matched_r(128,bi-prev_bi)
                decoded:common.Color_Block
                decode_block4x4a(&decoded,prev_block,info.flags)
                subst:Constraints
                if info.constraints!=0 {subst=constraints_from_pixels(&decoded)}
                if constraints_superset_of(subst,info.constraints) {
                    info.d=common.vqd(&decoded,colors,act)
                    info.j=rd_j(info.d,repeat_r,lambda_f)
                    continue
                }
            } else {
                block_to_index[baseline_bits]=bi
            }
        }

        input_1s:[4]Input
        for rbit in 0..<4 {input_get(&input_1s[rbit],block,1,0,rbit,1)}
        mtf_input:Input
        good_endpoints:[GOOD_ENDPOINT_MAX]int
        good_endpoint_count:=0

        if window_endpoints.size>0 {
            best_j_here:=f32(ERROR_MAX)
            ssd_cutoff:=f32(ERROR_MAX)
            iters:=min(window_endpoints.size+1,config.mtf_window_endpoints_size)
            last:=iters-1
            iters=last
            best_err:=ERROR_MAX
            mode456_overall_err:[6]f32
            mode456_scaled_pca:[6][4]f32
            {
                ana:=&prep.analysis
                for i in 0..<5 {
                    subset_id:=int(prep.ranking.pca_subset1[0])+i
                    mode456_overall_err[i+1]=ana.storage[.Overall_Err][subset_id]
                    pca_err:=ana.storage[.Pca_Err][subset_id]
                    mode456_scaled_pca[i+1][0]=ana.storage[.Pca_R][subset_id]*pca_err
                    mode456_scaled_pca[i+1][1]=ana.storage[.Pca_G][subset_id]*pca_err
                    mode456_scaled_pca[i+1][2]=ana.storage[.Pca_B][subset_id]*pca_err
                    mode456_scaled_pca[i+1][3]=ana.storage[.Pca_A][subset_id]*pca_err
                }
            }
            for wi:=0; wi<iters; wi+=1 {
                extra:=&window_endpoint_extra[window_endpoints.mtf[wi]]
                if extra.mode_class>MODE_CLASS[best_st.mode&7] {continue}
                pca_type:=int(extra.pca_type)%6
                ssd_estimate:=window_extra_estimate_ssd(extra,mode456_overall_err[pca_type],
                    &mode456_scaled_pca[pca_type])
                if ssd_estimate>ssd_cutoff {continue}
                window_entry:=window_at(&window_endpoints,wi)
                window_st:=&window_entry.st
                if !are_endpoints_permitted(window_st,info) {continue}
                st:Block_State
                input:^Input
                if window_st.mode>=4 && window_st.mode<=6 {
                    input=&input_1s[window_st.subsets[0].rbit&3]
                } else {
                    input_get_state(&mtf_input,block,window_st)
                    input=&mtf_input
                }
                slow_exact:=wi==last
                reindex_flags:=info.flags|(slow_exact ? IDXS_EXACT : 0)
                bits_changed:=reindex_block(&st,window_st,raw_data(input.subsets[:]),reindex_flags)
                cur_matched_bits:=128-bits_changed
                if st.err>best_err {continue}
                best_err=st.err
                ssd_cutoff=f32(st.err)
                cur_d:=rd_d_state(&st,colors,act)
                cur_r:=matched_r(cur_matched_bits,wi+1)
                cur_j:=rd_j(cur_d,cur_r,lambda_f)
                if cur_j<best_j {
                    best_j=cur_j
                    best_d=cur_d
                    best_st=st
                    best_endpoints_i=wi
                    best_indices_i=-1
                    good_endpoints[good_endpoint_count&(GOOD_ENDPOINT_MAX-1)]=wi
                    good_endpoint_count+=1
                }
                if cur_j<best_j_here {
                    best_j_here=cur_j
                    window_at(&window_endpoints,last)^=window_at(&window_endpoints,wi)^
                    extras:=window_endpoint_extra
                    extras[window_endpoints.mtf[last]]=extras[window_endpoints.mtf[wi]]
                    iters=last+1
                }
            }
        }

        if config.core_endpoints_from_indices && window_indices.size>0 {
            best_j_here:=f32(ERROR_MAX)
            iters:=min(window_indices.size+1,config.mtf_window_indices_size)
            last:=iters-1
            iters=last
            best_err:=ERROR_MAX
            for wi:=0; wi<iters; wi+=1 {
                window_st:=&window_at(&window_indices,wi).st
                if MODE_CLASS[window_st.mode&7]>MODE_CLASS[best_st.mode&7] {continue}
                flags:Flags
                if !are_indices_permitted(window_st,info,&flags) {continue}
                input:^Input
                if window_st.mode>=4 && window_st.mode<=6 {
                    input=&input_1s[window_st.subsets[0].rbit&3]
                } else {
                    input_get_state(&mtf_input,block,window_st)
                    input=&mtf_input
                }
                st:Block_State
                is_last:=wi==last
                cache:=&window_index_endpoint_cache[window_indices.mtf[wi]]
                bits_changed:=find_endpoints(&st,window_st,input,flags,false,is_last,cache)
                _=bits_changed
                if st.err>best_err {continue}
                best_err=st.err
                cur_matched_bits:=lz_matched_bits_reendpoint(int(st.mode),false)+int(st.mode)+1
                cur_d:=rd_d_state(&st,colors,act)
                cur_r:=matched_r(cur_matched_bits,wi+1)
                cur_j:=rd_j(cur_d,cur_r,lambda_f)
                if cur_j<best_j {
                    best_j=cur_j
                    best_d=cur_d
                    best_st=st
                    best_endpoints_i=-1
                    best_indices_i=wi
                }
                if cur_j<best_j_here {
                    best_j_here=cur_j
                    window_at(&window_indices,last)^=window_at(&window_indices,wi)^
                    caches:=window_index_endpoint_cache
                    caches[window_indices.mtf[last]]=caches[window_indices.mtf[wi]]
                    iters=last+1
                }
            }
        }

        if config.do_ilm && good_endpoint_count>0 {
            good_endpoint_start:=max(good_endpoint_count-GOOD_ENDPOINT_MAX,0)
            matrix_dim:=min(config.mtf_window_endpoints_size,config.mtf_window_indices_size,
                config.ilm_hyperbola_max_index_product)
            matrix_dim_ind:=min(matrix_dim,window_indices.size)
            best_decoded:common.Color_Block
            decode_state(&best_st,(^[16]Color)(&best_decoded))
            before_sad:=common.color_block_sad_rgba(colors,&best_decoded)
            must_beat_sad:=u32(froundint(f32(before_sad)+
                lambda_f*FINAL_MATRIX_SAD_INCREASE_TOLERANCE))
            for indi in 0..<matrix_dim_ind {
                past_indices:=window_at(&window_indices,indi)
                past_indices_st:=&past_indices.st
                mode:=int(past_indices_st.mode&7)
                mask_ip:=BITRANGE_INDICES_WITH_PBITS_MASK[mode]
                past_indices_noe:=past_indices.encoded&mask_ip
                for gi:=good_endpoint_start; gi<good_endpoint_count; gi+=1 {
                    endpi:=good_endpoints[gi&(GOOD_ENDPOINT_MAX-1)]
                    index_product:=(indi+1)*(good_endpoint_count-gi)
                    if index_product>config.ilm_hyperbola_max_index_product {break}
                    past_endpoints:=window_at(&window_endpoints,endpi)
                    if int(past_endpoints.st.mode)!=mode {continue}
                    if past_endpoints.st.p!=past_indices_st.p {continue}
                    if past_indices.encoded==past_endpoints.encoded {continue}
                    merged_bits:=(past_endpoints.encoded&~mask_ip)|past_indices_noe
                    decoded:common.Color_Block
                    decode_bits4x4a(&decoded,merged_bits,info.flags)
                    sad:=common.color_block_sad_rgba(colors,&decoded)
                    if sad<=must_beat_sad {
                        satisfied:Constraints
                        if info.constraints!=0 {satisfied=constraints_from_pixels(&decoded)}
                        if constraints_superset_of(satisfied,info.constraints) {
                            cur_d:=common.vqd(&decoded,colors,act)
                            if cur_d<best_j {
                                cur_r:=matched_r_lz(endpi+1)+matched_r_lz(indi+1)
                                cur_j:=rd_j(cur_d,cur_r,lambda_f)
                                if cur_j<best_j {
                                    emit_flags&=~PRESERVE_EXTREMES
                                    mb:=transmute([16]u8)merged_bits
                                    state_from_bits(&best_st,&mb,emit_flags)
                                    best_j=cur_j
                                    best_d=cur_d
                                    best_endpoints_i=endpi
                                    best_indices_i=indi
                                }
                            }
                        }
                    }
                }
            }
        }

        info.d=best_d
        info.j=best_j
        emit(output_bc7,&best_st)
        for si in 0..<3 {best_st.subsets[si].endpoints=best_st.subsets[si].endpoints_q}
        new_entry:Window_Entry
        new_entry.st=best_st
        new_entry.encoded=bits_load(output_bc7)
        window_update(&window_endpoints,&new_entry,best_endpoints_i)
        window_update(&window_indices,&new_entry,best_indices_i)
        if best_endpoints_i<0 {
            window_extra_init(&window_endpoint_extra[window_endpoints.mtf[0]],&new_entry.st)
        }
        if best_indices_i<0 {
            input_get_state(&mtf_input,block,&best_st)
            find_endpoints_init_cache(&window_index_endpoint_cache[window_indices.mtf[0]],&best_st,
                &mtf_input)
        }
    }

    if config.do_bottom_up_merge {
        if e:=bottom_up_merge_indices(to,activity,infos,lambda_f,opt.flags,
            allocator); e!=.None {return e}
    }
    if e:=recompute_rates_static_model(to,infos,lambda_f,allocator); e!=.None {return e}
    if config.do_final_matrix {
        if e:=final_matrix(to,activity,infos,lambda_f,opt.flags,config,
            allocator); e!=.None {return e}
    }
    if config.do_final_optimize {
        if e:=final_optimize(to,infos,opt.flags,false,allocator); e!=.None {return e}
        if e:=final_optimize(to,infos,opt.flags,true,allocator); e!=.None {return e}
    }
    return .None
}
