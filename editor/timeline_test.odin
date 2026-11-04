package editor

import "core:testing"

@(test)
the_strip_keeps_its_view_and_range_inside_the_duration :: proc(t:^testing.T) {
    strip:Timeline
    start,end:=timeline_view(&strip,60)
    testing.expect(t,start==0 && end==60,"A view never set shows the whole duration")
    strip.start,strip.end=50,80
    start,end=timeline_view(&strip,60)
    testing.expect(t,start==30 && end==60,"A view past the end slides back inside it")
    strip.start,strip.end=10,11
    start,end=timeline_view(&strip,60)
    testing.expect(t,end-start==TIMELINE_MIN_FRAMES,"The view shows at least a few frames")
    lo,hi:=timeline_bounds(&strip,60)
    testing.expect(t,lo==0 && hi==60,"A range that is off bounds nothing")
    strip.range,strip.range_in,strip.range_out=true,12,90
    lo,hi=timeline_bounds(&strip,60)
    testing.expect(t,lo==12 && hi==60,"A range that is on bounds what plays, inside the duration")
}

@(test)
the_ruler_spaces_its_ticks_and_labels_by_the_zoom :: proc(t:^testing.T) {
    tick,label:=timeline_steps(10,30)
    testing.expect(t,tick==1 && label==10,"Ten points a frame: a tick each frame, a label each ten")
    tick,label=timeline_steps(1,30)
    testing.expect(t,tick==10 && label==60,"A point a frame: a tick each ten and a label each two seconds")
    tick,label=timeline_steps(2,30)
    testing.expect(t,label==30,"A label lands on each second when one fits")
}
