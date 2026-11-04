package editor

import "core:testing"
import erender "mirai:engine/render"
import "mirai:std/base"

@(test)
post_process_helpers_compact_and_keep_neighbors_in_their_stage :: proc(t:^testing.T) {
	layers:[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer
	layers[0]={material=base.Asset_Id{1,0},after_tonemap=false}
	layers[2]={material=base.Asset_Id{2,0},after_tonemap=false}
	layers[3]={material=base.Asset_Id{3,0},after_tonemap=true}
	layers[5]={material=base.Asset_Id{4,0},after_tonemap=true}
	testing.expect_value(t,post_process_count(&layers),4)
	testing.expect_value(t,post_process_compact(&layers),4)
	testing.expect(t,layers[0].material==base.Asset_Id{1,0})
	testing.expect(t,layers[1].material==base.Asset_Id{2,0})
	testing.expect(t,layers[2].material==base.Asset_Id{3,0})
	testing.expect(t,layers[3].material==base.Asset_Id{4,0})
	testing.expect(t,layers[4].material==base.Asset_Id{})
	testing.expect_value(t,post_process_neighbor(&layers,0,1),1)
	testing.expect_value(t,post_process_neighbor(&layers,1,1),-1)
	testing.expect_value(t,post_process_neighbor(&layers,2,1),3)
	testing.expect_value(t,post_process_neighbor(&layers,3,-1),2)
	testing.expect_value(t,post_process_neighbor(&layers,2,-1),-1)
}

@(test)
post_process_inspect_counts_the_effects_up_to_a_layer_on_each_side :: proc(t:^testing.T) {
	layers:[erender.POST_PROCESS_CAPACITY]erender.Post_Process_Layer
	layers[0]={material=base.Asset_Id{1,0},enabled=true}
	layers[1]={material=base.Asset_Id{2,0},after_tonemap=true,enabled=true}
	layers[2]={material=base.Asset_Id{3,0},enabled=false}
	layers[3]={material=base.Asset_Id{4,0},enabled=true}
	layers[4]={material=base.Asset_Id{5,0},after_tonemap=true,enabled=true}
	usable:[erender.POST_PROCESS_CAPACITY]bool
	for i in 0..<5 {usable[i]=true}
	effects,ok:=post_process_inspect_counts(&layers,usable,0)
	testing.expect(t,ok && effects==[2]u8{1,0})
	effects,ok=post_process_inspect_counts(&layers,usable,3)
	testing.expect(t,ok && effects==[2]u8{2,0})
	effects,ok=post_process_inspect_counts(&layers,usable,1)
	testing.expect(t,ok && effects==[2]u8{2,1})
	effects,ok=post_process_inspect_counts(&layers,usable,4)
	testing.expect(t,ok && effects==[2]u8{2,2})
	_,ok=post_process_inspect_counts(&layers,usable,2)
	testing.expect(t,!ok,"a disabled layer shows nothing")
	usable[0]=false
	effects,ok=post_process_inspect_counts(&layers,usable,3)
	testing.expect(t,ok && effects==[2]u8{1,0},"a layer the renderer cannot use is not counted")
}
