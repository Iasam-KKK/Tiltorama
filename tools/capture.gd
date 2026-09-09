extends SceneTree

## Takes a picture of the real game so a look does not require a human.
##
##   godot --path . --script res://tools/capture.gd -- <out.png> [seconds] [tiltX] [tiltY] [scenario]
##
## NOT --headless: there is no renderer under that flag, so the capture would be
## blank. This opens a window, drives the real scene for a while, saves a PNG and
## quits. Everything the harness cannot see -- whether a mesh is white, whether the
## ground z-fights, whether a structure is inside out -- is visible here.
##
## Scenarios build a situation before the shutter: "build" drops one of every tool
## in the palette, "wave" calls the raiders in early, "tilt" is just the angle.

const SIZE := Vector2i(1280, 720)

var _out := "user://capture.png"
var _seconds := 3.0
var _tilt := Vector2.ZERO
var _scenario := ""
var _main: Node


func _initialize() -> void:
    var args := OS.get_cmdline_user_args()
    if args.size() > 0:
        _out = args[0]
    if args.size() > 1:
        _seconds = float(args[1])
    if args.size() > 3:
        _tilt = Vector2(float(args[2]), float(args[3]))
    if args.size() > 4:
        _scenario = args[4]
    _run()


func _run() -> void:
    await process_frame
    DisplayServer.window_set_size(SIZE)
    root.content_scale_size = SIZE

    var packed := load("res://scenes/main.tscn") as PackedScene
    if packed == null:
        printerr("capture: scenes/main.tscn will not load")
        quit(1)
        return
    _main = packed.instantiate()
    root.add_child(_main)

    # start_run() is deferred a frame and Main._ready bakes the navmesh.
    for i in 20:
        await process_frame

    match _scenario:
        "build":
            _build_one_of_everything()
        "wave":
            Input.action_press(&"wave_call")
            await process_frame
            Input.action_release(&"wave_call")
        _:
            pass

    if _tilt != Vector2.ZERO:
        var tilt := _main.get_node_or_null("TiltController")
        if tilt:
            # Held rather than nudged: set it directly and stop the controller
            # chasing a stick that is not being touched.
            tilt.set_physics_process(false)
            tilt.set("tilt", _tilt)
            tilt.call("_apply")

    var until := 0.0
    while until < _seconds:
        until += 1.0 / 60.0
        await process_frame

    # The image is only readable once the frame it belongs to has actually been drawn.
    await RenderingServer.frame_post_draw
    var img := root.get_texture().get_image()
    var err := img.save_png(_out)
    if err != OK:
        printerr("capture: could not write %s (%d)" % [_out, err])
        quit(1)
        return
    print("capture: wrote %s  %dx%d  after %.1fs  tilt %.1f,%.1f  scenario '%s'"
        % [_out, img.get_width(), img.get_height(), _seconds, _tilt.x, _tilt.y, _scenario])
    quit()


## One of every tool the palette offers, spread out so nothing overlaps, plus a
## couple of rollers above each so their interaction is in shot.
func _build_one_of_everything() -> void:
    var structures := _main.get_node_or_null("World/NavRegion/Structures")
    var rollers := _main.get_node_or_null("World/RollerPool")
    var build := _main.get_node_or_null("BuildSystem")
    if structures == null or build == null:
        return
    var spots := [Vector3(-3.2, 0.0, -3.4), Vector3(0.0, 0.0, -3.4),
        Vector3(3.2, 0.0, -3.4), Vector3(-3.2, 0.0, 2.6), Vector3(0.0, 0.0, 2.6),
        Vector3(3.2, 0.0, 2.6)]
    var palette: Array = build.get("palette")
    for i in mini(palette.size(), spots.size()):
        var type: StructureType = palette[i]
        if type == null:
            continue
        var s := Structure.new()
        s.position = structures.to_local(spots[i])
        structures.add_child(s)
        s.configure(type)
        s.reset_physics_interpolation()
        if rollers:
            # Uphill of each piece, so they run onto it rather than sit on it.
            rollers.call(&"spawn_at", spots[i] + Vector3(0.0, 1.4, -1.6), 3, 0.25)
