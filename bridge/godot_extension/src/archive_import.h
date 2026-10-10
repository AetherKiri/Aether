// archive_import.h — Godot-facing archive import facade over the
// GalgameExtractor (HRD) C ABI.

#pragma once

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Start an asynchronous archive import. Returns a job id (decimal string).
// The extraction itself runs on a worker thread.
String ArchiveImportStart(const String &input_path, const String &output_path,
                          const String &password_db, const String &password);

// Poll a job started by ArchiveImportStart. Returns one of:
//   {"status":"pending"}
//   {"status":"missing"}
//   {"status":"ok","report":{...}}
//   {"status":"error","code":<hrd status>,"error":"..."}
String ArchiveImportTakeResult(const String &job_id);

}  // namespace godot
