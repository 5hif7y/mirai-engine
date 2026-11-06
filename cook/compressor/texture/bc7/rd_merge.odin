package bc7

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:simd"
import "mirai:cook/compressor/texture/bc67"
import "mirai:cook/compressor/texture/common"
import "mirai:std/compressor/lz/entropy"

// Bottom-up merge of the index sets of the BC7 RDO: within each mode, blocks
// whose indices are worth replacing take the indices of another set.

LARGE_D :: f32(1<<29)

@(private)
Index_VQ_Entry :: struct {
    indices:Bits,
    ind_constraints:[2]Constraints, // index constraints of the blocks, all satisfied by indices
    distortion_sum:f32,
    count:u32,
    count_log2_count:u32,
    block_link:int, // blocks with these indices, -1 terminated
    merged_onto:int, // -1 if not merged
}

@(private)
Index_VQ_Heap_Entry :: struct {
    fm,to:i32,
    dj:f32, // positive is good
    fm_count_save:i32,
    fm_distortion_onto:f32,
}

@(private)
Index_VQ_Block :: struct {
    encoding_without_indices:Bits,
    link:int,
}

// A block's endpoints predecoded per texel, so that its SSD with other indices is the
// interpolation of the 16-bit kernels (what decoding the spliced bits and measuring would
// give): two texels per vector, the four channels before the rotation of modes 4 and 5, so
// that channel 3 always takes the scalar index.
@(private)
Merge_Table :: struct {
    diff:[8]V8s,    // lo-hi of the endpoints of each texel's subset
    base:[8]V8s,    // lo minus the texel
    ind_sel:u8,     // the vector lerp factors are the second of each pair (modes 4 and 5)
    eqv:u8,         // anchor class of the partition
    built:bool,
}

// The lerp factors of one set of indices for each texel t: [2t] those of the first index
// array and [2t+1] those of the second (or of the first again, in modes with one).
@(private)
Merge_Lerps :: [32]u8

@(private)
Merge_Ctx :: struct {
    mode:int,
    tables:[]Merge_Table, // by block
    lerps:[]Merge_Lerps,  // [class*num_entries+entry]
    class_built:[14]bool,
    entries:[]Index_VQ_Entry,
    ignore_alpha:bool,
}

@(private)
merge_table_build :: proc "contextless" (t:^Merge_Table,enc:Bits,target:^common.Color_Block,
    ignore_alpha:bool) {
    b:=transmute([16]u8)enc
    desc:bc67.Block_Raw_Desc
    if !bc67.bc7_analyze_block_raw(&desc,&b) {t^={}; t.built=true; return}
    m:=desc.mode
    ns:=int(m.ns)
    part:=bc67.partition_of(m.ns,u32(desc.partition_id))
    cs:=(int(desc.rot)-1)&3
    // raw channel feeding each output channel
    raw:[4]int
    for k in 0..<4 {
        raw[k]=k
        if k==cs {raw[k]=3} else if k==3 {raw[k]=cs}
    }
    diff,base:[16][4]i16
    for p in 0..<16 {
        s:=int((part.subset_mask>>uint(2*p))&3)
        tg:=target[p]
        for k in 0..<4 {
            r:=raw[k]
            lo:=i16(desc.endpoints_raw[r][2*s])
            hi:=i16(desc.endpoints_raw[r][2*s+1])
            if k==3 && ignore_alpha {lo,hi=255,255}
            diff[p][r]=lo-hi
            base[p][r]=lo-i16(tg[k])
        }
    }
    t.diff=transmute([8]V8s)diff
    t.base=transmute([8]V8s)base
    t.ind_sel=m.ib2!=0 ? desc.ind_sel&1 : 0
    t.eqv=ns>1 ? bc67.ANCHOR_EQV[ns-1][desc.partition_id&63] : 0
    t.built=true
}

// The indices of index bits for a partition with the given anchors.
@(private)
unpack_indices :: proc "contextless" (inds:Bits,mode:int,a1,a2:int) -> [2][16]u8 {
    m:=&bc67.BC7_MODES[mode&7]
    ns:=int(m.ns)
    v:=u128(inds[0])|(u128(inds[1])<<64)
    start:=uint(128-BITS_INDICES[mode&7])
    out:[2][16]u8
    insert0 :: #force_inline proc "contextless" (v:u64,pos:int) -> u64 {
        high:=~u64(0)<<uint(pos)
        return (v&~high)|((v&high)<<1)
    }
    ib:=int(m.ib)
    total0:=uint(ib*16-ns)
    f0:=u64((v>>start)&((u128(1)<<total0)-1))
    f0=insert0(f0,ib-1)
    if a1!=0 {f0=insert0(f0,a1*ib+ib-1)}
    if a2!=0 {f0=insert0(f0,a2*ib+ib-1)}
    mask:=(u64(1)<<uint(ib))-1
    for i in 0..<16 {out[0][i]=u8((f0>>uint(i*ib))&mask)}
    if m.ib2!=0 {
        ib2:=int(m.ib2)
        f1:=u64((v>>(start+total0))&((u128(1)<<uint(ib2*16-1))-1))
        f1=insert0(f1,ib2-1)
        mask2:=(u64(1)<<uint(ib2))-1
        for i in 0..<16 {out[1][i]=u8((f1>>uint(i*ib2))&mask2)}
    }
    return out
}

@(private)
merge_table :: #force_inline proc "contextless" (c:^Merge_Ctx,bi:int,blocks:[]Index_VQ_Block,
    infos:[]Block_Info) -> ^Merge_Table {
    t:=&c.tables[bi]
    if !t.built {merge_table_build(t,blocks[bi].encoding_without_indices,&infos[bi].colors,
        c.ignore_alpha)}
    return t
}

// The lerp factors of every entry for the anchors of t's partition class.
@(private)
merge_class_lerps :: proc "contextless" (c:^Merge_Ctx,t:^Merge_Table,bi:int,
    blocks:[]Index_VQ_Block) -> []Merge_Lerps {
    cls:=int(t.eqv)
    n:=len(c.entries)
    lerps:=c.lerps[cls*n:][:n]
    if !c.class_built[cls] {
        b:=transmute([16]u8)blocks[bi].encoding_without_indices
        m:=&bc67.BC7_MODES[c.mode]
        part:=bc67.partition_of(m.ns,u32(read_partition_id(&b,c.mode)))
        lv:=&LERP_NEG2X[m.ib]
        ls:=&LERP_NEG2X[m.ib2!=0 ? m.ib2 : m.ib]
        for e in 0..<n {
            u:=unpack_indices(c.entries[e].indices,c.mode,int(part.anchor0),int(part.anchor1))
            if m.ib2==0 {u[1]=u[0]}
            for p in 0..<16 {
                lerps[e][2*p]=u8(lv[u[0][p]&15])
                lerps[e][2*p+1]=u8(ls[u[1][p]&15])
            }
        }
        c.class_built[cls]=true
    }
    return lerps
}

// Byte shuffles that put the lerp factors of texels 2q and 2q+1 (of a group of eight) in the
// high bytes of their four channels, the scalar one in channel 3: [ind_sel][q].
@(rodata,private)
MERGE_SPREAD := [2][4][16]u8{
    {
        {255,0,255,0,255,0,255,1,255,2,255,2,255,2,255,3},
        {255,4,255,4,255,4,255,5,255,6,255,6,255,6,255,7},
        {255,8,255,8,255,8,255,9,255,10,255,10,255,10,255,11},
        {255,12,255,12,255,12,255,13,255,14,255,14,255,14,255,15},
    },
    {
        {255,1,255,1,255,1,255,0,255,3,255,3,255,3,255,2},
        {255,5,255,5,255,5,255,4,255,7,255,7,255,7,255,6},
        {255,9,255,9,255,9,255,8,255,11,255,11,255,11,255,10},
        {255,13,255,13,255,13,255,12,255,15,255,15,255,15,255,14},
    },
}

@(private)
merge_eval_128 :: #force_inline proc "contextless" (t:^Merge_Table,
    lerps:^Merge_Lerps) -> u32 #no_bounds_check {
    spread:=&MERGE_SPREAD[t.ind_sel&1]
    acc:V4i
    #unroll for h in 0..<2 {
        l:=intrinsics.unaligned_load((^V16b)(&lerps[h*16]))
        #unroll for q in 0..<4 {
            f:=transmute(V8s)simd.runtime_swizzle(l,intrinsics.unaligned_load((^V16b)(&spread[q])))
            e:=common.mulhrs_i16(f,t.diff[h*4+q])+t.base[h*4+q]
            acc+=common.madd_i16(e,e)
        }
    }
    return u32(simd.reduce_add_ordered(acc))
}

// The first of lerps[from:][:count] whose SSD is at most thresh: its position after from, or
// count when there is none; out_err gets the SSD.
@(private)
merge_find_next_128 :: #force_inline proc "contextless" (t:^Merge_Table,lerps:[]Merge_Lerps,
    from,count:int,thresh:u32,out_err:^u32) -> int #no_bounds_check {
    n:=min(count,len(lerps)-from)
    for i in 0..<n {
        e:=merge_eval_128(t,&lerps[from+i])
        if e<=thresh {out_err^=e; return i}
    }
    return count
}

@(private)
vq_heap_less :: proc(a,b:Index_VQ_Heap_Entry) -> bool {return a.dj<b.dj}
@(private)
vq_heap_greater :: proc(a,b:Index_VQ_Heap_Entry) -> bool {return b.dj<a.dj}
@(private)
vq_entry_less :: proc(a,b:Index_VQ_Entry) -> bool {return a.count>b.count}

// VQD estimate (2*SSD) of a block with new indices.
@(private)
single_block_index_change_distortion :: #force_inline proc "contextless" (bi:int,
    blocks:[]Index_VQ_Block,
    infos:[]Block_Info,new_indices:Bits,flags:Flags) -> f32 {
    encoding:=blocks[bi].encoding_without_indices|new_indices
    return f32(rd_ssd_bits(encoding,&infos[bi].colors,flags))*2.0
}

// The lerp factors of entry for the partition class of t.
@(private)
merge_entry_lerps :: #force_inline proc "contextless" (c:^Merge_Ctx,t:^Merge_Table,bi:int,
    blocks:[]Index_VQ_Block,entry:int) -> ^Merge_Lerps #no_bounds_check {
    cls:=int(t.eqv)
    if c.class_built[cls] {return &c.lerps[cls*len(c.entries)+entry]}
    return &merge_class_lerps(c,t,bi,blocks)[entry]
}

// VQD (2*SSD) of the blocks linked from bi with the indices of entry; LARGE_D once it is above
// must_beat_d.
@(private)
block_link_distortion_128 :: proc "contextless" (c:^Merge_Ctx,bi:int,blocks:[]Index_VQ_Block,
    infos:[]Block_Info,entry:int,must_beat_d:f32) -> f32 #no_bounds_check {
    d_sum:f32
    bi:=bi
    for bi>=0 {
        t:=merge_table(c,bi,blocks,infos)
        d_sum+=f32(merge_eval_128(t,merge_entry_lerps(c,t,bi,blocks,entry)))*2.0
        if d_sum>must_beat_d {return LARGE_D}
        bi=blocks[bi].link
    }
    return d_sum
}

@(private)
index_merge_dj :: proc "contextless" (from,to:^Index_VQ_Entry,d_diff,lambda:f32,
    index_bits:int) -> f32 {
    merged_count:=from.count+to.count
    log2one_merged:=merged_count*u32(entropy.log2tabled_bk_32(merged_count))
    log2one_delta:=from.count_log2_count+to.count_log2_count-log2one_merged
    rate_delta:=f32(log2one_delta)*(1.0/f32(entropy.LOG2TABLE_ONE))
    rate_delta+=f32(index_bits)
    return -d_diff+lambda*rate_delta
}

@(private)
is_legal_merge :: #force_inline proc "contextless" (fm,to:^Index_VQ_Entry) -> bool {
    return constraints_superset_of(to.ind_constraints[0],fm.ind_constraints[0]) &&
        constraints_superset_of(to.ind_constraints[1],fm.ind_constraints[1])
}

@(private)
push_heap_entry :: proc(heap:^[dynamic]Index_VQ_Heap_Entry,e:Index_VQ_Heap_Entry) -> bool {
    _,err:=append(heap,e)
    return err==nil
}

@(private)
make_heap_fm_singletons :: proc(c:^Merge_Ctx,heap:^[dynamic]Index_VQ_Heap_Entry,
    entries:[]Index_VQ_Entry,
    blocks:[]Index_VQ_Block,infos:[]Block_Info,mode:int,first_singleton:int,lambda:f32,
    index_bits_this_mode:int,max_distortion_increase:f32,flags:Flags) -> bool {
    entries_size:=len(entries)
    VQD_FROM_SSD :: f32(2.0)
    SSD_FROM_VQD :: f32(1.0/2.0)
    for fm in first_singleton..<entries_size {
        fm_base:=entries[fm].distortion_sum
        fm_bi:=entries[fm].block_link
        best_distortion:=fm_base+max_distortion_increase
        best_ssd:=u32(math.ceil(best_distortion*SSD_FROM_VQD))
        t:=merge_table(c,fm_bi,blocks,infos)
        lerps:=merge_class_lerps(c,t,fm_bi,blocks)
        for to:=0; to<entries_size; to+=1 {
            if fm==to {continue}
            max_count:=to<fm ? fm-to : entries_size-to
            ssd:u32
            skipped:=merge_find_next(t,lerps,to,max_count,best_ssd,&ssd)
            to+=skipped
            if skipped==max_count {continue}
            if ssd<=best_ssd {
                new_index_d:=VQD_FROM_SSD*f32(ssd)
                best_distortion=new_index_d
                best_ssd=ssd
                if is_legal_merge(&entries[fm],&entries[to]) {
                    delta_d:=new_index_d-fm_base
                    dj:=index_merge_dj(&entries[fm],&entries[to],delta_d,lambda,
                        index_bits_this_mode)
                    if dj>0 {
                        if !push_heap_entry(heap,{fm=i32(fm),to=i32(to),dj=dj,fm_count_save=1,
                            fm_distortion_onto=new_index_d}) {return false}
                    }
                }
            }
        }
    }
    return true
}

@(private)
test_shrink_vq_heap :: proc(heap:^[dynamic]Index_VQ_Heap_Entry,limit:int) {
    if len(heap)<limit {return}
    common.stdsort(heap[:],vq_heap_greater)
    resize(heap,limit/2)
}

@(private)
bottom_up_merge_indices :: proc(to_blocks:[]u8,activity:[]common.Float_Block,infos:[]Block_Info,
    lambda:f32,
    flags:Flags,allocator:runtime.Allocator) -> common.Error {
    nb:=len(infos)
    v_indices_pb:[8][dynamic]common.Bits128_And_Count
    for m in 0..<8 {v_indices_pb[m]=make([dynamic]common.Bits128_And_Count,allocator)}
    defer for m in 0..<8 {delete(v_indices_pb[m])}
    blocks,err:=make([]Index_VQ_Block,nb,allocator)
    if err!=nil {return .Out_Of_Memory}
    defer delete(blocks,allocator)
    for bi in 0..<nb {
        bits:=bits_load(block_bits_at(to_blocks,bi))
        mode:=bits_get_mode(bits)&7
        ind:=bits_extract_indices(bits,false)
        if _,e:=append(&v_indices_pb[mode],common.Bits128_And_Count{ind,
            u32(bi)}); e!=nil {return .Out_Of_Memory}
        blocks[bi].link=-1
        blocks[bi].encoding_without_indices=bits~ind
    }
    entries:=make([dynamic]Index_VQ_Entry,0,nb,allocator)
    if cap(entries)<nb {return .Out_Of_Memory}
    defer delete(entries)
    vq_heap_limit:=max(nb,64)*12
    heap:=make([dynamic]Index_VQ_Heap_Entry,0,vq_heap_limit,allocator)
    if cap(heap)<vq_heap_limit {return .Out_Of_Memory}
    defer delete(heap)
    best_distortions,err2:=make([]f32,nb,allocator)
    if err2!=nil {return .Out_Of_Memory}
    defer delete(best_distortions,allocator)
    ctx:Merge_Ctx
    ctx.ignore_alpha=flags&IGNORE_ALPHA!=0
    err3,err4:runtime.Allocator_Error
    ctx.tables,err3=make([]Merge_Table,nb,allocator)
    if err3!=nil {return .Out_Of_Memory}
    defer delete(ctx.tables,allocator)
    ctx.lerps,err4=make([]Merge_Lerps,14*nb,allocator)
    if err4!=nil {return .Out_Of_Memory}
    defer delete(ctx.lerps,allocator)
    for mode in 0..<8 {
        if len(v_indices_pb[mode])<=1 {continue}
        vs:=v_indices_pb[mode][:]
        common.sort_bits128_and_count_compare_bits(vs)
        clear(&entries)
        vcount:=len(vs)
        vbase:=0
        for vbase<vcount {
            indices:=vs[vbase].val
            append(&entries,Index_VQ_Entry{indices=indices,block_link=-1,merged_onto=-1})
            entry:=&entries[len(entries)-1]
            vi:=vbase
            for ; vi<vcount && indices==vs[vi].val; vi+=1 {
                bi:=int(vs[vi].count)
                if infos[bi].j==0 {continue}
                if !may_merge_indices(block_bits_at(to_blocks,bi),mode,&infos[bi],
                    &entry.ind_constraints) {
                    continue
                }
                d:=single_block_index_change_distortion(bi,blocks,infos,indices,flags)
                blocks[bi].link=entry.block_link
                entry.block_link=bi
                entry.count+=1
                entry.distortion_sum+=d
            }
            if entry.count==0 {
                pop(&entries)
            } else if entry.ind_constraints[0]!=0 || entry.ind_constraints[1]!=0 {
                st:Block_State
                state_from_bits(&st,block_bits_at(to_blocks,entry.block_link),flags)
                sst:=&st.subsets[0]
                sat0:=constraints_from_indices(&sst.idxs[0],mode==4 ? 3 : 2)
                sat1:=constraints_from_indices(&sst.idxs[1],2)
                if !constraints_superset_of(sat0,entry.ind_constraints[0]) ||
                    !constraints_superset_of(sat1,entry.ind_constraints[1]) {
                    pop(&entries)
                }
            }
            vbase=vi
        }
        num_entries:=len(entries)
        if num_entries<2 {continue}
        for &e in entries {e.count_log2_count=e.count*u32(entropy.log2tabled_bk_32(e.count))}
        index_bits_this_mode:=BITS_PBITS[mode]+BITS_INDICES[mode]
        max_distortion_increase:=f32(index_bits_this_mode)*lambda
        common.stdsort(entries[:],vq_entry_less)
        ctx.mode=mode
        ctx.entries=entries[:]
        ctx.class_built={}
        clear(&heap)
        entries_size:=num_entries
        first_singleton:=entries_size
        ENTRY_CHUNK :: 256
        for to_chunk_begin:=0; to_chunk_begin<entries_size; to_chunk_begin+=ENTRY_CHUNK {
            to_chunk_end:=min(to_chunk_begin+ENTRY_CHUNK,entries_size)
            fm:=0
            for ; fm<entries_size; fm+=1 {
                if entries[fm].count<=1 {break}
                fm_base:=entries[fm].distortion_sum
                best:=&best_distortions[fm]
                if to_chunk_begin==0 {best^=fm_base+max_distortion_increase}
                for to in to_chunk_begin..<to_chunk_end {
                    if fm==to {continue}
                    new_d:=block_link_distortion(&ctx,entries[fm].block_link,blocks,infos,to,best^)
                    if new_d<=best^ {
                        best^=new_d
                        if is_legal_merge(&entries[fm],&entries[to]) {
                            delta_d:=new_d-fm_base
                            dj:=index_merge_dj(&entries[fm],&entries[to],delta_d,lambda,
                                index_bits_this_mode)
                            if dj>0 {
                                test_shrink_vq_heap(&heap,vq_heap_limit)
                                if !push_heap_entry(&heap,{fm=i32(fm),to=i32(to),dj=dj,
                                    fm_count_save=i32(entries[fm].count),
                                    fm_distortion_onto=new_d}) {return .Out_Of_Memory}
                            }
                        }
                    }
                }
            }
            first_singleton=fm
        }
        if !make_heap_fm_singletons(&ctx,&heap,entries[:],blocks,infos,mode,first_singleton,lambda,
            index_bits_this_mode,max_distortion_increase,flags) {return .Out_Of_Memory}
        common.heap_make(heap[:],vq_heap_less)
        for len(heap)>0 {
            he:=heap[0]
            common.heap_popped(heap[:],vq_heap_less)
            pop(&heap)
            fm:=int(he.fm)
            if entries[fm].merged_onto>=0 {continue}
            dirty:=he.fm_count_save!=i32(entries[fm].count)
            to:=int(he.to)
            if entries[to].merged_onto>=0 {
                for {
                    to=entries[to].merged_onto
                    if entries[to].merged_onto<0 {break}
                }
                if to==fm {continue}
                dirty=true
            }
            if dirty {
                fm_base:=entries[fm].distortion_sum
                must_beat_d:=fm_base+max_distortion_increase
                new_d:=block_link_distortion(&ctx,entries[fm].block_link,blocks,infos,to,
                    must_beat_d)
                if new_d<LARGE_D && is_legal_merge(&entries[fm],&entries[to]) {
                    delta_d:=new_d-fm_base
                    dj:=index_merge_dj(&entries[fm],&entries[to],delta_d,lambda,
                        index_bits_this_mode)
                    if dj>0 {
                        test_shrink_vq_heap(&heap,vq_heap_limit)
                        if !push_heap_entry(&heap,{fm=i32(fm),to=i32(to),dj=dj,
                            fm_count_save=i32(entries[fm].count),
                            fm_distortion_onto=new_d}) {return .Out_Of_Memory}
                        common.heap_push(heap[:],vq_heap_less)
                    }
                }
                continue
            }
            entries[fm].merged_onto=to
            entries[to].count+=entries[fm].count
            to_count:=entries[to].count
            entries[to].count_log2_count=to_count*u32(entropy.log2tabled_bk_32(to_count))
            link:=entries[fm].block_link
            for blocks[link].link>=0 {link=blocks[link].link}
            blocks[link].link=entries[to].block_link
            entries[to].block_link=entries[fm].block_link
            entries[to].distortion_sum+=he.fm_distortion_onto
        }
        for &e in entries {
            if e.merged_onto>=0 {continue}
            new_indices:=e.indices
            bi:=e.block_link
            for bi>=0 {
                bits:=blocks[bi].encoding_without_indices|new_indices
                block:=block_bits_at(to_blocks,bi)
                prev:=bits_load(block)
                if bits!=prev {
                    bits_store(block,bits)
                    new_d:=rd_d_bits(bits,&infos[bi].colors,flags,&activity[bi])
                    delta_d:=new_d-infos[bi].d
                    infos[bi].d=new_d
                    infos[bi].j+=delta_d
                }
                bi=blocks[bi].link
            }
        }
    }
    return .None
}
