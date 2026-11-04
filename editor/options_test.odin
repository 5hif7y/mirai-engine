package editor

import "core:testing"

// A headless editor draws its UI at the density asked for, which a restart keeps; a window takes the one of its display.
@(test)
a_headless_editor_takes_the_density_of_its_ui :: proc(t:^testing.T) {
    o,ok:=options_read({"--headless","--density","1.25"})
    testing.expect(t,ok)
    testing.expect_value(t,o.density,f32(1.25))
    kept:=options_passed({"--headless","--density","1.5","--frames","3"})
    testing.expect_value(t,len(kept),3)
    if len(kept)==3 {testing.expect_value(t,kept[2],"1.5")}
    _,ok=options_read({"--density","1.25"})
    testing.expect(t,!ok,"a window takes the density of its display")
    _,ok=options_read({"--headless","--density","9"})
    testing.expect(t,!ok)
    _,ok=options_read({"--headless","--density","high"})
    testing.expect(t,!ok)
}
