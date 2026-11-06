package entropy

import "base:intrinsics"
import "core:simd"
import "mirai:std/compressor"

// Indexed multiarrays: the bytes of all source arrays are assigned to a few shared entropy arrays
// in intervals. Layout: 0x80+num_entropy_arrays, the entropy arrays, a 2-byte LE size of the
// interval length bits (bit 15: indices and lengths packed in one array), the index array(s),
// then the length bits (forward stream, backward stream).

@(private="file") Lazy_Merge_Candidate :: struct {gain_J:f32, merged_complen_bits:u32, src1,
    src2:i32, src1len,src2len:u32}
@(private="file")
lazy_less :: proc "contextless" (a,b:Lazy_Merge_Candidate) -> bool {return a.gain_J<b.gain_J}

Histo_Cost_Bits :: enum {Order0_Codelen, Estimate_Complen}

@(private="file")
histo_cost_bits :: #force_inline proc "contextless" (kind:Histo_Cost_Bits, h:^Histo256,
    n:int) -> u32 {
    if kind==.Order0_Codelen {return entropysets_order0_codelen_bits(h,n)}
    return histo_estimate_complen_bits(h,n)
}

@(private="file")
make_lazy_merge_candidate :: proc "contextless" (h1:^Entropyset, i:int, h2:^Entropyset, j:int,
    merge_J_saved:f32, kind:Histo_Cost_Bits) -> Lazy_Merge_Candidate {
    mh:Histo256
    histo_add(&mh,&h1.histo,&h2.histo)
    merged_len:=int(h1.total)+int(h2.total)
    merged_bits:=histo_cost_bits(kind,&mh,merged_len)
    before:=h1.complen+h2.complen
    delta:=i32(before-merged_bits)
    return Lazy_Merge_Candidate{f32(delta)/8.0+merge_J_saved,merged_bits,i32(i),i32(j),h1.total,
        h2.total}
}

// Bottom-up merge of the sets (by best J gain first) down to at most max_target sets, then
// further while the gain is at least min_gain_J. Returns the new count (sets compacted to the
// front), or -1 when the arena runs out.
merge_entropysets :: proc(histos:[]Entropyset, merge_J_saved:f32, min_gain_J:f32, max_target:int,
    kind:Histo_Cost_Bits, arena:^Arena) -> int #no_bounds_check {
    n:=len(histos)
    for i in 0..<n {histos[i].complen=histo_cost_bits(kind,&histos[i].histo,int(histos[i].total))}
    cap:=n*(n-1)/2
    heap:=arena_alloc(arena,Lazy_Merge_Candidate,max(cap,1))
    if heap==nil {return -1}
    defer arena_free(arena,heap)
    hs:=0
    for i in 0..<n {
        for j in i+1..<n {
            heap[hs]=make_lazy_merge_candidate(&histos[i],i,&histos[j],j,merge_J_saved,kind)
            hs+=1
        }
    }
    heap_make(heap[:hs],lazy_less)
    remaining:=n
    for hs>0 {
        cur:=heap[0]
        heap_popped(heap[:hs],lazy_less)
        hs-=1
        i:=int(cur.src1)
        j:=int(cur.src2)
        if histos[i].total!=cur.src1len || histos[j].total!=cur.src2len {
            if histos[i].total==0 || histos[j].total==0 {continue}
            heap[hs]=make_lazy_merge_candidate(&histos[i],i,&histos[j],j,merge_J_saved,kind)
            hs+=1
            heap_push(heap[:hs],lazy_less)
            continue
        }
        if cur.gain_J<min_gain_J && remaining<=max_target {break}
        histo_add(&histos[i].histo,&histos[i].histo,&histos[j].histo)
        histos[i].total+=histos[j].total
        histos[j].total=0
        histos[i].complen=cur.merged_complen_bits
        histos[j].complen=0
        remaining-=1
    }
    dest:=0
    for src in 0..<n {
        if histos[src].total>0 {
            if src!=dest {histos[dest]=histos[src]}
            dest+=1
        }
    }
    return dest
}

merge_entropysets_for_entropy_arrays :: proc(histos:[]Entropyset, lambda:f32,
    target_num_arrays:int, arena:^Arena) -> int {
    gain:=lambda*speedfit_estimate_entropy_array_time(0)
    return merge_entropysets(histos,gain,0,target_num_arrays,.Estimate_Complen,arena)
}

// Swap-removes the empty sets from the back; returns the new count.
remove_unused_entropysets :: proc "contextless" (histos:[]Entropyset) -> int {
    n:=len(histos)
    for hi:=n-1;hi>=0;hi-=1 {
        if histos[hi].total==0 {
            histos[hi]=histos[n-1]
            n-=1
        }
    }
    return n
}

@(private="file")
slide_to_purify :: proc "contextless" (h:^Histo256, p:int, size:int, base:[^]u8,
    end:int) -> int #no_bounds_check {
    p:=p
    gl:i32=-1
    if p>0 {gl=i32(h.counts[base[p-1]])-i32(h.counts[base[p+size-1]])}
    gr:i32=-1
    if p+size<end {gr=i32(h.counts[base[p+size]])-i32(h.counts[base[p]])}
    if gl>gr {
        for p>0 {
            gl=i32(h.counts[base[p-1]])-i32(h.counts[base[p+size-1]])
            if gl<=0 {break}
            h.counts[base[p-1]]+=1
            h.counts[base[p+size-1]]-=1
            p-=1
        }
    } else {
        for p+size<end {
            gr=i32(h.counts[base[p+size]])-i32(h.counts[base[p]])
            if gr<0 {break}
            h.counts[base[p+size]]+=1
            h.counts[base[p]]-=1
            p+=1
        }
    }
    return p
}

// For each byte, every set's best cost (staying in it, or switching from the cheapest at
// switch_cost) and the cheapest set. padded is a multiple of 8; the padding lanes hold
// ENTROPYSET_SYM_INVALID_HIGH_CL and never become the cheapest.
@(private="file")
trellis_core :: proc "contextless" (switch_flags:[]u64, cheapest:[]u8, p:[]u8, first_pos:int,
    cost_in:^[64]u16,
    transposed:[]u16, num_sets,padded:int, prev_cheapest:u16, switch_cost:u16) #no_bounds_check {
    V :: #simd[8]u16
    nb:=padded/8
    cost:[8]V
    for b in 0..<nb {cost[b]=intrinsics.unaligned_load((^V)(&cost_in[b*8]))}
    sw:=V(switch_cost)
    prev:=prev_cheapest
    for k in 0..<len(p) {
        row:=raw_data(transposed[padded*int(p[k]):])
        pv:=V(prev)
        best:=u16(0xFFFF)
        best_i:=0
        flags:u64=0
        for b in 0..<nb {
            sc:=intrinsics.unaligned_load((^V)(&row[b*8]))
            fs:=cost[b]-pv
            c:=sc+simd.min(fs,sw)
            cost[b]=c
            flags|=u64(transmute(u8)simd.extract_msbs(simd.lanes_gt(fs,sw)))<<uint(8*b)
            mn:=simd.reduce_min(c)
            if mn<best {
                best=mn
                eq:=transmute(u8)simd.extract_msbs(simd.lanes_eq(c,V(mn)))
                best_i=b*8+int(intrinsics.count_trailing_zeros(eq))
            }
        }
        pos:=first_pos+k
        switch_flags[pos]=flags
        cheapest[pos]=u8(best_i)
        prev=best
    }
}

@(private="file") Indexed_Interval :: struct {start,len,histo:i32}
@(private="file") Index_And_Count :: struct {index,count:i32}
@(private="file")
index_count_greater :: proc "contextless" (a,b:Index_And_Count) -> bool {return a.count>b.count}

@(private="file") MULTIARRAY_INDEXED_EST_INTERVAL_CYCLES :: f32(55)

// The indexed multiarray of the source arrays (without an array header); written only when it
// beats *pJ, then *pJ is updated. -1 otherwise.
put_multiarray_indexed_sub :: proc(out:[^]u8, out_end:[^]u8, from_ptrs:[][^]u8, from_lens:[]int,
    flags:u32,
    lambda:f32, pJ:^f32, arena:^Arena, compression_level:int) -> int #no_bounds_check {
    INITIAL_HISTO_SIZE_MIN :: 16
    INITIAL_HISTO_STEP_MIN :: 64
    INITIAL_HISTO_MAX_COUNT_TARGET :: 100
    NUM_TRELLIS_LLOYD_ITERS :: 3
    num_arrays:=min(len(from_ptrs),len(from_lens))
    target_num_arrays:=encoder_max_num_arrays(compression_level)
    tot_from_len,max_from_len:=0,0
    for i in 0..<num_arrays {
        if from_lens[i]<0 {return -1}
        tot_from_len+=from_lens[i]
        max_from_len=max(max_from_len,from_lens[i])
    }
    if tot_from_len<compressor.HUFF_ARRAY_MIN_SIZE*3 {return -1}
    if max_from_len<INITIAL_HISTO_SIZE_MIN*2 {return -1}
    target_chosen:=target_num_arrays*2
    initial_step:=max(tot_from_len/INITIAL_HISTO_MAX_COUNT_TARGET,INITIAL_HISTO_STEP_MIN)

    codelens:=arena_alloc(arena,Entropyset_Codelens,target_chosen+1)
    if codelens==nil {return -1}
    defer arena_free(arena,codelens)
    num_codelens:=0

    // Seeds: short semi-random windows, slid to purify.
    max_histo_count:=0
    seeds:[]Entropyset
    defer arena_free(arena,seeds)
    num_seeds:=0
    for pass in 0..<2 {
        if pass==1 {
            seeds=arena_alloc(arena,Entropyset,max(max_histo_count,1))
            if seeds==nil {return -1}
        }
        kiss:u32=0xB5B62FB9
        kiss=69069*kiss+12345
        for ai in 0..<num_arrays {
            if from_lens[ai]<INITIAL_HISTO_SIZE_MIN {continue}
            base:=from_ptrs[ai]
            end:=from_lens[ai]
            p:=0
            for {
                step:=int(u32((u64(kiss)*u64(initial_step))>>32))
                kiss=69069*kiss+12345
                step+=initial_step/2
                step=min(step,end-p)
                if step<INITIAL_HISTO_SIZE_MIN {break}
                size_max:=min(step,256)
                size_min:=64
                size:=int(u32((u64(kiss)*u64(i64(size_max-size_min)))>>32))
                kiss=69069*kiss+12345
                size+=size_min
                if step<size_min {size=step}
                if pass==0 {
                    max_histo_count+=1
                } else {
                    if num_seeds>=len(seeds) {break}
                    cur:=&seeds[num_seeds]
                    num_seeds+=1
                    count_histo_array_u8(base[p:][:size],cur.histo.counts[:])
                    cur.total=u32(size)
                    sp:=slide_to_purify(&cur.histo,p,size,base,end)
                    p=max(p,sp)
                }
                p+=step
            }
        }
    }

    // k-means++ style choice of target_chosen seeds, starting from a flat one.
    histos:=arena_alloc(arena,Entropyset,target_chosen+1)
    if histos==nil {return -1}
    defer arena_free(arena,histos)
    num_histos:=1
    for s in 0..<256 {histos[0].histo.counts[s]=10}
    histos[0].total=256*10
    entropysets_histo_to_codelens(&histos[0].histo,int(histos[0].total),&codelens[0])
    num_codelens=1
    {
        dist_mem:=arena_alloc(arena,i32,max(num_seeds*3,1))
        if dist_mem==nil {return -1}
        defer arena_free(arena,dist_mem)
        dist:=dist_mem[:num_seeds]
        closest:=dist_mem[num_seeds:][:num_seeds]
        self_cl:=dist_mem[2*num_seeds:][:num_seeds]
        for i in 0..<num_seeds {
            dist[i]=max(i32)
            closest[i]=0
            self_cl[i]=entropysets_self_codelen(&seeds[i].histo,int(seeds[i].total))
        }
        MIN_NEW_SEED_DISTANCE :: 32*ENTROPYSET_CODELEN_ONE_BIT
        for num_seeds>0 {
            if num_histos>=target_chosen {break}
            max_d:i32=0
            max_i:=0
            cur_chosen:=num_histos-1
            last:=&codelens[cur_chosen]
            for i in 0..<num_seeds {
                d:=entropysets_cross_codelen(&seeds[i].histo,last)-self_cl[i]
                if d<dist[i] {dist[i]=d;closest[i]=i32(cur_chosen)}
                if dist[i]>max_d {max_d=dist[i];max_i=i}
            }
            if max_d<=MIN_NEW_SEED_DISTANCE {break}
            histos[num_histos]=seeds[max_i]
            entropysets_histo_to_codelens(&histos[num_histos].histo,
                int(histos[num_histos].total),&codelens[num_codelens])
            num_histos+=1
            num_codelens+=1
            b:=num_seeds-1
            seeds[max_i]=seeds[b]
            self_cl[max_i]=self_cl[b]
            dist[max_i]=dist[b]
            closest[max_i]=closest[b]
            num_seeds-=1
        }
        for i in 0..<num_seeds {
            c:=int(closest[i])
            histo_add(&histos[c].histo,&histos[c].histo,&seeds[i].histo)
            histos[c].total+=seeds[i].total
        }
        num_codelens=0
    }
    if num_histos==0 {return -1}
    if num_histos>target_num_arrays {
        num_histos=merge_entropysets(histos[:num_histos],2.0,0,target_num_arrays,.Order0_Codelen,
            arena)
        if num_histos<0 {return -1}
    }
    num_sets:=num_histos
    if num_sets==1 {return -1}

    intervals_storage:=arena_alloc(arena,Indexed_Interval,tot_from_len+num_arrays)
    if intervals_storage==nil {return -1}
    defer arena_free(arena,intervals_storage)
    iv_off:=arena_alloc(arena,int,num_arrays+1)
    iv_cnt:=arena_alloc(arena,int,num_arrays+1)
    defer {arena_free(arena,iv_off);arena_free(arena,iv_cnt)}
    if iv_off==nil || iv_cnt==nil {return -1}
    {
        o:=0
        for ai in 0..<num_arrays {iv_off[ai]=o;iv_cnt[ai]=0;o+=from_lens[ai]+1}
    }

    switch_cost_flag:=u32(15*ENTROPYSET_CODELEN_ONE_BIT)
    switch_cost_time:=u32(lambda*MULTIARRAY_INDEXED_EST_INTERVAL_CYCLES*8*
        f32(ENTROPYSET_CODELEN_ONE_BIT))
    switch_cost_max:=u32(max(i16))-ENTROPYSET_SYM_INVALID_HIGH_CL*2
    switch_cost:=u16(min(switch_cost_flag+switch_cost_time,switch_cost_max))
    switch_flags:=arena_alloc(arena,u64,max_from_len)
    cheapest:=arena_alloc(arena,u8,max_from_len)
    defer {arena_free(arena,switch_flags);arena_free(arena,cheapest)}
    if switch_flags==nil || cheapest==nil {return -1}
    max_padded:=(target_num_arrays+1+7)&~7
    transposed:=arena_alloc(arena,u16,max(max_padded,64)*256)
    if transposed==nil {return -1}
    defer arena_free(arena,transposed)
    NEAR_UNCOMPRESSED :: u16(2035) // 7.95 bits

    for trellis_iter:=0;;trellis_iter+=1 {
        last_iter:=trellis_iter==NUM_TRELLIS_LLOYD_ITERS-1
        num_codelens=num_histos
        for i:=num_histos-1;i>=0;i-=1 {
            entropysets_histo_to_codelens(&histos[i].histo,int(histos[i].total),&codelens[i])
            total:=u32(entropysets_cross_codelen(&histos[i].histo,&codelens[i]))
            if total>=histos[i].total*u32(NEAR_UNCOMPRESSED) {
                codelens[i]=codelens[num_codelens-1]
                num_codelens-=1
            }
        }
        if num_codelens<MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT && num_codelens<len(codelens) {
            for s in 0..<256 {codelens[num_codelens].codelen[s]=NEAR_UNCOMPRESSED}
            num_codelens+=1
        }
        num_sets=num_codelens
        padded:=(num_sets+7)&~7
        if padded*256>len(transposed) || num_sets>64 {return -1}
        for sym in 0..<256 {
            row:=transposed[padded*sym:]
            for hi in 0..<num_sets {row[hi]=codelens[hi].codelen[sym]}
            for hi in num_sets..<padded {row[hi]=ENTROPYSET_SYM_INVALID_HIGH_CL}
        }
        if num_sets>len(histos) {return -1}
        num_histos=num_sets
        for i in 0..<num_histos {histos[i]={}}
        cost:[64]u16
        tot_num_intervals:=0
        for ai in 0..<num_arrays {
            base:=from_ptrs[ai]
            array_len:=from_lens[ai]
            if array_len==0 {continue}
            prev_cheapest:=u16(max(i16))
            {
                row:=transposed[padded*int(base[0]):]
                ci:=-1
                for hi in 0..<num_sets {
                    c:=row[hi]
                    cost[hi]=c
                    if c<prev_cheapest {prev_cheapest=c;ci=hi}
                }
                for hi in num_sets..<padded {cost[hi]=ENTROPYSET_SYM_INVALID_HIGH_CL}
                switch_flags[0]=0
                cheapest[0]=u8(ci)
            }
            trellis_core(switch_flags,cheapest,base[1:array_len],1,&cost,transposed,num_sets,
                padded,prev_cheapest,switch_cost)
            tot_num_intervals+=1
            if last_iter {
                ivs:=intervals_storage[iv_off[ai]:][:array_len+1]
                n:=0
                pos:=array_len-1
                cur:=int(cheapest[pos])
                cur_end:=array_len
                mask:=u64(1)<<uint(cur)
                for pos>=0 {
                    if switch_flags[pos]&mask!=0 && pos>0 {
                        ivs[n]=Indexed_Interval{i32(pos),i32(cur_end-pos),i32(cur)};n+=1
                        cur_end=pos
                        cur=int(cheapest[pos-1])
                        mask=u64(1)<<uint(cur)
                        tot_num_intervals+=1
                    }
                    pos-=1
                }
                ivs[n]=Indexed_Interval{0,i32(cur_end),i32(cheapest[cur_end-1])};n+=1
                for a,b:=0,n-1;a<b;a,b=a+1,b-1 {ivs[a],ivs[b]=ivs[b],ivs[a]}
                iv_cnt[ai]=n
            } else {
                pos:=array_len-1
                cur:=int(cheapest[pos])
                mask:=u64(1)<<uint(cur)
                for pos>=0 {
                    sym:=base[pos]
                    histos[cur].histo.counts[sym]+=1
                    histos[cur].total+=1
                    if switch_flags[pos]&mask!=0 && pos>0 {
                        cur=int(cheapest[pos-1])
                        mask=u64(1)<<uint(cur)
                        tot_num_intervals+=1
                    }
                    pos-=1
                }
            }
        }
        if last_iter {break}
        num_histos=remove_unused_entropysets(histos[:num_histos])
        if num_histos==1 {return -1}
        num_histos=merge_entropysets_for_entropy_arrays(histos[:num_histos],lambda,
            target_num_arrays,arena)
        if num_histos<=1 {return -1}
        if tot_num_intervals>4000 {
            sc32:=u32(switch_cost)*2
            if sc32<switch_cost_max {
                switch_cost=u16(sc32)
                trellis_iter-=1
            } else {
                switch_cost=u16(switch_cost_max)
            }
        }
    }

    // Output.
    use:[MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT+1]Index_And_Count
    if num_sets>len(use) {return -1}
    for i in 0..<num_sets {use[i].index=i32(i)}
    tot_num_intervals:=0
    for ai in 0..<num_arrays {
        tot_num_intervals+=iv_cnt[ai]
        for v in intervals_storage[iv_off[ai]:][:iv_cnt[ai]] {use[v.histo].count+=1}
    }
    stdsort(use[:num_sets],index_count_greater)
    old_to_new:[MULTIARRAYS_ENCODER_MAX_NUM_ARRAYS_STRICT+1]int
    for hi in 0..<num_sets {old_to_new[use[hi].index]=hi}
    for num_sets>0 && use[num_sets-1].count==0 {num_sets-=1}
    if num_sets<=1 {return -1}
    num_entropy_arrays:=num_sets
    tot_num_indices:=tot_num_intervals+num_arrays
    if tot_num_indices*6>=compressor.ARRAY_INTERNAL_MAX_SCRATCH {return -1}
    to_size:=tot_from_len+32
    scratch:=arena_alloc(arena,u8,to_size+tot_from_len+tot_num_indices*2+tot_num_intervals)
    if scratch==nil {return -1}
    defer arena_free(arena,scratch)
    to:=raw_data(scratch)
    to_end:=to[to_size:]
    gather:=to_end[:tot_from_len]
    packed:=gather[tot_from_len:][:tot_num_indices]
    indices:=packed[tot_num_indices:][:tot_num_indices]
    lens_log2:=indices[tot_num_indices:][:tot_num_intervals]
    p:=to
    p[0]=u8(0x80+num_entropy_arrays);p=p[1:]
    tot_J:f32=0
    tot_J+=1
    sub_flags:=flags&~ARRAY_FLAG_ALLOW_SPLIT
    for newhi in 0..<num_entropy_arrays {
        g:=0
        for ai in 0..<num_arrays {
            src:=from_ptrs[ai]
            for v in intervals_storage[iv_off[ai]:][:iv_cnt[ai]] {
                if old_to_new[v.histo]==newhi {
                    copy_bytes(raw_data(gather[g:]),src[v.start:],int(v.len))
                    g+=int(v.len)
                }
            }
        }
        J:=LAGRANGE_COST_INVALID
        n:=put_array_small_allowed(p,to_end,gather[:g],sub_flags,lambda,&J,ARRAY_DEADLINE_HUGE,
            arena,compression_level)
        if n<0 {return -1}
        p=p[n:]
        tot_J+=J
        if tot_J>=pJ^ {return -1}
    }
    size_at:=p
    p=p[2:]
    tot_J+=2
    ni,nl:=0,0
    max_len_log2,tot_len_log2:=0,0
    for ai in 0..<num_arrays {
        for v in intervals_storage[iv_off[ai]:][:iv_cnt[ai]] {
            new_index:=old_to_new[v.histo]
            indices[ni]=u8(new_index+1)
            l2:=int(bit_level_nonzero(u32(v.len)))-1
            lens_log2[nl]=u8(l2);nl+=1
            max_len_log2=max(max_len_log2,l2)
            tot_len_log2+=l2
            packed[ni]=u8((l2<<4)|(new_index+1))
            ni+=1
        }
        indices[ni]=0
        packed[ni]=0
        ni+=1
    }
    VARBITS_FLUSH_END_PAD_BYTES :: 8
    varbits_est_bytes:=(tot_len_log2+7)/8+2*VARBITS_FLUSH_END_PAD_BYTES
    did_packed:=false
    arrays_start:=p
    J1:=LAGRANGE_COST_INVALID
    c1:=put_array_small_allowed(p,to_end,indices,sub_flags,lambda,&J1,ARRAY_DEADLINE_HUGE,arena,
        compression_level)
    if c1<=0 {return -1}
    p=p[c1:]
    J2:=LAGRANGE_COST_INVALID
    c2:=put_array_small_allowed(p,to_end,lens_log2,sub_flags,lambda,&J2,ARRAY_DEADLINE_HUGE,
        arena,compression_level)
    if c2<=0 {return -1}
    p=p[c2:]
    interval_arrays_J:=J1+J2
    if num_entropy_arrays<=15 && max_len_log2<=15 {
        n:=put_array_small_allowed(arrays_start,to_end,packed,sub_flags,lambda,
            &interval_arrays_J,ARRAY_DEADLINE_HUGE,arena,compression_level)
        if n>0 {
            p=arrays_start[n:]
            did_packed=true
        }
    }
    tot_J+=interval_arrays_J
    if tot_J+f32(varbits_est_bytes)>=pJ^ {return -1}
    if varbits_est_bytes>ptr_diff(to_end,p) {return -1}
    vstart:=p
    vb1,vb2:Var_Bits
    varbits_open(&vb1,p,to_end)
    varbits_open(&vb2,to_end,p)
    which:=0
    for ai in 0..<num_arrays {
        for v in intervals_storage[iv_off[ai]:][:iv_cnt[ai]] {
            l:=u32(v.len)
            l2:=int(bit_level_nonzero(l))-1
            l&=(u32(1)<<uint(l2))-1
            if which==0 {
                varbits_put(&vb1,u64(l),l2)
                varbits_output(&vb1)
            } else {
                varbits_put(&vb2,u64(l),l2)
                varbits_output_back(&vb2)
            }
            which~=1
        }
        if did_packed {which~=1}
    }
    varbits_put_flush8(&vb1)
    varbits_put_flush8_back(&vb2)
    vb1_end:=varbits_put_end_ptr(&vb1)
    vb2_end:=vb2.cur
    s1:=ptr_diff(vb1_end,vstart)
    s2:=ptr_diff(to_end,vb2_end)
    if ptr_diff(vb2_end,vb1_end)<0 {return -1}
    copy_bytes(vb1_end,vb2_end,s2)
    varbits_len:=s1+s2
    p=vstart[varbits_len:]
    u:=u16(varbits_len)
    if did_packed {u|=1<<15}
    size_at[0]=u8(u);size_at[1]=u8(u>>8)
    tot_J+=f32(varbits_len)
    tot_J+=lambda*speedfit_get_multiarrays(tot_num_intervals,tot_from_len)
    tot:=ptr_diff(p,to)
    if tot_J>=pJ^ {return -1}
    if tot>ptr_diff(out_end,out) {return -1}
    pJ^=tot_J
    copy_bytes(out,to,tot)
    return tot
}
