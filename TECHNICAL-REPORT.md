# 月老 — 技术架构报告

## 系统概览

月老是一个两层架构的 AI 婚恋匹配系统。用户端是一个遵循 [Agent Skills](https://agentskills.io) 标准的本地 Skill，后端是基于 [OpenClaw](https://github.com/openclaw/openclaw) 改造的匹配引擎。两层通过 REST API 通信。

```
用户 A 的机器                           用户 B 的机器
┌─────────────────┐                    ┌─────────────────┐
│  月老 Skill (A)  │                    │  月老 Skill (B)  │
│  私人月老 A      │                    │  私人月老 B      │
│  本地对话+筛选   │                    │  本地对话+筛选   │
└────────┬────────┘                    └────────┬────────┘
         │ REST API                             │ REST API
         ▼                                      ▼
┌──────────────────────────────────────────────────────────┐
│                 匹配引擎 (OpenClaw fork)                   │
│                                                          │
│  PostgreSQL    三层漏斗匹配    自进化系统    传话消息队列    │
│  (档案+状态)   (SQL→向量→LLM)  (每日复盘)   (异步中转)     │
└──────────────────────────────────────────────────────────┘
```

## 用户端：私人月老

每个用户安装的 Skill 都是一个**独立的私人月老**。她不只是调 API 的客户端——她有自己的判断力。

### 设计原则：判断力归 LLM，时序和不变量归代码

LLM 是系统里最不可靠的执行者，所以工作流程的时序和状态不依赖提示词自觉，全部收进 `yuelao` CLI：

- **本地状态快照。** `~/.yuelao/state.json` 记录上次同步的推荐状态、已见消息、筛选记录、联系方式交换进度。`yuelao sync` 拉取全量数据后与快照 diff，直接输出结构化的"变化摘要"（新推荐、状态跃迁、新传话、到手的联系方式、到期的跟进），月老只负责把它讲成人话。跨会话的"记忆"由文件承担，不依赖 LLM 的上下文。
- **代码强制的不变量。** `respond` 拒绝没有本地 filter 记录的推荐——"先筛选、回传判断、再展示、用户表态"这个顺序不是提示词请求，而是程序保证。
- **不丢数据的合并语义。** 档案增量更新的深度合并规则：object 递归合并；纯字符串数组取并集（增量添加不丢失旧值）；其他数组（如 `age_range`）整体替换；删除元素走 `profile set` 全量替换。
- **一次会话一次网络往返簇。** `sync` 内部聚合 recommendations / inbox / pause / exchange 四类查询，月老打招呼前只需要跑一条命令。

### 职责分工

| 用户端负责 | 后端负责 |
|-----------|---------|
| 对话式信息收集（从聊天中提取结构化档案） | 档案存储 |
| 推荐二次筛选（后端一轮最多入库 5 条，月老最多展示 3 个） | 全量匹配计算 |
| 传话措辞包装（不直接转发用户原话） | 消息中转存储 |
| 婚恋认知引导（帮用户理清自己要什么） | 匹配分+理由生成 |
| 约会后跟进（主动问进展，收集反馈） | 反馈数据聚合 |
| 暂停/恢复判断（识别用户意图） | 状态管理 |
| 跨会话状态记忆（快照+diff） | — |

### 为什么要两层

后端只有结构化档案（年龄、城市、性格标签），但用户端月老在对话中积累了大量**非结构化信息**：

- 用户嘴上说"学历无所谓"，但每次聊到高学历的人语气明显不同
- 用户回避谈异地话题——档案里没写 dealbreaker，但月老知道
- 用户前后矛盾——先说不在乎收入，后来又问对方收入多少

这些信息只有本地月老知道，后端无法获取。所以后端做粗筛，用户端做细筛。

### 筛选反馈闭环

```
后端推荐 → 本地月老筛选 → 回传 filter 反馈 (shown/suppressed + 理由) → 后端学习
```

如果某类推荐被本地月老频繁压住，说明匹配逻辑在那个维度上不准。

### 本地文件

```
~/.yuelao/                     （权限均为 600）
├── config.json           # user_id, api_token, backend_url, 联系方式
├── state.json            # 推荐状态快照、已见消息、筛选/交换/反馈记录
└── profile-cache.json    # 档案本地缓存（增量更新时深度合并用）
```

## 后端：匹配引擎

基于 OpenClaw 改造。OpenClaw 提供了 gateway、cron 引擎、多通道适配器等基础设施，月老在上面加了匹配逻辑、传话系统和自进化引擎。

### 三层漏斗匹配

**第一层：SQL 预筛（毫秒级）** — 硬性条件过滤：性别互斥、年龄区间交集、城市匹配、排除已推荐。200 用户 → 约 2000 候选对。

**第二层：向量粗排（秒级）** — 通义千问 text-embedding-v4，档案文本转 1024 维向量，余弦相似度取 top-K。Embedding 按 text hash 缓存，档案没变不重算。

**第三层：LLM 精判（分钟级）** — 对候选对调用 LLM 深度评估，输出分数、双向推荐理由和挑战提示。评估维度：互补性(40%)、价值观兼容(30%)、生活方式(20%)、基本条件(10%)。

### 自进化系统

**数据来源（四层反馈）：**

| 层级 | 数据 | 来源 | 含义 |
|------|------|------|------|
| 月老筛选 | shown/suppressed + 理由 | 本地 Skill | 后端觉得合适但本地月老不认可 |
| 用户决策 | accept/reject + 原因 | 用户操作 | 用户的显性偏好 |
| 约会反馈 | chatting/met/dating/ended + 评分 | 用户回访 | 匹配的真实结果 |
| 进化分析 | insights + 阈值调整 | LLM 复盘 | 系统自我认知 |

**进化流程：** 每日复盘最近 30 天数据 → 分析成功/失败因素 → 生成 insights → 调整阈值权重 → 注入下次匹配的 prompt。

> ⚠️ **这一节描述的是设计意图，不是当前状态。** 四层反馈里目前三层永远收不到数据
> ——没有推荐被生成过，就没有筛选、没有决定、没有约会反馈。所以"自进化"现在
> **并未运行**，也**不存在**定时改权重的后台任务（`server/src/` 里没有 cron/定时器，
> 见 TODO 一节）。权重目前是一份静态的外部先验。在攒到真实反馈之前，任何
> "越用越准"的表述都是承诺而不是事实。

### 传话系统

```
A："帮我问问她周末干嘛" → A 的月老包装 → POST /messages → 数据库
→ B 下次打开 Skill → sync 发现新消息 → B 的月老转述 → B 回复 → 原路返回
```

消息不暴露发送方 UUID，只有 recommendation_id 供月老关联上下文。

### 双向同意状态机

```
recommended → A accept → waiting_for_b
recommended → B accept → waiting_for_a
waiting_for_x → X accept → matched (可交换联系方式)
任一方 reject → rejected
```

联系方式交换只有 `matched` 状态才能提交和获取。

## 数据模型

```
profiles            — 用户档案（UUID, summary JSONB, preferences JSONB, status）
profile_embeddings  — 向量缓存（user_id, embedding FLOAT8[], text_hash）
recommendations     — 匹配推荐（user_a, user_b, score, reasons, status）
exchanges           — 联系方式交换（match_id, user_id, contact）
filter_feedback     — 月老筛选反馈（recommendation_id, action, reason）
messages            — 传话消息（from_user, to_user, content, read_at）
date_feedback       — 约会后反馈（recommendation_id, outcome, rating, comment）
```

## API

基础地址：`{BACKEND_URL}/api/v1/yuelao`

| 接口 | 方法 | 功能 | 认证 |
|------|------|------|------|
| `/profile` | POST | 注册 | 无 |
| `/profile/:id` | GET | 获取档案 | Bearer token |
| `/profile/:id` | PATCH | 更新档案 | Bearer token |
| `/profile/:id` | DELETE | 注销 | Bearer token |
| `/profile/:id/pause` | POST/GET | 暂停匹配 | Bearer token |
| `/profile/:id/resume` | POST | 恢复匹配 | Bearer token |
| `/recommendations/:id` | GET | 获取推荐（含对方脱敏画像） | Bearer token |
| `/response` | POST | 接受/拒绝推荐 | Bearer token |
| `/recommendations/:id/filter` | POST | 月老筛选反馈 | 无（见下方安全项） |
| `/exchange/:match_id` | POST/GET | 联系方式交换 | Bearer token |
| `/messages` | POST | 发送传话 | Bearer token |
| `/messages/:user_id` | GET | 查看收件箱 | Bearer token |
| `/messages/:id/read` | POST | 标记已读 | Bearer token |
| `/feedback` | POST/GET | 约会后反馈 | Bearer token |
| `/match/run`, `/evolve` 等 | POST/GET | 运维接口 | 无（见下方安全项） |

## 数据安全（现状，如实陈述）

| 数据类型 | 存储位置 | 说明 |
|----------|---------|------|
| 对话原文 | 用户本地 | 不发到匹配后端。注意这不等于"不出网"：月老跑在用户自己的 agent 里，对话仍会经过用户所选模型服务 |
| 联系方式 | 平时在本地 config.json | 双方同意后经 API 上传交换，服务器 `exchanges` 表可见 |
| 结构化档案 | 后端 PostgreSQL | 年龄/城市/性格标签等，无姓名 |
| 筛选理由 / 传话内容 | 后端 PostgreSQL | 含对话衍生信息，服务器可见 |
| 匹配记录 | 后端 PostgreSQL | 分数、理由、状态 |

## 演进路线图

按优先级排序，内测期间逐项落地：

### 安全与信任（最高优先级）

1. **HTTPS + 域名。** 当前为明文 HTTP + 裸 IP，token、画像、联系方式明文传输，上线试用前必须切换。
2. **身份只来自 token。** 去掉 URL 路径和 payload 里的 user_id，服务端从 Bearer token 反查身份，整类 IDOR 风险直接消失。
3. **无认证接口加锁。** `/recommendations/:id/filter`（可污染学习信号）、`/match/run`、`/evolve`（可被滥用烧 LLM 费用）全部加认证；注册加限流。
4. **端到端加密中转。** 匹配建立时双方经服务器交换公钥，之后传话和联系方式用对方公钥加密——服务器从"承诺不看"变成"看不了"。落地后更新隐私文档。
5. **验证与治理。** 分级实名验证（手机→更高级别）、举报/拉黑、传话内容安全审查。婚恋场景的对抗面大，虚假档案收割联系方式是真实威胁。

### 匹配引擎成本与质量重构

6. **LLM 只判"人"，不判"对"（O(N²)→O(N)）。** 注册/档案更新时用小模型对每个用户深度编码一次，产出"供给画像"（这个人作为伴侣是什么样）、"需求画像"（TA 真正需要什么样的人，由 LLM 从全档案推断而非照抄 preferences）和硬约束表。
7. **双塔检索替代档案相似度。** 当前向量层计算两份档案的相似度，度量的是"像不像"而非"合不合适"，系统性奖励同质。改为 `score(A,B) = sim(A.seek, B.offer) × sim(B.seek, A.offer)`——双向交叉打分，单向仰慕自动降权，与双向同意状态机的语义一致。pgvector ANN 索引，毫秒级。
8. **精判下放边缘。** 服务端输出紧凑候选卡（脱敏画像+分数拆解，每张几百 token），最终判断交给本地月老——她有档案外的私有上下文，且她的算力免费。服务端残余的 LLM 复核用小模型 + prompt caching + Batch API。
9. **事件驱动替代每日全量批跑。** 新注册/档案变更才触发编码与增量检索；只为活跃用户计算。

### 学习系统（自动化 + 门禁）

10. **参数化 rubric + 贝叶斯收缩。** 匹配维度权重显式化：`有效权重 = n/(n+k)·自有数据估计 + k/(n+k)·外部先验`。先验来自关系科学研究结论（价值观相似性 > 兴趣相似性、地理距离的强流失效应、情绪稳定性的预测力等）和公开数据集校准。样本量上来后权重自动向自有数据过渡，每个维度独立。

    **部分已实现**：rubric 与先验权重已落地在 `server/src/judgment.js`（互补性 40% / 价值观 30% / 生活方式 20% / 基本条件 10%，可用 `JUDGMENT_WEIGHTS` 覆盖），由 TypeSafe System One 模型产出各维分数与置信度，权重在代码里合成——**不是**写在提示词里。n=0 时该公式退化为纯先验，正是当前状态；反馈数据攒起来后各维度可独立向自有数据过渡，权重表结构不用改。**尚未实现**的是收缩本身（那把 `n` 从 0 变大的那一步）——它需要 `date_feedback` 有数据，而当前池子里还没有一次真实约会反馈。
11. **管道全自动，部署有门禁。** 每日复盘产出的是候选假设（效应量+样本量+置信区间），通过显著性检验和历史回放测试才自动生效，否则留在假设池继续攒证据。
12. **探索配额。** 5-10% 的推荐标记为探索性展示，防止月老筛选造成的选择偏差让反馈闭环退化为自我确认。
13. **指标阶梯锚定终局。** 展示→accept→双向匹配→交换→30 天仍在发展，学习目标锚定后端信号，前端信号只做代理并标注偏差。

## 技术栈

| 组件 | 技术 |
|------|------|
| 用户端 | Agent Skills 标准（SKILL.md + `yuelao` bash CLI） |
| 后端 | TypeScript / Node.js（OpenClaw fork） |
| 数据库 | PostgreSQL 16 |
| LLM（匹配） | MiniMax M2.7（通过 OpenClaw 配置） |
| LLM（用户对话） | 用户本地 Agent 工具自带的 LLM |
| Embedding | 阿里通义千问 text-embedding-v4 |
| 判断打分（服务端） | TypeSafe System One（Jev）——四维复合打分，返回分数 + 置信度，不做决定 |
| 部署 | Docker（PostgreSQL）+ Node.js 直接运行 |
