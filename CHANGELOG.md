# Changelog

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
