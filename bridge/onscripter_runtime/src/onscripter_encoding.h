#pragma once

#include "coding2utf16.h"
#include <memory>
#include <string>

std::unique_ptr<Coding2UTF16> MakeOnsEncoding(const std::string &name);
