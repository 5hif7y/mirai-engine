package asset

// BC6H without sign (BC6H_UF16): 4x4 texels of rgb half floats in 16 bytes.
// cook/textures writes mode 11 alone (bc6h.odin): one subset whose two
// endpoints keep 10 bits per channel, and an index of 4 bits per texel,
// the first texel's of 3 (its high bit is 0). The bits, from the lowest:
//
//   0-4     mode, 00011
//   5-34    first endpoint, red, green and blue of 10 bits
//   35-64   second endpoint, the same
//   65-127  indices of the texels in rows from the top: 3 bits, then 15 of 4
//
// A channel interpolates in the 16-bit range the endpoints unquantize to,
// and that value times 31/64 is the bits of its half float (D3D11 functional
// specification, 19.5.8). Every other mode decodes to black here, as the
// reserved modes of the format do.

TEXTURE_BC6H_MODE_11 :: 0b00011
TEXTURE_BC6H_ENDPOINT_BITS :: 10

// A quantized endpoint channel of mode 11 in the 16-bit range it interpolates in.
texture_bc6h_unquantize :: proc "contextless" (value:u32) -> u32 {
    if value==0 {return 0}
    if value==(1<<TEXTURE_BC6H_ENDPOINT_BITS)-1 {return 0xffff}
    return ((value<<16)+0x8000)>>TEXTURE_BC6H_ENDPOINT_BITS
}

// The bits of the half float an index of weight (out of 64) gives between
// two unquantized endpoint channels.
texture_bc6h_interpolate :: proc "contextless" (a,b,weight:u32) -> u16 {
    value:=(a*(64-weight)+b*weight+32)>>6
    return u16((value*31)>>6)
}

// The half floats of a block, in rows from the top.
texture_bc6h_block_decode :: proc "contextless" (block:[16]u8) -> (texels:[16][3]u16) {
    bits:u128
    for b,i in block {bits|=u128(b)<<(u32(i)*8)}
    if u32(bits&0x1f)!=TEXTURE_BC6H_MODE_11 {return}
    first,second:[3]u32
    for c in 0..<3 {
        first[c]=texture_bc6h_unquantize(u32(bits>>(5+u32(c)*10))&0x3ff)
        second[c]=texture_bc6h_unquantize(u32(bits>>(35+u32(c)*10))&0x3ff)
    }
    at:=u32(65)
    for i in 0..<16 {
        size:=u32(3) if i==0 else 4
        index:=u32(bits>>at)&((1<<size)-1)
        at+=size
        for c in 0..<3 {texels[i][c]=texture_bc6h_interpolate(first[c],second[c],BC7_WEIGHTS_4[index])}
    }
    return
}
