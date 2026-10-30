#include "ChecklistFileAccess.h"

// Lexical skipping only: callers first validate the complete JSON document.
// Keep the explicit byte count because JSON strings may contain arbitrary UTF-8.
static int string_end(const uint8_t *bytes, size_t count, size_t *index) {
    if (*index >= count || bytes[*index] != '"') return 0;
    ++*index;
    while (*index < count) {
        uint8_t byte = bytes[(*index)++];
        if (byte == '\\') {
            if (*index >= count) return 0;
            ++*index;
        } else if (byte == '"') {
            return 1;
        }
    }
    return 0;
}

int checklist_json_value_end(const uint8_t *bytes, size_t count, size_t start, size_t *end) {
    if (bytes == NULL || end == NULL || start >= count) return 0;
    size_t index = start;
    if (bytes[index] == '"') {
        if (!string_end(bytes, count, &index)) return 0;
    } else if (bytes[index] == '{' || bytes[index] == '[') {
        size_t depth = 0;
        do {
            if (index >= count) return 0;
            uint8_t byte = bytes[index];
            if (byte == '"') {
                if (!string_end(bytes, count, &index)) return 0;
                continue;
            }
            if (byte == '{' || byte == '[') ++depth;
            if (byte == '}' || byte == ']') --depth;
            ++index;
        } while (depth > 0);
    } else {
        while (index < count) {
            switch (bytes[index]) {
                case 9: case 10: case 13: case 32: case ',': case '}':
                    *end = index;
                    return index > start;
                default: ++index;
            }
        }
    }
    *end = index;
    return index > start;
}
