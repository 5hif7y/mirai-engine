package entropy

import "base:intrinsics"
import "mirai:std/compressor"

// Huffman arrays. huff3 splits the data into three LSB-first streams laid out as
// strm0-> | strm2-> | <-strm1 (strm1 byte-reversed), symbols interleaved 0,1,2,0,1,2...;
// huff6 is two huff3 halves, the first preceded by its 3-byte size.

// Bit reversal of an 11-bit value.
@(private="file")
bitreverse11 :: #force_inline proc "contextless" (x:u32) -> u32 {
    return intrinsics.reverse_bits(x)>>(32-compressor.HUFF_CODELEN_LIMIT)
}

encode_uniform_u8_block :: proc "contextless" (vb:^Var_Bits, values:[]u8, bits_per_val:int) {
    if bits_per_val==0 {return}
    varbits_output(vb)
    for v in values {
        varbits_put(vb,u64(v),bits_per_val)
        varbits_output(vb)
    }
}

encode_variable_u8_block :: proc "contextless" (vb:^Var_Bits, values:[]u8,
    nbits:[]u8) #no_bounds_check {
    varbits_output(vb)
    for i in 0..<min(len(values),len(nbits)) {
        varbits_put(vb,u64(values[i]),int(nbits[i]))
        varbits_output(vb)
    }
}

encode_unary_block :: proc "contextless" (vb:^Var_Bits, values:[]u8) {
    varbits_output(vb)
    for v in values {
        code:=u32(v)
        for code>=24 {
            varbits_put(vb,0,24)
            varbits_output(vb)
            code-=24
        }
        varbits_put(vb,1,int(code)+1)
        varbits_output(vb)
    }
}

encode_rice_u8_split :: proc "contextless" (top,bottom:[]u8, values:[]u8,
    rice_k:int) #no_bounds_check {
    mask:=u8((u32(1)<<uint(rice_k))-1)
    for v,i in values {
        top[i]=v>>uint(rice_k)
        bottom[i]=v&mask
    }
}

// run_lens: initial zero run, then pairs of (nonzero run, zero run). Returns the number of
// Exp-Golomb codes written to top/bot/bot_nbits.
encode_alphabet_shape_runlens_split :: proc "contextless" (top,bot,bot_nbits:[]u8, num_syms:int,
    run_lens:[]i32, run_count:int) -> int #no_bounds_check {
    if num_syms>=256 {return 0}
    num_pairs:=(run_count-3)/2
    initial_zero_run:=run_lens[0]!=0 ? 1 : 0
    num_egs:=num_pairs*2+initial_zero_run
    begin:=1-initial_zero_run
    for j in 0..<num_egs {
        i:=j+begin
        k:=u32((i&1)!=0 ? 0 : 1)
        val:=u32(run_lens[i])-1+(u32(1)<<k)
        main_bits:=val>>k
        prefix:=31-u32(intrinsics.count_leading_zeros(main_bits))
        num_bottom:=prefix+k
        top[j]=u8(prefix)
        bot[j]=u8(val&((u32(1)<<num_bottom)-1))
        bot_nbits[j]=u8(num_bottom)
    }
    return num_egs
}

encode_alphabet_shape_num_eg :: proc "contextless" (vb:^Var_Bits, num_eg:int, num_syms:int) {
    if num_syms==256 {return}
    bound:=min(num_syms,257-num_syms)*2
    nbits:=32-int(intrinsics.count_leading_zeros(u32(bound-1)))
    large:=(1<<uint(nbits))-bound
    if num_eg<large {
        varbits_put(vb,u64(num_eg),nbits-1)
    } else {
        varbits_put(vb,u64(num_eg+large),nbits)
    }
    varbits_output(vb)
}

// Initial zero run, then (nonzero run, zero run) pairs of the code lens; returns the count.
@(private="file")
identify_alphabet_runs :: proc "contextless" (h:^Huffman, run_lens:[]i32,
    num_symbols:int) -> int #no_bounds_check {
    sym:=0
    for sym<num_symbols && h.code_len_table[sym]==0 {sym+=1}
    run_lens[0]=i32(sym)
    rc:=1
    for sym<num_symbols {
        base:=sym
        for sym<num_symbols && h.code_len_table[sym]>0 {sym+=1}
        run_lens[rc]=i32(sym-base);rc+=1
        base=sym
        for sym<num_symbols && h.code_len_table[sym]==0 {sym+=1}
        run_lens[rc]=i32(sym-base);rc+=1
    }
    return rc
}

@(private="file")
encode_hufflens2 :: proc "contextless" (h:^Huffman, vb:^Var_Bits, run_lens:[]i32,
    run_count:int) #no_bounds_check {
    MAX_FOLDED :: (compressor.HUFF_CODELEN_LIMIT-1)*2
    num_delta:[MAX_FOLDED+1]i32
    delta_folded:[256]u8
    prev4:=8*4
    got:=0
    sym:=int(run_lens[0])
    for pair:=1;pair<run_count;pair+=2 {
        end:=sym+int(run_lens[pair])
        for sym<end {
            cl:=int(h.code_len_table[sym])
            pred:=(prev4+2)>>2
            delta:=cl-pred
            f:=fold_up_negatives(i32(delta))
            num_delta[min(f,MAX_FOLDED)]+=1
            prev4+=delta
            delta_folded[got]=u8(f)
            got+=1
            sym+=1
        }
        sym+=int(run_lens[pair+1])
    }
    varbits_output(vb)
    rice_bits:=1
    {
        best:=f64(99999999999.0)
        for cur in 0..<4 {
            e:=f64(entropy_of_counts_rice(num_delta[:],cur))
            if e<best {best=e;rice_bits=cur}
        }
    }
    varbits_put(vb,u64(rice_bits),2)
    runlen_top,runlen_bot,runlen_bot_nbits:[256]u8
    num_eg:=encode_alphabet_shape_runlens_split(runlen_top[:],runlen_bot[:],runlen_bot_nbits[:],
        got,run_lens,run_count)
    varbits_put(vb,u64(got-1),8)
    encode_alphabet_shape_num_eg(vb,num_eg,got)
    varbits_output(vb)
    codelen_top,codelen_bot:[256]u8
    encode_rice_u8_split(codelen_top[:],codelen_bot[:],delta_folded[:got],rice_bits)
    encode_unary_block(vb,codelen_top[:got])
    encode_unary_block(vb,runlen_top[:num_eg])
    encode_uniform_u8_block(vb,codelen_bot[:got],rice_bits)
    encode_variable_u8_block(vb,runlen_bot[:num_eg],runlen_bot_nbits[:num_eg])
}

// One huff3 block: 2-byte LE size of strm0, strm0, strm2, strm1. to_ptr_end bounds the
// backward stream; returns the size or -1 when the streams do not fit.
@(private="file")
put_array_huff3streams :: proc(to:[^]u8, to_ptr_end:[^]u8, from:[]u8, codelens:^[260]u8,
    le_codes:^[257]u64, arena:^Arena) -> int #no_bounds_check {
    from_len:=len(from)
    room:=ptr_diff(to_ptr_end,to)-2
    if room<4 {return -1}
    max_stream:=(from_len*11+23)/(8*3)+1+8
    // strm1 and strm2 are built forward in scratch; strm1 is reversed into place.
    scratch:=arena_alloc(arena,u8,2*max_stream)
    if scratch==nil {return -1}
    defer arena_free(arena,scratch)
    s1:=to[2:]
    s2:=raw_data(scratch)
    s3:=s2[max_stream:]
    lim1:=min(room,max_stream)
    b1,b2,b3:u64
    c1,c2,c3:uint
    n1,n2,n3:int
    sym:=raw_data(from)
    i:=0
    for ;i+6<=from_len;i+=6 {
        s:=sym[i]
        b1|=le_codes[s]<<c1;c1+=uint(codelens[s])
        s=sym[i+1]
        b2|=le_codes[s]<<c2;c2+=uint(codelens[s])
        s=sym[i+2]
        b3|=le_codes[s]<<c3;c3+=uint(codelens[s])
        s=sym[i+3]
        b1|=le_codes[s]<<c1;c1+=uint(codelens[s])
        s=sym[i+4]
        b2|=le_codes[s]<<c2;c2+=uint(codelens[s])
        s=sym[i+5]
        b3|=le_codes[s]<<c3;c3+=uint(codelens[s])
        if c1>=32 {
            if n1+4>lim1 {return -1}
            intrinsics.unaligned_store((^u32le)(&s1[n1]),u32le(b1));n1+=4;b1>>=32;c1-=32
        }
        if c2>=32 {
            if n2+4>max_stream {return -1}
            intrinsics.unaligned_store((^u32le)(&s2[n2]),u32le(b2));n2+=4;b2>>=32;c2-=32
        }
        if c3>=32 {
            if n3+4>max_stream {return -1}
            intrinsics.unaligned_store((^u32le)(&s3[n3]),u32le(b3));n3+=4;b3>>=32;c3-=32
        }
    }
    for k:=0;i<from_len;i,k=i+1,k+1 {
        s:=sym[i]
        switch k%3 {
        case 0: b1|=le_codes[s]<<c1;c1+=uint(codelens[s])
        case 1: b2|=le_codes[s]<<c2;c2+=uint(codelens[s])
        case 2: b3|=le_codes[s]<<c3;c3+=uint(codelens[s])
        }
    }
    for c1>0 {if n1>=lim1 {return -1};s1[n1]=u8(b1);n1+=1;b1>>=8;c1-=min(c1,8)}
    for c2>0 {if n2>=max_stream {return -1};s2[n2]=u8(b2);n2+=1;b2>>=8;c2-=min(c2,8)}
    for c3>0 {if n3>=max_stream {return -1};s3[n3]=u8(b3);n3+=1;b3>>=8;c3-=min(c3,8)}
    tot:=n1+n2+n3+2
    if tot>ptr_diff(to_ptr_end,to) || n1>=0xFFFF {return -1}
    to[0]=u8(n1);to[1]=u8(n1>>8)
    p:=s1[n1:]
    copy_bytes(p,s3,n3)
    p=p[n3:]
    for k in 0..<n2 {p[k]=s2[n2-1-k]}
    return tot
}

// Huffman (huff3 or huff6) payload of from at to, without the 5-byte array header. Writes only
// when its J (header included) beats *pJ; then sets *pJ and *p_huff_type and returns the payload
// size. -1 otherwise.
put_array_huff :: proc(to:[^]u8, to_end:[^]u8, from:[]u8, histogram:^[256]u32, lambda:f32, pJ:^f32,
    deadline_t:f32, p_huff_type:^u32, entropy_flags:u32, arena:^Arena,
    compression_level:int) -> int #no_bounds_check {
    from_len:=len(from)
    if from_len==0 {return -1}
    H:Huffman
    huffman_init(&H,256)
    if !huffman_build_code_lens(&H,histogram[:],u32(from_len),compressor.HUFF_CODELEN_LIMIT,arena,
        compression_level>=6) {return -1}
    nonzero_alphabet:=int(H.top_sym)+1
    num_non_zero:=int(H.got_num_symbols)
    if num_non_zero<2 {
        if ptr_diff(to_end,to)<3 {return -1}
        huff_J:=5+3+lambda*speedfit_memcpy(from_len)
        if huff_J>=pJ^ {return -1}
        put_array_huff3_memset_payload(to,from[0])
        p_huff_type^=compressor.ARRAY_TYPE_HUFF
        pJ^=huff_J
        return 3
    }
    run_lens:[260]i32
    run_count:=0
    num_alphabet_runs:=0
    est_bits:=int(code_len_of_histogram256(histogram[:],H.code_len_table[:],nonzero_alphabet))
    expected_bpb:=f32(est_bits)/f32(from_len)
    HUFF6_EXTRA_BYTES :: f32(5.0+3*3.5/8.0)
    huff_type:=u32(compressor.ARRAY_TYPE_HUFF)
    if entropy_flags&ARRAY_FLAG_ALLOW_HUFF6!=0 {
        t:=speedfit_huff6(from_len,num_non_zero,num_alphabet_runs,expected_bpb)-
            speedfit_huff3(from_len,num_non_zero,num_alphabet_runs,expected_bpb)
        if HUFF6_EXTRA_BYTES+lambda*t<0 {huff_type=compressor.ARRAY_TYPE_HUFF6}
    }
    p_huff_type^=huff_type
    huff_time:=speedfit_huff_time(huff_type,from_len,num_non_zero,num_alphabet_runs,expected_bpb)
    huff_J_add:=5+lambda*huff_time
    if huff_time>deadline_t {return -1}
    est:=(est_bits+7)/8+13
    min_header_size:=(num_non_zero*2+8+7)/8
    if f32(est)+huff_J_add+f32(min_header_size)>=pJ^ {return -1}
    run_count=identify_alphabet_runs(&H,run_lens[:],256)
    header:[256]u8
    vb:Var_Bits
    varbits_open(&vb,raw_data(header[:]),raw_data(header[:])[len(header):])
    if H.got_num_symbols>4 && entropy_flags&ARRAY_FLAG_ALLOW_HUFFLENS2!=0 {
        varbits_put(&vb,1,1)
        varbits_put(&vb,0,1)
        encode_hufflens2(&H,&vb,run_lens[:],run_count)
    } else {
        varbits_put(&vb,0,1)
        huffman_pack_code_lens(&H,&vb)
    }
    varbits_put_flush8(&vb)
    header_size:=varbits_put_size_bytes(&vb,raw_data(header[:]))
    if header_size+16>=len(header) {return -1}
    est+=header_size
    if f32(est)+huff_J_add>=pJ^ {return -1}
    if est+8>=ptr_diff(to_end,to) {return -1}
    to_ptr_end:=to_end
    if ptr_diff(to_ptr_end,to)>from_len+256 {to_ptr_end=to[from_len+256:]}
    copy_bytes(to,raw_data(header[:]),header_size)
    to_ptr:=to[header_size:]
    if !huffman_build_encode_table(&H) {return -1}
    le_codes:[257]u64
    for i in 0..<nonzero_alphabet {
        cl:=u32(H.code_len_table[i])
        code:=H.encode_table[i]&((1<<compressor.HUFF_CODELEN_LIMIT)-1)
        le_codes[i]=u64(bitreverse11(code)>>(compressor.HUFF_CODELEN_LIMIT-cl))
    }
    if huff_type==compressor.ARRAY_TYPE_HUFF6 {
        size_at:=to_ptr
        to_ptr=to_ptr[3:]
        first:=(from_len+1)>>1
        size1:=put_array_huff3streams(to_ptr,to_ptr_end,from[:first],&H.code_len_table,&le_codes,
            arena)
        if size1<0 {return -1}
        to_ptr=to_ptr[size1:]
        size_at[0]=u8(size1);size_at[1]=u8(size1>>8);size_at[2]=u8(size1>>16)
        size2:=put_array_huff3streams(to_ptr,to_ptr_end,from[first:],&H.code_len_table,&le_codes,
            arena)
        if size2<0 {return -1}
        to_ptr=to_ptr[size2:]
    } else {
        size:=put_array_huff3streams(to_ptr,to_ptr_end,from,&H.code_len_table,&le_codes,arena)
        if size<0 {return -1}
        to_ptr=to_ptr[size:]
    }
    tot:=ptr_diff(to_ptr,to)
    pJ^=f32(tot)+huff_J_add
    return tot
}
