#pragma once

#include <godot_cpp/variant/string.hpp>

namespace godot {

String ArchiveImportStart(const String &input_path,
                          const String &output_path,
                          const String &password_db,
                          const String &password);
String ArchiveImportTakeResult(const String &job_id);

} // namespace godot
