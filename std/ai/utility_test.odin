package ai

import "core:testing"
import "mirai:std/base"

@(test)
response_curves_map_inputs_to_scores :: proc(t:^testing.T) {
    linear:=Response{kind=.Linear,slope=1}
    testing.expect(t,near(response_evaluate(linear,0.25),0.25) && near(response_evaluate(linear,2),1) && near(response_evaluate(linear,-1),0))
    testing.expect(t,near(response_evaluate({kind=.Linear,slope=1,invert=true},0.25),0.75))
    squared:=Response{kind=.Polynomial,degree=2,slope=1}
    testing.expect(t,near(response_evaluate(squared,0.5),0.25))
    shifted:=Response{kind=.Polynomial,degree=2,slope=4,shift_x=0.5}
    testing.expect(t,near(response_evaluate(shifted,0.5),0) && near(response_evaluate(shifted,0.75),0.25))
    sigmoid:=Response{kind=.Sigmoid,slope=10,shift_x=0.5}
    low,mid,high:=response_evaluate(sigmoid,0),response_evaluate(sigmoid,0.5),response_evaluate(sigmoid,1)
    testing.expect(t,near(mid,0.5) && low<0.1 && high>0.9 && low<response_evaluate(sigmoid,0.4) && response_evaluate(sigmoid,0.6)<high)
    step:=Response{kind=.Step,shift_x=0.6}
    testing.expect(t,response_evaluate(step,0.59)==0 && response_evaluate(step,0.6)==1)
    testing.expect(t,response_evaluate({kind=.Step,shift_x=0.6,shift_y=0.2},0.1)==0.2)
}

@(test)
utility_picks_the_action_whose_considerations_score_highest :: proc(t:^testing.T) {
    u:Utility
    testing.expect(t,utility_init(&u,{max_actions=4,max_considerations=8}))
    defer utility_destroy(&u)
    HEALTH,ENEMY_DISTANCE:=u16(0),u16(1)
    heal:=utility_add_action(&u,10,1,{{input=HEALTH,min=0,max=100,response={kind=.Linear,slope=1,invert=true}}})
    attack:=utility_add_action(&u,20,1,{
        {input=ENEMY_DISTANCE,min=0,max=50,response={kind=.Linear,slope=1,invert=true}},
        {input=HEALTH,min=0,max=100,response={kind=.Linear,slope=1}}})
    idle:=utility_add_action(&u,30,0.2,nil)
    testing.expect(t,heal==0 && attack==1 && idle==2)
    id,score,ok:=utility_select(&u,{20,10})
    testing.expect(t,ok && id==10 && near(score,0.8))
    id,score,ok=utility_select(&u,{90,5})
    testing.expect(t,ok && id==20 && score>0.5)
    id,_,ok=utility_select(&u,{100,50}) // healthy but the enemy is out of reach: only the fallback is left
    testing.expect(t,ok && id==30)
    testing.expect(t,near(utility_score(&u,idle,nil),0.2))
    testing.expect(t,utility_score(&u,-1,nil)==0 && utility_score(&u,9,nil)==0)
}

@(test)
utility_compensates_for_the_number_of_considerations :: proc(t:^testing.T) {
    u:Utility
    testing.expect(t,utility_init(&u,{max_actions=2,max_considerations=4}))
    defer utility_destroy(&u)
    half:=Consideration{input=0,min=0,max=1,response={kind=.Linear,slope=1}}
    one:=utility_add_action(&u,1,1,{half})
    three:=utility_add_action(&u,2,1,{half,half,half})
    a,b:=utility_score(&u,one,{0.5}),utility_score(&u,three,{0.5})
    testing.expect(t,near(a,0.5))
    testing.expect(t,b>0.5*0.5*0.5 && near(b,0.125+(1-0.125)*(1-1.0/3)*0.125,1e-4))
    testing.expect(t,utility_score(&u,three,{0})==0) // a zero vetoes the action
    out:[2]f32
    testing.expect_value(t,utility_scores(&u,{0.5},out[:]),2)
    testing.expect(t,near(out[0],a) && near(out[1],b))
    testing.expect_value(t,utility_scores(&u,{0.5},out[:1]),1)
}

@(test)
utility_reads_missing_inputs_as_zero_and_empty_ranges_as_a_threshold :: proc(t:^testing.T) {
    u:Utility
    testing.expect(t,utility_init(&u,{max_actions=2,max_considerations=2}))
    defer utility_destroy(&u)
    utility_add_action(&u,1,1,{{input=5,min=0,max=1,response={kind=.Linear,slope=1,shift_y=0.25}}})
    utility_add_action(&u,2,1,{{input=0,min=3,max=3,response={kind=.Linear,slope=1}}})
    testing.expect(t,near(utility_score(&u,0,{1}),0.25))
    testing.expect(t,utility_score(&u,1,{2.9})==0 && utility_score(&u,1,{3})==1)
}

@(test)
utility_pick_chooses_in_proportion_to_the_scores :: proc(t:^testing.T) {
    u:Utility
    testing.expect(t,utility_init(&u,{max_actions=3,max_considerations=0}))
    defer utility_destroy(&u)
    utility_add_action(&u,1,1,nil)
    utility_add_action(&u,2,3,nil)
    utility_add_action(&u,3,0,nil)
    rng:=base.rng_make(21)
    counts:[4]int
    scores:[3]f32
    for _ in 0..<4000 {
        id,ok:=utility_pick(&u,nil,scores[:],&rng)
        testing.expect(t,ok)
        counts[id]+=1
    }
    testing.expect(t,counts[3]==0 && counts[2]>2*counts[1] && counts[2]<4*counts[1])
    empty:Utility
    testing.expect(t,utility_init(&empty,{max_actions=1,max_considerations=0}))
    defer utility_destroy(&empty)
    utility_add_action(&empty,1,0,nil)
    _,picked:=utility_pick(&empty,nil,scores[:],&rng)
    _,selected,found:=utility_select(&empty,nil)
    testing.expect(t,!picked && !found && selected==0)
}

@(test)
utility_refuses_actions_past_its_capacity :: proc(t:^testing.T) {
    u:Utility
    testing.expect(t,utility_init(&u,{max_actions=2,max_considerations=2}))
    defer utility_destroy(&u)
    c:=Consideration{max=1}
    testing.expect_value(t,utility_add_action(&u,1,1,{c,c}),0)
    testing.expect_value(t,utility_add_action(&u,2,1,{c}),-1) // considerations: 3 > 2
    testing.expect_value(t,utility_add_action(&u,2,1,nil),1)
    testing.expect_value(t,utility_add_action(&u,3,1,nil),-1) // actions: 3 > 2
    testing.expect_value(t,u.failed,u64(2))
    bad:Utility
    testing.expect(t,!utility_init(&bad,{max_actions=0}) && !utility_init(&bad,{max_actions=1,max_considerations=-1}))
}
