#+build !amd64
package bc7

// The kernels of dispatch_amd64.odin, which picks a build for the instruction set of the
// CPU, with the only build there is elsewhere.

@(private)
calc_vector_inds_linear :: #force_inline proc "contextless" (out_inds:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,n:int,$IB:int,$NC:int) -> Error {
    return vector_inds_linear_128(out_inds,in_,ep,n,IB,NC)
}

@(private)
calc_twoindex_linear :: #force_inline proc "contextless" (idx_v,idx_s:^[16]u8,in_:^Subset_Input,
    ep:^[2]Color,$IBV,$IBS:int) -> (vec_err,scalar_err:Error) {
    return twoindex_linear_128(idx_v,idx_s,in_,ep,IBV,IBS)
}

@(private)
calc_vector_err :: #force_inline proc "contextless" (inds:^[16]u8,in_:^Subset_Input,ep:^[2]Color,
    $IB:int,$NC:int) -> Error {
    return vector_err_128(inds,in_,ep,IB,NC)
}


@(private)
analysis_compute :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,masks:[]u32,
    scale:[]f32,first,count:int,is_rgba:bool) {
    analysis_compute_body(a,pixels,masks,scale,first,count,is_rgba)
}

@(private)
analysis_compute_1subset :: proc "contextless" (a:^Subset_Analysis,pixels:^[16][4]u8,first:int) {
    analysis_compute_1subset_body(a,pixels,first)
}

@(private)
block_link_distortion :: #force_inline proc "contextless" (c:^Merge_Ctx,bi:int,
    blocks:[]Index_VQ_Block,infos:[]Block_Info,entry:int,must_beat_d:f32=LARGE_D) -> f32 {
    return block_link_distortion_128(c,bi,blocks,infos,entry,must_beat_d)
}

@(private)
merge_find_next :: #force_inline proc "contextless" (t:^Merge_Table,lerps:[]Merge_Lerps,
    from,count:int,thresh:u32,out_err:^u32) -> int {
    return merge_find_next_128(t,lerps,from,count,thresh,out_err)
}
