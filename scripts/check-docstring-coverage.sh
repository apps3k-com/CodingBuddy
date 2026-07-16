#!/bin/sh
# Deterministically measures documentation coverage for the app target's Swift API.
# Uses only POSIX shell/awk so local macOS runs and GitHub's Ubuntu runner agree.
set -eu
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
SOURCE_ROOT=$ROOT
MINIMUM=${DOCSTRING_MINIMUM:-90}
FORMAT=human

usage() {
    cat <<'EOF'
Usage: ./scripts/check-docstring-coverage.sh [--json] [--minimum PERCENT] [--source-root DIRECTORY]

Measures /// coverage for module-level and member Swift declarations.
The default minimum is 90; DOCSTRING_MINIMUM may override it.
The source root override exists for deterministic checker fixture tests.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json)
            FORMAT=json
            shift
            ;;
        --minimum)
            [ "$#" -ge 2 ] || { echo "error: --minimum requires a value" >&2; exit 2; }
            MINIMUM=$2
            shift 2
            ;;
        --source-root)
            [ "$#" -ge 2 ] || { echo "error: --source-root requires a directory" >&2; exit 2; }
            SOURCE_ROOT=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$MINIMUM" in
    ''|*[!0-9]*)
        echo "error: minimum must be an integer from 0 through 100" >&2
        exit 2
        ;;
esac
[ "$MINIMUM" -le 100 ] || { echo "error: minimum must be an integer from 0 through 100" >&2; exit 2; }
[ -d "$SOURCE_ROOT" ] || { echo "error: source root is not a directory: $SOURCE_ROOT" >&2; exit 2; }

TMPDIR_GATE=$(mktemp -d "${TMPDIR:-/tmp}/codingbuddy-docstrings.XXXXXX")
trap 'rm -rf "$TMPDIR_GATE"' EXIT HUP INT TERM
RECORDS="$TMPDIR_GATE/records.tsv"
FILES="$TMPDIR_GATE/files.txt"
TEST_PATHS="$TMPDIR_GATE/test-paths.txt"
GENERATED_PATHS="$TMPDIR_GATE/generated-paths.txt"
: > "$RECORDS"
: > "$TEST_PATHS"
: > "$GENERATED_PATHS"

has_generated_header() {
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function has_marker(value) {
            value = trim(value)
            sub(/^\*[[:space:]]*/, "", value)
            return trim(value) == "@generated"
        }
        {
            line = $0
            while (1) {
                if (in_block_comment) {
                    close_at = index(line, "*/")
                    if (close_at > 0) {
                        if (has_marker(substr(line, 1, close_at - 1))) found = 1
                        line = substr(line, close_at + 2)
                        in_block_comment = 0
                        continue
                    }
                    if (has_marker(line)) found = 1
                    next
                }

                sub(/^[[:space:]]+/, "", line)
                if (line == "") next
                if (substr(line, 1, 2) == "//") {
                    if (has_marker(substr(line, 3))) found = 1
                    next
                }
                if (substr(line, 1, 2) == "/*") {
                    line = substr(line, 3)
                    in_block_comment = 1
                    continue
                }

                exit(found ? 0 : 1)
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

json_array() {
    awk '
        function escape_json(value) {
            gsub(/\\/, "\\\\", value)
            gsub(/"/, "\\\"", value)
            gsub(/\t/, "\\t", value)
            gsub(/\r/, "\\r", value)
            return value
        }
        BEGIN { separator = ""; printf "[" }
        {
            printf "%s\"%s\"", separator, escape_json($0)
            separator = ","
        }
        END { printf "]" }
    ' "$1"
}

print_paths() {
    label=$1
    path_file=$2
    echo "$label:"
    if [ -s "$path_file" ]; then
        sed 's/^/  /' "$path_file"
    else
        echo "  (none)"
    fi
}

cd "$SOURCE_ROOT"
find CodingBuddy CodingBuddyTests -type f -name '*.swift' -print | LC_ALL=C sort > "$FILES"

files_scanned=0
test_files=0
generated_files=0

while IFS= read -r file; do
    case "$file" in
        CodingBuddyTests/*|*/Tests/*)
            test_files=$((test_files + 1))
            printf '%s\n' "$file" >> "$TEST_PATHS"
            continue
            ;;
    esac

    if has_generated_header "$file"; then
        generated_files=$((generated_files + 1))
        printf '%s\n' "$file" >> "$GENERATED_PATHS"
        continue
    fi

    files_scanned=$((files_scanned + 1))
    awk -v path="$file" '
        function ltrim(value) { sub(/^[[:space:]]+/, "", value); return value }
        function first_token(value, result) {
            value = ltrim(value)
            if (match(value, /^[^[:space:]]+/)) return substr(value, RSTART, RLENGTH)
            return ""
        }
        function is_modifier(token) {
            return token ~ /^(open|public|package|internal|private|fileprivate|final|indirect|nonisolated|static|required|convenience|override|mutating|nonmutating|lazy|weak|unowned)$/ ||
                token ~ /^(private|fileprivate|nonisolated)\(.+\)$/
        }
        function normalized_declaration(value, token) {
            value = ltrim(value)
            while (value ~ /^@[A-Za-z_][A-Za-z0-9_.]*(\([^)]*\))?[[:space:]]+/) {
                sub(/^@[A-Za-z_][A-Za-z0-9_.]*(\([^)]*\))?[[:space:]]+/, "", value)
            }
            if (value ~ /^class[[:space:]]+(func|subscript|var)([[:space:](]|$)/) {
                sub(/^class[[:space:]]+/, "", value)
            }
            token = first_token(value)
            while (is_modifier(token)) {
                sub(/^[^[:space:]]+[[:space:]]+/, "", value)
                token = first_token(value)
            }
            return value
        }
        function declaration_kind(value) {
            if (value ~ /^(actor|class|enum|protocol|struct)([[:space:]<(]|$)/) return "type"
            if (value ~ /^case[[:space:]]+/) return "case"
            if (value ~ /^func([[:space:]<(]|$)/) return "func"
            if (value ~ /^init[?!]?[[:space:]]*\(/) return "init"
            if (value ~ /^subscript[[:space:]]*\(/) return "subscript"
            if (value ~ /^(typealias|associatedtype)[[:space:]]+/) return "typealias"
            if (value ~ /^(let|var)[[:space:]]+/) return "property"
            if (value ~ /^(prefix[[:space:]]+|postfix[[:space:]]+|infix[[:space:]]+)?operator[[:space:]]+/) return "operator"
            return ""
        }
        function emit(status, reason, kind) {
            printf "%s\t%s\t%s\t%d\t%s\n", status, reason, kind, NR, path
        }
        function spaces(count, result) {
            result = ""
            while (count-- > 0) result = result " "
            return result
        }
        function closes_string(value, position, quote_count, suffix, i) {
            if (substr(value, position, quote_count) != (quote_count == 3 ? "\"\"\"" : "\"")) return 0
            suffix = substr(value, position + quote_count, string_hashes)
            if (length(suffix) != string_hashes) return 0
            for (i = 1; i <= string_hashes; i++) {
                if (substr(suffix, i, 1) != "#") return 0
            }
            return 1
        }
        function lex_line(value, output, i, character, next_two, hashes, quote_position, quote_count) {
            output = ""
            line_is_doc = 0
            line_has_doc_content = 0
            line_has_comment = 0

            if (string_kind == "" && block_comment_depth == 0 && ltrim(value) ~ /^\/\/\//) {
                line_is_doc = 1
                doc_content = ltrim(value)
                sub(/^\/\/\//, "", doc_content)
                if (doc_content ~ /[^[:space:]]/) line_has_doc_content = 1
                lexed_line = ""
                return
            }

            i = 1
            while (i <= length(value)) {
                character = substr(value, i, 1)
                next_two = substr(value, i, 2)

                if (string_kind != "") {
                    quote_count = string_kind == "multiline" ? 3 : 1
                    if (closes_string(value, i, quote_count)) {
                        output = output spaces(quote_count + string_hashes)
                        i += quote_count + string_hashes
                        string_kind = ""
                        string_hashes = 0
                    } else if (string_kind == "normal" && string_hashes == 0 && character == "\\") {
                        output = output "  "
                        i += 2
                    } else {
                        output = output " "
                        i++
                    }
                    continue
                }

                if (block_comment_depth > 0) {
                    if (next_two == "/*") {
                        block_comment_depth++
                        output = output "  "
                        i += 2
                    } else if (next_two == "*/") {
                        block_comment_depth--
                        output = output "  "
                        i += 2
                    } else {
                        output = output " "
                        i++
                    }
                    continue
                }

                if (next_two == "//") {
                    line_has_comment = 1
                    output = output spaces(length(value) - i + 1)
                    break
                }
                if (next_two == "/*") {
                    line_has_comment = 1
                    block_comment_depth = 1
                    output = output "  "
                    i += 2
                    continue
                }

                hashes = 0
                quote_position = i
                if (character == "#") {
                    while (substr(value, quote_position, 1) == "#") {
                        hashes++
                        quote_position++
                    }
                }
                if (substr(value, quote_position, 1) == "\"") {
                    quote_count = substr(value, quote_position, 3) == "\"\"\"" ? 3 : 1
                    output = output spaces(hashes + quote_count)
                    string_hashes = hashes
                    string_kind = quote_count == 3 ? "multiline" : "normal"
                    i = quote_position + quote_count
                    continue
                }

                output = output character
                i++
            }
            lexed_line = output
        }
        function paren_delta(value, delta, i, character) {
            delta = 0
            for (i = 1; i <= length(value); i++) {
                character = substr(value, i, 1)
                if (character == "(") delta++
                else if (character == ")") delta--
            }
            return delta
        }
        function update_contexts(value, callable_open, enum_open, character, i) {
            # Pending declarations can still contain closure literals in their
            # signatures. Only an explicitly confirmed body start may open a
            # declaration scope; otherwise a default `= {}` closes the scope
            # before the real function body is reached.
            callable_open = enter_callable
            enum_open = enter_enum
            for (i = 1; i <= length(value); i++) {
                character = substr(value, i, 1)
                if (character == "{") {
                    brace_depth++
                    if (callable_open) {
                        callable_at_depth[brace_depth] = 1
                        callable_count++
                        callable_open = 0
                        pending_callable = 0
                    }
                    if (enum_open) {
                        enum_at_depth[brace_depth] = 1
                        enum_count++
                        enum_open = 0
                        pending_enum = 0
                    }
                } else if (character == "}") {
                    if (callable_at_depth[brace_depth]) {
                        delete callable_at_depth[brace_depth]
                        callable_count--
                    }
                    if (enum_at_depth[brace_depth]) {
                        delete enum_at_depth[brace_depth]
                        enum_count--
                    }
                    if (brace_depth > 0) brace_depth--
                }
            }
        }
        BEGIN {
            pending_doc = 0
            brace_depth = 0
            callable_count = 0
            enum_count = 0
            pending_callable = 0
            pending_callable_parens = 0
            pending_callable_waiting = 0
            pending_enum = 0
            block_comment_depth = 0
            string_kind = ""
            string_hashes = 0
        }
        {
            original = $0
            lex_line(original)
            code = lexed_line
            trimmed = ltrim(code)

            if (line_is_doc) {
                if (line_has_doc_content) pending_doc = 1
                next
            }
            if (trimmed == "") {
                if (ltrim(original) == "" || line_has_comment) pending_doc = 0
                next
            }
            if (trimmed ~ /^@[A-Za-z_][A-Za-z0-9_.]*(\([^)]*\))?[[:space:]]*$/) {
                update_contexts(code)
                next
            }

            enter_callable = 0
            enter_enum = 0

            if (pending_callable) {
                if (!pending_callable_waiting) {
                    pending_callable_parens += paren_delta(code)
                    if (pending_callable_parens > 0) {
                        pending_doc = 0
                        update_contexts(code)
                        next
                    }
                    pending_callable_waiting = 1
                    if (code !~ /\{/) {
                        pending_doc = 0
                        update_contexts(code)
                        next
                    }
                }
                if (code ~ /\{/) {
                    enter_callable = 1
                    pending_callable = 0
                    pending_callable_parens = 0
                    pending_callable_waiting = 0
                    pending_doc = 0
                    update_contexts(code)
                    next
                }
                pending_callable = 0
                pending_callable_parens = 0
                pending_callable_waiting = 0
            }

            if (pending_enum) {
                if (code ~ /\{/) {
                    enter_enum = 1
                    pending_enum = 0
                    pending_doc = 0
                    update_contexts(code)
                    next
                }
                pending_enum = 0
            }

            normalized = normalized_declaration(code)
            kind = declaration_kind(normalized)
            if (kind == "") {
                pending_doc = 0
                update_contexts(code)
                next
            }

            # A new declaration proves that a previously pending declaration
            # was bodyless (for example a protocol requirement).
            pending_callable = 0
            pending_enum = 0

            if (kind == "case" && (enum_count == 0 || callable_count > 0)) {
                pending_doc = 0
                update_contexts(code)
                next
            }

            if ((kind == "func" || kind == "init" || kind == "subscript" || kind == "property") && code ~ /\{/) {
                enter_callable = 1
            } else if (kind == "func" || kind == "init" || kind == "subscript" || kind == "property") {
                pending_callable = 1
                pending_callable_parens = paren_delta(code)
                pending_callable_waiting = pending_callable_parens <= 0
            }
            if (kind == "type" && normalized ~ /^enum([[:space:]<(]|$)/ && code ~ /\{/) {
                enter_enum = 1
            } else if (kind == "type" && normalized ~ /^enum([[:space:]<(]|$)/) {
                pending_enum = 1
            }

            prefix = code
            sub(/(actor|associatedtype|class|enum|func|init|let|operator|protocol|struct|subscript|typealias|var).*/, "", prefix)
            if (callable_count > 0) {
                emit("excluded", "local", kind)
            } else if (prefix ~ /(^|[[:space:]])(private|fileprivate)(\([^)]*\))?([[:space:]]|$)/) {
                emit("excluded", "private", kind)
            } else if (prefix ~ /(^|[[:space:]])override([[:space:]]|$)/) {
                emit("excluded", "override", kind)
            } else if (kind == "property" && normalized ~ /^var[[:space:]]+body[[:space:]]*:[[:space:]]*some[[:space:]]+View([[:space:]{]|$)/) {
                emit("excluded", "swiftui-body", kind)
            } else if (pending_doc) {
                emit("covered", "-", kind)
            } else {
                emit("missing", "-", kind)
            }
            pending_doc = 0
            update_contexts(code)
        }
    ' "$file" >> "$RECORDS"
done < "$FILES"

metrics=$(awk -F '\t' '
    $1 == "covered" { covered++ }
    $1 == "missing" { missing++ }
    $1 == "excluded" { excluded++ }
    $2 == "private" { private_count++ }
    $2 == "override" { override_count++ }
    $2 == "swiftui-body" { body_count++ }
    $2 == "local" { local_count++ }
    END {
        eligible = covered + missing
        printf "%d %d %d %d %d %d %d %d", eligible, covered, missing, excluded, private_count, override_count, body_count, local_count
    }
' "$RECORDS")
IFS=' ' read -r eligible documented missing excluded private_count override_count body_count local_count <<EOF
$metrics
EOF

if [ "$eligible" -eq 0 ]; then
    coverage_hundredths=10000
else
    coverage_hundredths=$((documented * 10000 / eligible))
fi
coverage_whole=$((coverage_hundredths / 100))
coverage_fraction=$((coverage_hundredths % 100))
coverage=$(printf '%d.%02d' "$coverage_whole" "$coverage_fraction")
passed=false
[ "$coverage_hundredths" -ge "$((MINIMUM * 100))" ] && passed=true

if [ "$FORMAT" = json ]; then
    test_paths_json=$(json_array "$TEST_PATHS")
    generated_paths_json=$(json_array "$GENERATED_PATHS")
    printf '{"metric":"documented_eligible_swift_declarations","minimum_percent":%d,"coverage_percent":%s,"eligible":%d,"documented":%d,"missing":%d,"excluded_declarations":%d,"exclusions":{"private_or_fileprivate":%d,"overrides":%d,"swiftui_body":%d,"local_declarations":%d,"test_files":%d,"generated_files":%d},"excluded_paths":{"test_files":%s,"generated_files":%s},"files_scanned":%d,"passed":%s}\n' \
        "$MINIMUM" "$coverage" "$eligible" "$documented" "$missing" "$excluded" \
        "$private_count" "$override_count" "$body_count" "$local_count" "$test_files" "$generated_files" \
        "$test_paths_json" "$generated_paths_json" "$files_scanned" "$passed"
else
    echo "Docstring coverage: $documented/$eligible ($coverage%; minimum $MINIMUM%)"
    echo "Excluded declarations: $excluded (private/fileprivate: $private_count, overrides: $override_count, SwiftUI body: $body_count, local: $local_count)"
    echo "Excluded files: tests: $test_files, generated: $generated_files; scanned app files: $files_scanned"
    print_paths "Excluded test files" "$TEST_PATHS"
    print_paths "Excluded generated files" "$GENERATED_PATHS"
    if [ "$missing" -gt 0 ]; then
        echo "Missing documentation:"
        awk -F '\t' '$1 == "missing" { printf "  %s:%s (%s)\n", $5, $4, $3 }' "$RECORDS"
    fi
fi

if [ "$passed" != true ]; then
    echo "error: docstring coverage $coverage% is below the required $MINIMUM%" >&2
    exit 1
fi
