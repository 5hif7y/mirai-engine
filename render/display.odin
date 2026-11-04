package mirai_render

import "mirai:rhi"

// The display transform (display.slang): the ACES 2.0 Output Transform of a
// display, baked once when the renderer starts into a LUT of
// DISPLAY_LUT_SIZE³ that the tonemap, the UI and the previews read.

// DISPLAY_LUT_SIZE of display.slang.
DISPLAY_LUT_SIZE :: 65
// ACES_HUES of aces.slang.
DISPLAY_HUES :: 360

// A display: the luminance of its white, nits, and the chromaticities of its
// primaries and white. It shows sRGB.
Display_Desc :: struct {
	peak:            f32,
	red, green, blue, white: Vec2,
}

// An SDR display of Rec.709 primaries, as the sRGB of a monitor.
DISPLAY_SDR :: Display_Desc{peak = 100, red = {0.64, 0.33}, green = {0.3, 0.6}, blue = {0.15, 0.06}, white = {0.3127, 0.329}}

// The tables of hue of the transform for the display, then the LUT from them.
@(private)
display_build :: proc(r: ^Renderer, display: Display_Desc) -> bool {
	d := r.device
	tables_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Tables_Comp], name = "display tables"})
	defer if tables_pipeline != 0 {rhi.pipeline_destroy(d, tables_pipeline)}
	lut_pipeline := rhi.pipeline_create_compute(d, {shader = &r.shader_codes[.Display_Lut_Comp], name = "display lut"})
	defer if lut_pipeline != 0 {rhi.pipeline_destroy(d, lut_pipeline)}
	tables := rhi.buffer_create(d, {size = DISPLAY_HUES * size_of(Vec4), usage = {.Storage}, name = "display tables"})
	defer if tables != 0 {rhi.buffer_destroy(d, tables)}
	Params :: struct {red_green, blue_white: Vec4, peak: f32, pad: [3]u32}
	params_buffer := rhi.buffer_create(d, {size = size_of(Params), usage = {.Uniform}, memory = .Upload, name = "display params"})
	defer if params_buffer != 0 {rhi.buffer_destroy(d, params_buffer)}
	r.display_lut = rhi.texture_create(d, {width = DISPLAY_LUT_SIZE, height = DISPLAY_LUT_SIZE, depth = DISPLAY_LUT_SIZE, format = .RGBA16_Float, usage = {.Sampled, .Storage}, name = "display lut"})
	if tables_pipeline == 0 || lut_pipeline == 0 || tables == 0 || params_buffer == 0 || r.display_lut == 0 {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	params := Params{red_green = {display.red.x, display.red.y, display.green.x, display.green.y}, blue_white = {display.blue.x, display.blue.y, display.white.x, display.white.y}, peak = display.peak}
	rhi.buffer_upload(d, params_buffer, 0, ([^]u8)(&params)[:size_of(params)])
	cmd := rhi.immediate_begin(d)
	rhi.cmd_bind_pipeline(cmd, tables_pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PARAMS, params_buffer)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS0, tables)
	rhi.cmd_dispatch(cmd, groups(DISPLAY_HUES, 64))
	rhi.cmd_bind_pipeline(cmd, lut_pipeline)
	rhi.cmd_bind_buffer(cmd, SLOT_PARAMS, params_buffer)
	rhi.cmd_bind_texture(cmd, SLOT_PASS0, r.display_lut)
	rhi.cmd_bind_buffer(cmd, SLOT_PASS1, tables)
	rhi.cmd_dispatch(cmd, groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4), groups(DISPLAY_LUT_SIZE, 4))
	rhi.cmd_barrier_texture(cmd, r.display_lut, .Shader_Read)
	if !rhi.immediate_end(d, cmd) {
		set_error(r, "display lut: %s", rhi.device_error(d))
		return false
	}
	return true
}
