package host

import "mirai:asset"
import "mirai:std/base"

assets_fracture :: proc(a:^Assets,id:base.Asset_Id,file:^asset.Asset) -> (view:asset.Fracture_View,ok:bool) {
    if a==nil || file==nil {return}
    _,_,opened:=assets_open(a,id,.Fracture,file)
    if !opened {return}
    error:asset.Error
    view,error=asset.fracture_view(file,&a.types)
    if error!=.None {
        asset.asset_close(file)
        return
    }
    return view,true
}
