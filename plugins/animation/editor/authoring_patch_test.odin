package animation_editor

import "core:fmt"
import "core:testing"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(test)
graph_patch_edits_multiple_named_fields_atomically :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"patch") {return};defer authoring_test_destroy(f)
    source:=program_test_source(f,t);defaults:=program_graph_defaults();patch:Graph_Patch_Params
    authoring_test_register(f,t,"set",Graph_Write_Params,program_graph_set,defaults);authoring_test_register(f,t,"patch",Graph_Patch_Params,authoring_graph_patch,&patch)
    result:=authoring_test_execute(f,"set",fmt.tprintf(`{{"path":"graph.agraph","animation":"%s","output":"mix","nodes":[{{"name":"mix","kind":"Blend","left":"idle","right":"walk","weight":0.2}},{{"name":"idle","kind":"Clip","clip":"idle"}},{{"name":"walk","kind":"Clip","clip":"walk"}}],"parameters":[{{"name":"speed","value":0.5,"min":0,"max":1}}]}}`,authoring_test_id_text(source)))
    if !testing.expect(t,result.code==0,result.message) {return}
    id:=authoring_test_id(f,"graph.agraph");identity:=authoring_test_id_text(id);revision:=authoring_test_revision(f,"graph.agraph")
    request:=fmt.tprintf(`{{"asset":"%s","nodes":[{{"name":"mix","weight":0.7}},{{"name":"walk","speed":1.25}}],"parameters":[{{"name":"speed","value":0.8}}]}}`,identity)
    result=authoring_test_execute(f,"patch",request);if !testing.expect(t,result.code==0,result.message) {return}
    file:asset.Asset;testing.expect_value(t,authoring_test_load(f,"graph.agraph",&file),asset.Error.None)
    profile,error:=anim.graph_view(&file,&f.assets.types);testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,profile.nodes[2].weight==.7 && profile.nodes[1].speed==1.25 && profile.nodes[0].loop && profile.parameters[0].value==.8);asset.asset_close(&file)
    revision=authoring_test_revision(f,"graph.agraph")
    result=authoring_test_execute(f,"patch",fmt.tprintf(`{{"asset":"%s","nodes":[{{"name":"walk","speed":3}},{{"name":"mix","left":"mix"}}]}}`,identity))
    testing.expect_value(t,result.code,api.INVALID_PARAMS);testing.expect_value(t,authoring_test_revision(f,"graph.agraph"),revision)
    testing.expect_value(t,authoring_test_id(f,"graph.agraph"),base.Asset_Id(id))
}
