---
name: test-triage
description: claudecode-telegram 的 test.sh 失敗排查流程 — 判定紅燈是程式碼造成還是環境造成、把不透明的失敗變成有證據的結論。任何時候 test.sh 有測試失敗、測試紅得不明不白、懷疑 flaky、想在 commit/push 前確認失敗與自己的變更無關、或要在 test.sh 新增/修測試時,都要用這個 skill — 即使失敗看起來「顯然」是誰的錯也先走流程,2026-06-12 有兩個「顯然是新變更害的」失敗最後都證明是環境問題。
---

# test-triage

每個步驟都是 2026-06-12 實戰驗證過的:當天 FULL 套件兩個失敗看起來像 v1.1.2
新變更造成,最後都被本流程證明是環境問題 — 沒有這套流程就會回滾好端端的程式碼。

## 排查決策流

```
測試失敗 → 1. TEST_FILTER 單測重跑(可重現嗎?)
         → 2. 查已知環境性失敗清單(中了就結案)
         → 3. worktree 對照實驗(上一個 commit 也紅 = 環境問題)
         → 4. 仍懷疑程式碼 → 插桩看真相
```

## 1. 單測重跑(先確認可重現)

```bash
source ~/.config/claudecode-telegram/test.env
TEST_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TEST_CHAT_ID="$TEST_CHAT_ID" \
  TEST_FILTER=<測試名> ./test.sh
```
套件負載下偶發、單跑就過 ⇒ 記為 flaky 觀察項,先繼續;單跑也紅 ⇒ 往下。
(unit 測試加 `FAST=1` 即可;integration 測試不要加,FAST 模式不含它們。)

## 2. 已知環境性失敗(這台 Linux 機器)

中了清單就不用再驗屍 — 都做過 baseline/HEAD~1 對照證明與程式碼無關:

| 測試 | 症狀 | 驗證日 |
|------|------|--------|
| `Concurrent sends`(flock interleave) | 0/25 delivered | 2026-06-12 |
| `test_send_to_session_integration` | `/cd` 建不出 tmain,sent: False | 2026-06-12 |

修好或新增證明過的項目時,同步更新這張表和 CLAUDE.md 的對應 learning。

## 3. worktree 對照實驗(歸因的決定性證據)

「失敗是不是我的變更造成」不要用猜的 — 在上一個 commit 跑同一個測試:

```bash
git worktree add /tmp/wt-ctl HEAD~1
ln -sf "$(pwd)/.venv" /tmp/wt-ctl/.venv        # 共用 venv,不必重新 uv sync
cd /tmp/wt-ctl && source ~/.config/claudecode-telegram/test.env && \
  TEST_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TEST_CHAT_ID="$TEST_CHAT_ID" \
  TEST_FILTER=<測試名> ./test.sh
cd - && git worktree remove --force /tmp/wt-ctl
```

相同失敗 ⇒ 環境問題,安心繼續(並補進上面的清單);只有新 commit 紅 ⇒ 真的是
變更造成,回頭修。工作樹乾淨時也可用 `git stash` + 跑 + `git stash pop` 替代。

## 4. 插桩(不透明失敗的唯一解法)

test.sh 把 python 的 stderr 丟進 `2>/dev/null`,而且 `cleanup()` 在 EXIT 時會
刪掉 `$BRIDGE_LOG` — 失敗後現場什麼都不剩。不要瞪著「✗」猜:

```bash
# (a) 暫時把該測試的 stderr 接出來(查完務必 git checkout -- test.sh 還原)
#     2>/dev/null  →  2>/tmp/dbg.err | tee /tmp/dbg.out
# (b) bridge log 要在跑的「同時」側錄,等它結束就被 cleanup 刪了:
(TEST_BOT_TOKEN=... TEST_FILTER=<名> ./test.sh >/tmp/run.log 2>&1 &)
for i in $(seq 1 120); do
  cp ~/.claude/telegram/nodes/test/bridge.log /tmp/bridge-snap.log 2>/dev/null
  sleep 0.5
done
```

判讀提示:python 輸出缺了預期的 bootstrap/debug 行,往往比錯誤訊息更有資訊量
(例:`Registry bootstrapped` 沒出現 = session 根本不存在,問題在更上游)。

## 5. 寫測試/修測試時的地雷(每一條都炸過)

- **set -e**:裸 `((x++))` 在 x=0 時回傳 1 直接炸掉整個套件;函式最後一行是
  `cond && action` 同理。寫 `((x++)) || true`,分支收尾要明確。
- **全域計數器遮蔽**:`success()`/`fail()` 動的是全域 `passed`/`failed`/
  `tests_run`,測試裡 `local failed=0` 會把套件層的失敗數吃掉(bash 動態作用
  域)。換別的名字。
- **fake subprocess 讓 tmux_exists 說謊**:mock 的 `subprocess.run` 一律回
  rc=0 會讓 `create_session` 以為 session 已存在而提早 return。要一起
  monkeypatch `bridge.tmux_exists = lambda *a: False`。
- **monkeypatch 鐵律**:patch bridge 模組屬性(`bridge.X = ...`),絕不
  rebind import 進來的副本。
- **時窗測試要證明走到目標分支**:rc 睡 6s 對上 8s 確認窗的測試永遠到不了
  重送決策 — 綠得毫無意義。時序要逼出分支,並留一個能重現紅的旋鈕
  (例:`PANE_LAUNCH_CONFIRM_SECS=8`)當敏感度證明。
- **隔離鐵律**:tmux session 一律用 `${TMUX_PREFIX}`(預設 `claude-test-`)
  命名;只 kill 自己記下的 PID;絕不碰 dev node(:8270)與它的 poll forwarder。
