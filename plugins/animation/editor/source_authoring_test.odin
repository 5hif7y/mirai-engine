package animation_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "mirai:asset"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:host"
import "mirai:std/base"
import anim "plugins:animation/runtime"

@(test)
program_authoring_accepts_distinct_clip_sources_and_patch_preserves_explicit_identity :: proc(t:^testing.T) {
    f:=new(Authoring_Test);defer free(f);if !authoring_test_init(f,t,"program-sources") {return};defer authoring_test_destroy(f)
    primary:=program_test_source(f,t);other:=base.Asset_Id{16,33}
    testing.expect_value(t,asset.animation_save(fmt.tprintf("%s/other.anim",f.root),&f.assets.types,{id=other,clips={{name="walk"},{name="jump",tracks={{target="hip",property=.Position,keys={{},{time=2,value={2,0,0,0}}}}}}}}),asset.Error.None)
    testing.expect(t,host.assets_scan(&f.assets))
    first,second:=authoring_test_id_text(primary),authoring_test_id_text(other)
    blend_defaults:=program_blend_defaults();graph_defaults:=program_graph_defaults();action_defaults:=action_write_defaults();patch:Graph_Patch_Params
    authoring_test_register(f,t,"blend",Blend_Write_Params,program_blend_set,blend_defaults)
    authoring_test_register(f,t,"graph",Graph_Write_Params,program_graph_set,graph_defaults)
    authoring_test_register(f,t,"patch",Graph_Patch_Params,authoring_graph_patch,&patch)
    authoring_test_register(f,t,"action",Action_Write_Params,authoring_action_set,action_defaults)
    result:=authoring_test_execute(f,"blend",fmt.tprintf(`{{"path":"sources.blend","info":{{"animation":"%s","dimension":"One","x":{{"name":"speed","min":0,"max":1}}}},"samples":[{{"position":[0,0],"clip":"walk"}},{{"position":[1,0],"clip":"walk","animation":"%s"}}]}}`,second,first))
    if !testing.expect(t,result.code==0,result.message) {return}
    blend:=authoring_test_id_text(authoring_test_id(f,"sources.blend"))
    // A .blend is an aim offset or additive space: only the right of an Additive node.
    graph:=fmt.tprintf(`{{"path":"sources.agraph","animation":"%s","output":"mix","nodes":[{{"name":"mix","kind":"Additive","left":"external","right":"aim"}},{{"name":"external","kind":"Clip","clip":"jump","animation":"%s"}},{{"name":"aim","kind":"Blend_Space","blend_space":"%s"}}]}}`,first,second,blend)
    blended,_:=strings.replace_all(graph,`"kind":"Additive"`,`"kind":"Blend"`,context.temp_allocator)
    result=authoring_test_execute(f,"graph",blended)
    testing.expect(t,result.code==api.INVALID_PARAMS && strings.contains(result.data,`"path":"nodes[2]"`) && strings.contains(result.data,"Additive_Only") && strings.contains(result.data,"the right of Blend node mix") && !authoring_test_exists(f,"sources.agraph"))
    result=authoring_test_execute(f,"graph",graph)
    if !testing.expect(t,result.code==0,result.message) {return}
    identity:=authoring_test_id_text(authoring_test_id(f,"sources.agraph"))
    result=authoring_test_execute(f,"patch",fmt.tprintf(`{{"asset":"%s","nodes":[{{"name":"external","speed":1.25}}]}}`,identity))
    if !testing.expect(t,result.code==0,result.message) {return}
    file:asset.Asset;defer asset.asset_close(&file)
    testing.expect_value(t,authoring_test_load(f,"sources.agraph",&file),asset.Error.None)
    view,error:=anim.graph_view(&file,&f.assets.types);testing.expect_value(t,error,asset.Error.None)
    testing.expect(t,view.nodes[0].animation==other && view.nodes[0].speed==1.25)
    result=authoring_test_execute(f,"action",fmt.tprintf(`{{"path":"sources.action","animation":"%s","actions":[{{"name":"jump","clip":"jump","animation":"%s"}}],"windows":[{{"action":"jump","name":"contact","start":0.25,"end":1.5}}]}}`,first,second))
    testing.expect(t,result.code==0,result.message)
}
