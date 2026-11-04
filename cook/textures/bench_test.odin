package textures

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "mirai:asset"
import "mirai:std/jobs"

BENCH :: #config(COOK_BENCH,false)
BENCH_ROUNDS :: 5
// A list of color images, "<set>\t<path>" per line: their BC7 against BC1
// (opaque) or BC3 (with alpha), level 0 at most DEFAULT_MAX_SIZE.
BC7_BENCH :: #config(BC7_BENCH,"")
// Profiles of bc7e measured besides the one of the encoder: "basic", "slow", "veryslow".
BC7_BENCH_PROFILES :: #config(BC7_BENCH_PROFILES,"slow")

@(test)
bench_mip_chains :: proc(t:^testing.T) {
    if !BENCH {return}
    SIZE :: 2048
    pixels:=make([]u8,SIZE*SIZE*4);defer delete(pixels)
    for i in 0..<SIZE*SIZE {
        pixels[i*4]=u8(i*7);pixels[i*4+1]=u8(i*13>>3);pixels[i*4+2]=u8(i>>5);pixels[i*4+3]=u8(i*3>>2)
    }
    cases:=[?]struct{name:string,options:Build_Options}{
        {"linear RGBA8",{encoding=.Uncompressed}},{"srgb RGBA8",{srgb=true,encoding=.Uncompressed}},{"normal map RGBA8",{normal_map=true,encoding=.Uncompressed}},{"masked srgb RGBA8",{srgb=true,alpha_coverage=0.5,encoding=.Uncompressed}},
        {"data BC3",{}},{"normal map BC5",{normal_map=true}},
    }
    for entry in cases {
        best:=time.Duration(max(i64))
        for _ in 0..<BENCH_ROUNDS {
            start:=time.tick_now()
            built,error:=build(rgba8(pixels,SIZE,SIZE),entry.options)
            assert(error==.None)
            built_destroy(&built)
            best=min(best,time.tick_since(start))
        }
        fmt.printfln("%dx%d %s: %v (%.1f Mtexel/s of the first level)",SIZE,SIZE,entry.name,best,f64(SIZE*SIZE)/1e6/time.duration_seconds(best))
    }
}

@(private="file")
Bench_Level :: struct {
    pixels:[]u8,
    width,height:int,
    settings:Bc7_Settings,
    out:[]u8,
}

@(private="file")
bench_rows :: proc(level:^Bench_Level,first,last:int,_:int) {
    blocks_x:=(level.width+3)/4
    texels:[16][4]u8
    for by in first..<last {
        for bx in 0..<blocks_x {
            for y in 0..<4 {
                for x in 0..<4 {
                    at:=(min(by*4+y,level.height-1)*level.width+min(bx*4+x,level.width-1))*4
                    texels[y*4+x]={level.pixels[at],level.pixels[at+1],level.pixels[at+2],level.pixels[at+3]}
                }
            }
            block:=bc7_encode_block(&texels,&level.settings)
            copy(level.out[(by*blocks_x+bx)*16:],block[:])
        }
    }
}

@(private="file")
bench_psnr :: proc(format:asset.Texture_Format,blocks,pixels:[]u8,width,height,channels:int) -> f64 {
    decoded:=make([]u8,width*height*4)
    defer delete(decoded)
    asset.texture_level_rgba8(format,blocks,width,height,decoded)
    total:f64
    for i in 0..<width*height {
        for c in 0..<channels {
            d:=f64(decoded[i*4+c])-f64(pixels[i*4+c])
            total+=d*d
        }
    }
    return 10*math.log10(255*255/max(total/f64(width*height*channels),1e-10))
}

@(private="file")
bench_profile :: proc(name:string) -> (settings:Bc7_Settings,ok:bool) {
    settings=BC7_SETTINGS
    switch name {
    case "slow":
    case "basic":
        settings.max_partitions={16,32,32,32,0,0,0,32}
        settings.tried={1,1,1,0,0,0,0,1}
        settings.opaque_modes-={2}
        settings.pbit_search=false
        settings.uber_level=1
    case "veryslow":
        settings.tried={2,2,2,0,0,0,0,2}
        settings.uber_level=2
    case: return {},false
    }
    return settings,true
}

@(private="file")
Bench_Sum :: struct {
    set,profile:string,
    alpha:bool,
    textures,texels:int,
    baseline_db,bc7_db:f64,
    baseline_time,bc7_time:time.Duration,
}

@(test)
bench_bc7_against_bc1_and_bc3 :: proc(t:^testing.T) {
    if BC7_BENCH=="" {return}
    list,read_error:=os.read_entire_file(BC7_BENCH,context.allocator)
    if read_error!=nil {fmt.eprintfln("cannot read %s",BC7_BENCH);return}
    defer delete(list)
    profiles:=strings.split(BC7_BENCH_PROFILES,",")
    defer delete(profiles)
    js:jobs.Job_System
    if !jobs.system_init(&js,{threads=jobs.THREADS_AUTO}) {return}
    defer jobs.system_destroy(&js)
    sums:[dynamic]Bench_Sum
    defer delete(sums)
    text:=string(list)
    for line in strings.split_lines_iterator(&text) {
        set,_,path:=strings.partition(strings.trim_space(line),"\t")
        if path=="" {continue}
        bytes,error:=os.read_entire_file(path,context.allocator)
        if error!=nil {fmt.eprintfln("cannot read %s",path);continue}
        image,decode_error:=image_decode(bytes)
        delete(bytes)
        if decode_error!=.None {fmt.eprintfln("cannot decode %s",path);continue}
        defer image_destroy(&image)
        pixels,width,height:=image.pixels,image.width,image.height
        for max(width,height)>DEFAULT_MAX_SIZE {
            reduced:=make([]u8,(width/2)*(height/2)*4)
            for y in 0..<height/2 {
                for x in 0..<width/2 {
                    for c in 0..<4 {
                        sum:=0
                        for dy in 0..<2 {for dx in 0..<2 {sum+=int(pixels[((y*2+dy)*width+x*2+dx)*4+c])}}
                        reduced[(y*(width/2)+x)*4+c]=u8((sum+2)/4)
                    }
                }
            }
            if raw_data(pixels)!=raw_data(image.pixels) {delete(pixels)}
            pixels,width,height=reduced,width/2,height/2
        }
        defer if raw_data(pixels)!=raw_data(image.pixels) {delete(pixels)}
        if width<4 || height<4 {continue}
        alpha:=false
        for i:=3;i<len(pixels);i+=4 {if pixels[i]!=255 {alpha=true;break}}
        channels:=4 if alpha else 3
        baseline_format:=asset.Texture_Format.BC3 if alpha else .BC1
        start:=time.tick_now()
        baseline,_:=bc_compress(pixels,width,height,baseline_format)
        baseline_time:=time.tick_since(start)
        baseline_db:=bench_psnr(baseline_format,baseline,pixels,width,height,channels)
        delete(baseline)
        for profile in profiles {
            settings,known:=bench_profile(profile)
            if !known {fmt.eprintfln("unknown profile %s",profile);return}
            level:=Bench_Level{pixels=pixels,width=width,height=height,settings=settings,out=make([]u8,asset.texture_level_size(.BC7,width,height))}
            start=time.tick_now()
            jobs.parallel_for(&js,jobs.OWNER,(height+3)/4,1,bench_rows,&level)
            bc7_time:=time.tick_since(start)
            bc7_db:=bench_psnr(.BC7,level.out,pixels,width,height,channels)
            delete(level.out)
            fmt.printfln("texture\t%s\t%s\t%s\t%dx%d\t%s\t%.3f\t%.3f\t%.1f\t%.1f",set,path,"alpha" if alpha else "opaque",width,height,profile,baseline_db,bc7_db,time.duration_milliseconds(baseline_time),time.duration_milliseconds(bc7_time))
            sum:^Bench_Sum
            for &entry in sums {
                if entry.set==set && entry.profile==profile && entry.alpha==alpha {sum=&entry}
            }
            if sum==nil {
                append(&sums,Bench_Sum{set=set,profile=profile,alpha=alpha})
                sum=&sums[len(sums)-1]
            }
            sum.textures+=1
            sum.texels+=width*height
            sum.baseline_db+=baseline_db
            sum.bc7_db+=bc7_db
            sum.baseline_time+=baseline_time
            sum.bc7_time+=bc7_time
        }
    }
    fmt.println("| Set | Alpha | Profile | Textures | Mtexels | BC1/BC3 dB | BC7 dB | BC1/BC3 s | BC7 s (16 threads) |")
    for s in sums {
        n:=f64(s.textures)
        fmt.printfln("| %s | %s | %s | %d | %.1f | %.2f | %.2f | %.2f | %.2f |",s.set,"yes" if s.alpha else "no",s.profile,s.textures,f64(s.texels)/1e6,s.baseline_db/n,s.bc7_db/n,time.duration_seconds(s.baseline_time),time.duration_seconds(s.bc7_time))
    }
}
