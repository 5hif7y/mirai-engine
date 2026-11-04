package mirai_input

import "core:testing"

// Every public procedure takes whatever it is given and returns: sizes,
// capacities and numbers that are zero, negative, NaN or infinite.

@(private="file") HOSTILE_ROUNDS :: #config(INPUT_HOSTILE_ROUNDS,400)

@(private="file")
Hostile :: struct {state:u64}

@(private="file")
hostile_next :: proc(h:^Hostile) -> u64 {
    h.state+=0x9e3779b97f4a7c15
    z:=h.state
    z=(z~(z>>30))*0xbf58476d1ce4e5b9
    z=(z~(z>>27))*0x94d049bb133111eb
    return z~(z>>31)
}

@(private="file")
hostile_int :: proc(h:^Hostile,below:int) -> int {return below<=0?0:int(hostile_next(h)%u64(below))}

@(private="file")
hostile_f32 :: proc(h:^Hostile) -> f32 {
    switch hostile_int(h,12) {
    case 0: return f32(0h7fc00000)
    case 1: return f32(0h7f800000)
    case 2: return f32(0hff800000)
    case 3: return 1e30
    case 4: return -1e30
    case 5: return 1e-30
    case 6: return 0
    case 7: return 1
    }
    return f32(hostile_int(h,2001)-1000)/100
}

@(private="file")
hostile_u32 :: proc(h:^Hostile) -> u32 {
    switch hostile_int(h,8) {
    case 0: return 0
    case 1: return max(u32)
    case 2: return 1
    }
    return u32(hostile_int(h,100))
}

@(private="file")
hostile_key :: proc(h:^Hostile) -> u64 {
    switch hostile_int(h,5) {
    case 0: return 0
    case 1: return max(u64)
    }
    return u64(hostile_int(h,12))
}

@(private="file")
hostile_input_desc :: proc(h:^Hostile) -> Input_Desc {
    pick :: proc(h:^Hostile,limit:int) -> int {
        switch hostile_int(h,8) {
        case 0: return 0
        case 1: return -1
        case 2: return 1<<50
        case 3: return max(int)
        case 4: return limit+1
        }
        return hostile_int(h,limit)
    }
    return {max_actions=pick(h,40),max_bindings=pick(h,60),code_count=pick(h,600),axis_count=pick(h,80),tap_ticks=hostile_u32(h),hold_ticks=hostile_u32(h)}
}

@(test)
hostile_bindings_through_the_input :: proc(t:^testing.T) {
    h:=Hostile{25}
    for _ in 0..<HOSTILE_ROUNDS {
        in_:Input
        if input_init(&in_,hostile_input_desc(&h)) {
            actions:[dynamic]Action
            for _ in 0..<60 {
                action:=Action(hostile_int(&h,4)==0?hostile_next(&h):u64(hostile_int(&h,len(actions)+2)))
                if len(actions)>0 && hostile_int(&h,2)==0 {action=actions[hostile_int(&h,len(actions))]}
                code:=Input_Code(hostile_int(&h,3)==0?hostile_next(&h):u64(hostile_int(&h,600)))
                axis:=Axis_Code(hostile_int(&h,3)==0?hostile_next(&h):u64(hostile_int(&h,80)))
                switch hostile_int(&h,20) {
                case 0,1:
                    added:=input_add_action(&in_,Action_Kind(hostile_int(&h,3)),hostile_key(&h))
                    if added!=0 {append(&actions,added)}
                case 2: _=input_bind_code(&in_,action,code)
                case 3: _=input_bind_axis_button(&in_,action,axis,hostile_f32(&h),hostile_f32(&h))
                case 4: _=input_bind_codes_axis(&in_,action,code,Input_Code(hostile_next(&h)),hostile_f32(&h))
                case 5: _=input_bind_axis(&in_,action,axis,hostile_f32(&h),hostile_f32(&h))
                case 6: _=input_bind_codes_2d(&in_,action,code,code+1,Input_Code(hostile_next(&h)),code)
                case 7: _=input_bind_axes_2d(&in_,action,axis,Axis_Code(hostile_next(&h)),hostile_f32(&h),hostile_f32(&h))
                case 8: _=input_bind_delta(&in_,action,axis,hostile_f32(&h))
                case 9: _=input_bind_delta_2d(&in_,action,axis,axis+1,hostile_f32(&h))
                case 10: input_unbind(&in_,action)
                case 11,12: _=input_set_code(&in_,code,hostile_int(&h,2)==0)
                case 13,14: _=input_set_axis(&in_,axis,hostile_f32(&h))
                case 15: input_release_all(&in_)
                case 16,17: input_update(&in_)
                case 18:
                    _=input_find_action(&in_,hostile_key(&h));_=action_state(&in_,action);_=action_down(&in_,action);_=action_pressed(&in_,action)
                    _=action_released(&in_,action);_=action_tapped(&in_,action);_=action_hold_started(&in_,action);_=action_holding(&in_,action)
                    _=action_value(&in_,action);_=action_vector(&in_,action)
                case 19: _=code_gamepad(u16(hostile_next(&h)),u16(hostile_next(&h)));_=axis_gamepad(u16(hostile_next(&h)),u16(hostile_next(&h)))
                }
            }
            delete(actions)
            input_destroy(&in_)
        }
        input_destroy(&in_)
        zero:Input
        action:=Action(hostile_next(&h))
        _=input_add_action(&zero,.Button);_=input_bind_code(&zero,action,0);_=input_set_code(&zero,0,true);_=input_set_axis(&zero,0,1)
        input_update(&zero);input_release_all(&zero);input_unbind(&zero,action);_=input_find_action(&zero,1);_=action_state(&zero,action)
        input_destroy(&zero)
    }
}

@(test)
hostile_sizes_through_the_input_init :: proc(t:^testing.T) {
    h:=Hostile{26}
    for _ in 0..<HOSTILE_ROUNDS {
        in_:Input
        desc:=hostile_input_desc(&h)
        if input_init(&in_,desc) {
            _=input_add_action(&in_,.Axis)
            input_update(&in_)
            input_destroy(&in_)
        }
    }
}
