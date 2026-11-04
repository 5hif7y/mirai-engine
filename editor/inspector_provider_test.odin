package editor

import "core:testing"
import "mirai:core"

Inspector_Test_Provider :: struct {provider:Inspector_Provider}
inspector_test_provider_v1 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v1}}}
inspector_test_provider_v2 :: proc(dst:rawptr) {(^Inspector_Test_Provider)(dst)^={provider={component=inspector_test_component_v2}}}
inspector_test_component_v1 :: proc(c:Inspector_Context) -> bool {c.session.frame+=1;return true}
inspector_test_component_v2 :: proc(c:Inspector_Context) -> bool {c.session.frame+=2;return true}

@(test)
inspector_extensions_use_current_metadata_and_preserve_the_generic_fallback :: proc(t:^testing.T) {
    storages:=[1]core.Storage_Info{{info=type_info_of(Inspector_Test_Provider),place=.Editor,default=inspector_test_provider_v1}}
    info:=core.World_Info{storages=storages[:]}
    session:=Session{info=&info}
    inspected:=Inspect{s=&session}
    testing.expect(t,inspector_extension(&inspected) && session.frame==1)
    storages[0].default=inspector_test_provider_v2
    session.library_generation+=1
    testing.expect(t,inspector_extension(&inspected) && session.frame==3)
    testing.expect(t,!inspector_extension(&inspected,type_info_of(f32)))
    storages[0].place=.World
    session.library_generation+=1
    testing.expect(t,!inspector_extension(&inspected))
}
