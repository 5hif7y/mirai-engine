package paint

import "mirai:host"
import "mirai:std/base"

// What a painted entity showed before its first stroke: a mesh asset, or the
// primitive when source is zero. Its Mesh_Renderer shows the painted copy, a
// mesh asset of its own that differs from the source only in the colors of
// its vertices.
@(component)
Painted :: struct {
    source:base.Asset_Id `mirai:"readonly"`,
    shape:host.Shape `mirai:"readonly"`,
}
