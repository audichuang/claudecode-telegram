# Spec: Deep Clean — 徹底移除 multi-worker 時代殘留,收斂為純 topic-only 架構

- **Date:** 2026-06-12
- **Status:** Approved (design) — implementation plan: `docs/superpowers/plans/2026-06-12-deep-clean-topic-only.md`
- **Branch suggestion:** `refactor/deep-clean-topic-only`
- **Version:** v1.1.0(架構清理,刪除的都是已死/已棄用表面;對 topic-only 使用者零行為變更)

## Context

v1.0.0 把產品收斂成「一個 Telegram 話題 = 一個 Claude session」,但三輪稽核
(Codex、Antigravity、加上本次 5 個對抗式驗證 agent)確認大量舊 multi-worker
時代殘留仍在。bridge.py 9,905 行中約 **1,300–1,500 行是純殘渣**,test.sh 有
**~34 個 legacy 測試仍接在 runner 上**(其中 `test_forge_register_endpoint`
現在就是 FAIL——`/register` 已 404),文件(DOC.md/TEST.md/README.md)自相矛盾。

### 對抗式驗證後的最終事實(修正前兩輪稽核的誤判)

| ID | 事實 | 處置 |
|----|------|------|
| A1 | `GET /workers`(bridge.py:8838)活著、無認證、**無任何呼叫者**(hooks 不用) | 刪除 |
| A2 | backend 檔幽靈 session:**被推翻**——topic-only 永不寫 backend 檔(只有非互動後端寫,claude 是互動);僅舊磁碟殘檔有風險 | 隨 adapter 死碼一併刪 fallback(:4729-4738) |
| A5 | `teleport_state` watchdog 抑制(:3599-3603):程式活著但**全 repo 無人再寫**該檔 | 隨 teleport 死碼刪除 |
| A6 | `BRIDGE_PUBLIC_URL` tailscale 自動偵測 + `0.0.0.0` auto-bind:**重新定性為現役**——pr-review/rewind/team-chat 連結靠它;僅註解過時 | 保留行為,改註解 |
| A3 | PR comment @mention 路由:**現役刻意功能**(`/pr` 流程的一部分) | 保留;`parse_at_mentions` 保留 |
| A4 | Gmail/GitHub connectors:程式活著但定址模型已死(topic 名 `t<id>-<slug>`,email 提 `@alice` 靜默失敗),預設關閉,含上游作者硬編碼 | **刪除**(owner 決策;要用時從 git 復活) |
| B0-B7 | TOPIC_MODE 寫死 True、welcome else 分支、pipes、adapter scaffolding、`parse_worker_prefix`/reply helpers、`format_team_lines`/`format_progress_lines`、teleport 分支(`get_worker_host` 恆 None)、legacy 指令 tombstone——**全部確認死透**;唯一例外 `kill_adapter` 在 `end()`(:5089)有 caller 但對 claude 是 no-op | 全刪 |
| D | test.sh ~34 legacy 測試 + ~13 個未接 runner 的 DIRECT_MODE 孤兒 + ~25 remote/teleport 測試 | 與對應產品碼**同 commit** 刪 |
| E | DOC.md 把 `/hire`/`/focus`/CodexBackend 寫成現行哲學(:49-185)同檔 changelog(:343)又說已刪;TEST.md/README 同病 | 重寫 |
| — | `pr-review.py` 內建 HTTP server + `_route_mentions_to_workers`(:1815-1987)從未啟動(實際由 bridge.py 服務) | 刪該死半 |
| — | 上游 fork 硬編碼:`GMAIL_FROM_FILTER` 預設 gmail(:177)、`GITHUB_REPO="BasedHardware/omi"`(:184)、`"VPS (100.125.36.102)"`(:4950) | 隨 connectors/welcome 清除 |

## Owner 決策(2026-06-12 確認)

1. **connectors 刪除**:`gmail_connector.py`、`github_connector.py`、`base_connector.py`、
   `test_gmail_connector.py`、`test_github_connector.py`、bridge.py 接點全刪。
2. **輔助樹全刪**:`forge/`(gRPC 死透)、`boo/`(upstream 獨立 Go 專案)、
   `void/`(vm-setup 腳本)、`pilot/` + `/pilot` 指令(含 `claude-prod-` 硬編碼)。
3. **結構改善三項都做**:viewer 抽離成 `viewer.py`、`EXTRA_ROUTES`/`EXTRA_COMMANDS`
   擴充縫、命名重構(`WorkerManager→SessionManager` 等)。
4. **執行方式**:正式 plan + 逐階段 TDD,每階段 FAST 綠才 commit。

## Goals

- bridge.py 收斂到 ~4,600 行(核心)+ viewer.py ~1,900 行;test.sh 14,825 → ~11,500。
- 程式碼、測試、文件三者描述同一個產品:topic-only。
- 「加一個衛星功能」= 新增一段 + 註冊,不再改 router/Handler。
- 測試套件誠實:沒有測已刪功能的測試,沒有「通過理由是錯的」測試,沒有已知 FAIL。

## Non-goals / Deferred

- **不動 hook 合約**:POST `/response` body、GET `/checkin?name=`、
  `$SESSIONS_DIR/<name>/{chat_id,pending}` 佈局、`export_hook_env` 變數——
  已部署在使用者機器的 hooks 依賴它們。
- **不拆包**:單檔是承重牆(test.sh 254 處 `import bridge` + ~400 處 module-global
  monkeypatch;ops 工具 `pgrep bridge.py`、版本 grep)。唯一破例是 viewer.py。
- **persistent registry(:813-921)簡化**:與「tmux IS persistence」信條矛盾,
  但牽動 29 個測試點,遞延到獨立 spec。
- **不動安全/認證**(信任的單人部署)。
- `/health/workers`、`/checkin` 保留(ops + SessionStart hook 在用)。

## 風險與護欄(必守)

1. **刪碼與刪測試必須同 commit**——FAST 套件含 legacy 測試,分開刪必紅。
2. **test.sh module-global monkeypatch**:任何把名字移出 `bridge` namespace 的動作
   會讓 `bridge.X` patch 靜默失效。viewer.py 解法:viewer 函式內 `import bridge`
   讀 `bridge.SESSIONS_DIR` 等全域(延遲讀取,patch 仍生效)。
3. **TOPIC_MODE 常數保留**(test.sh 33 處引用);只刪 `if not TOPIC_MODE` 死分支。
4. **重命名放最後**(刪碼後爆炸半徑最小),bridge.py + test.sh 同 commit 機械式改。
5. tmux naming(`TMUX_PREFIX`、`t<thread>-<slug>`)、watchdog state 字串、
   webhook POST `/` 語意:**一律不改**。

## 驗收

- `FAST=1 TEST_BOT_TOKEN='...' ./test.sh` 全綠(每階段)。
- 預 commit:default 模式全綠;預 push:`FULL=1` 全綠。
- `rg -i "teleport|_remote_run|worker_pipe|_spawn_adapter|opencode|gmail_connector" bridge.py` 零命中(白名單除外)。
- `GET /workers` 回 404。
- DOC.md/TEST.md/README.md 無任何把 multi-worker 寫成現行的段落。
- 三檔版本號一致 = 1.1.0(`check-versions.sh` 通過)。
