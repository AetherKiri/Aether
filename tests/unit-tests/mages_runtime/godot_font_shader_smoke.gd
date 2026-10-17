extends SceneTree

# Execute the shared font intensity function on a local RenderingDevice.
# godot --path <project> --rendering-method mobile --script <this-file> -- <AetherMAGES-root>
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Pass the AetherMAGES source root")
		quit(1)
		return
	var source := FileAccess.get_file_as_string(args[0].path_join("src/shaders/opengl/EdgeDetectedSingleSheetFont_frag.glsl"))
	var begin := source.find("float getIntensity(")
	var end := source.find("\nvoid main()", begin)
	if begin < 0 or end < 0:
		push_error("Cannot locate the shared font intensity function")
		quit(1)
		return
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Font shader smoke requires a RenderingDevice")
		quit(1)
		return
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = """#version 450
layout(local_size_x=1) in;
layout(std430,set=0,binding=0) buffer Results { float values[]; } result;
const float DifferenceFactor = 1.0;
""" + source.substr(begin, end - begin) + """
void main() {
    result.values[0] = getIntensity(0.5, 0.5, 0.0);
    result.values[1] = getIntensity(0.25, 0.5, 0.0);
    result.values[2] = getIntensity(0.75, 0.5, 0.0);
    result.values[3] = getIntensity(0.5, 0.5, 0.25);
    result.values[4] = getIntensity(0.625, 0.5, 0.25);
}
"""
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		rd.free()
		quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(20)
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var bindings := rd.uniform_set_create([uniform], shader, 0)
	var commands := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(commands, pipeline)
	rd.compute_list_bind_uniform_set(commands, bindings, 0)
	rd.compute_list_dispatch(commands, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var actual := rd.buffer_get_data(buffer).to_float32_array()
	var expected := PackedFloat32Array([0.5, 0.0, 1.0, 0.5, 0.84375])
	var passed := actual.size() == expected.size()
	for i in mini(actual.size(), expected.size()):
		if not is_finite(actual[i]) or absf(actual[i] - expected[i]) > 0.00001:
			passed = false
	print("MAGES_FONT_SHADER passed=", passed, " actual=", actual)
	for resource in [bindings, buffer, pipeline, shader]:
		rd.free_rid(resource)
	rd.free()
	quit(0 if passed else 1)
