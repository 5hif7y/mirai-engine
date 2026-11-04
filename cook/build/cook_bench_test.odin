package build

import "core:fmt"
import "core:os"
import "core:testing"
import "mirai:project"

// The cook of a project as the job Game does it: without a texture cache,
// filling an empty one and from it. Run with --release -define:COOK_BENCH=true;
// COOK_BENCH_PROJECT names the project, the demo when empty.
@(private="file") COOK_BENCH :: #config(COOK_BENCH,false)
@(private="file") COOK_BENCH_PROJECT :: #config(COOK_BENCH_PROJECT,"")

@(test)
bench_cook_of_a_project_with_and_without_its_texture_cache :: proc(t:^testing.T) {
    if !COOK_BENCH {return}
    engine:=#directory+"/../.."
    root:=COOK_BENCH_PROJECT if COOK_BENCH_PROJECT!="" else project.path(engine,"demo",allocator=context.temp_allocator)
    p,error:=project.open(root,engine,context.temp_allocator)
    if !testing.expect_value(t,error.code,project.Error_Code.None) {return}
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-cook-bench-%d",directory,os.get_pid())
    os.remove_all(folder)
    defer os.remove_all(folder)
    desc:=Cook_Desc{
        assets=project.folder_path(p.root,.Assets,context.temp_allocator),
        output=fmt.tprintf("%s/out",folder),
        manifest=project.path(p.root,COOK_FILE,allocator=context.temp_allocator),
        allocator=context.temp_allocator,
    }
    plugins:=make([dynamic]project.Asset_Folder,context.temp_allocator)
    for found in project.asset_folders(&p,context.temp_allocator) {
        if found.prefix!="" {append(&plugins,found)}
    }
    desc.plugins=plugins[:]
    best :: proc(t:^testing.T,desc:Cook_Desc,runs:int) -> (seconds:f64,report:Cook_Report) {
        seconds=max(f64)
        for _ in 0..<runs {
            report=cook_assets(desc)
            testing.expect_value(t,report.error,Cook_Error.None)
            seconds=min(seconds,report.seconds)
        }
        return
    }
    plain,report:=best(t,desc,3)
    desc.texture_cache=fmt.tprintf("%s/cache",folder)
    filling,_:=best(t,desc,1)
    cached,_:=best(t,desc,3)
    fmt.printfln("cook of %s: %d files, %d textures compressed; without a texture cache %.1f ms, filling it %.1f ms, from it %.1f ms",p.root,len(report.files),report.textures_compressed,plain*1000,filling*1000,cached*1000)
}
