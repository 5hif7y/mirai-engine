package entropy

import "core:math/rand"
import "core:testing"
import "mirai:std/compressor"

@(private="file")
FLAG_SETS :: [?]u32{0x00,0x80,0xC1,0xC9,0xCD,0xDD,0xDF,0xFF}

@(private="file")
make_inputs :: proc(t:^testing.T) -> [dynamic][]u8 {
    r:=rand.create(7)
    gen:=rand.default_random_generator(&r)
    inputs:[dynamic][]u8
    for n in ([]int{0,1,5,6,31,32,33,64,97,300,1600,5000,40000}) {
        memset:=make([]u8,n);for i in 0..<n {memset[i]=0x5A}
        random:=make([]u8,n);for i in 0..<n {random[i]=u8(rand.uint64(gen))}
        skewed:=make([]u8,n)
        for i in 0..<n {
            x:=rand.uint64(gen)
            k:=u8(0)
            for x&1==1 {k+=1;x>>=1}
            skewed[i]=k*37
        }
        runs:=make([]u8,n)
        v:=u8(0)
        for i in 0..<n {if rand.uint64(gen)%50==0 {v=u8(rand.uint64(gen))};runs[i]=v}
        two:=make([]u8,n);for i in 0..<n {two[i]=u8(i%3==0 ? 200 : 7)}
        append(&inputs,memset,random,skewed,runs,two)
    }
    return inputs
}

@(test)
put_array_hostile_inputs_stay_in_bounds :: proc(t:^testing.T) {
    inputs:=make_inputs(t)
    defer {for s in inputs {delete(s)};delete(inputs)}
    arena:=arena_make(context.allocator)
    GUARD :: 64
    buf:=make([]u8,40000+3+GUARD)
    defer delete(buf)
    flag_sets:=FLAG_SETS
    for s in inputs {
        for flags in flag_sets {
            for level in ([]int{1,4,6,7,9}) {
                // Exactly the uncompressed bound, then one byte less.
                for slack in ([]int{3,2}) {
                    cap:=len(s)+slack
                    for i in 0..<len(buf) {buf[i]=0xEE}
                    J:=LAGRANGE_COST_INVALID
                    n:=put_array(raw_data(buf),raw_data(buf)[cap:],s,flags,0.01,&J,
                        ARRAY_DEADLINE_HUGE,&arena,level)
                    testing.expect(t,n<=cap)
                    if slack==3 {testing.expect(t,n>0)}
                    if n>0 {testing.expect(t,J<LAGRANGE_COST_INVALID && J>=f32(n)-2)}
                    for i in cap..<cap+GUARD {testing.expect(t,buf[i]==0xEE)}
                    J2:=LAGRANGE_COST_INVALID
                    m:=put_array_small_allowed(raw_data(buf),raw_data(buf)[cap:],s,flags,0.05,
                        &J2,1000,&arena,level)
                    testing.expect(t,m<=cap)
                    for i in cap..<cap+GUARD {testing.expect(t,buf[i]==0xEE)}
                }
            }
        }
        // Tiny destinations never succeed partially or write past their end.
        for cap in 0..<6 {
            for i in 0..<len(buf) {buf[i]=0xEE}
            J:=LAGRANGE_COST_INVALID
            n:=put_array(raw_data(buf),raw_data(buf)[cap:],s,0xFF,0.01,&J,ARRAY_DEADLINE_HUGE,
                &arena,9)
            testing.expect(t,n<=cap)
            for i in cap..<cap+GUARD {testing.expect(t,buf[i]==0xEE)}
        }
    }
    testing.expect(t,!arena.failed)
}

@(test)
put_array_is_deterministic :: proc(t:^testing.T) {
    inputs:=make_inputs(t)
    defer {for s in inputs {delete(s)};delete(inputs)}
    arena:=arena_make(context.allocator)
    a:=make([]u8,40100);b:=make([]u8,40100)
    defer {delete(a);delete(b)}
    for s in inputs {
        Ja,Jb:=LAGRANGE_COST_INVALID,LAGRANGE_COST_INVALID
        na:=put_array(raw_data(a),raw_data(a)[len(s)+16:],s,0xFF,0.01,&Ja,ARRAY_DEADLINE_HUGE,
            &arena,9)
        nb:=put_array(raw_data(b),raw_data(b)[len(s)+16:],s,0xFF,0.01,&Jb,ARRAY_DEADLINE_HUGE,
            &arena,9)
        testing.expect(t,na==nb && Ja==Jb)
        if na==nb && na>0 {testing.expect(t,string(a[:na])==string(b[:nb]))}
    }
}

@(test)
huffman_code_lens_are_complete_and_limited :: proc(t:^testing.T) {
    r:=rand.create(11)
    gen:=rand.default_random_generator(&r)
    arena:=arena_make(context.allocator)
    for k in 0..<300 {
        h:[256]u32
        sum:u32=0
        for i in 0..<256 {
            if rand.uint64(gen)%3==0 {continue}
            h[i]=u32(1)<<uint(rand.uint64(gen)%(k%2==0 ? 18 : 6))
            sum+=h[i]
        }
        H:Huffman
        huffman_init(&H,256)
        testing.expect(t,huffman_build_code_lens(&H,h[:],sum,compressor.HUFF_CODELEN_LIMIT,&arena,k%4<2))
        if H.got_num_symbols<2 {continue}
        kraft:u64=0
        for i in 0..<256 {
            cl:=H.code_len_table[i]
            testing.expect(t,(cl==0)==(h[i]==0))
            testing.expect(t,cl<=compressor.HUFF_CODELEN_LIMIT)
            if cl>0 {kraft+=u64(1)<<uint(compressor.HUFF_CODELEN_LIMIT-int(cl))}
        }
        testing.expect(t,kraft==1<<compressor.HUFF_CODELEN_LIMIT)
        testing.expect(t,huffman_build_encode_table(&H))
    }
}

@(test)
tans_normalized_counts_sum_to_L :: proc(t:^testing.T) {
    r:=rand.create(13)
    gen:=rand.default_random_generator(&r)
    for k in 0..<300 {
        h,norm:[256]u32
        sum:=0
        alphabet:=1+int(rand.uint64(gen)%256)
        for i in 0..<alphabet {
            h[i]=rand.uint64(gen)%4==0 ? 0 : u32(rand.uint64(gen)%u64(1+k*40))
            sum+=int(h[i])
        }
        if sum==0 {continue}
        L:=1<<uint(compressor.TANS_L_BITS_MIN+k%4)
        nz:=normalize_counts_v6(norm[:],L,h[:],sum,alphabet)
        total:=0
        for i in 0..<alphabet {
            total+=int(norm[i])
            testing.expect(t,(norm[i]==0)==(h[i]==0))
        }
        if nz<=L {testing.expect(t,total==L)}
    }
}
