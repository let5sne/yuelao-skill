#!/usr/bin/env bash
# 红娘 CLI 测试 — 无需额外依赖，只要 bash + jq。
#
#   ./tests/run-tests.sh
#
# 覆盖不联网就能验证的纯逻辑：档案深度合并语义、sync 的 diff 计算、
# ID 类型处理、"先筛后展"不变量、以及网络失败时快照不被清空。
# 这几处都是历史上真的出过 bug 的地方（见 CHANGELOG 0.2 / 0.3）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../scripts/yuelao"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
         printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; }

# assert_json <name> <expected> <actual>  — 比较前先规范化
assert_json() {
  local name="$1" exp act
  exp=$(printf '%s' "$2" | jq -Sc .) || { bad "$name" "$2" "<invalid expected json>"; return; }
  act=$(printf '%s' "$3" | jq -Sc . 2>/dev/null) || { bad "$name" "$exp" "$3"; return; }
  [[ "$exp" == "$act" ]] && ok "$name" || bad "$name" "$exp" "$act"
}

assert_eq() {
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"
}

assert_contains() {
  [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "包含 '$2'" "$3"
}

# 从 CLI 里抽出 jq 函数定义，直接对它做单元测试，避免复制粘贴导致测试与实现漂移。
extract_jq_block() { # extract_jq_block <VAR_NAME>
  awk -v v="$1" "/^${1}='/{f=1;sub(/^${1}='/,\"\");} f{print} f&&/'\$/{exit}" "$CLI" \
    | sed "s/'\$//"
}

JQ_DEEPMERGE_SRC=$(extract_jq_block JQ_DEEPMERGE)
JQ_ID_SRC=$(extract_jq_block JQ_ID)

dm() { # dm <cache_json> <new_json>
  jq -n --argjson a "$1" --argjson b "$2" "${JQ_DEEPMERGE_SRC} dm(\$a; \$b)"
}

echo
echo "档案深度合并 (JQ_DEEPMERGE)"

# CHANGELOG 0.2 记录的原始 bug：jq '*' 会整体替换数组，增量加 traits 会清掉旧值。
assert_json "字符串数组取并集，旧值不丢" \
  '{"summary":{"personality":{"traits":["理性","安静","幽默"]}}}' \
  "$(dm '{"summary":{"personality":{"traits":["理性","安静"]}}}' \
        '{"summary":{"personality":{"traits":["幽默"]}}}')"

assert_json "字符串数组并集去重" \
  '{"hobbies":["跑步","看电影"]}' \
  "$(dm '{"hobbies":["跑步","看电影"]}' '{"hobbies":["跑步"]}')"

assert_json "object 深度合并不丢同级字段" \
  '{"basic":{"age":28,"city":"北京","occupation":"工程师"}}' \
  "$(dm '{"basic":{"age":28,"city":"北京"}}' '{"basic":{"occupation":"工程师"}}')"

assert_json "数字数组整体替换（age_range 不能取并集）" \
  '{"preferences":{"age_range":[26,34]}}' \
  "$(dm '{"preferences":{"age_range":[25,32]}}' '{"preferences":{"age_range":[26,34]}}')"

assert_json "新增顶层字段" \
  '{"a":1,"b":2}' \
  "$(dm '{"a":1}' '{"b":2}')"

assert_json "null 不覆盖已有值" \
  '{"basic":{"city":"北京"}}' \
  "$(dm '{"basic":{"city":"北京"}}' '{"basic":{"city":null}}')"

assert_json "标量被新值覆盖" \
  '{"basic":{"city":"上海"}}' \
  "$(dm '{"basic":{"city":"北京"}}' '{"basic":{"city":"上海"}}')"

assert_json "混合类型数组按替换处理（不当字符串数组）" \
  '{"x":[1,"a"]}' \
  "$(dm '{"x":["b"]}' '{"x":[1,"a"]}')"

echo
echo "ID 类型处理 (JQ_ID)"

as_id() { printf '%s' "$1" | jq "${JQ_ID_SRC} as_id"; }

assert_eq "自增整数 ID 按数字发出" "42" "$(as_id '"42"')"
assert_eq "UUID 保持字符串" '"a3f9-c2e1"' "$(as_id '"a3f9-c2e1"')"
assert_eq "纯字母 ID 保持字符串" '"abc"' "$(as_id '"abc"')"

echo
echo "响应解包（裸数组 / 包一层 / 降级值）"

# 回归：原来写作 (.recommendations // .)，对数组取字符串 key 会直接报错而不是
# 走 //，导致后端返回裸数组（或失败降级成 []）时整个 sync 崩掉。
unwrap() { # unwrap <raw> <key>
  jq --arg k "$2" '
    if type=="array" then .
    elif type=="object" and (.[$k]|type)=="array" then .[$k]
    else [] end' <<<"$1"
}

assert_json "裸数组原样通过" '[{"id":1}]' "$(unwrap '[{"id":1}]' recommendations)"
assert_json "包一层被解开" '[{"id":1}]' "$(unwrap '{"recommendations":[{"id":1}]}' recommendations)"
assert_json "空数组不报错（网络失败降级值）" '[]' "$(unwrap '[]' recommendations)"
assert_json "意外对象降级为空数组" '[]' "$(unwrap '{"detail":"err"}' recommendations)"
assert_json "messages 同样解包" '[{"id":9}]' "$(unwrap '{"messages":[{"id":9}]}' messages)"

echo
echo "sync diff 逻辑"

# 复刻 cmd_sync 的 diff 表达式做纯函数测试。
sync_diff() { # sync_diff <recs> <old_snapshot> <filters>
  jq -n --argjson recs "$1" --argjson old "$2" --argjson filters "$3" '
    def rid: ((.id // .recommendation_id // "") | tostring);
    {
      new_recommendations: [ $recs[] | select($old[rid] == null) | rid ],
      status_changes: [ $recs[] | rid as $r
        | select(($old[$r] != null) and ($old[$r] != (.status // "unknown")))
        | {id: $r, from: $old[$r], to: (.status // "unknown")} ],
      needs_filter: [ $recs[] | select((.status // "") == "pending")
        | select($filters[rid] == null) | rid ]
    }'
}

assert_json "首次同步：全部算新推荐" \
  '{"new_recommendations":["1","2"],"status_changes":[],"needs_filter":["1","2"]}' \
  "$(sync_diff '[{"id":1,"status":"pending"},{"id":2,"status":"pending"}]' '{}' '{}')"

assert_json "已见过的推荐不再算新" \
  '{"new_recommendations":[],"status_changes":[],"needs_filter":["1"]}' \
  "$(sync_diff '[{"id":1,"status":"pending"}]' '{"1":"pending"}' '{}')"

assert_json "状态跃迁被捕获" \
  '{"new_recommendations":[],"status_changes":[{"id":"1","from":"pending","to":"matched"}],"needs_filter":[]}' \
  "$(sync_diff '[{"id":1,"status":"matched"}]' '{"1":"pending"}' '{}')"

assert_json "已筛选过的推荐不再进 needs_filter" \
  '{"new_recommendations":[],"status_changes":[],"needs_filter":[]}' \
  "$(sync_diff '[{"id":1,"status":"pending"}]' '{"1":"pending"}' '{"1":{"action":"shown"}}')"

assert_json "非 pending 状态不进 needs_filter" \
  '{"new_recommendations":[],"status_changes":[],"needs_filter":[]}' \
  "$(sync_diff '[{"id":1,"status":"matched"}]' '{"1":"matched"}' '{}')"

assert_json "数字 id 与快照里的字符串 key 能对上" \
  '{"new_recommendations":[],"status_changes":[],"needs_filter":[]}' \
  "$(sync_diff '[{"id":7,"status":"matched"}]' '{"7":"matched"}' '{}')"

echo
echo "匹配资格透出（false 与"字段不存在"必须区分）"

# 回归：第一版写作 ($profile.matchable // true)。jq 的 // 把 false 也当空值，
# 于是 false // true == true——所有不合格的用户都会被报成合格，红娘什么都不问，
# 整个闸门对用户就是隐形的。必须用 has() 判断字段是否存在。
matchable_of() { # matchable_of <profile_json>
  jq -n --argjson profile "$1" -c '{
    matchable: (if ($profile|has("matchable")) then $profile.matchable else true end),
    missing_labels: ($profile.missing_labels // [])
  }'
}

assert_json "matchable:false 如实透出（不被 // 吞掉）" \
  '{"matchable":false,"missing_labels":["性别","年龄"]}' \
  "$(matchable_of '{"matchable":false,"missing_labels":["性别","年龄"]}')"

assert_json "matchable:true 原样透出" \
  '{"matchable":true,"missing_labels":[]}' \
  "$(matchable_of '{"matchable":true,"missing_labels":[]}')"

assert_json "老服务端不返回该字段时按合格处理（不凭空报警）" \
  '{"matchable":true,"missing_labels":[]}' \
  "$(matchable_of '{}')"

assert_json "profile 拉取失败降级为 {} 时同样不误报" \
  '{"matchable":true,"missing_labels":[]}' \
  "$(matchable_of '{}')"

echo
echo "快照更新：网络失败不清空 state"

# 这是扩展 sync 时发现的 bug：拉取失败降级成 [] 后照样覆盖快照，
# 会导致下次成功时把所有推荐都当成"新推荐"重报一遍。
snapshot() { # snapshot <state> <recs> <recs_ok>
  jq -n --argjson s "$1" --argjson recs "$2" --argjson recs_ok "$3" '
    def rid: ((.id // .recommendation_id // "") | tostring);
    $s | (if $recs_ok == 1
            then .recs = ($recs | map({key: rid, value: (.status // "unknown")}) | from_entries)
            else . end)'
}

assert_json "拉取成功时快照被刷新" \
  '{"recs":{"1":"matched"}}' \
  "$(snapshot '{"recs":{"1":"pending"}}' '[{"id":1,"status":"matched"}]' 1)"

assert_json "拉取失败时保留旧快照（不被清空）" \
  '{"recs":{"1":"pending","2":"pending"}}' \
  "$(snapshot '{"recs":{"1":"pending","2":"pending"}}' '[]' 0)"

echo
echo "CLI 行为（离线，隔离 HOME）"

TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT
export YUELAO_HOME="$TMP_HOME/.yuelao"

assert_json "未注册时 status 返回 registered:false" \
  '{"registered":false}' \
  "$("$CLI" status)"

out=$("$CLI" sync 2>&1 || true)
assert_contains "未注册时 sync 报错而非静默" "Not registered" "$out"

out=$("$CLI" respond accept 1 2>&1 || true)
assert_contains "未注册时 respond 报错" "Not registered" "$out"

out=$("$CLI" badcommand 2>&1 || true)
assert_contains "未知命令有明确报错" "Unknown command" "$out"

out=$("$CLI" help 2>&1 || true)
assert_contains "help 列出 sync" "sync" "$out"
assert_contains "help 列出 filter" "filter" "$out"

# "先筛后展"不变量：伪造一份已注册的配置，但不给 filter 记录。
mkdir -p "$YUELAO_HOME"
cat > "$YUELAO_HOME/config.json" <<'JSON'
{"user_id":"test-uid","api_token":"test-token",
 "backend_url":"http://127.0.0.1:9","contact":{"type":"","value":""}}
JSON
chmod 600 "$YUELAO_HOME/config.json"
echo '{"recs":{},"seen_messages":[],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' \
  > "$YUELAO_HOME/state.json"

out=$("$CLI" respond accept 42 2>&1 || true)
assert_contains "无 filter 记录时 respond 被拒绝" "还没有筛选记录" "$out"
# 关键：拒绝必须发生在联网之前，否则不变量形同虚设（backend 指向死端口）
if [[ "$out" != *"network"* && "$out" != *"HTTP"* ]]; then
  ok "拒绝发生在发起网络请求之前"
else
  bad "拒绝发生在发起网络请求之前" "不含网络错误" "$out"
fi

# 有 filter 记录后，不变量放行（此时才会去联网，预期网络失败）
jq '.filters["42"]={"action":"shown","reason":"t","ts":0}' "$YUELAO_HOME/state.json" \
  > "$YUELAO_HOME/state.tmp" && mv "$YUELAO_HOME/state.tmp" "$YUELAO_HOME/state.json"
out=$("$CLI" respond accept 42 2>&1 || true)
if [[ "$out" != *"还没有筛选记录"* ]]; then
  ok "有 filter 记录后不变量放行"
else
  bad "有 filter 记录后不变量放行" "不再报缺少筛选记录" "$out"
fi

out=$("$CLI" contact set wechat test_wx_123 2>&1 || true)
assert_contains "contact set 成功" "Contact saved locally" "$out"
assert_json "contact get 读回本地值" \
  '{"type":"wechat","value":"test_wx_123"}' \
  "$("$CLI" contact get)"

perm=$(ls -l "$YUELAO_HOME/config.json" | cut -c1-10)
assert_eq "config.json 权限为 600" "-rw-------" "$perm"

out=$("$CLI" register '{"summary":{}}' 2>&1 || true)
assert_contains "已注册时 register 拒绝覆盖" "Already registered" "$out"

out=$("$CLI" profile update 'not json' 2>&1 || true)
assert_contains "非法 JSON 被拒绝" "Invalid JSON" "$out"

out=$("$CLI" filter 1 bogus 2>&1 || true)
assert_contains "filter 只接受 shown/suppressed" "shown" "$out"

echo
echo "资格信息透出（register / profile update / profile set）"

# ── 离线假 curl ──
#
# 真 curl 用 -w $'\n%{http_code}' 把状态码附在响应体之后，CLI 靠最后一行取码，
# 所以 mock 必须复现"响应体 + 换行 + 状态码"这个形状，否则 CLI 解析不到状态码。
# 响应内容由 MOCK_BODY / MOCK_CODE / MOCK_EXIT 逐用例控制，不联网。
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n%s\n' "${MOCK_BODY-}" "${MOCK_CODE:-200}"
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "$MOCK_BIN/curl"
SAVED_PATH="$PATH"
PATH="$MOCK_BIN:$PATH"

# 每个用例一个干净的 YUELAO_HOME：cmd_register 见到已存在的 config 会直接拒绝，
# 缓存和 config 也必须隔离，否则前一个用例会串味到下一个。
# fresh_unregistered_home 只给空目录（注册用例需要"尚未注册"的初始状态）。
fresh_unregistered_home() {
  local d; d=$(mktemp -d)
  export YUELAO_HOME="$d/.yuelao"
}

# 已注册状态：config + 缓存齐备，用于 profile update / set 用例。
fresh_home() {
  fresh_unregistered_home
  mkdir -p "$YUELAO_HOME"
  printf '%s\n' '{"user_id":"test-uid","api_token":"test-token","backend_url":"http://mock","contact":{"type":"","value":""}}' \
    > "$YUELAO_HOME/config.json"
  printf '%s\n' '{"summary":{"basic":{"age":30}},"preferences":{}}' \
    > "$YUELAO_HOME/profile-cache.json"
  chmod 600 "$YUELAO_HOME/config.json" "$YUELAO_HOME/profile-cache.json"
}

# 从 CLI 输出里抠出资格 JSON（从第一个以 { 开头的行到结尾），好用 assert_json 断言。
elig() { sed -n '/^{/,$p' <<<"$1"; }

FULL='{"user_id":"u1","api_token":"t1","recommendations":0,"matchable":true,"missing_fields":[],"missing_labels":[]}'
PARTIAL='{"matchable":false,"missing_fields":["basic.city"],"missing_labels":["所在城市"]}'
LEGACY='{"user_id":"u1","api_token":"t1","recommendations":0}'
# 注册响应必然带 user_id/api_token（CLI 靠它们写 config）；资格字段是附加信息。
PARTIAL_REG='{"user_id":"u1","api_token":"t1","recommendations":0,"matchable":false,"missing_fields":["basic.city"],"missing_labels":["所在城市"]}'

# register：保留成功提示，并透出资格
# 注意 `VAR=val cmd` 必须写在命令替换**内部**：写成 `VAR=val out=$(cmd)` 只会把
# VAR 设成当前 shell 的变量而不导出，子进程（mock curl）看不到它。
fresh_unregistered_home
out=$(MOCK_BODY="$PARTIAL_REG" "$CLI" register '{"summary":{"basic":{"age":30}}}' 2>&1 || true)
assert_contains "register 保留成功提示" "Registered. user_id" "$out"
assert_json "register 透出资格（缺失字段）" \
  '{"matchable":false,"missing_fields":["basic.city"],"missing_labels":["所在城市"]}' \
  "$(elig "$out")"

# register 不许回显 api_token
if [[ "$out" != *"t1"* ]]; then
  ok "register 不回显 api_token"
else
  bad "register 不回显 api_token" "输出里不含 token" "$out"
fi

fresh_unregistered_home
out=$(MOCK_BODY="$FULL" "$CLI" register '{"summary":{"basic":{"age":30}}}' 2>&1 || true)
assert_json "register 透出资格（完整档案）" \
  '{"matchable":true,"missing_fields":[],"missing_labels":[]}' \
  "$(elig "$out")"

# profile update
fresh_home
out=$(MOCK_BODY="$PARTIAL" "$CLI" profile update '{"summary":{"basic":{"city":"成都"}}}' 2>&1 || true)
assert_json "profile update 透出资格" \
  '{"matchable":false,"missing_fields":["basic.city"],"missing_labels":["所在城市"]}' \
  "$(elig "$out")"

# profile set
fresh_home
out=$(MOCK_BODY="$FULL" "$CLI" profile set '{"summary":{"basic":{"age":30,"city":"北京","gender":"male"}},"preferences":{}}' 2>&1 || true)
assert_json "profile set 透出资格" \
  '{"matchable":true,"missing_fields":[],"missing_labels":[]}' \
  "$(elig "$out")"

# 旧后端不返回资格字段：必须如实显示 null，**不能伪造 matchable:true**
fresh_home
out=$(MOCK_BODY="$LEGACY" "$CLI" profile update '{"summary":{"basic":{"age":31}}}' 2>&1 || true)
assert_json "旧后端缺字段时如实为 null（不伪造 true）" \
  '{"matchable":null,"missing_fields":null,"missing_labels":null}' \
  "$(elig "$out")"

# API 失败时不覆盖缓存
fresh_home
before=$(cat "$YUELAO_HOME/profile-cache.json")
out=$(MOCK_CODE=500 MOCK_BODY='{"error":"boom"}' "$CLI" profile update '{"summary":{"basic":{"age":99}}}' 2>&1 || true)
after=$(cat "$YUELAO_HOME/profile-cache.json")
assert_eq "API 失败时不覆盖缓存" "$before" "$after"
assert_contains "API 失败时明确报错" "Profile update failed" "$out"

# 缓存应以**服务端响应**为准，而不是本地合并结果
fresh_home
out=$(MOCK_BODY='{"summary":{"basic":{"age":30,"city":"服务端规范化后的城市"}},"preferences":{},"matchable":true,"missing_fields":[],"missing_labels":[]}' \
  "$CLI" profile update '{"summary":{"basic":{"city":"客户端写的"}}}' 2>&1 || true)
assert_json "缓存写服务端响应（权威值），不是本地合并结果" \
  '{"summary":{"basic":{"age":30,"city":"服务端规范化后的城市"}},"preferences":{}}' \
  "$(cat "$YUELAO_HOME/profile-cache.json")"

PATH="$SAVED_PATH"
unset MOCK_BODY MOCK_CODE MOCK_EXIT

echo
printf '\033[1m%s\033[0m\n' "结果: ${PASS} passed, ${FAIL} failed"
echo
[[ "$FAIL" -eq 0 ]]
