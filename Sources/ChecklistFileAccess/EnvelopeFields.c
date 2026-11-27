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

int checklist_json_is_plain_object(const uint8_t *bytes, size_t count) {
    if (bytes == NULL || count == 0 || bytes[0] != '{') return 0;
    size_t depth = 0;
    int in_string = 0;
    for (size_t index = 0; index < count; ++index) {
        uint8_t byte = bytes[index];
        if (byte == 0 || byte >= 0x80) return 0;
        // JSON1 can stop at an embedded NUL. Check the complete byte value.
        if (index > 0 && depth == 0) {
            if (byte != ' ' && byte != '\t' && byte != '\n' && byte != '\r') return 0;
            continue;
        }
        if (in_string) {
            if (byte < 0x20) return 0;
            if (byte == '\\') {
                // SQLite and Foundation can disagree on escaped Unicode.
                if (++index >= count || bytes[index] < 0x20 || bytes[index] == 'u' || bytes[index] >= 0x80) return 0;
            } else if (byte == '"') in_string = 0;
        } else if (byte == '"') {
            in_string = 1;
        } else if (byte == '{' || byte == '[') {
            if (++depth > 64) return 0;
        } else if (byte == '}' || byte == ']') {
            if (depth == 0) return 0;
            --depth;
        } else if (byte == '-' || (byte >= '0' && byte <= '9')) {
            size_t start = index;
            // A short plain decimal has no overflow or unrepresentable exponent.
            while (index + 1 < count) {
                uint8_t next = bytes[index + 1];
                if (next == 'e' || next == 'E') return 0;
                if (next != '.' && (next < '0' || next > '9')) break;
                ++index;
                if (index - start >= 18) return 0;
            }
        }
    }
    return depth == 0 && !in_string;
}
