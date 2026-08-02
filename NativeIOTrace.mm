#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#define GL_APICALL
#define GL_APIENTRY
#include <GLES2/gl2.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <execinfo.h>
#include <mutex>
#include <regex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using FOpen = FILE* (*)(const char*, const char*);
using FClose = int (*)(FILE*);
using FRead = size_t (*)(void*, size_t, size_t, FILE*);
using FSeek = int (*)(FILE*, long, int);
using FTell = long (*)(FILE*);

bool TraceEnabled() {
    static const bool enabled = [] {
        const char* value = std::getenv("YOGHOURT_ARTEMIS_IO_TRACE");
        return value && std::strcmp(value, "1") == 0;
    }();
    return enabled;
}

template <typename Function>
Function Original(const char* name) {
    return reinterpret_cast<Function>(dlsym(RTLD_NEXT, name));
}

std::mutex& PackMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_set<FILE*>& PackFiles() {
    static std::unordered_set<FILE*> files;
    return files;
}

std::string& GameRoot() {
    static std::string root;
    return root;
}

std::unordered_map<std::string, std::string>& PlatformTableOverrides() {
    static std::unordered_map<std::string, std::string> paths;
    return paths;
}

NSMutableArray<NSString*>* gPlatformTableTemporaryFiles;

bool ReadUInt32(NSData* data, NSUInteger offset, uint32_t& value) {
    if (offset > data.length || data.length - offset < sizeof(value)) return false;
    std::memcpy(&value, static_cast<const uint8_t*>(data.bytes) + offset, sizeof(value));
    value = CFSwapInt32LittleToHost(value);
    return true;
}

struct PackIndex {
    NSData* data = nil;
    NSData* index = nil;
    std::unordered_map<std::string, std::pair<uint32_t, uint32_t>> entries;
};

std::string NormalizePackPath(std::string path) {
    for (char& character : path) {
        if (character == '\\') character = '/';
        else character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return path;
}

bool LoadPackIndex(NSString* path, PackIndex& pack) {
    NSError* error = nil;
    NSData* data = [NSData dataWithContentsOfFile:path
                                         options:NSDataReadingMappedIfSafe
                                           error:&error];
    if (!data || data.length < 11) return false;
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    if (bytes[0] != 'p' || bytes[1] != 'f' || bytes[2] != '8') return false;

    uint32_t indexSize = 0;
    if (!ReadUInt32(data, 3, indexSize)
        || indexSize < 4
        || static_cast<uint64_t>(indexSize) + 7 > data.length) {
        return false;
    }
    NSData* index = [data subdataWithRange:NSMakeRange(7, indexSize)];
    uint32_t count = 0;
    if (!ReadUInt32(index, 0, count) || count == 0 || count > 100000) return false;

    NSUInteger cursor = 4;
    std::unordered_map<std::string, std::pair<uint32_t, uint32_t>> entries;
    for (uint32_t entryIndex = 0; entryIndex < count; ++entryIndex) {
        uint32_t nameLength = 0;
        if (!ReadUInt32(index, cursor, nameLength)) return false;
        cursor += 4;
        if (nameLength == 0 || cursor > index.length || index.length - cursor < nameLength) {
            return false;
        }
        NSData* nameData = [index subdataWithRange:NSMakeRange(cursor, nameLength)];
        NSString* name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithData:nameData encoding:NSShiftJISStringEncoding];
        cursor += nameLength;
        if (!name || cursor > index.length || index.length - cursor < 12) return false;
        cursor += 4; // reserved
        uint32_t offset = 0;
        uint32_t size = 0;
        if (!ReadUInt32(index, cursor, offset) || !ReadUInt32(index, cursor + 4, size)) {
            return false;
        }
        cursor += 8;
        if (static_cast<uint64_t>(offset) + size > data.length) return false;
        entries[NormalizePackPath(name.UTF8String ?: "")] = {offset, size};
    }
    pack.data = data;
    pack.index = index;
    pack.entries = std::move(entries);
    return true;
}

NSData* DecryptedEntry(const PackIndex& pack, const std::string& name) {
    auto entry = pack.entries.find(NormalizePackPath(name));
    if (entry == pack.entries.end()) return nil;
    const auto [offset, size] = entry->second;
    NSData* raw = [pack.data subdataWithRange:NSMakeRange(offset, size)];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(pack.index.bytes, static_cast<CC_LONG>(pack.index.length), digest);
    NSMutableData* decrypted = [raw mutableCopy];
    uint8_t* bytes = static_cast<uint8_t*>(decrypted.mutableBytes);
    for (NSUInteger index = 0; index < decrypted.length; ++index) {
        bytes[index] ^= digest[index % CC_SHA1_DIGEST_LENGTH];
    }
    return decrypted;
}

NSString* TablePathValue(NSString* table, NSString* key) {
    NSString* escapedKey = [NSRegularExpression escapedPatternForString:key];
    NSString* pattern = [NSString stringWithFormat:@"(?m)\\b%@\\s*=\\s*\\\"([^\\\"]+)\\\"", escapedKey];
    NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                 options:0
                                                                                   error:nil];
    NSTextCheckingResult* match = [expression firstMatchInString:table
                                                         options:0
                                                           range:NSMakeRange(0, table.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [table substringWithRange:[match rangeAtIndex:1]];
}

bool ResourcePrefixExists(
    NSString* gameRoot,
    const std::vector<PackIndex>& packs,
    NSString* prefix
) {
    if (!prefix.length) return false;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[gameRoot stringByAppendingPathComponent:prefix]]) {
        return true;
    }
    const std::string normalized = NormalizePackPath(prefix.UTF8String ?: "");
    for (const PackIndex& pack : packs) {
        for (const auto& entry : pack.entries) {
            if (entry.first.rfind(normalized, 0) == 0) return true;
        }
    }
    return false;
}

void RemovePlatformTableTemporaryFile() {
    for (NSString* path in gPlatformTableTemporaryFiles ?: @[]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    gPlatformTableTemporaryFiles = nil;
}

void PreparePlatformTableOverride(NSString* gameRoot) {
    RemovePlatformTableTemporaryFile();
    PlatformTableOverrides().clear();
    if (!gameRoot.length) return;

    NSArray<NSString*>* items = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:gameRoot error:nil];
    NSPredicate* packPredicate = [NSPredicate predicateWithBlock:^BOOL(NSString* name, NSDictionary*) {
        return [name isEqualToString:@"root.pfs"] || [name hasPrefix:@"root.pfs."];
    }];
    NSArray<NSString*>* packNames = [[items filteredArrayUsingPredicate:packPredicate]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    std::vector<PackIndex> packs;
    for (NSString* name in packNames) {
        PackIndex pack;
        if (LoadPackIndex([gameRoot stringByAppendingPathComponent:name], pack)) {
            packs.push_back(std::move(pack));
        }
    }

    NSString* iosTable = nil;
    NSString* windowsTable = nil;
    PackIndex* tablePack = nullptr;
    for (auto pack = packs.rbegin(); pack != packs.rend(); ++pack) {
        NSData* iosData = DecryptedEntry(*pack, "system/table/list_ios.tbl");
        NSData* windowsData = DecryptedEntry(*pack, "system/table/list_windows.tbl");
        if (iosData && windowsData) {
            iosTable = [[NSString alloc] initWithData:iosData encoding:NSUTF8StringEncoding];
            windowsTable = [[NSString alloc] initWithData:windowsData encoding:NSUTF8StringEncoding];
            if (iosTable && windowsTable) {
                tablePack = &*pack;
                break;
            }
        }
    }
    if (!iosTable || !windowsTable || !tablePack) return;

    bool needsDesktopTable = false;
    for (NSString* key in @[@"ui_path", @"image_path", @"movie_path"]) {
        NSString* iosPath = TablePathValue(iosTable, key);
        NSString* windowsPath = TablePathValue(windowsTable, key);
        if (!iosPath || !windowsPath || [iosPath isEqualToString:windowsPath]) continue;
        if (!ResourcePrefixExists(gameRoot, packs, iosPath)
            && ResourcePrefixExists(gameRoot, packs, windowsPath)) {
            needsDesktopTable = true;
            break;
        }
    }
    if (!needsDesktopTable) return;

    gPlatformTableTemporaryFiles = [NSMutableArray array];
    const std::string iosPrefix = "system/table/list_ios";
    const std::string windowsPrefix = "system/table/list_windows";
    for (const auto& entry : tablePack->entries) {
        const std::string& iosName = entry.first;
        if (iosName.rfind(iosPrefix, 0) != 0
            || iosName.size() < 4
            || iosName.compare(iosName.size() - 4, 4, ".tbl") != 0) {
            continue;
        }
        const std::string windowsName = windowsPrefix + iosName.substr(iosPrefix.size());
        NSData* desktopTable = DecryptedEntry(*tablePack, windowsName);
        if (!desktopTable) continue;
        NSString* temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"yoghourt-artemis-%d-%@-%s",
                getpid(), NSUUID.UUID.UUIDString.lowercaseString,
                iosName.substr(iosPrefix.size() + 1).c_str()]];
        if (![desktopTable writeToFile:temporaryPath atomically:YES]) continue;
        chmod(temporaryPath.fileSystemRepresentation, S_IRUSR | S_IWUSR);
        [gPlatformTableTemporaryFiles addObject:temporaryPath];
        PlatformTableOverrides()[iosName] = temporaryPath.fileSystemRepresentation;
    }
    std::fprintf(stderr, "[Yoghourt] ARTEMIS resource-table-override platform=windows tables=%zu\n",
        PlatformTableOverrides().size());
    std::fflush(stderr);
}

NSString* ArtemisGameIdentifier() {
    NSString* identifier = NSProcessInfo.processInfo.environment[@"YOGHOURT_GAME_ID"];
    identifier = identifier.lowercaseString;
    NSCharacterSet* invalidCharacters = [
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"]
        invertedSet
    ];
    if (identifier.length == 0
        || [identifier rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
        return nil;
    }
    return identifier;
}

NSString* IsolatedDocumentsDirectory() {
    static NSString* directory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* identifier = ArtemisGameIdentifier();
        NSString* configuredDirectory =
            NSProcessInfo.processInfo.environment[@"YOGHOURT_SAVE_ROOT"];
        if (!identifier || configuredDirectory.length == 0) {
            std::fputs(
                "[ArtemisSave] missing game identity or YOGHOURT_SAVE_ROOT; "
                "refusing to use the shared Documents directory\n",
                stderr
            );
            return;
        }

        directory = configuredDirectory.stringByStandardizingPath;

        NSError* error = nil;
        if (![[NSFileManager defaultManager]
                createDirectoryAtPath:directory
                withIntermediateDirectories:YES
                attributes:nil
                error:&error]) {
            std::fprintf(
                stderr,
                "[ArtemisSave] could not create isolated Documents directory: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error"
            );
            directory = nil;
            return;
        }
        std::fprintf(
            stderr,
            "[ArtemisSave] isolated Documents game=%s path=%s\n",
            identifier.UTF8String,
            directory.fileSystemRepresentation
        );
    });
    return directory;
}

bool IsPack(FILE* file) {
    std::lock_guard<std::mutex> lock(PackMutex());
    return PackFiles().find(file) != PackFiles().end();
}

void Trace(const char* format, ...) {
    if (!TraceEnabled()) return;
    va_list arguments;
    va_start(arguments, format);
    std::fputs("[ArtemisIO] ", stderr);
    std::vfprintf(stderr, format, arguments);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(arguments);
}

void ReplaceAll(std::string& value, const std::string& needle, const std::string& replacement) {
    size_t position = 0;
    while ((position = value.find(needle, position)) != std::string::npos) {
        value.replace(position, needle.size(), replacement);
        position += replacement.size();
    }
}

std::string ReplaceShaderTypes(std::string value) {
    value = std::regex_replace(value, std::regex("\\bfloat4\\b"), "vec4");
    value = std::regex_replace(value, std::regex("\\bfloat3\\b"), "vec3");
    value = std::regex_replace(value, std::regex("\\bfloat2\\b"), "vec2");
    return value;
}

bool TranslateHLSLPixelShader(const std::string& source, std::string& translated) {
    const size_t vertexStart = source.find("void vs");
    const size_t pixelStart = source.find("void ps");
    if (vertexStart == std::string::npos || pixelStart == std::string::npos) return false;

    const size_t bodyStart = source.find('{', pixelStart);
    if (bodyStart == std::string::npos) return false;
    size_t bodyEnd = std::string::npos;
    int depth = 0;
    for (size_t index = bodyStart; index < source.size(); ++index) {
        if (source[index] == '{') ++depth;
        if (source[index] == '}' && --depth == 0) {
            bodyEnd = index;
            break;
        }
    }
    if (bodyEnd == std::string::npos) return false;

    std::ostringstream output;
    output << "precision highp float;\n"
           << "varying vec2 resultCoord0;\n"
           << "varying vec2 resultCoord1;\n";

    std::unordered_set<std::string> textureNames;
    std::istringstream declarations(source.substr(0, vertexStart));
    std::string line;
    const std::regex texturePattern("^\\s*texture\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*;");
    const std::regex floatPattern(
        "^\\s*(const\\s+)?float([234])?\\s+[A-Za-z_][A-Za-z0-9_]*"
        "(\\s*\\[[0-9]+\\])?(\\s*=.*)?;"
    );
    while (std::getline(declarations, line)) {
        std::smatch match;
        if (std::regex_search(line, match, texturePattern)) {
            const std::string name = match[1].str();
            if (textureNames.insert(name).second) {
                output << "uniform sampler2D " << name << ";\n";
            }
            continue;
        }
        const size_t first = line.find_first_not_of(" \t\r");
        if (first == std::string::npos || line.compare(first, 2, "//") == 0) continue;
        if (line.compare(first, 8, "sampler ") == 0
            || line.compare(first, 10, "sampler2D ") == 0) {
            continue;
        }
        if (std::regex_search(line, floatPattern)) {
            const std::string converted = ReplaceShaderTypes(line.substr(first));
            if (converted.compare(0, 6, "const ") == 0) {
                output << converted << "\n";
            } else {
                output << "uniform " << converted << "\n";
            }
        }
    }

    std::string body = source.substr(bodyStart + 1, bodyEnd - bodyStart - 1);
    body = ReplaceShaderTypes(body);
    ReplaceAll(body, "texCoord0", "resultCoord0");
    ReplaceAll(body, "texCoord1", "resultCoord1");
    for (const std::string& texture : textureNames) {
        const std::string prefix = "texture";
        if (texture.compare(0, prefix.size(), prefix) != 0) continue;
        const std::string suffix = texture.substr(prefix.size());
        ReplaceAll(body, "tex2D(sampler" + suffix + ",", "texture2D(" + texture + ",");
    }
    body = std::regex_replace(
        body,
        std::regex("(^|\\n)([ \\t]*)result\\s*="),
        "$1$2gl_FragColor ="
    );

    const char* unsupported[] = {
        "tex2D(", "samplerBack", "samplerFore", "samplerMask",
        "samplerUser", "float2", "float3", "float4", "result ="
    };
    for (const char* token : unsupported) {
        if (body.find(token) != std::string::npos) return false;
    }
    if (body.find("gl_FragColor") == std::string::npos) return false;

    output << "\nvoid main()\n{\n" << body << "\n}\n";
    translated = output.str();
    return true;
}

FILE* TraceFOpen(const char* path, const char* mode) {
    FOpen original = Original<FOpen>("fopen");
    std::string overridePath;
    if (path && mode && mode[0] == 'r') {
        const std::string normalized = NormalizePackPath(path);
        std::lock_guard<std::mutex> lock(PackMutex());
        for (const auto& table : PlatformTableOverrides()) {
            if (normalized.size() >= table.first.size()
                && normalized.compare(
                    normalized.size() - table.first.size(),
                    table.first.size(),
                    table.first
                ) == 0) {
                overridePath = table.second;
                break;
            }
        }
    }
    FILE* file = overridePath.empty() ? original(path, mode) : original(overridePath.c_str(), mode);
    if (file && !overridePath.empty()) {
        Trace("redirect platform table path=%s -> %s", path, overridePath.c_str());
    }
    if (!file && path) {
        const char* packName = std::strstr(path, "root.pfs");
        if (packName && (packName == path || packName[-1] == '/')) {
            // The iOS static runtime derives the main pack path from argv[0],
            // while its loose files and system.ini are resolved from cwd.
            // Yoghourt deliberately selects the game directory as cwd, so
            // retry the pack basename there instead of requiring game data
            // inside the signed application bundle.
            std::string redirectedPath;
            {
                std::lock_guard<std::mutex> lock(PackMutex());
                if (!GameRoot().empty()) {
                    redirectedPath = GameRoot();
                    if (redirectedPath.back() != '/') redirectedPath.push_back('/');
                    redirectedPath.append(packName);
                }
            }
            const char* redirected = redirectedPath.empty()
                ? packName
                : redirectedPath.c_str();
            file = original(redirected, mode);
            if (TraceEnabled() && (file || std::strcmp(packName, "root.pfs") == 0)) {
                Trace(
                    "redirect pack path=%s -> %s result=%p",
                    path,
                    redirected,
                    file
                );
            }
        }
    }
    if (TraceEnabled() && path
        && (file || !std::strstr(path, "root.pfs."))) {
        Trace("fopen path=%s mode=%s result=%p", path, mode ?: "", file);
    }
    if (TraceEnabled() && path && std::strstr(path, "root.pfs")) {
        {
            std::lock_guard<std::mutex> lock(PackMutex());
            if (file) PackFiles().insert(file);
        }
    }
    return file;
}

int TraceFClose(FILE* file) {
    if (TraceEnabled()) {
        std::lock_guard<std::mutex> lock(PackMutex());
        PackFiles().erase(file);
    }
    return Original<FClose>("fclose")(file);
}

size_t TraceFRead(void* buffer, size_t size, size_t count, FILE* file) {
    const bool pack = TraceEnabled() && IsPack(file);
    long before = pack ? Original<FTell>("ftell")(file) : -1;
    size_t result = Original<FRead>("fread")(buffer, size, count, file);
    if (pack && (before >= 0x7fff'ffffL || result != count)) {
        long after = Original<FTell>("ftell")(file);
        Trace(
            "fread file=%p offset=%ld size=%zu count=%zu result=%zu after=%ld error=%d eof=%d",
            file,
            before,
            size,
            count,
            result,
            after,
            std::ferror(file),
            std::feof(file)
        );
    }
    return result;
}

int TraceFSeek(FILE* file, long offset, int origin) {
    const bool pack = TraceEnabled() && IsPack(file);
    int result = Original<FSeek>("fseek")(file, offset, origin);
    if (pack && (offset >= 0x7fff'ffffL || offset < 0 || result != 0)) {
        long after = Original<FTell>("ftell")(file);
        Trace(
            "fseek file=%p offset=%ld origin=%d result=%d after=%ld errno=%d",
            file,
            offset,
            origin,
            result,
            after,
            errno
        );
    }
    return result;
}

long TraceFTell(FILE* file) {
    long result = Original<FTell>("ftell")(file);
    if (TraceEnabled() && IsPack(file) && (result >= 0x7fff'ffffL || result < 0)) {
        Trace("ftell file=%p result=%ld errno=%d", file, result, errno);
    }
    return result;
}

} // namespace

extern "C" void ArtemisSetGameRoot(const char* path) {
    NSString* root = path ? [NSString stringWithUTF8String:path] : nil;
    PreparePlatformTableOverride(root);
    {
        std::lock_guard<std::mutex> lock(PackMutex());
        GameRoot() = path ?: "";
    }
    static std::once_flag cleanupRegistration;
    std::call_once(cleanupRegistration, [] { std::atexit(RemovePlatformTableTemporaryFile); });
}

extern "C" NSArray<NSString*>* YoghourtPathForDirectoriesInDomains(
    NSSearchPathDirectory directory,
    NSSearchPathDomainMask domainMask,
    BOOL expandTilde
) {
    if (directory == NSDocumentDirectory && (domainMask & NSUserDomainMask) != 0) {
        NSString* isolatedDirectory = IsolatedDocumentsDirectory();
        if (isolatedDirectory) return @[isolatedDirectory];
        // A missing game identity must not silently reopen the shared save
        // directory. Returning no path makes the SDK report a normal storage
        // initialization failure instead of mixing two games' saves.
        return @[];
    }
    return NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
}

extern "C" FILE* yopen(const char* path, const char* mode) {
    return TraceFOpen(path, mode);
}

extern "C" int yclose(FILE* file) {
    return TraceFClose(file);
}

extern "C" size_t yread(void* buffer, size_t size, size_t count, FILE* file) {
    return TraceFRead(buffer, size, count, file);
}

extern "C" int yseek(FILE* file, long offset, int origin) {
    return TraceFSeek(file, offset, origin);
}

extern "C" long ytell(FILE* file) {
    return TraceFTell(file);
}

extern "C" __attribute__((noreturn)) void yxit(int status) {
    void* frames[64];
    int count = backtrace(frames, 64);
    std::fprintf(stderr, "[ArtemisIO] engine requested exit status=%d\n", status);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    _exit(status);
}

extern "C" __attribute__((noreturn)) void ybort() {
    void* frames[64];
    int count = backtrace(frames, 64);
    std::fputs("[ArtemisIO] engine requested abort\n", stderr);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    abort();
}

extern "C" void ygShaderSource(
    GLuint shader,
    GLsizei count,
    const GLchar* const* strings,
    const GLint* lengths
) {
    std::string source;
    for (GLsizei index = 0; index < count; ++index) {
        if (!strings[index]) continue;
        const size_t length = lengths && lengths[index] >= 0
            ? static_cast<size_t>(lengths[index])
            : std::strlen(strings[index]);
        source.append(strings[index], length);
    }

    std::string translated;
    if (source.find("void main") == std::string::npos
        && TranslateHLSLPixelShader(source, translated)) {
        const GLchar* translatedSource = translated.c_str();
        const GLint translatedLength = static_cast<GLint>(translated.size());
        std::fprintf(
            stderr,
            "[ArtemisGL] translated legacy HLSL effect to GLSL (%zu -> %zu bytes)\n",
            source.size(),
            translated.size()
        );
        glShaderSource(shader, 1, &translatedSource, &translatedLength);
        return;
    }

    if (std::getenv("YOGHOURT_ARTEMIS_SHADER_TRACE")) {
        std::fputs("[ArtemisGL] shader source begin\n", stderr);
        std::fwrite(source.data(), 1, source.size(), stderr);
        std::fputs("\n[ArtemisGL] shader source end\n", stderr);
        std::fflush(stderr);
    }
    glShaderSource(shader, count, strings, lengths);
}
