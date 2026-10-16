#!/usr/bin/env bash
# 月老 CLI 测试 — 需要 bash + jq + Python 3，网络由假 curl 隔离。
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
# 于是 false // true == true——所有不合格的用户都会被报成合格，月老什么都不问，
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
if [[ -n "${MOCK_CURL_LOG:-}" ]]; then printf 'called\n' >> "$MOCK_CURL_LOG"; fi
if [[ "${MOCK_SYNC:-0}" == 1 ]]; then
  default_recs='[{"id":1,"status":"pending"}]'
  default_inbox='[{"id":9,"content":"hello"}]'
  default_pause='{"status":"active"}'
  default_profile='{"summary":{},"preferences":{},"matchable":false}'
  default_exchange='{}'
  case "${!#}" in
    */recommendations/*) body="${MOCK_RECS-$default_recs}" ;;
    *box=sent) body="${MOCK_SENT-[]}" ;;
    */messages/*) body="${MOCK_INBOX-$default_inbox}" ;;
    */pause) body="${MOCK_PAUSE-$default_pause}" ;;
    */profile/*) body="${MOCK_PROFILE-$default_profile}" ;;
    */exchange/*) body="${MOCK_EXCHANGE-$default_exchange}" ;;
  esac
  printf '%s\n200\n' "$body"
  exit 0
fi
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

echo
echo "sync 异常响应回归（实际 CLI）"
fresh_home
printf '%s\n' '{"recs":{"1":"pending"},"seen_messages":["9"],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
for bad_recs in '<html>gateway error</html>' '{"error":"unavailable"}' '[null]' '[{"status":"pending"}]'; do
  jq '.recs={"1":"pending"}' "$YUELAO_HOME/state.json" > "$YUELAO_HOME/state.tmp"
  mv "$YUELAO_HOME/state.tmp" "$YUELAO_HOME/state.json"
  out=$(MOCK_SYNC=1 MOCK_RECS="$bad_recs" "$CLI" sync 2>/dev/null || true)
  assert_eq "异常推荐响应仍输出可解析的 partial:true" true "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
  assert_json "异常推荐响应保留旧快照" '{"1":"pending"}' "$(jq '.recs' "$YUELAO_HOME/state.json")"
done
out=$(MOCK_SYNC=1 MOCK_INBOX='{"error":"unavailable"}' "$CLI" sync 2>/dev/null || true)
assert_eq "异常收件箱响应报告部分失败" true "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
assert_json "异常收件箱响应保留已见消息" '["9"]' "$(jq '.seen_messages' "$YUELAO_HOME/state.json")"
out=$(MOCK_SYNC=1 MOCK_PROFILE='<html>error</html>' MOCK_PAUSE='{"error":"unavailable"}' "$CLI" sync 2>/dev/null || true)
assert_eq "档案和暂停响应异常报告部分失败" true "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
assert_eq "档案未知不能伪造匹配合格" null "$(jq -r '.matchable' <<<"$out" 2>/dev/null)"
assert_eq "暂停状态未知不能伪造 active" null "$(jq -r '.paused' <<<"$out" 2>/dev/null)"
out=$(MOCK_SYNC=1 MOCK_RECS='[]' MOCK_INBOX='[]' "$CLI" sync 2>/dev/null || true)
assert_eq "合法空列表成功同步" false "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
assert_json "合法空列表刷新快照" '{}' "$(jq '.recs' "$YUELAO_HOME/state.json")"
out=$(MOCK_SYNC=1 MOCK_RECS='{"recommendations":[{"id":1,"status":"pending"}]}' MOCK_INBOX='{"messages":[{"id":9}]}' "$CLI" sync 2>/dev/null || true)
assert_eq "包装列表仍兼容" false "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
assert_eq "matchable:false 仍如实输出" false "$(jq -r '.matchable' <<<"$out" 2>/dev/null)"
out=$(MOCK_SYNC=1 MOCK_RECS='[{"id":1,"status":{"error":"missing"}}]' "$CLI" sync 2>/dev/null || true)
assert_eq "对象状态的推荐报告部分失败" true "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
out=$(MOCK_SYNC=1 MOCK_INBOX='[{"recommendation_id":1}]' "$CLI" sync 2>/dev/null || true)
assert_eq "消息必须有自己的 ID" true "$(jq -r '.partial' <<<"$out" 2>/dev/null)"
assert_json "缺消息 ID 时不写入 null 已见标记" '["9"]' "$(jq '.seen_messages' "$YUELAO_HOME/state.json")"

echo
echo "UTF-8 前置校验（实际 CLI，禁止请求和状态写入）"
BAD_UTF8=$(printf '\263\311\266\274')
BAD_JSON=$(printf '{"summary":{"basic":{"city":"%s"}},"preferences":{}}' "$BAD_UTF8")
REPLACEMENT=$(printf '\357\277\275')
BAD_FILE="$TMP_HOME/gbk-profile.json"
printf '%s' "$BAD_JSON" > "$BAD_FILE"
CURL_LOG="$TMP_HOME/encoding-curl.log"

assert_encoding_rejected() {
  local name="$1" expected="$2" input_mode="$3" out code
  shift 3
  : > "$CURL_LOG"
  local before after
  before=$(find "$YUELAO_HOME" -type f -exec cksum {} \; 2>/dev/null | sort)
  if [[ "$input_mode" == stdin ]]; then
    out=$(printf '%s' "$BAD_JSON" | MOCK_CURL_LOG="$CURL_LOG" MOCK_BODY="$FULL" "$CLI" "$@" 2>&1)
  else
    out=$(MOCK_CURL_LOG="$CURL_LOG" MOCK_BODY="$FULL" "$CLI" "$@" 2>&1)
  fi
  code=$?
  after=$(find "$YUELAO_HOME" -type f -exec cksum {} \; 2>/dev/null | sort)
  if [[ "$code" -ne 0 && "$out" == *"$expected"* && ! -s "$CURL_LOG" && "$before" == "$after" ]]; then
    ok "${name}：本地拒绝、未联网、文件不变"
  else
    bad "${name}：本地拒绝、未联网、文件不变" "nonzero/$expected/no curl/unchanged files" "exit=$code output=$out curl=$(cat "$CURL_LOG") files_unchanged=$([[ "$before" == "$after" ]] && echo true || echo false)"
  fi
}

for mode in argument file stdin; do
  fresh_unregistered_home
  mkdir -p "$YUELAO_HOME"
  case "$mode" in
    argument) input="$BAD_JSON" ;;
    file) input="$BAD_FILE" ;;
    stdin) input='-' ;;
  esac
  assert_encoding_rejected "注册 $mode 的 GBK 输入" UTF-8 "$mode" register "$input"
done

fresh_home
printf '%s\n' '{"recs":{},"seen_messages":[],"filters":{"1":{"action":"shown"}},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
assert_encoding_rejected '档案增量参数 GBK' UTF-8 argument profile update "$BAD_JSON"
assert_encoding_rejected '档案增量文件 GBK' UTF-8 file profile update "$BAD_FILE"
assert_encoding_rejected '档案全量文件 GBK' UTF-8 file profile set "$BAD_FILE"
assert_encoding_rejected '筛选理由 GBK' UTF-8 argument filter 1 shown '' "$BAD_UTF8"
assert_encoding_rejected '回应理由 GBK' UTF-8 argument respond reject 1 "$BAD_UTF8"
assert_encoding_rejected '传话 GBK' UTF-8 argument message send 1 "$BAD_UTF8"
assert_encoding_rejected '约会反馈 GBK' UTF-8 argument feedback submit 1 "$(printf '{"comment":"%s"}' "$BAD_UTF8")"
assert_encoding_rejected '暂停理由 GBK' UTF-8 argument pause on "$BAD_UTF8"
assert_encoding_rejected '联系方式 GBK' UTF-8 argument contact set wechat "$BAD_UTF8"
assert_encoding_rejected '交换联系方式 GBK' UTF-8 argument exchange submit 1 "$BAD_UTF8"
assert_encoding_rejected '字面 U+FFFD 传话' U+FFFD argument message send 1 "$REPLACEMENT"
assert_encoding_rejected 'JSON 转义 U+FFFD' U+FFFD argument feedback submit 1 '{"comment":"\ufffd"}'
assert_encoding_rejected 'JSON 孤立代理项' U+FFFD argument feedback submit 1 '{"comment":"\ud800"}'
for invalid in "$(printf '\300\257')" "$(printf '\355\240\200')" "$(printf '\364\220\200\200')" "$(printf '\342\202')"; do
  assert_encoding_rejected '非法 UTF-8 序列' UTF-8 argument message send 1 "$invalid"
done

: > "$CURL_LOG"
out=$(MOCK_CURL_LOG="$CURL_LOG" MOCK_BODY='{"sent":true}' "$CLI" message send 1 '成都见 👋 𠀀 é' 2>&1)
assert_contains '合法中文、emoji、扩展汉字及组合字符正常发送' '"sent":true' "$out"
assert_eq '合法文本只发送一次请求' 1 "$(wc -l < "$CURL_LOG" | tr -d ' ')"
out=$("$CLI" contact set wechat '中文昵称_👋' 2>&1)
assert_contains '合法中文联系方式正常保存' 'Contact saved locally' "$out"
assert_json '合法中文联系方式无损读回' '{"type":"wechat","value":"中文昵称_👋"}' "$("$CLI" contact get)"

assert_encoding_rejected '重复 JSON 键中的 U+FFFD' U+FFFD argument feedback submit 1 '{"comment":"\ufffd","comment":"ok"}'
assert_encoding_rejected '重复 JSON 键中的孤立代理项' U+FFFD argument feedback submit 1 '{"comment":"\ud800","comment":"ok"}'
fresh_home
assert_encoding_rejected '无状态文件时的坏反馈' U+FFFD argument feedback submit 1 '{"comment":"\ufffd"}'
fresh_unregistered_home
mkdir -p "$YUELAO_HOME"
printf '%s\n' 'user_id: test-uid' 'api_token: test-token' 'backend_url: http://mock' > "$YUELAO_HOME/config.yaml"
assert_encoding_rejected '旧配置未迁移时的坏档案文件' UTF-8 file profile update "$BAD_FILE"
assert_encoding_rejected '旧配置未迁移时的坏注册标准输入' UTF-8 stdin register -
fresh_unregistered_home
mkdir -p "$YUELAO_HOME"
printf '%s\n' 'user_id: test-uid' 'api_token: test-token' 'backend_url: http://mock' 'contact:' '  type: wechat' "  value: $BAD_UTF8" > "$YUELAO_HOME/config.yaml"
assert_encoding_rejected '旧配置文件的 GBK 联系方式' UTF-8 argument status

fresh_unregistered_home
VALID_FILE="$TMP_HOME/utf8-bom-profile.json"
printf '\357\273\277%s' '{"summary":{"basic":{"city":"成都","occupation":"研发\ud83d\ude00"}},"preferences":{}}' > "$VALID_FILE"
out=$(MOCK_BODY="$FULL" "$CLI" register "$VALID_FILE" 2>&1)
assert_contains '合法 UTF-8 BOM 文件仍可注册' 'Registered.' "$out"
assert_json '中文和 JSON 代理对无损入缓存' '{"summary":{"basic":{"city":"成都","occupation":"研发😀"}},"preferences":{}}' "$(cat "$YUELAO_HOME/profile-cache.json" 2>/dev/null)"

fresh_home
printf '%s' "$BAD_JSON" > "$YUELAO_HOME/profile-cache.json"
assert_encoding_rejected '旧缓存损坏不能作为合并 payload 发送' U+FFFD argument profile update '{"summary":{"basic":{"age":31}}}'
fresh_unregistered_home
mkdir -p "$YUELAO_HOME"
printf '%s\n' 'user_id: test-uid' 'api_token: test-token' 'backend_url: http://mock' 'contact:' '  type: wechat' '  value: 中文昵称_👋' > "$YUELAO_HOME/config.yaml"
out=$("$CLI" status 2>&1)
assert_contains '合法 UTF-8 旧配置正常迁移' '"registered": true' "$out"
assert_json '迁移保留中文联系方式' '{"type":"wechat","value":"中文昵称_👋"}' "$("$CLI" contact get)"

echo
echo "产品缺陷回归：移除通知 / 冻结状态 / 完整传话 / 拉黑 / 主动要推荐"
fresh_home
printf '%s\n' '{"recs":{"1":"pending","2":"matched"},"seen_messages":[],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
out=$(MOCK_SYNC=1 MOCK_RECS='[{"id":1,"status":"pending"}]' MOCK_INBOX='[]' "$CLI" sync 2>/dev/null || true)
assert_json "对方注销：报告被移除的推荐和移除前状态" '[{"id":"2","last_status":"matched"}]' "$(jq -c '.changes.removed_recommendations' <<<"$out")"
assert_json "移除后快照不再含该推荐" '{"1":"pending"}' "$(jq -c '.recs' "$YUELAO_HOME/state.json")"

printf '%s\n' '{"recs":{"1":"pending","2":"matched"},"seen_messages":[],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
out=$(MOCK_SYNC=1 MOCK_RECS='<html>bad gateway</html>' MOCK_INBOX='[]' "$CLI" sync 2>/dev/null || true)
assert_json "推荐拉取失败时不误报移除" '[]' "$(jq -c '.changes.removed_recommendations' <<<"$out")"

printf '%s\n' '{"recs":{"1":"pending"},"seen_messages":[],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
out=$(MOCK_SYNC=1 MOCK_RECS='[{"id":1,"status":"partner_paused"}]' MOCK_INBOX='[]' "$CLI" sync 2>/dev/null || true)
assert_json "对方暂停表现为状态变化" '[{"id":"1","from":"pending","to":"partner_paused"}]' "$(jq -c '.changes.status_changes' <<<"$out")"
assert_json "冻结中的推荐不进入待筛选" '[]' "$(jq -c '.needs_filter' <<<"$out")"

out=$(MOCK_SYNC=1 \
  MOCK_INBOX='[{"id":9,"recommendation_id":1,"content":"好呀","created_at":"2026-10-16T02:00:00Z","read_at":null},{"id":11,"recommendation_id":2,"content":"别的人","created_at":"2026-10-16T03:00:00Z","read_at":null}]' \
  MOCK_SENT='[{"id":8,"recommendation_id":1,"content":"周末爬山吗","created_at":"2026-10-16T01:00:00Z"}]' \
  "$CLI" message thread 1 2>/dev/null || true)
assert_json "thread 合并收发并按时间排序、只含该推荐" '[["sent","周末爬山吗"],["received","好呀"]]' "$(jq -c '[.[] | [.direction, .content]]' <<<"$out")"
out=$("$CLI" message thread 2>&1 || true)
assert_contains "thread 缺推荐 ID 时提示用法" "Usage: yuelao message thread" "$out"

fresh_home
out=$(MOCK_BODY='{"recorded":true,"status":"rejected","matched":false}' "$CLI" block 5 "骚扰" 2>&1 || true)
assert_contains "block 不要求 filter 记录" "Blocked (rec 5)" "$out"
assert_json "block 记入本地状态" '["5"]' "$(jq -c '.blocked' "$YUELAO_HOME/state.json")"
out=$(MOCK_BODY='{"error":"recommendation already rejected"}' MOCK_CODE=409 "$CLI" block 5 2>&1 || true)
assert_contains "服务端错误如实透出" "409" "$out"

out=$(MOCK_BODY='{"scope":"self","created":2}' "$CLI" match 2>&1 || true)
assert_json "match 输出新增推荐数" '{"created":2}' "$(jq -c . <<<"$out")"

out=$("$CLI" help 2>&1 || true)
for c in "block <rec_id>" "match " "message thread" "message sent"; do
  assert_contains "help 列出 $c" "$c" "$out"
done
assert_not_contains_brand() { if grep -q '红娘' <<<"$3"; then bad "$1" "不含 红娘" "$3"; else ok "$1"; fi; }
assert_not_contains_brand "help 不再出现旧品牌名" "" "$out"

echo
echo "推荐过期 / 主动通知"
fresh_home
NLOG="$TMP_HOME/notify-calls.log"
FAKE_NOTIFY="$TMP_HOME/fake-notify"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s"\n' "$NLOG" > "$FAKE_NOTIFY"
chmod +x "$FAKE_NOTIFY"
export YUELAO_NOTIFY_CMD="$FAKE_NOTIFY"
: > "$NLOG"
printf '%s\n' '{"recs":{"1":"pending"},"seen_messages":[],"filters":{},"exchanges":{},"feedback":[],"last_sync":0}' > "$YUELAO_HOME/state.json"
N_RECS='[{"id":1,"status":"expired"},{"id":2,"status":"pending"}]'
N_INBOX='[{"id":9,"recommendation_id":2,"content":"周末有空吗","created_at":"2026-10-16T02:00:00Z","read_at":null}]'
before=$(cksum < "$YUELAO_HOME/state.json")
out=$(MOCK_SYNC=1 MOCK_RECS="$N_RECS" MOCK_INBOX="$N_INBOX" "$CLI" sync --peek 2>/dev/null || true)
assert_json "sync --peek 照样报告变化" '{"new":["2"],"msgs":1}' "$(jq -c '{new:.changes.new_recommendations, msgs:(.changes.new_messages|length)}' <<<"$out")"
assert_eq "sync --peek 不写本地状态" "$before" "$(cksum < "$YUELAO_HOME/state.json")"
assert_json "过期表现为状态变化" '[{"id":"1","from":"pending","to":"expired"}]' "$(jq -c '.changes.status_changes' <<<"$out")"

out=$(MOCK_SYNC=1 MOCK_RECS="$N_RECS" MOCK_INBOX="$N_INBOX" "$CLI" notify 2>/dev/null || true)
assert_json "notify 汇总数量" '{"notified":true,"new_recommendations":1,"messages":1,"expired":1}' \
  "$(jq -c '{notified, new_recommendations, messages, expired}' <<<"$out")"
assert_eq "notify 调用通知器一次" 1 "$(wc -l < "$NLOG" | tr -d ' ')"
assert_contains "通知含数量" "1 位新推荐、1 条新传话、1 条推荐已过期" "$(cat "$NLOG")"
if grep -q '周末有空吗' "$NLOG"; then bad "通知不含传话内容" "无内容" "$(cat "$NLOG")"; else ok "通知不含传话内容"; fi
assert_json "notify 不动快照（月老之后 sync 仍能看到）" '{"1":"pending"}' "$(jq -c '.recs' "$YUELAO_HOME/state.json")"

out=$(MOCK_SYNC=1 MOCK_RECS="$N_RECS" MOCK_INBOX="$N_INBOX" "$CLI" notify 2>/dev/null || true)
assert_json "同一组变化不重复提醒" '{"notified":false,"reason":"already_notified"}' "$(jq -c . <<<"$out")"
assert_eq "重复检查不再调用通知器" 1 "$(wc -l < "$NLOG" | tr -d ' ')"

MOCK_SYNC=1 MOCK_RECS="$N_RECS" MOCK_INBOX="$N_INBOX" "$CLI" sync >/dev/null 2>&1 || true
out=$(MOCK_SYNC=1 MOCK_RECS="$N_RECS" MOCK_INBOX="$N_INBOX" "$CLI" notify 2>/dev/null || true)
assert_json "月老 sync 之后无变化不提醒" '{"notified":false,"reason":"no_changes"}' "$(jq -c . <<<"$out")"

out=$(MOCK_SYNC=1 MOCK_RECS='<html>bad gateway</html>' MOCK_INBOX="$N_INBOX" "$CLI" notify 2>/dev/null || true)
assert_json "后台连不上时不提醒" '{"notified":false,"reason":"partial"}' "$(jq -c . <<<"$out")"
assert_eq "连不上时不调用通知器" 1 "$(wc -l < "$NLOG" | tr -d ' ')"

LA_DIR="$TMP_HOME/LaunchAgents"
out=$(YUELAO_OS=Darwin YUELAO_LAUNCHD_DIR="$LA_DIR" YUELAO_SKIP_LAUNCHCTL=1 https_proxy=http://127.0.0.1:7890 "$CLI" notify install 30 2>&1 || true)
PL="$LA_DIR/cn.ciyuanlife.yuelao.notify.plist"
assert_contains "install 提示已开启" "every 30 minutes" "$out"
assert_contains "plist 间隔 1800 秒" "<integer>1800</integer>" "$(cat "$PL" 2>/dev/null)"
assert_contains "plist 运行 yuelao notify" "<string>notify</string>" "$(cat "$PL" 2>/dev/null)"
assert_contains "plist 带上代理变量" "<key>https_proxy</key><string>http://127.0.0.1:7890</string>" "$(cat "$PL" 2>/dev/null)"
assert_contains "plist 指定 YUELAO_HOME" "<key>YUELAO_HOME</key><string>$YUELAO_HOME</string>" "$(cat "$PL" 2>/dev/null)"
if grep -q 'test-token\|api_token' "$PL" 2>/dev/null; then bad "plist 不含 token" "无 token" "$(cat "$PL")"; else ok "plist 不含 token"; fi
if command -v plutil >/dev/null 2>&1; then
  if plutil -lint "$PL" >/dev/null; then ok "plist 格式合法（plutil）"; else bad "plist 格式合法（plutil）" "lint ok" "$(plutil -lint "$PL")"; fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$PL" 2>/dev/null; then ok "plist 格式合法（plistlib）"; else bad "plist 格式合法（plistlib）" "parse ok" "$(cat "$PL")"; fi
fi
assert_json "status 显示已开启" '{"installed":true,"interval_minutes":30}' "$("$CLI" notify status | jq -c '{installed, interval_minutes}')"
out=$(YUELAO_OS=Darwin YUELAO_LAUNCHD_DIR="$LA_DIR" YUELAO_SKIP_LAUNCHCTL=1 "$CLI" notify install 5 2>&1 || true)
assert_contains "间隔过短被拒绝" "between 10 and 1440" "$out"
out=$(YUELAO_OS=Darwin YUELAO_LAUNCHD_DIR="$LA_DIR" YUELAO_SKIP_LAUNCHCTL=1 "$CLI" notify uninstall 2>&1 || true)
assert_contains "uninstall 提示已关闭" "Notifications off" "$out"
if [[ -e "$PL" ]]; then bad "uninstall 删除 plist" "不存在" "$PL"; else ok "uninstall 删除 plist"; fi
assert_json "status 显示已关闭" '{"installed":false}' "$("$CLI" notify status | jq -c '{installed}')"
out=$(YUELAO_OS=Linux "$CLI" notify install 15 2>&1 || true)
assert_contains "非 macOS 给出 crontab 行" "*/15 * * * *" "$out"
out=$("$CLI" notify bogus 2>&1 || true)
assert_contains "notify 未知子命令提示用法" "Usage: yuelao notify" "$out"
out=$("$CLI" help 2>&1 || true)
assert_contains "help 列出 notify install" "notify install" "$out"
unset YUELAO_NOTIFY_CMD

PATH="$SAVED_PATH"
unset MOCK_BODY MOCK_CODE MOCK_EXIT

echo
printf '\033[1m%s\033[0m\n' "结果: ${PASS} passed, ${FAIL} failed"
echo
[[ "$FAIL" -eq 0 ]]
