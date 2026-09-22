/*
 * Standalone BOB-16 assembler in C.
 * Architecture credit: misterbob / somerandomviolinkid
 *
 * Translates BOB-16 assembly (.basm) to 16-bit hex words (.hex) for $readmemh.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>

#define DEFAULT_WORDS 4096
#define MAX_WORDS     65536
#define MAX_ARGS      16
#define LINE_BUF_SIZE 4096

static char g_err_msg[512] = {0};

static void set_error(const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    memcpy(g_err_msg, tmp, sizeof(g_err_msg));
}

static char *trim(char *s) {
    while (isspace((unsigned char)*s)) s++;
    if (!*s) return s;
    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

static void strip_comment(char *s) {
    char quote = '\0';
    bool escaped = false;
    for (size_t i = 0; s[i] != '\0'; i++) {
        char c = s[i];
        if (escaped) escaped = false;
        else if (c == '\\' && quote != '\0') escaped = true;
        else if (quote != '\0' && c == quote) quote = '\0';
        else if (quote == '\0' && (c == '"' || c == '\'')) quote = c;
        else if (quote == '\0' && c == ';') { s[i] = '\0'; return; }
    }
}

static bool match_label(const char *text, char *out, size_t out_sz, const char **after) {
    if (!isalpha((unsigned char)*text) && *text != '_') return false;
    size_t i = 0;
    while (isalnum((unsigned char)text[i]) || text[i] == '_') i++;
    if (text[i] != ':' || i >= out_sz) return false;
    memcpy(out, text, i);
    out[i] = '\0';
    *after = text + i + 1;
    return true;
}

typedef struct {
    char *name;
    uint16_t addr;
} Label;

typedef struct {
    Label *items;
    size_t count;
    size_t cap;
} LabelTable;

static void label_table_init(LabelTable *lt) {
    lt->count = 0;
    lt->cap = 64;
    lt->items = malloc(lt->cap * sizeof(Label));
}

static void label_table_free(LabelTable *lt) {
    for (size_t i = 0; i < lt->count; i++) free(lt->items[i].name);
    free(lt->items);
    lt->items = NULL;
    lt->count = lt->cap = 0;
}

static bool label_table_find(const LabelTable *lt, const char *name, uint16_t *out_addr) {
    for (size_t i = 0; i < lt->count; i++) {
        if (strcmp(lt->items[i].name, name) == 0) {
            if (out_addr) *out_addr = lt->items[i].addr;
            return true;
        }
    }
    return false;
}

static bool label_table_add(LabelTable *lt, const char *name, uint16_t addr) {
    if (label_table_find(lt, name, NULL)) return false;
    if (lt->count >= lt->cap) {
        lt->cap *= 2;
        Label *items = realloc(lt->items, lt->cap * sizeof(Label));
        if (!items) return false;
        lt->items = items;
    }
    lt->items[lt->count].name = strdup(name);
    lt->items[lt->count].addr = addr;
    lt->count++;
    return true;
}

static bool parse_number(const char *text, bool fill, long *out_val) {
    while (isspace((unsigned char)*text)) text++;
    if (!*text) {
        set_error("empty number string");
        return false;
    }
    if (*text == '#') {
        text++;
        char *end;
        errno = 0;
        long val = strtol(text, &end, 10);
        if (errno || end == text || *end != '\0') {
            set_error("invalid decimal literal: %s", text - 1);
            return false;
        }
        *out_val = val;
        return true;
    }

    long sign = 1;
    if (*text == '+') text++;
    else if (*text == '-') { sign = -1; text++; }

    int base = 10;
    if (text[0] == '0' && tolower((unsigned char)text[1]) == 'x') {
        base = 16; text += 2;
    } else if (text[0] == '0' && tolower((unsigned char)text[1]) == 'b') {
        base = 2; text += 2;
    } else if (text[0] == '0' && tolower((unsigned char)text[1]) == 'o') {
        base = 8; text += 2;
    } else if (fill) {
        base = 16;
    }

    char *end;
    errno = 0;
    long val = strtol(text, &end, base);
    if (errno || end == text || *end != '\0') {
        set_error("invalid integer literal: %s", text);
        return false;
    }
    *out_val = sign * val;
    return true;
}

static bool is_reg(const char *s) {
    return s && tolower((unsigned char)s[0]) == 'r' && s[1] >= '0' && s[1] <= '7' && s[2] == '\0';
}

static bool parse_reg(const char *s, int *out_reg) {
    if (!is_reg(s)) {
        set_error("invalid register: %s", s);
        return false;
    }
    *out_reg = s[1] - '0';
    return true;
}

static bool signed_field(long value, int bits, uint16_t *out_val) {
    long lo = -(1L << (bits - 1)), hi = (1L << (bits - 1)) - 1;
    if (value < lo || value > hi) {
        set_error("%ld is outside signed %d-bit range %ld..%ld", value, bits, lo, hi);
        return false;
    }
    *out_val = (uint16_t)(value & ((1L << bits) - 1));
    return true;
}

static bool resolve_value(const char *s, const LabelTable *lt, bool fill, long *out_val) {
    uint16_t laddr;
    if (label_table_find(lt, s, &laddr)) {
        *out_val = (long)laddr;
        return true;
    }
    return parse_number(s, fill, out_val);
}

static bool resolve_offset(const char *s, int bits, uint16_t pc, const LabelTable *lt, uint16_t *out_val) {
    long n = 0;
    uint16_t laddr = 0;
    if (label_table_find(lt, s, &laddr)) {
        n = (long)laddr;
        n = (n - ((pc + 1) & 0xffff)) & 0xffff;
        if (n & 0x8000) n -= 0x10000;
    } else {
        if (!parse_number(s, false, &n)) return false;
    }
    return signed_field(n, bits, out_val);
}

static bool parse_stringz(const char *s, uint16_t *dest, size_t *out_len) {
    while (isspace((unsigned char)*s)) s++;
    size_t count = 0;
    if (*s == '"' || *s == '\'') {
        char quote = *s++;
        while (*s && *s != quote) {
            unsigned char c;
            if (*s == '\\') {
                s++;
                if (!*s) { set_error("invalid quoted string"); return false; }
                switch (*s) {
                    case 'n':  c = '\n'; s++; break;
                    case 't':  c = '\t'; s++; break;
                    case 'r':  c = '\r'; s++; break;
                    case 'a':  c = '\a'; s++; break;
                    case 'b':  c = '\b'; s++; break;
                    case 'f':  c = '\f'; s++; break;
                    case 'v':  c = '\v'; s++; break;
                    case '\\': c = '\\'; s++; break;
                    case '\'': c = '\''; s++; break;
                    case '"':  c = '"';  s++; break;
                    case '0':  c = '\0'; s++; break;
                    case 'x':
                    case 'X': {
                        if (!isxdigit((unsigned char)s[1]) || !isxdigit((unsigned char)s[2])) {
                            set_error("invalid hex escape in string");
                            return false;
                        }
                        char hex[3] = {s[1], s[2], '\0'};
                        c = (unsigned char)strtol(hex, NULL, 16);
                        s += 3;
                        break;
                    }
                    default:   c = (unsigned char)*s++; break;
                }
            } else {
                c = (unsigned char)*s++;
            }
            if (dest) dest[count] = c;
            count++;
        }
        if (*s != quote) { set_error("invalid quoted string"); return false; }
        s++;
        while (isspace((unsigned char)*s)) s++;
        if (*s != '\0') { set_error("trailing characters after quoted string"); return false; }
    } else {
        if (!*s) { set_error(".stringz expects 1 operand(s)"); return false; }
        for (const char *p = s; *p; p++) {
            if (isspace((unsigned char)*p)) { set_error("quote strings containing spaces"); return false; }
        }
        while (*s) {
            if (dest) dest[count] = (uint16_t)(unsigned char)*s;
            count++;
            s++;
        }
    }
    if (dest) dest[count] = 0;
    count++;
    *out_len = count;
    return true;
}

static char *split_op(char *text, char *op, size_t op_sz) {
    size_t i = 0;
    while (text[i] && !isspace((unsigned char)text[i])) {
        if (i < op_sz - 1) {
            op[i] = (char)tolower((unsigned char)text[i]);
            i++;
        } else {
            break;
        }
    }
    op[i] = '\0';
    return trim(text + i);
}

static int split_args(char *rest, char **args, int max_args) {
    for (int i = 0; rest[i]; i++) {
        if (rest[i] == ',') rest[i] = ' ';
    }
    int argc = 0;
    char *token = strtok(rest, " \t\r\n");
    while (token && argc < max_args) {
        args[argc++] = token;
        token = strtok(NULL, " \t\r\n");
    }
    return argc;
}

static bool check_argc(const char *op, int argc, int min, int max) {
    if (argc < min || argc > max) {
        if (min == max) set_error("%s expects %d operand(s)", op, min);
        else set_error("%s expects %d or %d operand(s)", op, min, max);
        return false;
    }
    return true;
}

static bool encode_inst(const char *op, char **a, int argc, uint16_t pc,
                        const LabelTable *labels, uint16_t *out_word) {
    if (strcmp(op, ".fill") == 0) {
        if (!check_argc(op, argc, 1, 1)) return false;
        long n;
        if (!resolve_value(a[0], labels, true, &n)) return false;
        if (n < -32768 || n > 65535) {
            set_error(".fill value does not fit one 16-bit word");
            return false;
        }
        *out_word = (uint16_t)(n & 0xffff);
        return true;
    }
    if (strcmp(op, "nop") == 0) {
        if (!check_argc(op, argc, 0, 0)) return false;
        *out_word = 0x0000;
        return true;
    }
    if (strcmp(op, "ret") == 0) {
        if (!check_argc(op, argc, 0, 0)) return false;
        *out_word = 0xe000;
        return true;
    }
    if (strcmp(op, "add") == 0 || strcmp(op, "and") == 0) {
        if (!check_argc(op, argc, 2, 3)) return false;
        int rd;
        if (!parse_reg(a[0], &rd)) return false;
        uint16_t word = ((op[1] == 'd' ? 1 : 2) << 12) | ((uint16_t)rd << 9);
        if (argc == 3) {
            int ra;
            if (!parse_reg(a[1], &ra)) return false;
            word |= ((uint16_t)ra << 4);
            if (is_reg(a[2])) {
                int rb;
                parse_reg(a[2], &rb);
                word |= ((uint16_t)rb << 1);
            } else {
                long val;
                if (!resolve_value(a[2], labels, false, &val)) return false;
                uint16_t imm;
                if (!signed_field(val, 4, &imm)) return false;
                word |= (1 << 7) | imm;
            }
        } else {
            if (is_reg(a[1])) {
                int ra;
                parse_reg(a[1], &ra);
                word |= (2 << 7) | ((uint16_t)ra << 4);
            } else {
                long val;
                if (!resolve_value(a[1], labels, false, &val)) return false;
                uint16_t imm;
                if (!signed_field(val, 7, &imm)) return false;
                word |= (3 << 7) | imm;
            }
        }
        *out_word = word;
        return true;
    }
    if (strcmp(op, "not") == 0) {
        if (!check_argc(op, argc, 1, 2)) return false;
        int rd;
        if (!parse_reg(a[0], &rd)) return false;
        uint16_t word = 0x3000 | ((uint16_t)rd << 9);
        if (argc == 1) word |= 0x0100;
        else {
            int ra;
            if (!parse_reg(a[1], &ra)) return false;
            word |= ((uint16_t)ra << 5);
        }
        *out_word = word;
        return true;
    }
    if (strcmp(op, "ld") == 0 || strcmp(op, "ldi") == 0 ||
        strcmp(op, "st") == 0 || strcmp(op, "sti") == 0 ||
        strcmp(op, "lea") == 0) {
        if (!check_argc(op, argc, 2, 2)) return false;
        int rd;
        if (!parse_reg(a[0], &rd)) return false;
        uint16_t opc = (strcmp(op, "ld") == 0) ? 4 :
                       (strcmp(op, "ldi") == 0) ? 5 :
                       (strcmp(op, "st") == 0) ? 7 :
                       (strcmp(op, "sti") == 0) ? 8 : 13;
        uint16_t off;
        if (!resolve_offset(a[1], 9, pc, labels, &off)) return false;
        *out_word = (opc << 12) | ((uint16_t)rd << 9) | off;
        return true;
    }
    if (strcmp(op, "ldr") == 0 || strcmp(op, "str") == 0) {
        if (!check_argc(op, argc, 3, 3)) return false;
        int rd, rbase;
        if (!parse_reg(a[0], &rd) || !parse_reg(a[1], &rbase)) return false;
        long val;
        if (!resolve_value(a[2], labels, false, &val)) return false;
        uint16_t off;
        if (!signed_field(val, 6, &off)) return false;
        uint16_t opc = (op[0] == 'l') ? 6 : 9;
        *out_word = (opc << 12) | ((uint16_t)rd << 9) | ((uint16_t)rbase << 6) | off;
        return true;
    }
    if (strcmp(op, "br") == 0) {
        if (!check_argc(op, argc, 2, 2)) return false;
        const char *flags = a[0];
        if (!*flags) {
            set_error("branch flags must be a non-repeated combination of n, z, p");
            return false;
        }
        bool seen_n = false, seen_z = false, seen_p = false;
        uint16_t mask = 0;
        for (int i = 0; flags[i]; i++) {
            char c = (char)tolower((unsigned char)flags[i]);
            if (c == 'n' && !seen_n) { seen_n = true; mask |= 4; }
            else if (c == 'z' && !seen_z) { seen_z = true; mask |= 2; }
            else if (c == 'p' && !seen_p) { seen_p = true; mask |= 1; }
            else {
                set_error("branch flags must be a non-repeated combination of n, z, p");
                return false;
            }
        }
        uint16_t off;
        if (!resolve_offset(a[1], 9, pc, labels, &off)) return false;
        *out_word = 0xa000 | (mask << 9) | off;
        return true;
    }
    if (strcmp(op, "jmp") == 0) {
        if (!check_argc(op, argc, 1, 1)) return false;
        int rbase;
        if (!parse_reg(a[0], &rbase)) return false;
        *out_word = 0xb000 | ((uint16_t)rbase << 9);
        return true;
    }
    if (strcmp(op, "jsr") == 0) {
        if (!check_argc(op, argc, 1, 1)) return false;
        uint16_t off;
        if (!resolve_offset(a[0], 11, pc, labels, &off)) return false;
        *out_word = 0xc000 | off;
        return true;
    }
    if (strcmp(op, "jsrr") == 0) {
        if (!check_argc(op, argc, 1, 1)) return false;
        int rbase;
        if (!parse_reg(a[0], &rbase)) return false;
        *out_word = 0xc800 | ((uint16_t)rbase << 8);
        return true;
    }
    if (strcmp(op, "trap") == 0) {
        if (!check_argc(op, argc, 1, 1)) return false;
        long n;
        if (!resolve_value(a[0], labels, false, &n)) return false;
        if (n < 0 || n > 3) {
            set_error("implemented trap vectors are 0..3");
            return false;
        }
        *out_word = 0xf000 | ((uint16_t)n << 8);
        return true;
    }

    set_error("unknown instruction/directive: %s", op);
    return false;
}

static bool emit_words(uint16_t *image, uint8_t *used, uint16_t addr,
                       const uint16_t *words, size_t n, int lineno) {
    for (size_t i = 0; i < n; i++) {
        uint16_t a = addr + (uint16_t)i;
        if (used[a]) {
            set_error("line %d: overlapping output at 0x%04x", lineno, a);
            return false;
        }
    }
    for (size_t i = 0; i < n; i++) {
        uint16_t a = addr + (uint16_t)i;
        used[a] = 1;
        image[a] = words ? words[i] : 0;
    }
    return true;
}

static char *process_line_labels(char *line, LabelTable *lt, uint16_t pc, int words, int lineno) {
    strip_comment(line);
    char *text = trim(line);
    char name[128];
    const char *after;
    while (match_label(text, name, sizeof(name), &after)) {
        if (lt) {
            if (pc >= words) {
                set_error("line %d: label outside memory", lineno);
                return NULL;
            }
            if (!label_table_add(lt, name, pc)) {
                set_error("line %d: duplicate label: %s", lineno, name);
                return NULL;
            }
        }
        text = trim((char *)after);
    }
    return text;
}

static bool parse_org(const char *rest, int words, int lineno, uint16_t *out_pc) {
    char buf[128];
    strncpy(buf, rest, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *args[4];
    int argc = split_args(buf, args, 4);
    if (argc != 1) {
        set_error("line %d: .org expects one numeric address", lineno);
        return false;
    }
    long new_pc;
    if (!parse_number(args[0], false, &new_pc)) {
        set_error("line %d: %s", lineno, g_err_msg);
        return false;
    }
    if (new_pc < 0 || new_pc >= words) {
        set_error("line %d: .org is outside configured memory", lineno);
        return false;
    }
    *out_pc = (uint16_t)new_pc;
    return true;
}

static bool parse_space_count(const char *rest, int words, int lineno, size_t *out_count) {
    char buf[128];
    strncpy(buf, rest, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *args[4];
    int argc = split_args(buf, args, 4);
    if (argc != 1) {
        set_error("line %d: .space expects one count", lineno);
        return false;
    }
    long count;
    if (!parse_number(args[0], false, &count)) {
        set_error("line %d: %s", lineno, g_err_msg);
        return false;
    }
    if (count < 0 || count > words) {
        set_error("line %d: invalid .space count", lineno);
        return false;
    }
    *out_count = (size_t)count;
    return true;
}

static uint16_t *assemble_source(const char *source, int words, int *out_count) {
    if (words < 1 || words > MAX_WORDS) {
        set_error("memory size must be 1..65536 words");
        return NULL;
    }

    LabelTable labels;
    label_table_init(&labels);

    char line[LINE_BUF_SIZE];
    uint16_t pc = 0;
    int lineno = 0;
    const char *p = source;

    /* Pass 1: Parse labels, directives, and advance PC */
    while (*p) {
        lineno++;
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = nl ? nl + 1 : p + len;

        char *text = process_line_labels(line, &labels, pc, words, lineno);
        if (!text) goto error;
        if (!*text) continue;

        char op[64];
        char *rest = split_op(text, op, sizeof(op));
        if (strcmp(op, ".org") == 0) {
            if (!parse_org(rest, words, lineno, &pc)) goto error;
            continue;
        }

        size_t length = 1;
        if (strcmp(op, ".stringz") == 0) {
            if (!parse_stringz(rest, NULL, &length)) {
                set_error("line %d: %s", lineno, g_err_msg);
                goto error;
            }
        } else if (strcmp(op, ".space") == 0) {
            if (!parse_space_count(rest, words, lineno, &length)) goto error;
        }

        if (pc + length > (size_t)words) {
            set_error("line %d: program exceeds configured memory", lineno);
            goto error;
        }
        pc += (uint16_t)length;
    }

    uint16_t *image = calloc(words, sizeof(uint16_t));
    uint8_t *used = calloc(words, sizeof(uint8_t));
    if (!image || !used) {
        free(image); free(used);
        set_error("out of memory");
        goto error;
    }

    /* Pass 2: Encode instructions and directives */
    pc = 0;
    lineno = 0;
    p = source;
    while (*p) {
        lineno++;
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';
        p = nl ? nl + 1 : p + len;

        char *text = process_line_labels(line, NULL, pc, words, lineno);
        if (!*text) continue;

        char op[64];
        char *rest = split_op(text, op, sizeof(op));
        if (strcmp(op, ".org") == 0) {
            parse_org(rest, words, lineno, &pc);
            continue;
        }

        if (strcmp(op, ".stringz") == 0) {
            size_t count = 0;
            uint16_t str_words[1024];
            parse_stringz(rest, str_words, &count);
            if (!emit_words(image, used, pc, str_words, count, lineno)) {
                free(image); free(used); goto error;
            }
            pc += (uint16_t)count;
        } else if (strcmp(op, ".space") == 0) {
            size_t count = 0;
            parse_space_count(rest, words, lineno, &count);
            if (!emit_words(image, used, pc, NULL, count, lineno)) {
                free(image); free(used); goto error;
            }
            pc += (uint16_t)count;
        } else {
            char *args[MAX_ARGS];
            int argc = split_args(rest, args, MAX_ARGS);
            uint16_t word;
            if (!encode_inst(op, args, argc, pc, &labels, &word)) {
                set_error("line %d: %s", lineno, g_err_msg);
                free(image); free(used); goto error;
            }
            if (!emit_words(image, used, pc, &word, 1, lineno)) {
                free(image); free(used); goto error;
            }
            pc++;
        }
    }

    free(used);
    label_table_free(&labels);
    *out_count = words;
    return image;

error:
    label_table_free(&labels);
    return NULL;
}

static void make_parent_dirs(const char *path) {
    char buf[1024];
    size_t len = strlen(path);
    if (len >= sizeof(buf)) return;
    memcpy(buf, path, len + 1);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0755);
            *p = '/';
        }
    }
}

static bool write_hex(const char *path, const uint16_t *image, int words) {
    make_parent_dirs(path);
    FILE *fp = fopen(path, "w");
    if (!fp) {
        set_error("cannot open output file %s: %s", path, strerror(errno));
        return false;
    }
    for (int i = 0; i < words; i++) {
        fprintf(fp, "%04x\n", image[i]);
    }
    fclose(fp);
    return true;
}

static char *read_entire_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        set_error("cannot open source file %s: %s", path, strerror(errno));
        return NULL;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        set_error("cannot seek source file %s: %s", path, strerror(errno));
        return NULL;
    }
    long size = ftell(fp);
    if (size < 0) {
        fclose(fp);
        set_error("cannot get size of source file %s: %s", path, strerror(errno));
        return NULL;
    }
    rewind(fp);
    char *buf = malloc((size_t)size + 1);
    if (!buf) {
        fclose(fp);
        set_error("out of memory reading %s", path);
        return NULL;
    }
    size_t read_bytes = fread(buf, 1, (size_t)size, fp);
    buf[read_bytes] = '\0';
    fclose(fp);
    return buf;
}

static void print_usage(const char *prog_name) {
    fprintf(stderr, "usage: %s source -o OUTPUT [--words WORDS]\n", prog_name);
    fprintf(stderr, "Corrected BOB-16 assembler.\n\n");
    fprintf(stderr, "positional arguments:\n  source                source .basm file\n\n");
    fprintf(stderr, "options:\n");
    fprintf(stderr, "  -h, --help            show this help message and exit\n");
    fprintf(stderr, "  -o OUTPUT, --output OUTPUT\n                        destination .hex file\n");
    fprintf(stderr, "  --words WORDS         RAM depth, default 4096 words\n");
}

int main(int argc, char **argv) {
    const char *source_path = NULL;
    const char *output_path = NULL;
    int words = DEFAULT_WORDS;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "assembly failed: option %s requires an argument\n", argv[i - 1]);
                return 1;
            }
            output_path = argv[i];
            continue;
        }
        if (strcmp(argv[i], "--words") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "assembly failed: option %s requires an argument\n", argv[i - 1]);
                return 1;
            }
            words = atoi(argv[i]);
            continue;
        }
        if (argv[i][0] == '-') {
            fprintf(stderr, "assembly failed: unrecognized option %s\n", argv[i]);
            return 1;
        }
        if (source_path) {
            fprintf(stderr, "assembly failed: multiple source files specified\n");
            return 1;
        }
        source_path = argv[i];
    }

    if (!source_path || !output_path) {
        print_usage(argv[0]);
        return 1;
    }

    char *source_text = read_entire_file(source_path);
    if (!source_text) {
        fprintf(stderr, "assembly failed: %s\n", g_err_msg);
        return 1;
    }

    int word_count = 0;
    uint16_t *image = assemble_source(source_text, words, &word_count);
    free(source_text);

    if (!image) {
        fprintf(stderr, "assembly failed: %s\n", g_err_msg);
        return 1;
    }

    if (!write_hex(output_path, image, word_count)) {
        fprintf(stderr, "assembly failed: %s\n", g_err_msg);
        free(image);
        return 1;
    }

    printf("%s -> %s (%d words)\n", source_path, output_path, word_count);
    free(image);
    return 0;
}
