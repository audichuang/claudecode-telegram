---
name: test-ops
description: claudecode-telegram 的完整測試工作流 — 用對的模式跑 test.sh(FAST/default/FULL 閘門)、TDD 紅綠重構迴圈、在 test.sh 新增測試的慣例與註冊方式、commit/push 前的釋出檢查。任何時候要跑測試、寫測試、做 TDD、驗證變更、或準備 commit/push 這個 repo,都要用這個 skill — 包括「跑一下測試」這種簡單請求,因為憑記憶手打指令會漏掉 token 載入、模式閘門或隔離前綴。測試「失敗了要排查」則改用 test-triage skill。
---

# test-ops

## Quick start

```bash
.claude/skills/test-ops/scripts/run-tests.sh                    # FAST 套件
.claude/skills/test-ops/scripts/run-tests.sh fast <filter>      # 單測(TDD 內圈)
.claude/skills/test-ops/scripts/run-tests.sh default            # commit 前
.claude/skills/test-ops/scripts/run-tests.sh full               # push 前
```

腳本自動從 `~/.config/claudecode-telegram/test.env` 載入憑證(`set -a` —
檔案沒有 export),不必手打 token。`TEST_FILTER` 是子字串比對。

## 模式閘門(規矩,不是建議)

| 時機 | 模式 | 內容 |
|------|------|------|
| 開發中(TDD 內圈) | `fast <filter>` | 單一測試,秒級回饋 |
| 每個增量轉綠後 | `fast` | unit + CLI,抓回歸 |
| **commit 前** | `default` | + 本地 bridge integration |
| **push 前** | `full` | + tunnel/webhook 測試 |

版本 bump 的 commit 還要過 `.claude/skills/bridge-ops/scripts/check-versions.sh`
(三檔版本同步),並更新 `DOC.md` changelog 與 `TEST.md` inventory。

## TDD 迴圈(專案規定 — 詳見 CLAUDE.md「TDD Workflow」)

1. 先把功能拆成增量階梯(空案例 → 最簡 happy path → 變化 → 邊界 → 錯誤 → 整合)
2. 每個增量:**RED**(寫一個失敗測試,跑 filter 確認真的紅)→ **GREEN**(最小
   實作轉綠)→ **REFACTOR**(清理後再跑一次)
3. 紅不了的測試沒有價值:回填既有行為的測試要附**敏感度證明** — 一個能讓它
   變紅的指令(config 旋鈕、模擬舊行為,例:`PANE_LAUNCH_CONFIRM_SECS=8`)

## 在 test.sh 新增測試

1. **測行為,不測鷹架** — 斷言使用者在乎的結果(session 還活著、訊息送達了),
   不是函式存在或 HTTP 200。字串形狀斷言曾在 zsh 真壞掉時照樣綠(v1.1.1 教訓)。
2. **一個測試一個行為**;命名 `test_<行為描述>`,filter 用子字串就能命中。
3. **註冊**:在 `run_unit_tests`(自足快速)或 `run_integration_tests`(需
   bridge/網路)加 `run_test test_名稱` — 沒註冊的測試不會跑。
4. **隔離**:tmux 一律 `${TMUX_PREFIX}`(預設 `claude-test-`)前綴;只 kill
   自己記下的 PID;絕不碰 dev node(:8270)和它的 poll forwarder;暫存檔用
   `$$` 後綴並在結尾清理。
5. **可攜性**:macOS+Linux 都要過 — 禁 `grep -P`、單用 `stat -c`、`date +%N`;
   計時用 `for i in $(seq 1 N); do sleep 0.05; done`;依賴 `ss` 等 Linux-only
   工具的測試要 skip-with-success 守門。
6. **地雷**(set -e、全域計數器遮蔽、fake subprocess、monkeypatch 鐵律):
   完整清單見 test-triage skill 第 5 節與 CLAUDE.md「test.sh landmines」。
7. 寫完同步更新 `TEST.md` 的 inventory 與計數表。

## 失敗了?

換 **test-triage** skill:單測重跑 → 已知環境性失敗清單(concurrent-sends、
send_to_session_integration)→ worktree HEAD~1 對照實驗 → 插桩。在歸因前
不要急著改程式碼或回滾。
