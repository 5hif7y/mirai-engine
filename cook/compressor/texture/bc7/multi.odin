package bc7

import "mirai:cook/compressor/texture/bc67"

// Endpoint solves shared by several blocks that keep their own indices.

// Blocks with their inputs; each entry must stay in place once set.
Multi_Blocks :: struct {
    data:[]Block_And_Input,
}

@(private)
multi_blocks_set :: proc "contextless" (m:^Multi_Blocks,index:int,block_bits:^[16]u8,
    pixels:^[16]Color,
    flags:Flags) {
    if index<0 || index>=len(m.data) {return}
    d:=&m.data[index]
    state_from_bits(&d.state,block_bits,flags)
    input_get_state(&d.input,pixels,&d.state)
}

@(private)
Subset_LLS_State :: struct {
    bsum:[4]f32,
    ata:[4]f32,    // ata00, ata10, ata11 of the vector indices
    atb0:[4]f32,
    atab_2:[4]f32, // ata00, ata10, ata11 of the scalar indices, atb in the last
}

@(private)
accumulate_lls :: proc "contextless" (lls:^[3]Subset_LLS_State,data:^Block_And_Input) {
    st:=&data.state
    input:=&data.input
    mode:=&bc67.BC7_MODES[st.mode&7]
    isbit:=st.subsets[0].isbit
    fv:=&bc67.LERP_FACTOR_4X[isbit!=0 ? mode.ib2 : mode.ib]
    fs:=&bc67.LERP_FACTOR_4X[isbit!=0 ? mode.ib : mode.ib2]
    for s in 0..<int(mode.ns) {
        sst:=&st.subsets[s]
        in_:=&input.subsets[s]
        acc:=&lls[s]
        idxs:=&sst.idxs[isbit&1]
        for i in 0..<in_.num_pixels {
            fac:=&fv[idxs[i]&15]
            acc.ata[0]+=fac[0]
            acc.ata[1]+=fac[1]
            acc.ata[2]+=fac[2]
            w:=fac[3]
            for c in 0..<4 {
                p:=f32(in_.pixels[i][c])
                acc.atb0[c]+=w*p
                acc.bsum[c]+=p
            }
        }
        if mode.ib2!=0 {
            idxs2:=&sst.idxs[(isbit&1)~1]
            for i in 0..<in_.num_pixels {
                fac:=&fs[idxs2[i]&15]
                acc.atab_2[0]+=fac[0]
                acc.atab_2[1]+=fac[1]
                acc.atab_2[2]+=fac[2]
                acc.atab_2[3]+=fac[3]*f32(in_.pixels[i][3])
            }
        }
    }
}

@(private)
find_endpoints_multi_mode :: proc "contextless" (st:^Block_State,multi:^Multi_Blocks,
    lls:^[3]Subset_LLS_State,
    flags:Flags,change_pbits,slow_anneal:bool,$M:int) {
    IB2 :: MODE_IB2[M]
    ib1_comp:=(IB2==0 && flags&IGNORE_ALPHA==0) ? 4 : 3
    st.err=0
    ctx:=Multiblock_Iter_Context{multi=multi,change_pbits=change_pbits}
    for s in 0..<MODE_NS[M] {
        sst:=&st.subsets[s]
        sst.err=ERROR_MAX
        sst.scalar_err=ERROR_MAX/2
        {
            ata00:=lls[s].ata[0]; ata10:=lls[s].ata[1]; ata11:=lls[s].ata[2]
            det:=ata00*ata11-ata10*ata10
            if det!=0 {
                idet:=1.0/det
                iata00:=ata11*idet
                iata10:=ata10*idet
                iata11:=ata00*idet
                for c in 0..<ib1_comp {
                    atb0c:=lls[s].atb0[c]
                    atb1c:=lls[s].bsum[c]-atb0c
                    sst.endpoints[0][c]=round_and_clamp_u8(iata11*atb1c-iata10*atb0c)
                    sst.endpoints[1][c]=round_and_clamp_u8(iata00*atb0c-iata10*atb1c)
                }
            }
        }
        when IB2!=0 {
            ata00:=lls[s].atab_2[0]; ata10:=lls[s].atab_2[1]; ata11:=lls[s].atab_2[2]
            det:=ata00*ata11-ata10*ata10
            if det!=0 {
                idet:=1.0/det
                atb0:=lls[s].atab_2[3]
                atb1:=lls[s].bsum[3]-atb0
                sst.endpoints[0][3]=round_and_clamp_u8(idet*(ata00*atb1-ata10*atb0))
                sst.endpoints[1][3]=round_and_clamp_u8(idet*(ata11*atb0-ata10*atb1))
            }
        }
        endpoints_q:[2]Color
        sst.pbits=calc_endpoints_and_pbits(&endpoints_q,sst,flags,
            change_pbits ? -1 : int(sst.pbits),M)
        sst.endpoints=endpoints_q
        if slow_anneal {
            ctx.subset=s
            refine_greedyoptimize_endpoints_core(sst,flags,&ctx,M,.Multi_Block)
        }
    }
}

// One set of endpoints for every block of multi, which share st's mode and
// partition; endpoints end up in st.
@(private)
find_endpoints_multi :: proc "contextless" (st:^Block_State,multi:^Multi_Blocks,flags:Flags,
    change_pbits,
    slow_anneal:bool) {
    if len(multi.data)==0 {return}
    lls:[3]Subset_LLS_State
    for i in 0..<len(multi.data) {accumulate_lls(&lls,&multi.data[i])}
    switch st.mode {
    case 0: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,0)
    case 1: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,1)
    case 2: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,2)
    case 3: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,3)
    case 4: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,4)
    case 5: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,5)
    case 6: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,6)
    case 7: find_endpoints_multi_mode(st,multi,&lls,flags,change_pbits,slow_anneal,7)
    }
}
