#!/bin/bash
# childprofile.py(子CLIプロファイルの解決, POSIX版)
source "$(dirname "$0")/lib.sh"

# set_child_agent <profile|""> <command_template>: config.json の child_agent を書き換える
set_child_agent() {
    python3 -c "
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    c = json.load(f)
if sys.argv[2]:
    c['child_agent']['profile'] = sys.argv[2]
else:
    c['child_agent'].pop('profile', None)
c['child_agent']['command_template'] = sys.argv[3]
with open(p, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(c, f)
" "$(py_path "$PROJ/.agents/workflow/config.json")" "$1" "$2"
}

# run_profile: childprofile.py を実行し OUT / ERR / CODE を設定する(OUT は行ごとの比較用に末尾改行を保つ)
run_profile() {
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    (cd "$PROJ" && python3 .agents/workflow/scripts/childprofile.py .) > "$out_file" 2> "$err_file"
    CODE=$?
    OUT="$(cat "$out_file")"; ERR="$(cat "$err_file")"
    LINES_OUT=()
    mapfile -t LINES_OUT < "$out_file"
    rm -f "$out_file" "$err_file"
}

t_auto_default() {
    set_child_agent "" 'claude -p "{prompt}" --output-format stream-json --verbose'
    run_profile
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq 7 "${#LINES_OUT[@]}" "7 lines"
    assert_eq "auto" "${LINES_OUT[0]}" "name"
    assert_eq "claude-stream-json" "${LINES_OUT[1]}" "output_format resolved from command_template"
    assert_eq "false" "${LINES_OUT[6]}" "agents_md_imports"
    set_child_agent "" 'opencode run "{prompt}"'
    run_profile
    assert_eq "text" "${LINES_OUT[1]}" "output_format is text without stream-json"
}

t_custom_replaces_builtin() {
    printf '{"opencode": {"output_format": "text", "permission_denied_pattern": "^DENIED: "}}\n' \
        > "$PROJ/.agents/workflow/child-profiles.json"
    set_child_agent "opencode" 'opencode run "{prompt}"'
    run_profile
    assert_eq 0 "$CODE" "exit: $ERR"
    assert_eq "opencode" "${LINES_OUT[0]}" "name"
    assert_eq "" "${LINES_OUT[2]}" "tool_activity_pattern is empty (replaced)"
    assert_eq "^DENIED: " "${LINES_OUT[4]}" "permission_denied_pattern from project"
}

t_unknown_profile() {
    set_child_agent "nope" 'opencode run "{prompt}"'
    run_profile
    assert_eq 1 "$CODE" "unknown profile rejected"
    assert_contains "$ERR" "Unknown child profile: nope (defined: auto, claude-stream-json, opencode, plain)" "message"
}

echo "test-child-profile.sh"
test_case "profile: 未指定は auto で、command_template に stream-json があれば claude-stream-json の出力形式" t_auto_default
test_case "profile: 利用先の child-profiles.json が同名の組み込み定義を置き換える" t_custom_replaces_builtin
test_case "profile: 未定義の名前は exit 1" t_unknown_profile
summary
