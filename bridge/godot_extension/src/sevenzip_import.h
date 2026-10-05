#pragma once

#include <string>

namespace godot {

bool RunSevenZipImport(const std::string &input_path,
                       const std::string &output_path,
                       const std::string &password_db,
                       const std::string &password,
                       std::string &error);

} // namespace godot
