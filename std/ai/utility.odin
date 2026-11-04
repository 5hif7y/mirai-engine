package ai

import "base:runtime"
import "mirai:std/math"

// Utility AI: every action has considerations, each reads one input, maps it
// through a response curve to a score from 0 to 1, and the action's score is
// their product (a consideration at 0 vetoes the action) compensated so that
// actions with many considerations are not penalized, times its weight. The
// action with the highest score wins. Only arithmetic is used, so scores are
// the same on every platform.

Response_Kind :: enum u8 {
    Linear,     // slope*(x-shift_x)+shift_y
    Polynomial, // slope*(x-shift_x)^degree+shift_y
    Sigmoid,    // an S around shift_x with steepness slope, from 0 to 1, plus shift_y
    Step,       // 1 from shift_x on, 0 before it, plus shift_y
}

// A curve over inputs normalized to 0..1; the result is clamped to 0..1.
Response :: struct {
    kind:Response_Kind,
    degree:u8, // Polynomial
    slope,shift_x,shift_y:f32,
    invert:bool, // 1 - result
}

response_evaluate :: proc "contextless" (r:Response,x:f32) -> f32 {
    y:f32
    switch r.kind {
    case .Linear: y=r.slope*(x-r.shift_x)+r.shift_y
    case .Polynomial:
        power:f32=1
        for _ in 0..<r.degree {power*=x-r.shift_x}
        y=r.slope*power+r.shift_y
    case .Sigmoid:
        s:=r.slope*(x-r.shift_x)
        y=0.5+0.5*s/(1+abs(s))+r.shift_y
    case .Step: y=(1 if x>=r.shift_x else 0)+r.shift_y
    }
    y=math.saturate(y)
    return 1-y if r.invert else y
}

// Reads `inputs[input]`, rescales it from [min, max] to 0..1 and applies the curve.
Consideration :: struct {
    input:u16,
    min,max:f32,
    response:Response,
}

@(private)
Utility_Action :: struct {id:u32,weight:f32,first,count:u32}

Utility :: struct {
    actions:[]Utility_Action,
    considerations:[]Consideration,
    action_count,consideration_count:int,
    failed:u64,
    allocator:runtime.Allocator,
}
Utility_Desc :: struct {
    max_actions,max_considerations:int,
    allocator:runtime.Allocator, // context.allocator when unset
}

utility_init :: proc(u:^Utility,desc:Utility_Desc) -> bool {
    allocator:=desc.allocator if desc.allocator.procedure!=nil else context.allocator
    u^={allocator=allocator}
    if desc.max_actions<=0 || desc.max_considerations<0 || desc.max_actions>max(int)/size_of(Utility_Action) || desc.max_considerations>int(max(u32)) {return false}
    e1,e2:runtime.Allocator_Error
    u.actions,e1=make([]Utility_Action,desc.max_actions,allocator)
    u.considerations,e2=make([]Consideration,desc.max_considerations,allocator)
    if e1!=nil || e2!=nil {utility_destroy(u);return false}
    return true
}
utility_destroy :: proc(u:^Utility) {
    if u.allocator.procedure!=nil {delete(u.actions,u.allocator);delete(u.considerations,u.allocator)}
    u^={}
}
// Adds an action and returns its index, or -1, counting a failure, when there is no room.
utility_add_action :: proc(u:^Utility,id:u32,weight:f32,considerations:[]Consideration) -> int {
    if u.action_count>=len(u.actions) || u.consideration_count+len(considerations)>len(u.considerations) {u.failed+=1;return -1}
    u.actions[u.action_count]={id,weight,u32(u.consideration_count),u32(len(considerations))}
    copy(u.considerations[u.consideration_count:],considerations)
    u.consideration_count+=len(considerations)
    u.action_count+=1
    return u.action_count-1
}

// The score of an action for the given inputs; an input index past `inputs`
// reads as 0. An action without considerations scores its weight.
utility_score :: proc "contextless" (u:^Utility,action:int,inputs:[]f32) -> f32 {
    if action<0 || action>=u.action_count {return 0}
    def:=u.actions[action]
    return score_considerations(u.considerations[def.first:][:def.count],def.weight,inputs)
}
// The score of one choice: the product of its considerations, compensated for
// their count, times its weight; its weight without considerations.
score_considerations :: proc "contextless" (considerations:[]Consideration,weight:f32,inputs:[]f32) -> f32 {
    if len(considerations)==0 {return weight}
    product:f32=1
    for c in considerations {
        x:f32=inputs[c.input] if int(c.input)<len(inputs) else 0
        span:=c.max-c.min
        normalized:=math.saturate((x-c.min)/span) if span!=0 else (1 if x>=c.max else 0)
        product*=response_evaluate(c.response,normalized)
        if product==0 {return 0}
    }
    compensation:=1-1/f32(len(considerations))
    return (product+(1-product)*compensation*product)*weight
}
// Writes the score of every action to `out` (as many as fit) and returns how many were written.
utility_scores :: proc "contextless" (u:^Utility,inputs:[]f32,out:[]f32) -> int {
    count:=min(u.action_count,len(out))
    for i in 0..<count {out[i]=utility_score(u,i,inputs)}
    return count
}
// The id of the highest-scoring action, with its score; the first wins ties.
// Not ok when none scores above 0.
utility_select :: proc "contextless" (u:^Utility,inputs:[]f32) -> (id:u32,score:f32,ok:bool) {
    for i in 0..<u.action_count {
        s:=utility_score(u,i,inputs)
        if s>score {score=s;id=u.actions[i].id;ok=true}
    }
    return
}
// Picks an action at random, each with a chance proportional to its score;
// `scores` is the scratch for them. Not ok when none scores above 0 or without `rng`.
utility_pick :: proc "contextless" (u:^Utility,inputs:[]f32,scores:[]f32,rng:^math.Rng) -> (id:u32,ok:bool) {
    if rng==nil {return}
    count:=utility_scores(u,inputs,scores)
    index:=math.random_weighted(rng,scores[:count])
    if index<0 {return}
    return u.actions[index].id,true
}
