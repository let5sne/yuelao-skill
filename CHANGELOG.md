# Changelog

> 版本号说明：git 历史中有一个 2026-04 的 commit 自称 "v0.3"，但当时的 metadata 与
> 实际发布版本是 0.1；随后 0.2 才是第一个统一 CLI 的版本。此处以 SKILL.md 的
> `metadata.version` 为准，当前为 **0.3**。

## 0.3 (2026-07-29)

### 修复

- **`sync` 把后端故障静默降级为"没有数据"。** 三个查询（recommendations / messages / pause）失败后都降级成空值，红娘无法区分"确实没新进展"和"服务不可用"，会对用户说"暂时没有新推荐"。现在 sync 输出新增 `partial` 与 `errors` 字段，SKILL.md 明确要求这种情况如实告知用户。
- **拉取失败会清空本地快照。** 上一条的连带后果：`recommendations` 拉取失败降级成 `[]` 后，函数末尾照样用它覆盖 `state.recs`，导致下一次成功的 sync 把全部推荐都当成"新推荐"重报一遍。现在只覆盖拉取成功的部分。
- **裸数组响应会让 sync 崩溃。** `(.recommendations // .)` 对数组取字符串 key 时 jq 直接报错而非走 `//`，后端返回裸数组（或失败降级成 `[]`）时整个 sync 退出码 5。改为显式判类型。
- **档案合并会打乱数组顺序。** 字符串数组并集用了 `unique`，它顺带排序——`["理性","安静"]` 增量加"幽默"会变成 `["安静","幽默","理性"]`。爱好和 dealbreaker 的先后隐含用户的强调程度，且每次更新都重排会让档案无意义地反复变动。改为保序去重。
- **ID 硬编码为数字。** `filter` / `respond` / `message send` / `feedback submit` 都用 `tonumber` 处理 recommendation_id，后端一旦改用 UUID 会同时失效（而 `sync` 内部一律按字符串处理）。改为能转数字就转、否则保持字符串。

### 文档

- **修正脚本路径。** SKILL.md 里 15 处命令写作相对路径 `scripts/hongniang`，但 agent 的工作目录通常是用户自己的项目，首次调用必然 command not found。改为先解析 skill 目录下的绝对路径。
- `respond` 的报错不再向 LLM 推销 `--force`。该 flag 保留为本地状态丢失后的人工修复手段，help 里注明用途，但不再出现在"卡住时下一步怎么做"的提示里——否则代码强制的不变量退化成软约束。
- 统一版本号（git 历史中 v0.3 与 v0.2 时间线倒挂）。

### 测试

- 新增 `tests/run-tests.sh`（39 项，只依赖 bash + jq，无需联网）：覆盖档案深度合并语义、sync 的 diff 计算、响应解包、快照更新、ID 类型处理，以及 CLI 的离线行为与"先筛后展"不变量（含"拒绝必须发生在联网之前"的断言）。测试直接从 CLI 源码里抽取 jq 函数定义，避免实现与测试漂移。

## 0.2 (2026-07-05)

### 架构

- **10 个脚本合并为一个 `scripts/hongniang` CLI**（子命令式），配置读取、网络封装、状态管理不再各自重复。旧脚本全部移除，SKILL.md 同步更新。
- **新增本地状态快照** `~/.hongniang/state.json`：记录上次同步的推荐状态、已见消息、筛选记录、联系方式交换进度、已提交反馈。
- **新增 `hongniang sync`**：一条命令聚合拉取推荐/收件箱/暂停状态/交换进度，与快照 diff 后输出结构化变化摘要（`changes.new_recommendations` / `status_changes` / `new_messages` / `contacts_received`、`needs_filter`、`followups_due`、`paused`）。红娘开场前只需跑这一条命令；v0.1 中"跟上次状态对比"的指令此前没有实现基础，现在由代码完成。
- **"先筛后展"改为代码强制**：`respond` 拒绝没有本地 filter 记录的推荐（可用 `--force` 显式绕过）。

### 修复

- **档案增量更新丢数据**：v0.1 用 jq `*` 深合并，数组被整体替换（增量更新 traits 会清掉旧值）。现在字符串数组取并集，数字数组（age_range）替换，删除元素走新增的 `profile set` 全量替换。
- **respond.sh 文档写 `agree` 代码要求 `accept`** 的不一致。
- SKILL.md 重复的"第三步"、persona.md 重复的"框架 3"编号。
- curl 无超时可能无限阻塞：全部请求 `--max-time 20`，GET 加 `--retry 2`。

### 安全与隐私

- 配置从手工解析的 YAML 改为 JSON（jq 解析），旧 `config.yaml` 自动迁移；本地文件权限统一 600。
- **隐私文档措辞改为如实陈述**：联系方式在双方同意后经服务器中转（服务器可见）；筛选理由和传话内容存储在服务器。移除"联系方式永不上传"的不实表述。E2E 加密中转列入路线图。
- 新增 `hongniang contact set/get`，注册流程不再要求手工编辑配置文件。

### 文档

- SKILL.md 精简约 40%：敏感话题处理移入 references/persona.md，流程描述围绕 `sync` 输出重写。
- TECHNICAL-REPORT.md 新增"演进路线图"：HTTPS、token-only 身份、无认证接口加锁、E2E 加密、双塔检索（O(N²)→O(N)）、精判下放边缘、带门禁的自动学习系统与探索配额。
