# Spec: Topic-only bridge (v1.0.0) — C1/C3/C4 落地

- **Date:** 2026-06-11
- **Status:** Approved（使用者拍板三項關鍵決策）
- **Target:** `bridge.py`, `test.sh`, docs
- **Branch:** `feat/topic-sessions`
- **Builds on:** `2026-06-10-topic-sessions-design.md`（話題=session 模型）

## 拍板的決策

1. **話題就是唯一模式。** 非話題 router（hire-by-name/focus/team/@mention 定址、
   active-worker 媒體路由）整個刪除。`TOPIC_MODE` 不再是模式開關。
   Breaking → **v1.0.0**。
2. **關閉話題 = 結束 session。** `forum_topic_closed` → `workers.end` + 清
   topic globals。`forum_topic_reopened` → 視為新話題（無綁定 → 資料夾選單）。
   話題「刪除」沒有 Bot API 事件 → **送達失敗備援**：送訊息回話題收到
   thread-not-found 類錯誤 → 自動收掉該 session 並大聲 log。
3. **啟動通知一行話題語意。**「✅ Bridge v1.0.0 上線 — N 個話題 session 存活」。
   不再有 Team:/Focused:。

## 稽核發現的遷移缺口（一併修）

- **媒體在話題中被靜默丟棄**：`handle_message` 在媒體解析前就進
  `_handle_topic_message`，photo/document/voice/video 的下載路徑只存在於
  legacy 路徑。修法：把媒體管線移進話題路徑（下載到 session inbox →
  以本地路徑＋caption 餵給該話題的 worker）。
- **`hire()` 無條件 `set_focus`**：寫入端活著、話題路徑零讀者 → 刪。
- **啟動「Restored last active worker」**：對話題模式無意義 → 刪。

## 刪除清單（C4，分批、每批 FAST 全綠）

| 批次 | 刪 | 留（理由） |
|------|----|-----------|
| a. 入口 | legacy `handle_message` 媒體/指令路由（媒體管線先搬進話題路徑） | `tmain` 非論壇 fallback |
| b. 編排 | `/hire /focus /team /end /progress /pause` handlers、@mention、per-worker 選單、`set_focus`/`state["active"]`/last-active 持久化 | `TOPIC_LEGACY_CMDS` 提示墓碑（5 行，UX） |
| c. teleport | `_remote_run`/`_remote_copy`/git push-pull state/registry teleport 欄位/`/teleport*`（~130 refs）、inbox 的 rsync 遠端分支 | inbox 本體（媒體收件匣） |
| d. 後端 | Codex/Gemini/OpenCode backends、`in.pipe` worker 互傳、gRPC stubs、`/register` forge endpoint | ClaudeBackend、`/pr-*` endpoints（/pr 工作流在用） |
| e. 文件 | CLI help 的 hire/focus 文案、README/DOC/CLAUDE/TEST 對齊 | 多節點隔離（prod/dev/test，部署層）、sandbox（shell 層） |

**不動**：watchdog/pending/typing/emoji 活性、transport seam、hook 回覆路徑、
`/memory /voice /settings /rewind /pr /quota /cd /close`、團隊記憶、uv 工具鏈。

## 執行順序（TDD，每階段 FAST gate）

1. **P1 (C1)** closed→end；reopened→選單；thread-not-found 備援
2. **P2 (C3)** 退役 focus/active/last-active；啟動通知改寫
3. **P3 (C4a)** 媒體管線移入話題路徑；`TOPIC_MODE` 硬化為 True
4. **P4 (C4b)** 刪編排指令層
5. **P5 (C4c)** 刪 teleport
6. **P6 (C4d)** 刪非互動後端/pipes/gRPC/forge
7. **P7** 文件 + v1.0.0 + FULL suite + dev 部署

風險控管：git 隨時可復原；legacy 測試隨對應機制同批刪除；
媒體管線搬移（P3）是唯一「搬」而非「刪」的步驟，先寫 e2e 測試再動。
