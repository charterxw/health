# OpenGym 对 Health 训练 App 的借鉴与资源调查

调查日期：2026-11-12（America/New_York）。

后续选择已收敛为按实际健身房器材整理的 24 个动作，见 [器材与实现说明](gym-exercises.md)。以下保留原始资源调研，千项目录没有导入当前应用。

调查对象：[DuarteSantos8/openGym](https://github.com/DuarteSantos8/openGym)，固定到本次读取的提交 [50ab7f24e3c4ee70e7f26b3beb426f571e03414b](https://github.com/DuarteSantos8/openGym/tree/50ab7f24e3c4ee70e7f26b3beb426f571e03414b)（提交时间 2026-11-09）。

方法：读取 OpenGym 源码、文档和许可证，对照本地 Health 源码，并下载解析两个候选动作库的 JSON。没有运行 OpenGym、测试其 App，也没有修改或部署 Health 功能。本文的优先级、接入方案和示例均为针对 Health 的建议；外部项目的功能以所链接源码为依据。

## 结论

最值得先加的是：**动作库与中文说明、按肌群统计已完成训练组数、可解释的下次训练目标**。随后可加 A/B 轮换、器械档位与替代动作。我们现有的训练记录和健康数据分析可以继续作为基础。

资源需要分别看待：

- OpenGym 自有代码：AGPL-3.0；适合研究设计，直接采用代码要处理适用的 AGPL 条款。
- 1,324 个动作的上游文字数据：有独立 MIT 来源，包括中文说明，适合优先接入。
- 人体肌肉图：可从原项目 MuscleMap 获取 MIT 授权的图形数据或 SwiftUI SDK。
- OpenGym 演示图与动画：Gym visual 单独授权，不能复制到独立的 Health App；低分辨率也不自动获得使用权。

来源：[OpenGym 第三方声明](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/NOTICE.md)、[上游数据许可证](https://github.com/hasaneyldrm/exercises-dataset/blob/main/LICENSE)、[MuscleMap 许可证](https://github.com/melihcolpan/MuscleMap/blob/main/LICENSE)。

## 1. 我们已经具备什么

以下是本地实现状态，不是对线上数据库现有记录的清点。

| 项目 | Health 当前情况 | 对此次借鉴的意义 |
| --- | --- | --- |
| 动作与模板 | 默认 9 个动作、2 个训练模板；可新增动作、编辑模板 | 缺口主要是动作内容、说明和筛选，不必重做模板系统 |
| 训练中记录 | 历史预填、kg/lb、辅助与自重、热身组、逐组勾选、暂停、休息计时 | OpenGym 的基础记录流程与我们已有能力重叠 |
| 努力程度 | 每个动作可选 easy/normal/hard | 还没有逐组 RIR/RPE，不能把现有三级评价直接当成精确 RIR |
| 训练后比较 | 同动作与负重方式的历史、同重量次数比较；只计已勾选组 | 可以继续扩展为长期趋势和下次目标 |
| 健康上下文 | 训练时间窗心率、步数、估计活动能量，以及睡眠/HRV/静息心率上下文 | 可以支持后续观察与计划建议，不必另起一个 AI 系统 |
| 保存与同步 | localStorage 草稿、SQLite、版本冲突处理、删除标记 | 断网时已打开页面可继续；完整离线重开尚未实现 |
| iPhone | SwiftUI/WKWebView 原型、Live Activity 和休息提醒的源码已存在 | 原生编译、签名及真机验证仍待完成，手表功能宜放后面 |

本地依据：[训练模型](../backend/app/strength_training.py)、[训练界面](../frontend/src/components/StrengthTraining.jsx)、[训练辅助函数](../frontend/src/training/strength.js)、[训练报告](../frontend/src/training/report.js)、[保存与同步](../frontend/src/training/useStrengthStore.js)、[iOS 状态](../ios/README.md)。

## 2. 建议借鉴的功能与顺序

| 优先级 | 功能 | Health 中具体怎么用 | 工作量判断 |
| --- | --- | --- | --- |
| 第一批 | 动作库、说明与筛选 | 中英文名称/别名、主次肌群、器械、分步说明；常用动作置顶，按肌群/器械筛选 | 中：主要是数据导入、核对和界面 |
| 第一批 | 肌群训练分布 | 模板卡展示训练部位；周报告展示各肌群已完成工作组和最近训练日期 | 中：先统一肌群标识，再接人体图 |
| 第一批 | 下次训练目标 | 每个动作配置次数区间和加重步长，基于完成历史给出下次重量/次数，并显示理由 | 中至高：需要修改目标模型及历史判定 |
| 第二批 | A/B 轮换 | 现有两套模板构成循环，主页提示下一套；完成一场后推进，休息日无需改星期表 | 小至中 |
| 第二批 | 器械档位与杠铃配重 | 保存哑铃/插片真实档位；建议重量必须可选到；卧推显示每侧杠铃片组合 | 中 |
| 第二批 | 替代动作 | 器械被占用时，从人工审核的同动作类型候选里替换，并使用替代动作自己的历史 | 中；依赖动作元数据 |
| 第二批 | 长期趋势与 PR | 同动作的重量/次数趋势和明确条件下的纪录；辅助动作单独判定进步方向 | 中 |
| 第二批 | 完整离线启动 | 缓存应用壳，离线可重新打开训练；联网后同步，并保留删除/冲突保护 | 中至高：还涉及登录和现有推送 worker |
| 后续 | 逐组 RIR/RPE、超级组、计时动作 | 在需要时展开；先增加明确记录能力，再考虑更复杂的训练剂量估计 | 中至高 |
| 后续 | 导入导出、AI 计划建议、MCP | JSON 完整备份与 CSV 导出优先；有迁移需求再做 Strong/Hevy/FitNotes；AI 生成可审核的计划修改 | 视范围而定 |

这些是相对工作量判断，不是交付时间承诺。第一批可以分别交付，无须等待素材购买或完整动作动画库。

### 下次目标最值得借鉴的设计

OpenGym 的 [progression.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/progression.js) 支持线性、Greyskull、双重进阶、三重进阶和时长进阶。它从历史推导目标，记录仍代表实际发生的训练；未勾选或不足目标的组不会被当成全部达标。

Health 首版建议只实现可关闭的双重进阶。例如用户配置卧推 3 组、8–12 次、步长 5 lb：

- 本次 100 lb × 12/11/10：下次保持重量，提示继续在次数区间内推进。
- 本次 100 lb × 12/12/12 且全部为已完成工作组：提示下次 105 lb、目标回到每组 8 次。
- 缺组、未完成或改变了动作/器械条件：不直接判定为加重成功。

这是建议的产品规则示例，不是对个人训练负重的处方。用户可调整或关闭；真实器械档位约束建议重量。辅助动作、自重、单侧/双侧计数需要各自的规则，不能套用同一个加重方向。

### 肌群展示先展示记录，再考虑恢复估计

适合先展示“过去 7 天已完成多少工作组”和“最近何时训练过”。主肌群与次肌群分开显示，避免把两者都重复计为完整训练量；没有逐组努力程度时，名称用“工作组”，不宣称是已经准确测得的“有效组”。

OpenGym 自己的 [疲劳模型说明](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/docs/dev/FATIGUE_SETS_MODEL.md) 记录了较早版本长期显示疲劳的问题，并介绍多次调整。这说明红/黄/绿恢复图涉及额外模型假设。Health 初期可以显示已记录的训练暴露，不把颜色直接解释为真实恢复百分比。

### 替代动作要保留动作差异

OpenGym 的 [替代候选](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/exercise-substitutes.js) 使用审核过的动作家族，并有同类型/肌群的后备候选。Health 可以借鉴这种候选分层，优先为常用动作人工整理 2–3 个替代选项。

例如杠铃卧推换成哑铃卧推后，不能把杠铃总重直接填成单只哑铃重量；应读取替代动作的历史，或留空让用户填写。已经完成的组保留在原动作下。

## 3. 可以使用的资源

### A. 首选文字动作库：hasaneyldrm/exercises-dataset

- 仓库：[exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset)。
- 数据入口：[data/exercises.json](https://raw.githubusercontent.com/hasaneyldrm/exercises-dataset/main/data/exercises.json)。本次实际解析到 **1,324 条**，原始响应 **17,391,530 字节**；体积主要包含多语言内容。
- 可用字段：动作名称、身体部位、器械、目标肌群、次要肌群、分类、说明及分步说明；仓库列出中文等 10 种语言。
- [LICENSE](https://github.com/hasaneyldrm/exercises-dataset/blob/main/LICENSE) 明确将代码、数据结构、说明和翻译置于 MIT，同时排除 images/videos 媒体。
- 使用方式：离线导入选定文字字段到 Health，保留版权和 MIT 声明。只向前端发送所需语言和索引，说明按需加载；移除未经授权的图片/GIF 地址。
- 中文说明和动作对应关系仍需校对。源数据分类词汇不应直接等同于我们新建的统一分类。

这个来源的中文文字数据与 OpenGym 后续自行制作的中文翻译是两套授权来源，应从上游直接获取，不从 OpenGym 混合生成文件里整包抽取。

### B. 人体图与原生组件：MuscleMap

- 仓库：[melihcolpan/MuscleMap](https://github.com/melihcolpan/MuscleMap)。
- [README](https://github.com/melihcolpan/MuscleMap/blob/main/README.md) 提供男女体型、正背面、肌群高亮/热力图和交互；SwiftUI/UIKit，iOS 17+，可通过 Swift Package Manager 引入。
- [MIT 许可证](https://github.com/melihcolpan/MuscleMap/blob/main/LICENSE)：使用时保留版权和许可文本。
- 当前主界面在 React：可从原项目图形路径转换为自己的 SVG 数据与组件；未来原生页面可直接评估 Swift 包。转换工作仍需我们实现。
- OpenGym 的 NOTICE 说明其 body-paths.js 源自该项目，但自己的 BodyMap 组件与统计逻辑属于另外的代码层；直接从原项目取得素材能保持来源清楚。

### C. 备选动作库和静态照片：free-exercise-db

- 仓库：[yuhonas/free-exercise-db](https://github.com/yuhonas/free-exercise-db)。
- 数据入口：[dist/exercises.json](https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json)。本次实际解析到 **876 条**，响应 **1,005,327 字节**。
- 字段包括主次肌群、器械、难度、动作类型、英文步骤与静态照片路径。
- 仓库声明 [Unlicense](https://github.com/yuhonas/free-exercise-db/blob/main/LICENSE.md)，README 明确介绍 JSON 与图片的本地使用方式；按该声明可作为免费数据及静态图候选。
- 适合低成本补充静态动作图，不提供与 OpenGym 等价的动画。README 也列出部分字段缺失和少量重复图片，需要内容整理。

### D. 统一演示图与动画：Gym visual

- 权利方：[Gym visual](https://gymvisual.com/)，[使用条款](https://gymvisual.com/content/3-terms-and-conditions-of-use)。
- OpenGym 的 [NOTICE](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/NOTICE.md) 明确说：媒体不属于 AGPL，也不属于动作文字许可；独立 App 要自行取得许可，不能直接提取或热链。
- OpenGym 对非商业 fork 的特定 180 px 例外不等于允许移植到我们的独立 Health App。
- 如果希望统一专业动画，可先整理常用动作清单，再向权利方取得适合 Health 的 App/Web 授权；本次没有询价、购买或下载媒体。
- OpenGym 声明还禁止把这些媒体用于 AI 输入或生成素材的基础，因此不能将该仓库动画作为 AI 重绘参考来绕过授权。

### E. OpenGym 自有目录、代码、测试、API 与 MCP

本次解析其生成动作目录得到 **5,632 个可列举动作**。仓库 catalogue/exercises 下有更多 JSON 文件，包含变体/别名等，不能把文件数直接当独立可选动作数。主目录有 12 类动作；它不是单纯的力量训练清单。

目录的 [维护说明](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/catalogue/README.md) 值得参考：稳定 ID、每动作一个 JSON、翻译独立、构建校验、媒体独立。新条目、描述、肌群修正和翻译按 NOTICE 属于 OpenGym 的 AGPL，不能把完整目录视为 MIT 数据集。

OpenGym 自有代码使用 [AGPL-3.0](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/LICENSE)。直接复制或修改再使用时，要按分发和网络交互等具体方式满足适用的对应源码等义务；不应把它当成 MIT 组件直接粘贴。Health 可以研究功能和数据组织方式，并针对现有模型独立实现。

| 源码入口 | 可借鉴内容 | 对 Health 的适配判断 |
| --- | --- | --- |
| [progression.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/progression.js) 及相邻测试 | 次数区间、未完成组、停滞、降重、解释下次目标 | 依赖它的历史/器械模型，不能仅复制单文件就接入 |
| [onerm.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/onerm.js) | 估计 1RM、单位与动作条件处理 | 后续只在合适动作和组次条件下展示估计值 |
| [muscles.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/muscles.js) | 肌群别名与训练分布 | 统一我们现有中文肌群标识，同时保留需要的细分部位 |
| [equipment.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/equipment.js)、[plates.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/plates.js)、[dumbbells.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/dumbbells.js) | 器械筛选、真实重量档位、杠铃片组合 | 保留 Health 的逐动作单位与辅助负重语义 |
| [rotation.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/rotation.js)、[starter.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/starter.js) | 循环顺序、入门模板 | 优先沿用用户已有两套模板，给出下一套提示 |
| [import-csv.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/import-csv.js)、[导入说明](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/docs/DATA_IMPORTS.md) | CSV 识别、动作匹配、单位、重导入去重 | 我们已有 Xunji 档案，其他来源按实际迁移需求添加 |
| [sync-merge.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/src/lib/sync-merge.js)、[sw.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/frontend/public/sw.js) | 删除保留、字段合并、离线壳、按版本更新缓存 | 我们现有记录模型不同；先补离线重开，再评估更复杂的合并 |
| [AI_COACH.md](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/docs/AI_COACH.md)、[validate.js](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/api/coach/core/validate.js) | 有依据的结构化修改建议、验证、预览、应用、撤销 | 在现有 AI 观察基础上扩展；应用前核对模板版本，保留历史训练事实 |
| [API 文档](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/docs/API.md)、[OpenAPI](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/api/openapi.yaml)、[MCP](https://github.com/DuarteSantos8/openGym/blob/50ab7f24e3c4ee70e7f26b3beb426f571e03414b/mcp/README.md) | 训练历史查询、肌群分布、下次训练预览、日志写入 | 面向 OpenGym 实例与数据结构，并非 Health 的即插即用接口，也不提供公共媒体授权 |

## 4. 接到现有 Health 的建议方案

### 第一步：内容与肌群展示

先覆盖现有 9 个动作和一批常见替代动作，再按需扩大目录。不要一开始在手机上展示几千个动作，也不要把 17 MB 多语言 JSON 放进首屏包。

1. 建立带来源版本的动作种子数据；保留现有 exercise_id，增加 source/source_id 映射，避免破坏已记录训练。
2. 为目录增加英文名、中文别名、主次肌群、动作类型、步骤、内容许可与独立媒体许可字段。
3. 人工核对现有动作的具体变式。特别是 Y 字绳索侧平举、正握牧师器弯举、辅助双杠，不能仅按名称模糊匹配到相邻动作。
4. 训练选择器增加器械和肌群筛选；动作详情显示说明。人体图使用独立来源的图形数据和自己的统计逻辑。
5. 模板显示训练部位；周报告只汇总已完成非热身工作组。模板覆盖与已完成训练分布分开展示，避免把计划视为已经执行。

主要接入位置：[后端动作模型](../backend/app/strength_training.py)、[目录路由](../backend/app/routes/strength.py)、[训练界面](../frontend/src/components/StrengthTraining.jsx)、[训练报告组件](../frontend/src/components/TrainingReport.jsx)。当前 Pydantic 模型禁止额外字段，扩展目录时要同步修改校验与 API 输出。

### 第二步：目标与器械

模板目标增加 rep_min/rep_max、progression_policy、increment 或可选重量档位。开始训练时保存本次计划目标快照，实际完成数据继续单独记录；不要结束后拿已经修改的模板反推当时是否达标。

目标计算可以放在独立的纯函数模块，输入完成历史、计划和器械，输出建议重量、次数及理由。历史修改/删除后重新推导；复用现有删除与比较语义。我们目前“已勾选才算完成、不同负重模式分开、单位显式转换”的原则要继续成立。

A/B 轮换可以单独交付：由明确归属某模板的已完成场次推进顺序，放弃草稿不推进；跨设备重复同步同一场训练不重复推进。

### 第三步：离线与后续自动化

当前 [push-sw.js](../frontend/public/push-sw.js) 只负责推送，不缓存页面和 API。完整离线需要设计同一作用域 worker 的升级、静态资源缓存、更新失败回退、登录状态和退出后的本地数据清理，而不只是添加另一个 worker。

后续 AI 计划建议可沿用 OpenGym 的“结构化提案→服务端校验→展示差异→用户应用→可撤销”思路。确定性的加重规则由代码执行；AI 可以解释上下文或提出模板调整，训练日志仍以实际记录为准。

## 5. 本次核验的边界

- 动作数量和 JSON 体积为本次实际读取值，后续上游可能变化；落地时应固定来源提交并保存许可副本。
- 资源可用性判断依据权利方条款和仓库公开许可声明；没有取得 Gym visual 的独立授权，也没有把其媒体导入 Health。
- 源码中出现某功能只说明该提交具有实现，不代表本次完成了运行、设备兼容性或科学有效性验证。
- 本次交付为研究文档；没有更改 Health 应用代码、生产数据或部署状态。
