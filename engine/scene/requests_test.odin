package scene

import "core:testing"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// The scene the player was launched with is asked once per world; one that
// does not load ends the player, and every request that fails leaves its
// result and a problem that says how to fix it.
@(test)
a_scene_that_does_not_load_leaves_its_result_and_a_problem :: proc(t:^testing.T) {
    app:host.App
    app.launch.scene="scenes/missing.scene"
    requests:Scene_Requests
    results:Scene_Results
    launch:Scene_Launch
    problems:core.Problems
    defer delete(requests.queue.items)
    defer delete(results.queue.items)

    scene_requests({},&app,&requests,&results,&launch,nil,nil,&problems)
    testing.expect(t,launch.taken)
    testing.expect_value(t,app.exit_code,host.PLAYER_SCENE)
    result,found:=result_of(&results,{},"scenes/missing.scene")
    testing.expect(t,found)
    testing.expect_value(t,result.error,Error.No_Assets)
    testing.expect_value(t,problems.count,1)

    app.quit,app.exit_code=false,0
    request(&requests,base.Asset_Id{1,2})
    scene_requests({},&app,&requests,&results,&launch,nil,nil,&problems)
    testing.expect_value(t,len(results.queue.items),1)
    testing.expect(t,!app.quit)
    by_id,_:=result_of(&results,base.Asset_Id{1,2})
    testing.expect_value(t,by_id.error,Error.No_Assets)

    scene_requests({},&app,&requests,&results,&launch,nil,nil,&problems)
    testing.expect_value(t,len(results.queue.items),0)
}

@(test)
a_path_that_does_not_fit_is_not_asked_for :: proc(t:^testing.T) {
    requests:Scene_Requests
    defer delete(requests.queue.items)
    long:[SCENE_PATH_CAPACITY]u8
    for &c in long {c='a'}
    testing.expect(t,!request_path(&requests,string(long[:])))
    testing.expect(t,!request_path(&requests,""))
    testing.expect(t,request_path(&requests,"scenes/main.scene"))
    testing.expect_value(t,len(requests.queue.items),1)
}
