package entropy

import "base:intrinsics"
import "mirai:std/compressor"

// tANS: 5 states over two bit streams. Encode states are in [L,2L).

TANS_L_BITS_BITS :: 2

Tans_Encode_Entry :: struct {base:i32, max_state_thresh:u16, max_state_numbits:u16}

// The encode table of one normalization: state s of symbol c goes to packed[entries[c].base+s].
Tans_Encoder :: struct {
    L, L_bits, alphabet:i32,
    entries:[256]Tans_Encode_Entry,
    packed:[1<<compressor.TANS_L_BITS_MAX]u16,
}

ilog2round :: #force_inline proc "contextless" (v:u32) -> u32 {
    return ((transmute(u32)f32(v)+0x4AFB0C)>>23)-127
}

@(private="file", rodata)
LOG_ONE_PLUS_INV := [32]f32{
    0.000000, 0.693147, 0.405465, 0.287682, 0.223144, 0.182322, 0.154151, 0.133531,
    0.117783, 0.105361, 0.095310, 0.087011, 0.080043, 0.074108, 0.068993, 0.064539,
    0.060625, 0.057158, 0.054067, 0.051293, 0.048790, 0.046520, 0.044452, 0.042560,
    0.040822, 0.039221, 0.037740, 0.036368, 0.035091, 0.033902, 0.032790, 0.031749,
}

@(private="file", rodata)
LOG_ONE_MINUS_INV := [32]f32{
    0.000000, 0.000000, -0.693147, -0.405465, -0.287682, -0.223144, -0.182322, -0.154151,
    -0.133531, -0.117783, -0.105361, -0.095310, -0.087011, -0.080043, -0.074108, -0.068993,
    -0.064539, -0.060625, -0.057158, -0.054067, -0.051293, -0.048790, -0.046520, -0.044452,
    -0.042560, -0.040822, -0.039221, -0.037740, -0.036368, -0.035091, -0.033902, -0.032790,
}

@(private="file")
log_one_plus_inv :: proc "contextless" (i:u32) -> f32 {
    if i<32 {return LOG_ONE_PLUS_INV[i]}
    x:=1.0/f32(i)
    return x-x*x*0.5
}

@(private="file")
log_one_minus_inv :: proc "contextless" (i:u32) -> f32 {
    if i<32 {return LOG_ONE_MINUS_INV[i]}
    x:=1.0/f32(i)
    return -x-x*x*0.5
}

@(private="file") Sort_Sym :: struct {sym:i32, rank:f32}

@(private="file")
sort_sym_less :: proc "contextless" (a,b:Sort_Sym) -> bool {return a.rank<b.rank}

// Scales from[:alphabet] (summing to from_sum) to counts summing to to_sum_desired, keeping
// nonzero counts nonzero. Returns the number of nonzero counts.
normalize_counts_v6 :: proc "contextless" (to:[]u32, to_sum_desired:int, from:[]u32,
    from_sum:int, alphabet:int) -> int #no_bounds_check {
    alphabet:=min(alphabet,len(to),len(from),256)
    num_non_zero:=0
    to_sum:u32=0
    scale:=f64(to_sum_desired)/f64(from_sum)
    for i in 0..<alphabet {
        if from[i]==0 {to[i]=0;continue}
        fs:=f64(from[i])*scale
        down:=u32(fs)
        to[i]=down+(fs*fs>f64(down*(down+1)) ? 1 : 0)
        to_sum+=to[i]
        num_non_zero+=1
    }
    correction:=i32(to_sum_desired)-i32(to_sum)
    if correction==0 {return num_non_zero}
    storage:[257]Sort_Sym
    hs:=0
    if correction>0 {
        for i in 0..<alphabet {
            if from[i]==0 {continue}
            storage[hs]=Sort_Sym{i32(i),log_one_plus_inv(to[i])*f32(from[i])}
            hs+=1
        }
    } else {
        for i in 0..<alphabet {
            if from[i]==0 {continue}
            if to[i]>1 {
                storage[hs]=Sort_Sym{i32(i),log_one_minus_inv(to[i])*f32(from[i])}
                hs+=1
            }
        }
    }
    heap_make(storage[:hs],sort_sym_less)
    if correction>0 {
        for correction!=0 {
            if hs<=0 {break}
            ss:=storage[0]
            heap_popped(storage[:hs],sort_sym_less)
            hs-=1
            i:=ss.sym
            to[i]+=1
            correction-=1
            storage[hs]=Sort_Sym{i,log_one_plus_inv(to[i])*f32(from[i])}
            hs+=1
            heap_push(storage[:hs],sort_sym_less)
        }
    } else {
        for correction!=0 {
            if hs<=0 {break}
            ss:=storage[0]
            heap_popped(storage[:hs],sort_sym_less)
            hs-=1
            i:=ss.sym
            to[i]-=1
            correction+=1
            if to[i]>1 {
                storage[hs]=Sort_Sym{i,log_one_minus_inv(to[i])*f32(from[i])}
                hs+=1
                heap_push(storage[:hs],sort_sym_less)
            }
        }
    }
    return num_non_zero
}

@(private="file") BUCKET_BITS :: 2
@(private="file") BUCKET_SIZE :: 1<<BUCKET_BITS
@(private="file") BUCKET_MASK :: BUCKET_SIZE-1

// counts[:alphabet] sum to 1<<L_bits.
tans_encoder_fill :: proc "contextless" (t:^Tans_Encoder, L_bits:int, counts:[]u32,
    alphabet:int) #no_bounds_check {
    alphabet:=min(alphabet,len(counts),256)
    for alphabet>0 && counts[alphabet-1]==0 {alphabet-=1}
    L:=1<<uint(L_bits)
    t.L=i32(L);t.L_bits=i32(L_bits);t.alphabet=i32(alphabet)
    if alphabet==0 {return}
    if counts[alphabet-1]==u32(L) {
        e:=&t.entries[alphabet-1]
        e^=Tans_Encode_Entry{base=-i32(L),max_state_thresh=u16(2*L),max_state_numbits=0}
        for s in L..<2*L {t.packed[s-L]=u16(s)}
        return
    }
    num_singletons:=0
    for s in 0..<alphabet {if counts[s]==1 {num_singletons+=1}}
    bucket_start:[BUCKET_SIZE]u32
    bucket_total:=u32(L-num_singletons)
    even:=bucket_total>>BUCKET_BITS
    rem:=bucket_total&BUCKET_MASK
    cum:u32=0
    for r in 0..<BUCKET_SIZE {
        bucket_start[r]=cum
        cum+=even
        if u32(r)<rem {cum+=1}
    }
    singleton_next:=bucket_total
    cumulative:=0
    for s in 0..<alphabet {
        count:=counts[s]
        if count==0 {
            t.entries[s]={}
        } else if count==1 {
            t.entries[s]=Tans_Encode_Entry{base=i32(singleton_next)-1,max_state_thresh=u16(2*L),
                max_state_numbits=u16(L_bits)}
            t.packed[singleton_next&(1<<compressor.TANS_L_BITS_MAX-1)]=u16(u32(L)+singleton_next)
            singleton_next+=1
        } else {
            num_bits:=u32(L_bits)-ilog2ceil(count)
            t.entries[s]=Tans_Encode_Entry{base=i32(cumulative)-i32(count),
                max_state_thresh=u16((count+count)<<num_bits),max_state_numbits=u16(num_bits)}
            p:=cumulative
            for r in 0..<BUCKET_SIZE {
                run_len:=(int(count)+((cumulative+BUCKET_MASK-r)&BUCKET_MASK))>>BUCKET_BITS
                to:=bucket_start[r]
                for _ in 0..<run_len {
                    t.packed[p&(1<<compressor.TANS_L_BITS_MAX-1)]=u16(u32(L)+to)
                    p+=1
                    to+=1
                }
                bucket_start[r]+=u32(run_len)
            }
            cumulative+=int(count)
        }
    }
}

@(private="file") NUM_NON_ZERO_PC4 :: 7
@(private="file") NUM_NON_ZERO_BITS :: 3

@(private="file")
pack_counts4 :: proc "contextless" (vb:^Var_Bits, L_bits:int, counts:[]u32, alphabet:int,
    num_non_zero:int) #no_bounds_check {
    varbits_output(vb)
    varbits_put(vb,u64(num_non_zero-2),NUM_NON_ZERO_BITS)
    got:[NUM_NON_ZERO_PC4]u32
    n:=0
    for s in 0..<alphabet {
        if counts[s]==0 {continue}
        if n>=NUM_NON_ZERO_PC4 {break}
        got[n]=(counts[s]<<16)|u32(s)
        n+=1
    }
    for i in 1..<n {
        v:=got[i]
        p:=i
        for p>0 && v<got[p-1] {got[p]=got[p-1];p-=1}
        got[p]=v
    }
    icount:=num_non_zero-1
    max_delta_bits:u32=0
    prev:u32=0
    for i in 0..<icount {
        cur:=got[i]>>16
        delta:=cur-prev
        prev=cur
        max_delta_bits=max(max_delta_bits,bit_level(delta))
    }
    if max_delta_bits==0 {max_delta_bits=1}
    varbits_put(vb,u64(max_delta_bits),int(bit_level(u32(L_bits))))
    prev=0
    for i in 0..<icount {
        cur:=got[i]>>16
        delta:=cur-prev
        prev=cur
        varbits_output(vb)
        varbits_put(vb,u64(got[i]&0xff),8)
        varbits_put(vb,u64(delta)&((u64(1)<<max_delta_bits)-1),int(max_delta_bits))
    }
    varbits_output(vb)
    varbits_put(vb,u64(got[num_non_zero-1]&0xff),8)
}

@(private="file")
fold_delta_clamped :: #force_inline proc "contextless" (val,pred:i32) -> u32 {
    if val<=pred*2 {return fold_up_negatives(val-pred)}
    return u32(val)
}

@(private="file")
pack_counts_count_delta :: proc "contextless" (vb:^Var_Bits, L_bits:int, counts:[]u32,
    alphabet:int, num_non_zero:int) #no_bounds_check {
    HISTO_DELTA_COUNT :: 128
    histo_deltas:[HISTO_DELTA_COUNT]u32
    over:[256]u32
    num_over:=0
    deltas:[256]u32
    num_deltas:=0
    run_lens:[260]i32
    sym:=0
    got:=0
    rc:=1
    for sym<alphabet && counts[sym]==0 {sym+=1}
    run_lens[0]=i32(sym)
    pred_state:i32=1*4+2
    for sym<alphabet {
        base:=sym
        for sym<alphabet && counts[sym]!=0 {
            c:=i32(counts[sym])-1
            pred:=pred_state>>2
            d:=fold_delta_clamped(c,pred)
            deltas[num_deltas]=d;num_deltas+=1
            if d<HISTO_DELTA_COUNT {histo_deltas[d]+=1} else {over[num_over]=d;num_over+=1}
            pred_state=pred_state-pred+min(c,pred*2)
            got+=1
            sym+=1
        }
        run_lens[rc]=i32(sym-base);rc+=1
        base=sym
        for sym<alphabet && counts[sym]==0 {sym+=1}
        run_lens[rc]=i32(sym-base);rc+=1
    }
    run_lens[rc-1]=run_lens[rc-1]+256-i32(sym)
    varbits_output(vb)
    k_best:=1
    {
        best:=max(i32)
        for k in 0..<8 {
            h:i32=0
            for c,i in histo_deltas {
                if c>0 {h+=i32(c)*i32(count_bits_exp_golomb(u32(i),u32(k)))}
            }
            for i in 0..<num_over {h+=i32(count_bits_exp_golomb(over[i],u32(k)))}
            if h<best {best=h;k_best=k}
        }
        varbits_put(vb,u64(k_best),3)
    }
    runlen_top,runlen_bot,runlen_bot_nbits:[256]u8
    num_eg:=encode_alphabet_shape_runlens_split(runlen_top[:],runlen_bot[:],runlen_bot_nbits[:],
        got,run_lens[:],rc)
    varbits_put(vb,u64(got-1),8)
    varbits_output(vb)
    encode_alphabet_shape_num_eg(vb,num_eg,got)
    delta_top:[256]u8
    eg_bias:=u32(1)<<uint(k_best)
    for i in 0..<num_deltas {
        val:=deltas[i]+eg_bias
        prefix:=31-u32(intrinsics.count_leading_zeros(val>>uint(k_best)))
        num_bottom:=prefix+u32(k_best)
        delta_top[i]=u8(prefix)
        deltas[i]=val&((u32(1)<<num_bottom)-1)
    }
    encode_unary_block(vb,delta_top[:num_deltas])
    encode_unary_block(vb,runlen_top[:num_eg])
    encode_variable_u8_block(vb,runlen_bot[:num_eg],runlen_bot_nbits[:num_eg])
    for i in 0..<num_deltas {
        nbits:=int(delta_top[i])+k_best
        if nbits==0 {continue}
        varbits_output(vb)
        varbits_put(vb,u64(deltas[i]),nbits)
    }
    varbits_output(vb)
}

tans_pack_counts :: proc "contextless" (vb:^Var_Bits, L_bits:int, counts:[]u32, alphabet:int,
    num_non_zero:int) {
    varbits_output(vb)
    if num_non_zero<=NUM_NON_ZERO_PC4 {
        varbits_put(vb,0,1)
        pack_counts4(vb,L_bits,counts,alphabet,num_non_zero)
    } else {
        varbits_put(vb,1,1)
        pack_counts_count_delta(vb,L_bits,counts,alphabet,num_non_zero)
    }
    varbits_output(vb)
}

// TANS payload of from at to, without the 5-byte array header; written only when its J beats
// *pJ. histogram is the histogram of from.
put_array_tans :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, lambda:f32,
    pJ:^f32, arena:^Arena) -> int #no_bounds_check {
    if len(from)<compressor.HUFF_ARRAY_MIN_SIZE {return -1}
    prevJ:=pJ^
    from_len:=len(from)-5
    histo:=histogram^
    for k in 0..<5 {histo[from[from_len+k]]-=1}
    L_bits:=int(ilog2round(u32(from_len)))-2
    L_bits=clamp(L_bits,compressor.TANS_L_BITS_MIN,compressor.TANS_L_BITS_MAX)
    normc_sum:=1<<uint(L_bits)
    alphabet:=256
    for alphabet>0 && histo[alphabet-1]==0 {alphabet-=1}
    normc:[256]u32
    num_non_zero:=normalize_counts_v6(normc[:],normc_sum,histo[:],from_len,alphabet)
    if num_non_zero<=1 {return -1}
    J_add:=5+lambda*speedfit_tans(from_len,num_non_zero,normc_sum)
    must_be_under:=int(prevJ-J_add)
    if must_be_under<4 {return -1}
    header:[512]u8
    vb:Var_Bits
    varbits_open(&vb,raw_data(header[:]),raw_data(header[:])[len(header):])
    varbits_put(&vb,0,1)
    varbits_put(&vb,u64(L_bits-compressor.TANS_L_BITS_MIN),TANS_L_BITS_BITS)
    tans_pack_counts(&vb,L_bits,normc[:],alphabet,num_non_zero)
    varbits_put_flush8(&vb)
    header_size:=varbits_put_size_bytes(&vb,raw_data(header[:]))
    H:i64=0
    for i in 0..<alphabet {
        c:=normc[i]
        if c>0 {H+=i64(histogram[i])*i64(log2tabled(c<<uint(13-L_bits),13))}
    }
    H>>=LOG2TABLE_ONE_SHIFT+3
    if i64(header_size)+H>=i64(must_be_under) {return -1}
    enc:=arena_alloc(arena,Tans_Encoder,1)
    if enc==nil {return -1}
    defer arena_free(arena,enc)
    E:=&enc[0]
    tans_encoder_fill(E,L_bits,normc[:],alphabet)
    eet:=&E.entries
    packed:=&E.packed
    L:=u64(1)<<uint(L_bits)
    src:=raw_data(from)
    MASK :: 1<<compressor.TANS_L_BITS_MAX-1
    count1 :: #force_inline proc "contextless" (eet:^[256]Tans_Encode_Entry,
        packed:^[1<<compressor.TANS_L_BITS_MAX]u16, x:^u64, bitcnt:^int, sym:u8) {
        e:=&eet[sym]
        nb:=uint(e.max_state_numbits)+(x^>=u64(e.max_state_thresh) ? 1 : 0)
        x^=u64(packed[(int(e.base)+int(x^>>nb))&MASK])
        bitcnt^+=int(nb)
    }
    x:[5]u64
    for k in 0..<5 {x[k]=L|u64(src[from_len+k])}
    b1,b2:=0,0
    ntens:=from_len/10
    tail:=from_len%10
    bp:=from_len-1
    switch tail {
    case 9: count1(eet,packed,&x[3],&b2,src[bp]);bp-=1;fallthrough
    case 8: count1(eet,packed,&x[2],&b2,src[bp]);bp-=1;fallthrough
    case 7: count1(eet,packed,&x[1],&b2,src[bp]);bp-=1;fallthrough
    case 6: count1(eet,packed,&x[0],&b2,src[bp]);bp-=1;fallthrough
    case 5: count1(eet,packed,&x[4],&b1,src[bp]);bp-=1;fallthrough
    case 4: count1(eet,packed,&x[3],&b1,src[bp]);bp-=1;fallthrough
    case 3: count1(eet,packed,&x[2],&b1,src[bp]);bp-=1;fallthrough
    case 2: count1(eet,packed,&x[1],&b1,src[bp]);bp-=1;fallthrough
    case 1: count1(eet,packed,&x[0],&b1,src[bp]);bp-=1
    }
    for _ in 0..<ntens {
        count1(eet,packed,&x[4],&b2,src[bp]);count1(eet,packed,&x[3],&b2,src[bp-1])
        count1(eet,packed,&x[2],&b2,src[bp-2]);count1(eet,packed,&x[1],&b2,src[bp-3])
        count1(eet,packed,&x[0],&b2,src[bp-4]);count1(eet,packed,&x[4],&b1,src[bp-5])
        count1(eet,packed,&x[3],&b1,src[bp-6]);count1(eet,packed,&x[2],&b1,src[bp-7])
        count1(eet,packed,&x[1],&b1,src[bp-8]);count1(eet,packed,&x[0],&b1,src[bp-9])
        bp-=10
    }
    b1+=3*L_bits
    b2+=2*L_bits
    tail1:=b1&7
    tail2:=b2&7
    complen_estimate:=header_size+(b1+7)/8+(b2+7)/8
    if complen_estimate>=must_be_under {return -1}
    tans_J:=f32(complen_estimate)+J_add
    if tans_J>=prevJ {return -1}
    if complen_estimate+8>ptr_diff(to_end,to) {return -1}
    copy_bytes(to,raw_data(header[:]),header_size)
    to_ptr:=to[header_size:]
    for k in 0..<5 {x[k]=L|u64(src[from_len+k])}
    bp=from_len-1
    v1,v2:Var_Bits
    varbits_open(&v1,to_end,to_ptr)
    varbits_open(&v2,to_ptr,to_end)
    put1 :: #force_inline proc "contextless" (eet:^[256]Tans_Encode_Entry,
        packed:^[1<<compressor.TANS_L_BITS_MAX]u16, x:^u64, vb:^Var_Bits, sym:u8) {
        e:=&eet[sym]
        nb:=uint(e.max_state_numbits)+(x^>=u64(e.max_state_thresh) ? 1 : 0)
        varbits_put(vb,x^&((u64(1)<<nb)-1),int(nb))
        x^=u64(packed[(int(e.base)+int(x^>>nb))&MASK])
    }
    if tail1!=0 {varbits_put(&v1,0,8-tail1)}
    if tail2!=0 {varbits_put(&v2,0,8-tail2)}
    switch tail {
    case 9: put1(eet,packed,&x[3],&v2,src[bp]);bp-=1;fallthrough
    case 8: put1(eet,packed,&x[2],&v2,src[bp]);bp-=1;fallthrough
    case 7: put1(eet,packed,&x[1],&v2,src[bp]);bp-=1;fallthrough
    case 6: put1(eet,packed,&x[0],&v2,src[bp]);bp-=1;fallthrough
    case 5: put1(eet,packed,&x[4],&v1,src[bp]);bp-=1;fallthrough
    case 4: put1(eet,packed,&x[3],&v1,src[bp]);bp-=1;fallthrough
    case 3: put1(eet,packed,&x[2],&v1,src[bp]);bp-=1;fallthrough
    case 2: put1(eet,packed,&x[1],&v1,src[bp]);bp-=1;fallthrough
    case 1: put1(eet,packed,&x[0],&v1,src[bp]);bp-=1
    }
    varbits_output(&v2)
    varbits_output_back(&v1)
    for _ in 0..<ntens {
        put1(eet,packed,&x[4],&v2,src[bp]);put1(eet,packed,&x[3],&v2,src[bp-1])
        put1(eet,packed,&x[2],&v2,src[bp-2]);put1(eet,packed,&x[1],&v2,src[bp-3])
        put1(eet,packed,&x[0],&v2,src[bp-4])
        varbits_output(&v2)
        put1(eet,packed,&x[4],&v1,src[bp-5]);put1(eet,packed,&x[3],&v1,src[bp-6])
        put1(eet,packed,&x[2],&v1,src[bp-7]);put1(eet,packed,&x[1],&v1,src[bp-8])
        put1(eet,packed,&x[0],&v1,src[bp-9])
        varbits_output_back(&v1)
        bp-=10
    }
    lmask:=(u64(1)<<uint(L_bits))-1
    varbits_put(&v1,x[4]&lmask,L_bits)
    varbits_put(&v2,x[3]&lmask,L_bits)
    varbits_put(&v1,x[2]&lmask,L_bits)
    varbits_put(&v2,x[1]&lmask,L_bits)
    varbits_put(&v1,x[0]&lmask,L_bits)
    varbits_output_back(&v1)
    varbits_output(&v2)
    len1:=ptr_diff(to_end,v1.cur)
    len2:=ptr_diff(v2.cur,to_ptr)
    if len1+len2+header_size!=complen_estimate || ptr_diff(v1.cur,v2.cur)<0 {return -1}
    tmp:=arena_alloc(arena,u8,len1)
    if tmp==nil && len1>0 {return -1}
    copy_bytes(raw_data(tmp),v1.cur,len1)
    copy_bytes(to_ptr[len1:],to_ptr,len2)
    copy_bytes(to_ptr,raw_data(tmp),len1)
    arena_free(arena,tmp)
    pJ^=tans_J
    return header_size+len1+len2
}
