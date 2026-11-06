package compressor

import "base:intrinsics"

// RLE array: literals forward from the start, packets backward from the end.
// A simple packet is run length<<4 | (15 - literal run); values 1..0x2f are
// escapes: 1 sets the run byte from the literals, 2..8 a long literal run,
// 9..0xf a long run, 0x10..0x2f a 6-bit literal run and a 7-bit run.

@(private="file") RLE_PER_CHECK :: 4
@(private="file") RLE_READ_SIMPLE :: 1+15
@(private="file") RLE_READ_MEDIUM :: 2+63
@(private="file") RLE_READ_FAST :: (RLE_PER_CHECK-1)*RLE_READ_SIMPLE+RLE_READ_MEDIUM
@(private="file") RLE_READ_SLOW :: RLE_READ_MEDIUM
@(private="file") RLE_WRITE_SIMPLE :: 15+15
@(private="file") RLE_WRITE_MEDIUM :: 63+128+15
@(private="file") RLE_WRITE_FAST :: (RLE_PER_CHECK-1)*RLE_WRITE_SIMPLE+RLE_WRITE_MEDIUM
@(private="file") RLE_WRITE_SLOW :: RLE_WRITE_MEDIUM

@(private="file") rle_simple :: #force_inline proc "contextless" (
    packet:u32,
) -> bool {return packet-1>=0x2f}

@(private="file") V16 :: #simd[16]u8

@(private="file") rd16 :: #force_inline proc "contextless" (
    p:[^]u8,
) -> V16 {return intrinsics.unaligned_load((^V16)(p))}
@(private="file") wr16 :: #force_inline proc "contextless" (
    p:[^]u8,v:V16,
) {intrinsics.unaligned_store((^V16)(p),v)}

@(private="file") sat_sub :: #force_inline proc "contextless" (
    a,b:int,
) -> int {return a<b ? 0 : a-b}

// Decodes one packet. Returns false on a stream that does not fit.
@(private="file")
rle_packet :: #force_inline proc "contextless" (
    packet:u32,outp,lits,pkts:^[^]u8,out_end:[^]u8,runv:^V16,
) -> bool #no_bounds_check {
    out,lit,pk:=outp^,lits^,pkts^
    if rle_simple(packet) {
        lrl:=int((15-packet)&0xf)
        rl:=int(packet>>4)
        wr16(out,rd16(lit))
        out=out[lrl:];lit=lit[lrl:]
        wr16(out,runv^)
        out=out[rl:]
        pk=pk[-1:]
    } else if packet>=0x10 {
        pk=pk[-2:]
        v:=load16(pk)-0x1000
        lrl:=int(v&0x3f)
        rl:=int(v>>6)
        wr16(out,rd16(lit));wr16(out[16:],rd16(lit[16:]))
        wr16(out[32:],rd16(lit[32:]));wr16(out[48:],rd16(lit[48:]))
        out=out[lrl:];lit=lit[lrl:]
        wr16(out,runv^);wr16(out[16:],runv^);wr16(out[32:],runv^)
        if rl>48 {
            for i:=48;i<128;i+=16 {wr16(out[i:],runv^)}
        }
        out=out[rl:]
    } else if packet==1 {
        pk=pk[-1:]
        runv^=V16(lit[0])
        lit=lit[1:]
    } else if packet>=0x09 {
        pk=pk[-2:]
        rl:=int(load16(pk)-0x900+1)<<7
        if ptr_diff(out_end,out)<rl {return false}
        for i:=0;i<rl;i+=16 {wr16(out[i:],runv^)}
        out=out[rl:]
    } else {
        pk=pk[-2:]
        lrl:=int(load16(pk)-0x200+1)<<6
        if ptr_diff(pk,lit)<lrl || ptr_diff(out_end,out)<lrl {return false}
        intrinsics.mem_copy_non_overlapping(out,lit,lrl)
        out=out[lrl:];lit=lit[lrl:]
    }
    outp^,lits^,pkts^=out,lit,pk
    return true
}

@(private)
get_array_rle :: proc "contextless" (
    comp:[^]u8,comp_len:int,to:[^]u8,to_len:int,scratch,scratch_end:[^]u8,
) -> int #no_bounds_check {
    if comp_len<=1 || to_len<=0 {
        if comp_len==1 {
            fill(to,comp[0],to_len)
            return comp_len
        }
        return -1
    }
    lits:=comp[1:]
    pkts:=comp[comp_len:]
    scratch:=scratch
    if comp[0]!=0 {
        temp:=scratch
        temp_len:=0
        from_len:=get_array(&temp,comp,comp[comp_len:],&temp_len,ptr_diff(scratch_end,scratch),
            true,scratch,scratch_end)
        if from_len<=0 {return -1}
        rest:=comp_len-from_len
        if temp_len+rest>ptr_diff(scratch_end,scratch) {return -1}
        intrinsics.mem_copy(temp[temp_len:],comp[from_len:],rest)
        lits=temp
        pkts=temp[temp_len+rest:]
        scratch=scratch[temp_len+rest:]
    }
    out:=to
    out_check:=to[sat_sub(to_len,RLE_WRITE_FAST-1):]
    out_end:=to[to_len:]
    runv:V16
    for ptr_diff(pkts,lits)>=RLE_READ_FAST && uintptr(out)<uintptr(out_check) {
        ok:=true
        for _ in 0..<RLE_PER_CHECK {
            packet:=u32(pkts[-1])
            simple:=rle_simple(packet)
            ok=rle_packet(packet,&out,&lits,&pkts,out_end,&runv)
            if !simple {break}
        }
        if !ok {return -1}
    }
    tail_in:[RLE_READ_SLOW*2]u8
    tail_out:[RLE_WRITE_SLOW*2]u8 = ---
    final_in,final_out:=0,0
    out_check=to[sat_sub(to_len,RLE_WRITE_SLOW):]
    for {
        left:=ptr_diff(pkts,lits)
        if left<RLE_READ_SLOW {
            if final_in!=0 {return -1}
            intrinsics.mem_copy(&tail_in[0],lits,left)
            intrinsics.mem_copy(&tail_in[len(tail_in)-left],lits,left)
            lits=([^]u8)(&tail_in[0])
            pkts=lits[len(tail_in):]
            final_in=len(tail_in)-left
        }
        if uintptr(out)>=uintptr(out_check) {
            if out==out_end {break}
            if final_out!=0 {return -1}
            final_out=ptr_diff(out_end,out)
            out=([^]u8)(&tail_out[0])
            out_check=out[final_out:]
            out_end=out_check
        }
        if !rle_packet(u32(pkts[-1]),&out,&lits,&pkts,out_end,&runv) {return -1}
    }
    if out!=out_end || ptr_diff(pkts,lits)!=final_in {return -1}
    if final_out!=0 {intrinsics.mem_copy_non_overlapping(to[to_len-final_out:],&tail_out[0],
        final_out)}
    return comp_len
}
