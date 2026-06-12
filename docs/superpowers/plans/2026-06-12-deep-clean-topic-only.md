# Deep Clean: 純 topic-only 架構 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 刪除所有 multi-worker 時代殘留(teleport/pipes/adapters/connectors/forge/boo/void/pilot/死測試/矛盾文件),抽離 viewer,加擴充縫,完成命名重構 — bridge.py 9,905 → ~4,600 行,對 topic-only 使用者零行為變更。

**Architecture:** 純刪除為主(殘渣已由 5 個對抗式驗證 agent 確認死透,見 spec)。鐵律:**刪產品碼與刪其測試必須同一個 commit**(FAST 套件含 legacy 測試)。新增碼僅三處:擴充縫 registry(~30 行)、viewer.py(搬移)、相容 re-export。行號是 commit `04659b6` 的近似值——**每步先用給定的 rg 指令重新定位,不要盲信行號**。

**Tech Stack:** Python 3.12(stdlib http.server)、bash test harness(test.sh)、uv + ruff。

**Spec:** `docs/superpowers/specs/2026-06-12-deep-clean-topic-only-design.md`(含驗證後事實表與護欄,動手前必讀)

**每個 Task 結束的固定關卡(下文簡稱「GATE」):**
```bash
uv run ruff check .
FAST=1 TEST_BOT_TOKEN='...' ./test.sh   # 必須全綠
```

---

### Task 0: 基線與分支

**Files:** 無程式變更

- [ ] **Step 1: 建分支、打基線 tag**
```bash
cd /home/audichuang/research/claudecode-telegram
git checkout main && git pull
git checkout -b refactor/deep-clean-topic-only
git tag pre-deep-clean-baseline
```
- [ ] **Step 2: 記錄 FAST 基線(含已知 FAIL)**
```bash
FAST=1 TEST_BOT_TOKEN='...' ./test.sh 2>&1 | tail -20
```
預期:`test_forge_register_endpoint` FAIL(`/register` 已 404,測試期待 200)——這是本計畫要清掉的「測試說謊」證據。把 pass/fail 數記進 commit message 備查。
- [ ] **Step 3: Commit(空 commit 記基線)**
```bash
git commit --allow-empty -m "chore: deep-clean baseline — FAST=<pass>/<total>, known-fail: test_forge_register_endpoint"
```

---

### Task 1: 磁碟級刪除(不碰 bridge.py)

**Files:**
- Delete: `forge/`、`boo/`、`void/`、`hooks/codex-tmux-adapter.py`、`hooks/gemini-adapter.py`、`hooks/opencode-adapter.py`
- Move → `docs/history/`: `FEATURES.md`、`LOOP1.md`、`SDD-host-awareness.md`、`copy-review-spec.md`、`hooks-codex-review.md`、`TEMPLATE-PLAYBOOK.md`
- Modify: `test.sh`(forge 測試)、`pyproject.toml`(ruff exclude)

- [ ] **Step 1: 確認無活引用(預期全部零命中)**
```bash
rg -l "codex-tmux-adapter|gemini-adapter|opencode-adapter" claudecode-telegram.sh bridge.py hooks/send-to-telegram.sh hooks/checkin-on-start.sh hooks/forward-to-bridge.py hooks/on-tool-failure.sh
rg -l "forge/|workerforge" bridge.py claudecode-telegram.sh
```
- [ ] **Step 2: 刪除與搬移**
```bash
git rm -r forge boo void
git rm hooks/codex-tmux-adapter.py hooks/gemini-adapter.py hooks/opencode-adapter.py
mkdir -p docs/history
git mv FEATURES.md LOOP1.md SDD-host-awareness.md copy-review-spec.md hooks-codex-review.md TEMPLATE-PLAYBOOK.md docs/history/
```
- [ ] **Step 3: 同 commit 刪 forge 測試(含現在就 FAIL 的那個)**
```bash
rg -n "test_forge|forge" test.sh
```
刪掉 `test_forge_register_endpoint` 函式本體與其 `run_test` 行(~test.sh:14242 附近定義、~14668 附近 run_test),以及其他 forge 引用行。
- [ ] **Step 4: 清 pyproject ruff exclude**
```bash
rg -n "forge" pyproject.toml
```
移除 `forge/proto/python` exclude 項。
- [ ] **Step 5: GATE,然後 commit**
```bash
git add -A && git commit -m "chore: delete dead trees (forge/boo/void) + orphan backend adapters; archive era docs to docs/history/"
```

---

### Task 2: 移除 /pilot

**Files:**
- Delete: `pilot/`
- Modify: `bridge.py`(`TOPIC_GLOBAL_CMDS` :762、dispatch :6432-6433、`cmd_pilot` :6453-6480)
- Modify: `test.sh`(pilot 相關測試)

- [ ] **Step 1: 定位**
```bash
rg -n "pilot|PILOT" bridge.py test.sh claudecode-telegram.sh DOC.md
```
- [ ] **Step 2: 刪 bridge.py 三處** — `TOPIC_GLOBAL_CMDS` 集合中的 `"/pilot"`、`elif cmd == "/pilot":` 分支、整個 `def cmd_pilot`。`PILOT_PORT` 若僅在 cmd_pilot 內讀取則一併消失。
- [ ] **Step 3: 同 commit 刪 pilot 測試**(Step 1 找到的 test.sh 命中:刪函式 + run_test 行)
- [ ] **Step 4: 刪目錄** `git rm -r pilot`
- [ ] **Step 5: GATE,commit**
```bash
git commit -am "refactor: remove /pilot command + pilot/ (hardcoded claude-prod- prefix, unused)"
```

---

### Task 3: 刪 teleport / remote(最大塊)

**Files:**
- Modify: `bridge.py`、`test.sh`(同 commit)

- [ ] **Step 1: 列出全部 remote 觸點(動手前先看全貌)**
```bash
rg -n "_remote_run|_remote_copy|get_worker_host|_project_slug|teleport|BRIDGE_SSH_TARGET|_remote_home|_remap_sessions_dir|_sync_chat_id_to_remote|_fetch_remote_file|host=" bridge.py | wc -l
```
- [ ] **Step 2: 刪除以下單元(由上而下,每刪一塊就 `python3 -c "import bridge"` 驗證可 import)**
  1. `BRIDGE_SSH_TARGET` 設定區(~:106-111)
  2. `_remote_run` / `_remote_copy` / `get_worker_host` / `_project_slug` + git-based teleport sync(~:238-331)
  3. `_remote_home` / `_remap_sessions_dir` / `_sync_chat_id_to_remote`(~:3167-3211)
  4. watchdog 的 `teleport_state` 抑制(~:3599-3603)與 remote 探測分支(~:3686 附近 `if host:`)
  5. `_fetch_remote_file` + `_localize_media` 的 remote 分支(~:5509-5549;保留本地路徑邏輯)
  6. 所有 `host = get_worker_host(...)` 呼叫點與其 `if host:` 分支(~95 處):呼叫點刪除後,函式簽名中的 `host=None` 參數一併移除;registry 的 `host` 欄位讀寫(~:871-872、:4748-4751、:7130)刪除
- [ ] **Step 3: A6 註解修正(行為不動)** — `BRIDGE_PUBLIC_URL` 區(~:85-107)的註解從「reachable URL for teleported workers」改為「public URL for viewer links (/pr-review, /rewind transcript, /team-chat)」;tailscale 自動偵測與 `0.0.0.0` auto-bind **保留**(viewer 連結靠它,spec A6 重新定性為現役)。
- [ ] **Step 4: 驗證歸零**
```bash
rg -n "teleport|_remote_run|_remote_copy|get_worker_host|BRIDGE_SSH_TARGET" bridge.py
```
預期:零命中(DOC.md changelog 的歷史敘述不算)。
- [ ] **Step 5: 同 commit 刪 remote/teleport 測試**
```bash
rg -n "test_remote_|teleport|_remote_run|BRIDGE_SSH_TARGET" test.sh
```
刪 `test_remote_dispatch_*`、`test_remote_run_local`、`test_tmux_send_message_remote`、teleport SSH foundation 區塊(~:14393)、remote dispatch run_test 行(~:14426)等——**全部函式本體 + run_test 行**。test.sh 對 `bridge._remote_run` 的 22 處 patch 隨測試刪除而消失。
- [ ] **Step 6: GATE,commit**
```bash
git commit -am "refactor!: delete teleport/remote machinery (get_worker_host always-None since v1.0.0) + its tests"
```

---

### Task 4: 刪 worker pipes + adapter scaffolding + Backend Protocol

**Files:**
- Modify: `bridge.py`、`test.sh`(同 commit)

- [ ] **Step 1: 定位**
```bash
rg -n "ensure_worker_pipe|cleanup_worker_pipe|pipe_reader|_forward_pipe_message|WORKER_PIPE_ROOT|_spawn_adapter|kill_adapter|is_interactive|class Backend|BACKENDS" bridge.py
```
- [ ] **Step 2: 刪除**
  1. 整段 INTER-WORKER PIPES(~:1609-1811,含模組層 `get_workers(caller_from)` :1799)
  2. adapter spawn/kill(~:618-704;`kill_adapter` 在 `end()` :5089 的呼叫點一併刪——對 claude 恆為 no-op)
  3. `Backend` Protocol(~:217-237):`ClaudeBackend` 改為普通 class,不再宣告 Protocol
  4. 所有 `if not backend_obj.is_interactive:` 分支(:5007-5012 寫 backend 檔、:5158-5160、:5241-5242、:9736-9737)——claude 恆互動,分支死透;`is_interactive` 屬性本身保留與否取決於刪完後是否還有讀者(`rg -n "is_interactive" bridge.py` 歸零則連屬性一起刪)
  5. backend 檔 fallback 註冊(~:4729-4738,A2 幽靈來源)
  6. `WORKER_PIPE_ROOT` 設定(~:163-172 內)
- [ ] **Step 3: 同 commit 刪測試**
```bash
rg -n "test_pipe|worker_pipe|_spawn_adapter|pipe_forwarding|in\.pipe" test.sh
```
刪 `test_pipe_forwarding_to_codex`(~:6690)、`_spawn_adapter` 測試(~:6952)、worker-to-worker pipe e2e(~:12208)等函式 + run_test 行。
- [ ] **Step 4: 驗證歸零** `rg -n "worker_pipe|_spawn_adapter|pipe_reader" bridge.py test.sh` → 零命中
- [ ] **Step 5: GATE,commit**
```bash
git commit -am "refactor!: delete worker pipes, adapter scaffolding, Backend protocol (claude is the only backend) + tests"
```

---

### Task 5: 刪 worker 時代表面(/workers 端點、死 welcome、死 helpers、死 TOPIC_MODE 分支)

**Files:**
- Modify: `bridge.py`、`test.sh`(同 commit)

- [ ] **Step 1(TDD/RED): 先寫行為測試 — `/workers` 必須 404**

在 test.sh 既有 HTTP 端點測試區(參照 `test_workers_endpoint` ~:11854 的寫法)新增:
```bash
test_workers_endpoint_removed() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$BRIDGE_PORT/workers")
    [[ "$code" == "404" ]] || { echo "expected 404, got $code"; return 1; }
}
```
接上 runner(`run_test test_workers_endpoint_removed`),確認 RED:
```bash
TEST_FILTER=test_workers_endpoint_removed FAST=1 TEST_BOT_TOKEN='...' ./test.sh   # 預期 FAIL(現在回 200)
```
- [ ] **Step 2(GREEN): 刪除**
  1. `do_GET` 的 `/workers` 分支(:8838-8839)+ `handle_workers_endpoint`(:8892-8913)+ `API_ENDPOINTS` 的 `"GET /workers"` 條目(:126)。**保留** `/health/workers`(:8846)與 `/checkin`。
  2. `WorkerManager.get_workers` 的 `caller_from` 參數與 `_wrap_for_caller`(:4798-4905 內):`get_workers` 若仍被 `/health/workers` 或 watchdog 使用則只瘦身,否則整個刪——以 `rg -n "get_workers\(" bridge.py` 的剩餘呼叫者為準。
  3. `_build_welcome` 的非 topic else 分支(~:4922-4930)與其中 `"VPS (100.125.36.102)"` 字樣(~:4950 附近一併清)。
  4. 死 helpers(Task 3/4 刪完後再次確認零 caller 才刪):`parse_worker_prefix`(:6386)、`get_reply_context`(:6400)、`format_reply_context`(:6406)、`_extract_reply_media`(:6779)、`_worker_from_reply`(:6832)、`format_team_lines`(:4057)、`format_progress_lines`(:4579)。**保留 `parse_at_mentions`(:6369)— PR comment 路由在用。**
  5. 三處 `if not TOPIC_MODE:` 死分支(:5049、:5769、:5854)收斂為直走 topic 路徑。**`TOPIC_MODE = True` 常數本身保留**(test.sh 33 處引用)。
- [ ] **Step 3: 同 commit 處理對應測試**
```bash
rg -n "test_hire_command|test_mention_routing|test_last_active|test_workers_endpoint|format_team_lines|format_progress_lines|parse_worker_prefix|_worker_from_reply|/team|/progress" test.sh
```
判準:測試呼叫的函式在本 task 被刪 → 測試同刪(含 run_test 行);測試實際覆蓋仍存活的行為(如 `test_mention_routing` 若測的是 `parse_at_mentions`)→ 保留。`test_hire_command` 測的是 session 建立(活行為)→ **保留**,Task 10 重命名時一併改名。舊 `test_workers_endpoint`(期待 200)→ 刪,由 Step 1 的 404 測試取代。`/team`/`/progress` backend 輸出測試(~:5827、:5852)→ 刪。
- [ ] **Step 4: 順手刪 DIRECT_MODE 孤兒**(未接 runner,~test.sh:12347-12650):`rg -n "DIRECT_MODE|direct_mode" test.sh` 全刪。
- [ ] **Step 5: GATE(含新 404 測試 GREEN),commit**
```bash
git commit -am "refactor!: remove /workers endpoint + worker-era dead surface; /workers now 404 (e2e tested)"
```

---

### Task 6: 刪 Gmail/GitHub connectors

**Files:**
- Delete: `gmail_connector.py`、`github_connector.py`、`base_connector.py`、`test_gmail_connector.py`、`test_github_connector.py`
- Modify: `bridge.py`、`test.sh`(同 commit)

- [ ] **Step 1: 定位 bridge.py 接點**
```bash
rg -n "gmail|github|GMAIL|GHPOLL|GITHUB_" bridge.py
```
- [ ] **Step 2: 刪除** — import 區(:30、:37)、全域 instance(:64-65)、設定區(:174-188,含上游硬編碼 `ngocthinhdp@gmail.com`/`BasedHardware/omi`/`beastoin`)、shutdown 清理(:9689-9696)、main() 接線(~:9807-9899 的 connector 區塊)。`API_ENDPOINTS` 若有相關條目一併刪。
- [ ] **Step 3: 刪五個檔案** `git rm gmail_connector.py github_connector.py base_connector.py test_gmail_connector.py test_github_connector.py`
- [ ] **Step 4: 同 commit 刪 test.sh 內 connector 相關測試**(`rg -n "gmail|github_connector|GHPOLL" test.sh`)
- [ ] **Step 5: 驗證 + GATE,commit**
```bash
rg -in "gmail|ghpoll" bridge.py test.sh   # 預期零命中
git commit -am "refactor!: delete gmail/github connectors (@worker addressing died with the worker era; resurrect from git if needed)"
```

---

### Task 7: 刪 pr-review.py 死掉的一半

**Files:**
- Modify: `pr-review.py`(內建 HTTP server + `_route_mentions_to_workers`,~:1815-1987)

- [ ] **Step 1: 確認死碼邊界** — `rg -n "_route_mentions_to_workers|HTTPServer|serve|do_POST" pr-review.py`。bridge.py 的 `/pr-comment`(:8680)才是實際服務者;pr-review.py 的 server 從未啟動。
- [ ] **Step 2: 刪除該區塊**,確認 `python3 -c "import importlib.util,sys; spec=importlib.util.spec_from_file_location('prr','pr-review.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)"` 不需執行——pr-review.py 是腳本,改用 `uv run python pr-review.py --help` 或既有測試驗證。
- [ ] **Step 3: 跑 `/pr` 相關測試** `TEST_FILTER=pr FAST=1 TEST_BOT_TOKEN='...' ./test.sh`
- [ ] **Step 4: GATE,commit** `git commit -am "refactor: drop pr-review.py never-started internal server (bridge serves /pr-comment)"`

---

### Task 8: 擴充縫 EXTRA_COMMANDS / EXTRA_GET_ROUTES / EXTRA_POST_ROUTES

**Files:**
- Modify: `bridge.py`(registry + 三個 dispatch 點)、`test.sh`(新 e2e 測試)

- [ ] **Step 1(RED): 先寫測試**(仿照 test.sh 既有 `python3 - <<'EOF'` 單元測試寫法;以鄰近測試的 harness 為準調整建構方式):
```bash
test_extension_seam_command() {
    python3 - <<'EOF'
import bridge
calls = []
bridge.EXTRA_COMMANDS["/dummyext"] = lambda router, arg, chat_id: (calls.append((arg, chat_id)), True)[1]
router = bridge.command_router
handled = router.handle_command("/dummyext", "hello", 12345)
assert calls == [("hello", 12345)], f"seam not dispatched: {calls}"
EOF
}
```
確認 RED(`EXTRA_COMMANDS` 不存在 → AttributeError)。
- [ ] **Step 2(GREEN): 實作 registry**(放在 RAM state 區,~:705 附近):
```python
# --- Extension seams (v1.1.0) ---------------------------------------
# Satellites register here instead of editing the router/Handler.
# EXTRA_COMMANDS:    "/cmd" -> fn(router, arg, chat_id) -> True if handled
# EXTRA_GET_ROUTES:  "/path-prefix" -> fn(handler, parsed) (sends its own response)
# EXTRA_POST_ROUTES: "/path-prefix" -> fn(handler, parsed, body)
EXTRA_COMMANDS = {}
EXTRA_GET_ROUTES = {}
EXTRA_POST_ROUTES = {}
```
dispatch 插點:`handle_command` 在未知指令 fallthrough **之前** 加:
```python
        if cmd in EXTRA_COMMANDS:
            if EXTRA_COMMANDS[cmd](self, arg, chat_id):
                return True
```
`do_GET` 在 404 之前、`do_POST` 在白名單檢查之後 404 之前,各加 prefix 比對迴圈(同型)。
- [ ] **Step 3: GREEN 驗證 + 全 FAST**
- [ ] **Step 4: Commit** `git commit -am "feat: extension seam — EXTRA_COMMANDS/EXTRA_GET_ROUTES/EXTRA_POST_ROUTES registries (e2e tested)"`

---

### Task 9: 抽離 viewer.py(transcript / team-chat 渲染,~1,900 行)

**Files:**
- Create: `viewer.py`
- Modify: `bridge.py`、`test.sh`(~15 處 `bridge._render_*` 引用維持可用)

**Monkeypatch 護欄(spec 風險 #2):** viewer 函式讀設定一律延遲 `import bridge` 後取 `bridge.SESSIONS_DIR` 等;bridge 端 `from viewer import ...` 把名字綁回 bridge namespace,Handler 照舊呼叫 bridge 全域名 → test.sh 的 `bridge.X` patch 全部繼續生效。

- [ ] **Step 1: 圈出搬移範圍** — 從 TRANSCRIPT VIEWER banner(~:6925)到 HTTP Handler class 之前(~:8626)的**模組層**函式(兩個 `_render_*_html` 巨函式 + md/csv 渲染、transcript 解析、avatar、stats helpers)。Handler 的 GET 方法(~:9437-9666)**留在 bridge.py**,只呼叫函式。
```bash
rg -n "^def |^class " bridge.py | awk -F: '$1>6900 && $1<8630'
```
- [ ] **Step 2: 建 viewer.py** — 檔頭:
```python
"""Transcript / team-chat HTML viewer — extracted from bridge.py (v1.1.0).

Reads bridge config lazily (`import bridge` inside functions) so test.sh
monkeypatches on the bridge module keep working.
"""
```
搬函式時把對 bridge 全域(`SESSIONS_DIR`、`TMUX_PREFIX`、`REWIND_TOKENS`、`_resolve_transcript_path` 等)的引用改為函式內 `import bridge; bridge.X`。
- [ ] **Step 3: bridge.py 端** — 刪原函式,於檔案靠後(Handler class 定義前)加:
```python
from viewer import (
    _render_transcript_html,
    _render_team_chat_html,
    # …Step 1 圈出的全部公用入口,逐一列名
)
```
- [ ] **Step 4: 驗證 patch 相容** — `rg -n "bridge\._render|bridge\.viewer" test.sh` 列出的引用逐一跑過:
```bash
TEST_FILTER=transcript FAST=1 TEST_BOT_TOKEN='...' ./test.sh
TEST_FILTER=team_chat FAST=1 TEST_BOT_TOKEN='...' ./test.sh
```
- [ ] **Step 5: GATE + 行數確認**(`wc -l bridge.py viewer.py` 預期 ~4,600 / ~1,900),commit
```bash
git add viewer.py bridge.py test.sh && git commit -m "refactor: extract transcript/team-chat viewer to viewer.py (lazy bridge-config reads keep test monkeypatches working)"
```

---

### Task 10: 命名重構(機械式,一個 commit)

**Files:**
- Modify: `bridge.py`、`viewer.py`、`test.sh`(同 commit;test.sh 有 60 處 `bridge.worker_manager`)

**對照表(僅此清單,不擴大):**

| 舊 | 新 |
|----|----|
| `class WorkerManager` | `class SessionManager` |
| `worker_manager`(全域) | `session_manager` |
| `WorkerManager.hire` / `.hire(` | `SessionManager.open_session` / `.open_session(` |
| `WorkerManager.end` / `worker_manager.end(` | `.close_session(` |
| `send_to_worker` | `send_to_session` |
| `_worker_states` | `_session_states` |
| `test_hire_command` | `test_open_session_creates_tmux` |

**不改:** watchdog state 字串、tmux naming(`TMUX_PREFIX`/`t<id>-<slug>`)、hook env 變數、HTTP 路徑、per-session 檔名。

- [ ] **Step 1: 逐項 sed(每項後立刻 `python3 -c "import bridge"`)**
```bash
sed -i 's/\bWorkerManager\b/SessionManager/g' bridge.py test.sh
sed -i 's/\bworker_manager\b/session_manager/g' bridge.py viewer.py test.sh
sed -i 's/\bsend_to_worker\b/send_to_session/g' bridge.py test.sh
sed -i 's/\b_worker_states\b/_session_states/g' bridge.py test.sh
sed -i 's/def hire(/def open_session(/; s/\.hire(/\.open_session(/g' bridge.py test.sh
sed -i 's/session_manager\.end(/session_manager.close_session(/g; s/def end(/def close_session(/' bridge.py
rg -n "\.end\(" test.sh   # 人工確認每一處是 close_session 語意才改(避免誤傷字串方法)
sed -i 's/\btest_hire_command\b/test_open_session_creates_tmux/g' test.sh
```
- [ ] **Step 2: 殘留掃描** `rg -n "\bhire\b|worker_manager|WorkerManager|send_to_worker" bridge.py viewer.py test.sh` → 僅允許註解/changelog 歷史敘述。
- [ ] **Step 3: GATE(FAST 全綠是唯一可信驗證),commit**
```bash
git commit -am "refactor: rename worker-era identifiers to session vocabulary (WorkerManager→SessionManager, hire→open_session)"
```

---

### Task 11: 文件重寫 + 版本 1.1.0

**Files:**
- Modify: `DOC.md`、`TEST.md`、`README.md`、`CLAUDE.md`(key-files 表)、`bridge.py`、`claudecode-telegram.sh`、`pyproject.toml`

- [ ] **Step 1: DOC.md** — 刪/改寫把 multi-worker 寫成現行的段落(`/hire` :49、`state.active` :58、路由表 :92、`/team` :127、`CodexBackend...` :178、inter-worker "Available" :185、v0.33 「remote/pipes kept」:428);現行哲學區只描述 topic-only;新增 v1.1.0 changelog(列本計畫全部刪除項與 viewer.py 抽離)。歷史 changelog 條目**保留不改**(它們是歷史)。
- [ ] **Step 2: TEST.md** — 指令清單(:33-35)、backend 矩陣(:101)、`/hire` 解析(:145)、`/workers includes codex`(:164)、inventory(:309)全部對齊現存測試;補 `viewer.py`/擴充縫測試說明。
- [ ] **Step 3: README.md** — 開頭(:3、:9)從「multiple AI workers」改為 topic-only 描述,與 :650-676 既有 topic 段一致。
- [ ] **Step 4: CLAUDE.md** — key-files 表加 `viewer.py`;移除已刪檔案的引用(connectors 等)。
- [ ] **Step 5: 版本三連改 + 驗證**
```bash
sed -i 's/^VERSION="1\.0\.[0-9]*"/VERSION="1.1.0"/' claudecode-telegram.sh
sed -i 's/^version = "1\.0\.[0-9]*"/version = "1.1.0"/' pyproject.toml
sed -i 's/^VERSION = "1\.0\.[0-9]*"/VERSION = "1.1.0"/' bridge.py
.claude/skills/bridge-ops/scripts/check-versions.sh   # 必須 exit 0
```
- [ ] **Step 6: `API_ENDPOINTS` 最終對齊**(:122-135)— 逐條 curl 驗證存在性;已刪端點不得殘留。
- [ ] **Step 7: GATE,commit**
```bash
git commit -am "docs: v1.1.0 — re-baseline DOC/TEST/README to topic-only reality; version sync"
```

---

### Task 12: 最終關卡與收尾

- [ ] **Step 1: 預 commit 級全驗證**
```bash
TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh          # default 模式全綠
```
- [ ] **Step 2: 預 push 級**
```bash
FULL=1 TEST_BOT_TOKEN='...' TEST_CHAT_ID='...' ./test.sh   # 含 tunnel 測試全綠
```
- [ ] **Step 3: 殘渣總掃描(spec 驗收條款)**
```bash
rg -in "teleport|_remote_run|worker_pipe|_spawn_adapter|opencode|gmail_connector|forge|/pilot" bridge.py viewer.py test.sh claudecode-telegram.sh hooks/
```
預期:零命中(docs/history/ 與 changelog 歷史敘述除外)。
- [ ] **Step 4: 行數結算**(寫進 PR 描述)
```bash
wc -l bridge.py viewer.py test.sh
git diff --stat pre-deep-clean-baseline..HEAD | tail -3
```
- [ ] **Step 5: dev 節點實機驗證(CLAUDE.md 規矩:先 dev 後 prod)**
```bash
.claude/skills/bridge-ops/scripts/restart-node.sh dev
.claude/skills/bridge-ops/scripts/verify-node.sh dev
```
手動走一輪:建話題 → 選資料夾 → 訊息往返 → 關話題。
- [ ] **Step 6: 推分支開 PR**(merge 與 prod 部署由 owner 決定)
