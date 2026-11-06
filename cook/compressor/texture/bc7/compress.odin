package bc7

import "mirai:cook/compressor/texture/common"

// BC7 encode of RGBA blocks without rate-distortion optimization; to holds 16
// bytes per block. A block equal to the previous one copies its encoding.
compress :: proc "contextless" (to:[]u8,from:[]common.Color_Block,level:common.Level,
    options:common.Options) -> common.Error {
    if len(to)!=len(from)*16 {return .Invalid}
    opt:Enc_Options
    enc_options_set(&opt,level,options)
    for i in 0..<len(from) {
        out:=(^[16]u8)(&to[i*16])
        if i>0 && from[i]==from[i-1] {
            copy(to[i*16:i*16+16],to[(i-1)*16:i*16])
            continue
        }
        compress_block(out,(^[16]Color)(&from[i]),&opt)
    }
    return .None
}
