#+build !amd64
package common

// The kernels of dispatch_amd64.odin, which picks a build for the instruction set of the
// CPU, with the only build there is elsewhere.

// Best index per texel (ties to the lower index); error is the sum of the RGB SSD of the
// choices (plus the alpha penalty, 0 for canonical input).
bc1_find_indices_palette :: proc "contextless" (b:^Color_Block,palette:^[4]Color,
    err:^u32=nil) -> u32 {
    return bc1_find_indices_body(b,palette,err)
}

bc1_eval_palettes :: proc "contextless" (ctx:^BC1_Find_Errors_Context,out_ssds:[]u32,
    palettes:[][4]Color) {
    bc1_eval_palettes_body(ctx,out_ssds,palettes)
}

// (best error << 8) | index of the best of up to 256 palettes; max(u32) when there are none.
bc1_find_best_palette :: proc "contextless" (ctx:^BC1_Find_Errors_Context,
    palettes:[][4]Color) -> u32 {
    return bc1_find_best_palette_body(ctx,palettes)
}

// dest_ssd[i]: the best error of colors against vqendpoints[inds[i]&0xffff].palette.
batch_find_best_errors :: proc "contextless" (dest_ssd:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,colors:^Color_Block) {
    batch_find_best_errors_body(dest_ssd,vqendpoints,inds,colors)
}

// dest_vqd[2i], dest_vqd[2i+1]: the VQD of colors against first_palette and second_palette
// with the indices vqindices[inds[i]].dw.
batch_compute_vqds :: proc "contextless" (dest_vqd:[]f32,vqindices:[]BC1_VQ_Entry,inds:[]i32,
    colors:^Color_Block,first_palette,second_palette:^[4]Color,activity:^Float_Block) {
    batch_compute_vqds_body(dest_vqd,vqindices,inds,colors,first_palette,second_palette,activity)
}

// chunk_sads[i] = SAD of pair_colors[indices[i]] against colors.
compute_chunk_sads_indirect :: proc "contextless" (chunk_sads:[]i32,indices:[]u16,
    pair_colors:[]Color_Block,colors:^Color_Block) {
    chunk_sads_from(chunk_sads,indices,pair_colors,colors,0)
}

// Positions i (in order) of the groups of 16 bytes of index_batch whose SAD to ref_inds is
// below threshold; returns how many. positions is written up to count.
filter_by_index_sad :: proc "contextless" (positions:[]i32,count:int,index_batch:[]u8,
    ref_inds:^[16]u8,threshold:i32) -> int {
    return filter_by_index_sad_from(positions,count,index_batch,ref_inds,threshold,0,0)
}

// Writes (i<<16)|inds[i] for the candidates not rejected by the color box test (nor, with
// require_3c, for being four color); returns how many.
filter_endpoint_color_bbox :: proc "contextless" (dest_inds:[]i32,vqendpoints:[]BC1_VQ_Entry,
    inds:[]i32,bbox:^[2]Color,bbox_min_d:u32,require_3c:bool) -> int {
    return filter_endpoint_color_bbox_from(dest_inds,vqendpoints,inds,bbox,bbox_min_d,require_3c,
        0,0)
}

// out_d[i]: the distortion of in_indices[i]; returns the lowest, for early outs.
any_index_d_batch_lookup :: proc "contextless" (out_d:[]i32,aid:^Any_Index_D,
    in_indices:[]u32) -> i32 {
    return any_index_d_batch_lookup_from(out_d,aid,in_indices,0,0x7fffffff)
}

// out_d[i]: the distortion of candidate i of packs, for count of them.
any_index_8d64_batch_lookup_packed :: proc "contextless" (out_d:[]i64,aid:^Any_Index_8D64,
    packs:[]Any_Index_8D64_Pack,count:int) {
    any_index_8d64_lookup_packed_from(out_d,aid,packs,count,0)
}

bc4_change_distortion_batch :: proc "contextless" (dest:[]i32,pixels:^[16]i16,pal:^[8]i16,
    index8:[]u8,inds:[]i32) {
    bc4_change_distortion_batch_from(dest,pixels,pal,index8,inds,0)
}

vqd_bc1 :: proc "contextless" (colors:^Color_Block,palette:^[4]Color,in_indices:u32,
    activity:^Float_Block) -> f32 {
    return vqd_bc1_body(colors,palette,in_indices,activity)
}
