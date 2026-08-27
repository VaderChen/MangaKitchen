#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "ggml.h"
#include "gguf.h"

namespace {

struct ParsedFile {
    gguf_context * context = nullptr;
    ggml_context * tensorContext = nullptr;

    ParsedFile() = default;

    ~ParsedFile() {
        if (context != nullptr) {
            gguf_free(context);
        }
        if (tensorContext != nullptr) {
            ggml_free(tensorContext);
        }
    }

    ParsedFile(const ParsedFile &) = delete;
    ParsedFile & operator=(const ParsedFile &) = delete;

    ParsedFile(ParsedFile && other) noexcept
        : context(other.context), tensorContext(other.tensorContext) {
        other.context = nullptr;
        other.tensorContext = nullptr;
    }
};

std::string jsonEscape(std::string_view value) {
    std::ostringstream result;
    for (const unsigned char character : value) {
        switch (character) {
        case '"': result << "\\\""; break;
        case '\\': result << "\\\\"; break;
        case '\b': result << "\\b"; break;
        case '\f': result << "\\f"; break;
        case '\n': result << "\\n"; break;
        case '\r': result << "\\r"; break;
        case '\t': result << "\\t"; break;
        default:
            if (character < 0x20) {
                result << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                       << static_cast<int>(character) << std::dec;
            } else {
                result << character;
            }
            break;
        }
    }
    return result.str();
}

void writeString(std::ostream & output, std::string_view value) {
    output << '"' << jsonEscape(value) << '"';
}

std::string uppercaseTypeName(ggml_type type) {
    const char * name = ggml_type_name(type);
    std::string result = name == nullptr ? "UNKNOWN" : name;
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char value) {
        return static_cast<char>(std::toupper(value));
    });
    return result;
}

std::string uppercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::toupper(character));
    });
    return value;
}

const char * storageTypeFor(std::string_view typeName) {
    if (typeName == "Q1_0" || typeName == "Q2_0" ||
        typeName == "Q2_K" || typeName == "Q3_K" ||
        typeName == "Q4_0" || typeName == "Q4_1") {
        return "INT4";
    }
    if (typeName == "Q5_K" || typeName == "Q6_K" ||
        typeName == "Q8_0" || typeName == "I8") {
        return "INT8";
    }
    if (typeName == "Q4_K") {
        return "INT4";
    }
    if (typeName == "I16") {
        return "INT16";
    }
    if (typeName == "I32") {
        return "INT32";
    }
    if (typeName == "F16") {
        return "FP16";
    }
    if (typeName == "F32") {
        return "FP32";
    }
    return nullptr;
}

bool preservesSourceQuantization(std::string_view typeName) {
    return typeName == "Q4_0" || typeName == "Q4_1" || typeName == "Q8_0";
}

bool requiresConversion(std::string_view typeName) {
    return typeName == "Q1_0" || typeName == "Q2_0" ||
        typeName == "Q2_K" || typeName == "Q3_K" ||
        typeName == "Q4_K" || typeName == "Q5_K" || typeName == "Q6_K";
}

bool isMaterializable(ggml_type type, std::string_view typeName) {
    (void) type;
    return storageTypeFor(typeName) != nullptr;
}

ParsedFile openFile(const std::string & filePath, bool loadTensorData) {
    auto parsed = ParsedFile{};
    gguf_init_params params{};
    params.no_alloc = !loadTensorData;
    params.ctx = &parsed.tensorContext;
    parsed.context = gguf_init_from_file(filePath.c_str(), params);
    if (parsed.context == nullptr) {
        throw std::runtime_error("llama.cpp rejected the GGUF file");
    }
    return parsed;
}

std::vector<int64_t> shapeForTensor(
    const ParsedFile & parsed,
    int64_t tensorIndex) {
    const char * name = gguf_get_tensor_name(parsed.context, tensorIndex);
    const int64_t * dimensionsData = gguf_get_tensor_ne(parsed.context, tensorIndex);
    ggml_tensor * tensor = ggml_get_tensor(parsed.tensorContext, name);
    if (tensor == nullptr) {
        throw std::runtime_error("llama.cpp did not create a tensor context");
    }
    const int dimensions = ggml_n_dims(tensor);

    std::vector<int64_t> shape;
    shape.reserve(dimensions);
    for (int dimension = dimensions - 1; dimension >= 0; --dimension) {
        shape.push_back(dimensionsData[dimension]);
    }
    return shape;
}

uint64_t fileSize(const std::string & filePath) {
    std::error_code error;
    const uintmax_t size = std::filesystem::file_size(filePath, error);
    if (error || size > std::numeric_limits<uint64_t>::max()) {
        throw std::runtime_error("could not read GGUF file size");
    }
    return static_cast<uint64_t>(size);
}

void writeInspection(const std::string & filePath) {
    ParsedFile parsed = openFile(filePath, false);
    const int64_t tensorCount = gguf_get_n_tensors(parsed.context);
    std::map<std::string, int> typeCounts;
    std::set<std::string> unsupportedTypes;
    const uint64_t size = fileSize(filePath);

    std::cout << "{\"status\":\"ok\""
              << ",\"version\":" << gguf_get_version(parsed.context)
              << ",\"alignment\":" << gguf_get_alignment(parsed.context)
              << ",\"dataOffset\":" << gguf_get_data_offset(parsed.context)
              << ",\"fileSize\":" << size
              << ",\"metadataCount\":" << gguf_get_n_kv(parsed.context)
              << ",\"tensors\":[";

    for (int64_t index = 0; index < tensorCount; ++index) {
        const ggml_type type = gguf_get_tensor_type(parsed.context, index);
        const std::string typeName = uppercaseTypeName(type);
        typeCounts[typeName] += 1;
        const bool materializable = isMaterializable(type, typeName);
        if (!materializable) {
            unsupportedTypes.insert(typeName);
        }
        if (index > 0) {
            std::cout << ',';
        }
        std::cout << "{\"name\":";
        writeString(std::cout, gguf_get_tensor_name(parsed.context, index));
        std::cout << ",\"shape\":[";
        const std::vector<int64_t> shape = shapeForTensor(parsed, index);
        for (std::size_t dimension = 0; dimension < shape.size(); ++dimension) {
            if (dimension > 0) {
                std::cout << ',';
            }
            std::cout << shape[dimension];
        }
        std::cout << "],\"type\":";
        writeString(std::cout, typeName);
        std::cout << ",\"offset\":" << gguf_get_tensor_offset(parsed.context, index)
                  << ",\"byteSize\":" << gguf_get_tensor_size(parsed.context, index)
                  << ",\"isMaterializable\":"
                  << (materializable ? "true" : "false")
                  << ",\"storageType\":";
        const char * storageType = storageTypeFor(typeName);
        if (storageType == nullptr) {
            std::cout << "null";
        } else {
            writeString(std::cout, storageType);
        }
        std::cout << ",\"preservesSourceQuantization\":"
                  << (preservesSourceQuantization(typeName) ? "true" : "false")
                  << ",\"requiresConversion\":"
                  << (requiresConversion(typeName) ? "true" : "false") << '}';
    }
    std::cout << "],\"quantizationCounts\":{";
    bool first = true;
    for (const auto & [type, count] : typeCounts) {
        if (!first) {
            std::cout << ',';
        }
        first = false;
        writeString(std::cout, type);
        std::cout << ':' << count;
    }
    std::cout << "},\"unsupportedTypes\":[";
    first = true;
    for (const std::string & type : unsupportedTypes) {
        if (!first) {
            std::cout << ',';
        }
        first = false;
        writeString(std::cout, type);
    }
    std::cout << "]}\n";
}

std::string selectedTensorName(
    const ParsedFile & parsed,
    const std::string & requestedName) {
    if (!requestedName.empty()) {
        if (gguf_find_tensor(parsed.context, requestedName.c_str()) < 0) {
            throw std::runtime_error("tensor was not found: " + requestedName);
        }
        return requestedName;
    }
    const int64_t tensorCount = gguf_get_n_tensors(parsed.context);
    for (int64_t index = 0; index < tensorCount; ++index) {
        const ggml_type type = gguf_get_tensor_type(parsed.context, index);
        if (storageTypeFor(uppercaseTypeName(type)) != nullptr) {
            return gguf_get_tensor_name(parsed.context, index);
        }
    }
    if (tensorCount == 0) {
        throw std::runtime_error("GGUF file contains no tensors");
    }
    return gguf_get_tensor_name(parsed.context, 0);
}

void writeProbe(
    const std::string & filePath,
    const std::string & requestedName,
    const std::string & requestedStorage,
    bool includeStats) {
    ParsedFile parsed = openFile(filePath, true);
    const std::string tensorName = selectedTensorName(parsed, requestedName);
    const int64_t tensorIndex = gguf_find_tensor(parsed.context, tensorName.c_str());
    ggml_tensor * tensor = ggml_get_tensor(parsed.tensorContext, tensorName.c_str());
    if (tensor == nullptr || tensor->data == nullptr) {
        throw std::runtime_error("llama.cpp did not expose tensor data");
    }

    const std::string sourceTypeName = uppercaseTypeName(tensor->type);
    const char * automaticStorageType = storageTypeFor(sourceTypeName);
    if (automaticStorageType == nullptr) {
        throw std::runtime_error("no common storage type for tensor type");
    }
    const std::string storageType = requestedStorage.empty()
        || uppercase(requestedStorage) == "AUTO"
        ? automaticStorageType
        : uppercase(requestedStorage);
    const bool storageTypeMatchesSource = storageType == automaticStorageType;
    const bool isFloatingStorage = storageType == "FP16" || storageType == "FP32";
    if (!storageTypeMatchesSource && !isFloatingStorage) {
        throw std::runtime_error(
            "the POC does not perform lossy re-quantization to " + storageType
        );
    }

    const int64_t elementCount = ggml_nelements(tensor);
    if (elementCount <= 0 || elementCount > std::numeric_limits<int>::max() * 1024LL) {
        throw std::runtime_error("tensor is too large for the POC probe");
    }
    std::cout << "{\"status\":\"ok\",\"tensor\":\"" << jsonEscape(tensorName)
              << "\",\"type\":\"" << jsonEscape(uppercaseTypeName(tensor->type))
              << "\",\"shape\":[";
    const std::vector<int64_t> shape = shapeForTensor(parsed, tensorIndex);
    for (std::size_t dimension = 0; dimension < shape.size(); ++dimension) {
        if (dimension > 0) {
            std::cout << ',';
        }
        std::cout << shape[dimension];
    }
    const bool sourceQuantizationPreserved = storageTypeMatchesSource
        && preservesSourceQuantization(sourceTypeName);
    const bool conversionRequired = storageType != automaticStorageType
        || requiresConversion(sourceTypeName);
    std::cout << "],\"elementCount\":" << elementCount
              << ",\"rawByteSize\":"
              << gguf_get_tensor_size(parsed.context, tensorIndex)
              << ",\"storageType\":\"" << storageType
              << "\",\"preservesSourceQuantization\":"
              << (sourceQuantizationPreserved ? "true" : "false")
              << ",\"requiresConversion\":"
              << (conversionRequired ? "true" : "false");

    if (includeStats) {
        std::vector<float> values(static_cast<std::size_t>(elementCount));
        const ggml_type_traits * traits = ggml_get_type_traits(tensor->type);
        if (tensor->type == GGML_TYPE_F32) {
            std::memcpy(values.data(), tensor->data, values.size() * sizeof(float));
        } else if (traits != nullptr && traits->to_float != nullptr) {
            traits->to_float(tensor->data, values.data(), elementCount);
        } else {
            throw std::runtime_error(
                "llama.cpp has no diagnostic F32 conversion for tensor type"
            );
        }

        float minimum = values.front();
        float maximum = values.front();
        double meanAbsolute = 0;
        for (float value : values) {
            minimum = std::min(minimum, value);
            maximum = std::max(maximum, value);
            meanAbsolute += std::abs(static_cast<double>(value));
        }
        meanAbsolute /= static_cast<double>(values.size());

        std::cout << ",\"diagnosticDtype\":\"F32\",\"firstValues\":[";
        const std::size_t previewCount = std::min<std::size_t>(8, values.size());
        for (std::size_t index = 0; index < previewCount; ++index) {
            if (index > 0) {
                std::cout << ',';
            }
            std::cout << std::setprecision(9) << values[index];
        }
        std::cout << "],\"min\":" << std::setprecision(9) << minimum
                  << ",\"max\":" << maximum
                  << ",\"meanAbsolute\":" << meanAbsolute;
    } else {
        std::cout << ",\"diagnosticDtype\":null,\"firstValues\":[]"
                  << ",\"min\":null,\"max\":null,\"meanAbsolute\":null";
    }
    std::cout << "}\n";
}

void printUsage(const char * executable) {
    std::cerr << "usage: " << executable
              << " --mode inspect|probe --file model.gguf [--tensor name]"
              << " [--storage AUTO|INT4|INT8|INT16|INT32|FP16|FP32]"
              << " [--stats]\n";
}

}

int main(int argc, char ** argv) {
    std::string mode;
    std::string filePath;
    std::string tensorName;
    std::string storageType;
    bool includeStats = false;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if ((argument == "--mode" || argument == "--file" || argument == "--tensor" ||
             argument == "--storage") &&
            index + 1 < argc) {
            const std::string value = argv[++index];
            if (argument == "--mode") {
                mode = value;
            } else if (argument == "--file") {
                filePath = value;
            } else if (argument == "--tensor") {
                tensorName = value;
            } else {
                storageType = value;
            }
        } else if (argument == "--stats") {
            includeStats = true;
        } else if (argument == "--help" || argument == "-h") {
            printUsage(argv[0]);
            return 0;
        } else {
            printUsage(argv[0]);
            return 2;
        }
    }

    if (mode.empty() || filePath.empty() || (mode != "inspect" && mode != "probe")) {
        printUsage(argv[0]);
        return 2;
    }

    try {
        if (mode == "inspect") {
            writeInspection(filePath);
        } else {
            writeProbe(filePath, tensorName, storageType, includeStats);
        }
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    return 0;
}
