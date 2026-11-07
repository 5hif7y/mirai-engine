package editor

import "core:strings"
import "core:testing"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"

// asset.import takes what an image holds by name (color, data, normal,
// normal_green_down) and says what it takes when given another.
@(test)
asset_import_takes_the_use_of_an_image_by_name :: proc(t:^testing.T) {
    imports:Importer
    s:=Session{app=&host.App{},importer=&imports}
    run :: proc(s:^Session,image:string) -> api.Call {
        params:Import_Params
        base.text_set(params.path[:],"T_Katana_MR.png")
        base.text_set(params.image[:],image)
        method:=api.Method{params_id=Import_Params,result_id=Import_Result}
        result:Import_Result
        call:=api.Call{method=&method,params=&params,result=&result,allocator=context.temp_allocator}
        api_asset_import(s,&call)
        call.method,call.params,call.result=nil,nil,nil
        return call
    }
    wrong:=run(&s,"metallic")
    testing.expect(t,wrong.failed && wrong.error.code==api.INVALID_PARAMS && strings.contains(wrong.error.message,"data"),wrong.error.message)
    // A known use passes on to the import, which here has no asset folder to write into.
    known:=run(&s,"Data")
    testing.expect(t,known.failed && known.error.code==api.SERVER_ERROR && strings.contains(known.error.message,"asset folder"),known.error.message)
}
