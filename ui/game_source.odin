package ui

import "mirai:std/base"

// What the game gives the interfaces it builds and the ui package does not
// own: its input, its texts, its textures, its cameras and its sounds. Any
// procedure may be nil; what needs it then shows what it shows without one.
Game_Source :: struct {
    user:rawptr,
    family:Prompt_Family, // of the device the player used last
    // The prompts of an action, by the name_hash of its name, as the family shows them.
    prompts:proc(user:rawptr,action:u64,family:Prompt_Family,out:[]Prompt) -> int,
    // Whether an action is held, and whether it was pressed since the last frame.
    action:proc(user:rawptr,action:u64) -> (down,pressed:bool),
    // The language the localized texts show in: the name_hash of its code
    // ("es", "pt-BR"); 0, the one they are written in.
    language:u64,
    // What an Image shows for a texture asset.
    texture:proc(user:rawptr,id:base.Asset_Id) -> Quad,
    // What a camera sees, at a size in layout units.
    view:proc(user:rawptr,camera:base.Entity,size:[2]f32) -> Quad,
    // A particle effect playing in a rectangle of a size in layout units:
    // id is the element that shows it, which keeps it alive while it is built.
    particles:proc(user:rawptr,id:Id,effect:base.Asset_Id,size:[2]f32) -> Quad,
    // Plays a sound a style names.
    sound:proc(user:rawptr,id:base.Asset_Id),
}
