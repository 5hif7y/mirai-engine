package importer

import "core:math"
import "core:testing"
import "mirai:asset"

@(test)
specular_glossiness_becomes_metallic_roughness :: proc(t:^testing.T) {
    close :: proc(a,b:f32) -> bool {return abs(a-b)<1e-4}
    testing.expect(t,close(f0_from_ior(1.5),0.04) && close(f0_from_ior(1),0))
    testing.expect(t,ior_valid(0) && ior_valid(1) && ior_valid(1.5) && !ior_valid(0.5) && !ior_valid(-1) && !ior_valid(math.nan_f32()))

    // The defaults of the extension are a white mirror: a metal.
    info:=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={1,1,1,1},specular={1,1,1},glossiness=1})
    testing.expect(t,close(info.metallic,1) && close(info.roughness,0) && close(info.base_color.r,1),"a white specular is a metal")

    // The reflectance of a dielectric leaves the diffuse color as the base.
    info=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={0.5,0.25,0.125,0.75},specular={0.04,0.04,0.04},glossiness=0.25})
    testing.expect(t,close(info.metallic,0) && close(info.roughness,0.75) && close(info.opacity,0.75),"a plastic stays a dielectric")
    testing.expect(t,close(info.base_color.r,0.5) && close(info.base_color.g,0.25) && close(info.base_color.b,0.125))

    // A specular that a texture varies stays a dielectric with the diffuse color.
    info=asset.MATERIAL_DEFAULTS
    specular_glossiness(&info,{diffuse={0.5,0.5,0.5,1},specular={1,1,1},glossiness=0.5,textured=true})
    testing.expect(t,info.metallic==0 && info.base_color==[3]f32{0.5,0.5,0.5} && close(info.roughness,0.5))
    testing.expect(t,asset.material_check({info=&info}))
}
