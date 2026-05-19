# qqq 마이그레이션 plan v2.3

**Date**: 2026-05-14
**Status**: v2.3.1 — Codex CONDITIONAL-GO + 보완 4건 반영 (F1=b 정합성, race 방지, PR 산출물 형식, 라인 수 현실화)
**Scope**: agent view + worktree primitive 채택, 워크플로우 보존, 인프라 코드 ~75~78% 감소

---

## 1. 목적과 범위

### 목적
Claude Code v2.1.139+의 표준 인프라(`claude --bg`, `--worktree`, `claude attach/logs/stop/rm/respawn`, agent view)에 위임함으로써 qqq 고유 인프라 코드의 유지관리 의존도를 최소화한다.

### "유지관리 의존도 최소화"의 범위 (명시)
- 대상: **세션/워크트리/락/머지 인프라 코드**
- 제외: 워크플로우의 *프롬프트 복잡도와 운영 비용*은 별도 차원으로 본다 (W1~W6은 보존)

### 보존
3-phase 워크플로우 (clarify → plan → implement), 산출물 영구 기록, 3중 reviewer 패턴, NLTP/UI Optional 흐름, Phase 0 이슈 주입, Codex 통합.

---

## 2. 결정사항 종합

### 2.1 워크플로우 (W1~W6)

| | 결정 |
|---|---|
| W1 | 3개 페이즈 명시적 분리, 산출물 필수 |
| W2 | 산출물은 PR에 들어가 영구 기록 (`claude-works-completed/`) |
| W3 | 3중 plan reviewer 유지 (explorer/architect/critic) |
| W4 | NLTP/UI는 Optional |
| W5 | `--append-system-prompt-file phase0-issue.md` (Phase 0 이슈 주입) |
| W6 | 1 이슈 = 1 워크트리 = 페이즈 순차 |

### 2.2 마이그레이션 원칙 (D1, D2, D3, D4)

| | 결정 |
|---|---|
| D1− | 페이즈 게이팅: **검증 없음**이 기본. Phase 2→3에서만 `review_loop_completed === true` 자기 검증 (skill inline) |
| D2 | `.qqq.lock`, `.qqq/session.json` 완전 폐기 |
| D3 | 머지 = `/qqq:merge-mr` 슬래시 스킬 (검증 없는 wrapper) |
| D4 | CLI 명령 + fzf 기반 TUI (TUI가 메인 진입점) |

### 2.3 세부 결정 (Q1~Q4, F1~F2)

| | 결정 |
|---|---|
| Q1 | 작업 단위 세션 (1 워크트리에 페이즈 순차) |
| Q2 | `claude-works-completed/`만 frozen 보호 |
| Q3 | SessionStart 시 uncommit 산출물 경고만 |
| Q4 | fzf 필수 |
| F1 | 페이즈 전환 = 새 백그라운드 세션 dispatch + 산출물 파일 read (history 재로드 없음, 토큰 절약) |
| F2 | JSONL 로그 완전 폐기 (분석 흐름 없음 가정) |

### 2.4 CLI 결정

| | 결정 |
|---|---|
| CLI-1 | `qqq new <slug>` (이슈 없음) / `qqq new <slug> --issue N` (명시적 분기) |
| CLI-2 | 페이즈별 명령 (`qqq clarify` / `tech-spec` / `plan` / `implement`) |
| CLI-3 | UI/NLTP 별도 명령 (`qqq ui` / `qqq nltp`) |
| CLI-5 | `qqq attach <id>` + `qqq pick` 둘 다 |
| CLI-7 | `/qqq:merge-mr` 슬래시 스킬만 (CLI 없음) |
| CLI-8 | Aux 스킬은 슬래시 스킬로만 (CLI 없음) |
| CLI-9 | F1=(b)에 따라 새 세션 dispatch. fail-closed 4케이스 (2.6 참조) |
| CLI-10 | cwd 기준 자동 추론 + ID override |
| CLI-11 | TUI: 이슈 선택 → 자동 slug 제안 → 사용자 수정 |
| CLI-12 | TUI: 액션 수행 후 종료 (셸 복귀) |

### 2.5 가드 메커니즘 7항목

| # | 메커니즘 | 현재 | 새 구조 |
|---|---|---|---|
| A | 산출물 존재 검증 | `qqq-stop-guard.sh` + skill | **검증 없음** (D1−) |
| B | Phase 2→3 review fingerprint | `phase-detect.sh:32-65` + `workflow.sh:170` | **`review_loop_completed === true`만** (skill inline) |
| C | frozen 산출물 보호 | `qqq-protect-files.sh` PreToolUse | **유지 (범위 축소: `claude-works-completed/`만)** |
| D | `.qqq.lock` ownership | `.qqq.lock` | **완전 폐기** |
| E | launcher-owned 파일 | `qqq-protect-files.sh:128-227` | **대부분 폐기** (Q2=가) |
| F | reviewer 강제 호출 | agent 본문 | **유지** (agent 본문 그대로) |
| G | 페이즈 진입 시점 게이팅 | `workflow.sh` case 분기 | **폐기 + B에 흡수** |

### 2.6 CLI-9 fail-closed 5케이스 (F1=b 일관, race 방지 포함)

| 케이스 | 동작 |
|---|---|
| 한 워크트리에 2+ 세션 (예: `--fork-session` 사용) | 자동 선택 거부 → `qqq pick` 또는 명시 ID 요구 |
| cwd가 메인 체크아웃 (워크트리 아님) | 페이즈 명령(`plan`/`implement` 등) 실패 처리. `new`/`pick`/`attach`만 허용 |
| 세션이 stopped 상태 | **새 백그라운드 세션 dispatch** (F1=b 일관, `--resume --print` 사용 안 함). 기존 stopped 세션은 그대로 남음 (사용자가 별도 `claude rm`/`respawn`) |
| 세션이 exited/removed 상태 | fail closed — 명령 거부 |
| **동일 워크트리에 *running 중* 세션이 이미 존재 (race 방지)** | **새 dispatch 거부**. 사용자에게 명시적 `qqq stop <id>` 또는 `qqq attach <id>` 요구. 락 없이 *agent view state로 추론* (D2 정합) |

---

## 3. 새 구조

### 3.1 유지 (7개)

| 자산 | 라인 | 변경 |
|---|---|---|
| `agents/*.md` (13개) | — | `isolation: worktree` frontmatter 제거 |
| `skills/*/SKILL.md` (14개) | — | Phase 2→3 게이트 inline 추가 (`/qqq:code-implement`만) |
| `hooks/qqq-protect-files.sh` | 332 → ~80 | 범위 축소: `claude-works-completed/`만 frozen |
| `hooks/qqq-context.sh` | 66 → ~30 | 슬림화: 페이즈 추론 + uncommit 경고 |
| `scripts/qqq` (**신규**) | ~500 | TUI + CLI primitive 4개 |
| `.worktreeinclude` (**신규**) | — | gitignored 설정 파일 복사용 |
| `.gitignore` | — | `.claude/worktrees/` 추가 |

### 3.2 폐기 (~6,307줄)

| 파일 | 라인 | 사유 |
|---|---|---|
| `scripts/qqq-workflow.sh` | 263 | fzf+tmux 런처 → `scripts/qqq` 대체 |
| `scripts/lib/worktree-helpers.sh` | 1,062 | `--worktree` primitive 위임 |
| `scripts/lib/session-mgmt.sh` | 732 | `~/.claude/jobs/`로 위임 |
| `scripts/lib/merge-protocol.sh` | 696 | `/qqq:merge-mr` 슬래시 스킬 |
| `scripts/lib/worktree-actions.sh` | 479 | 동일 |
| `scripts/lib/mr-create.sh` | 313 | 슬래시 스킬 |
| `scripts/lib/tmux-launch.sh` | 291 | `claude --tmux` 위임 |
| `scripts/lib/action-handlers.sh` | 243 | TUI 신규 작성 |
| `scripts/lib/action-menu.sh` | 173 | TUI 신규 작성 |
| `scripts/lib/merge-archive.sh` | 147 | 슬래시 스킬 |
| `scripts/lib/bootstrap.sh` | 116 | 불필요 |
| `scripts/test-qqq-workflow-*.sh` | ~1,500 | `qqq verify`로 대체 |
| `hooks/qqq-stop-guard.sh` | 116 | D1− 채택으로 불필요 |
| `hooks/qqq-log-event.sh` | 102 | F2: 분석 흐름 없음 |
| `hooks/qqq-notify.sh` | 74 | agent view 시각화 대체 |
| **합계** | **~6,307** | |

### 3.3 재사용 (3개)

| 파일 | 라인 | 새 책임 |
|---|---|---|
| `scripts/lib/phase-detect.sh` | 313 → ~200 | 페이즈 추론만 (review fingerprint 부분 제거) |
| `scripts/lib/glab-cache.sh` | 89 | GitLab 이슈 fetch 캐시 |
| `scripts/lib/phase0-issue.sh` | 340 | `qqq new --issue N`이 호출 |

### 3.4 라인 수 추정 (현실화: Codex Q3 반영)

| | 라인 (낙관) | 라인 (현실) |
|---|---|---|
| 폐기 | ~6,307 | ~6,307 |
| 재사용 | ~640 (phase-detect 200 + glab-cache 89 + phase0-issue 340) | ~430 (`phase-detect` 일부는 `scripts/qqq` 안에 재작성 가능 — 단계 #7에서 결정) |
| 유지 (축소 후) | ~110 (protect-files 80 + context 30) | ~110 |
| 신규 | ~500 (scripts/qqq) | **~750** (TUI + 4 primitive + fzf + glab + 버전 게이트 + race 검사 모두 포함) |
| **잔존 합계** | ~1,250 | **~1,290~1,500** |
| **순 감소** | ~79% | **~75~78%** (여전히 극적) |

→ 낙관/현실 두 추정 모두 *유지관리 의존도 최소화* 목표를 만족. 실제 구현 시 §7 단계 #7에서 `phase-detect.sh` 재사용 vs `scripts/qqq` 내 재작성을 결정.

---

## 4. 워크플로우 흐름

```
[Phase 0 — Optional]
  qqq new <slug> --issue 123
    1. glab-cache.sh로 이슈 fetch
    2. phase0-issue.sh로 phase0-issue.md 생성 (워크트리 안)
    3. claude --bg --worktree <slug>
              --name "<slug>:phase1"
              --append-system-prompt-file phase0-issue.md
              "/qqq:clarify-requirement"

[Phase 1 — Clarify]
  사용자가 attach → req-clarifier와 Q&A → phase1-spec.md
  qqq ui    → 새 세션, /qqq:ui-outline (Optional)
  qqq nltp  → 새 세션, /qqq:interview-nltp (Optional, reviewer 게이트)
  qqq tech-spec → 새 세션, /qqq:interview-tech → phase1-tech-spec.md

[Phase 2 — Plan]
  qqq plan → 새 세션, /qqq:code-plan → phase2-code-plan.md
  내부적으로 code-planner가 explorer/architect/critic dispatch
  → phase2-review-state.json에 review_loop_completed: true

[Phase 3 — Implement]
  qqq implement → 새 세션, /qqq:code-implement
  Step 0: phase2-review-state.json의 review_loop_completed 자기 검증
  → 통과 시 phase3-implement-log.md + 코드 변경 + PR 생성

[Merge]
  agent view PR dot 녹색 확인 → /qqq:merge-mr (또는 TUI에서)
```

**F1=(b) 핵심 함의**: 각 페이즈 명령은 *기존 세션 resume이 아니라* **새 백그라운드 세션 dispatch**. 산출물 파일(`phase{N-1}-*.md`)이 워크트리에 누적되어 다음 페이즈 세션이 read.

**Phase 2→3 게이트의 skill inline (D1−)**:
```markdown
<!-- skills/code-implement/SKILL.md 0단계로 추가 -->
## Step 0 — Prerequisite check (mandatory)

Before reading the plan:
1. Verify `phase2-review-state.json` exists and parse it.
2. Check `review_loop_completed` is `true`.
3. If either fails, output exactly:
   "prerequisite invalid: phase2 review loop not completed"
   and stop.
```

### 4.1 산출물 commit 컨벤션 (Codex Q7-a 보완)

각 페이즈 종료 시점에 *사용자가 명시적으로* 산출물을 commit. **강제 안 함** — D1− "강제력 최소" 원칙 일관.

| 항목 | 규칙 |
|---|---|
| **시점** | 페이즈 종료 후, 다음 페이즈 dispatch *전* (사용자 책임) |
| **명령** | `git add phase{N}-*.md && git commit -m "phase{N}: <slug>"` (워크트리 안에서) |
| **권장 메시지 형식** | `phase1: <slug>`, `phase2: <slug>`, `phase3: <slug>` |
| **안전망** | `hooks/qqq-context.sh`가 SessionStart 시 uncommit `phase{N}-*.md` 발견하면 한 줄 경고 (Q3 결정) |
| **PR 머지 시** | 워크트리의 모든 `phase{N}-*.md`가 main 브랜치에 영구 기록. PR description에 자동 포함은 안 됨 (사용자가 필요시 첨부) |
| **워크트리 삭제 (`Ctrl+X` 두 번 또는 `claude rm`) 위험** | uncommit 산출물 영구 손실. README 경고 명시 |

---

## 5. CLI 명세

### 5.1 4개 Primitive 구조 (내부 함수)

| Primitive | 책임 |
|---|---|
| `new` | Phase 0 + Phase 1 진입 (워크트리 생성, phase0-issue.md 주입, dispatch) |
| `run-phase <skill>` | 새 백그라운드 세션 dispatch (`claude --bg "/qqq:<skill>"`) |
| `job-action <op> [<id>]` | 세션 조작 (attach/logs/stop/rm) — id 없으면 `pick` 호출 |
| `pick/tui` | fzf 메뉴 (TUI 진입 + ID 선택) |

### 5.2 외부 명령 (14개)

| 명령 | 동작 |
|---|---|
| `qqq` | TUI 진입 (실패 시 `qqq pick` fallback) |
| `qqq new <slug>` | Phase 1 시작 (이슈 없음) |
| `qqq new <slug> --issue N` | Phase 0 + Phase 1 시작 |
| `qqq clarify` | run-phase `/qqq:clarify-requirement` |
| `qqq ui` | run-phase `/qqq:ui-outline` (Optional) |
| `qqq nltp` | run-phase `/qqq:interview-nltp` (Optional) |
| `qqq tech-spec` | run-phase `/qqq:interview-tech` |
| `qqq plan` | run-phase `/qqq:code-plan` |
| `qqq implement` | run-phase `/qqq:code-implement` |
| `qqq attach <id>` | `claude attach <id>` |
| `qqq pick` | fzf → `claude attach <id>` |
| `qqq logs [<id>]` | id 없으면 fzf |
| `qqq stop [<id>]` | id 없으면 fzf |
| `qqq rm [<id>]` | id 없으면 fzf |
| `qqq verify` | 스모크 테스트 — PoC G1~G4 자동 검증 |

### 5.3 폐기된 명령 (기존 qqq-workflow.sh 기준)

`worktree-create`, `worktree-merge`, `worktree-merge-preview`, `worktree-open`, `worktree-remove`, `merge`, `register-issue` 등 12+ 액션 → 모두 `claude --worktree` / `claude attach` / `claude rm` / 슬래시 스킬로 흡수.

---

## 6. TUI 메뉴 구조

```
qqq (= fzf 메뉴 진입)
│
├─ 📋 새 작업 시작
│   ├─ 이슈에서 시작                  → glab issue list (TUI) → 자동 slug 제안 → 수정 → qqq new <slug> --issue N
│   ├─ 빈 작업 시작 (이슈 없이)         → slug 입력 → qqq new <slug>
│   └─ 새 이슈 생성 후 시작              → glab issue create → 위 흐름으로
│
├─ 🔍 진행 중인 세션 (메인 화면)
│   ├─ [<slug>:phase{N} — needs input]   ← 각 세션이 row
│   │   ├─ Attach                        → claude attach <id>
│   │   ├─ Next phase                    → 자동 추론 또는 페이즈 선택
│   │   ├─ Logs (tail)                   → claude logs <id>
│   │   ├─ Stop                          → claude stop <id>
│   │   └─ Delete                        → claude rm <id>
│   └─ ...
│
├─ 🔀 머지 가능한 세션 (PR dot 녹색)
│   └─ [<slug>:phase3 — PR #42 ✓]
│       └─ Merge                         → /qqq:merge-mr
│
└─ ⚙ 기타 (Optional)
    ├─ Rebase conflict resolve           → /qqq:rebase-conflict-resolve
    ├─ UI verify                         → /qqq:ui-verify
    └─ Frontend debug                    → /qqq:debug-frontend-pw
```

### TUI 동작 규칙 (CLI-11, CLI-12)

- **이슈 선택 후**: 이슈 제목에서 자동 slug 제안, 사용자 수정 가능
- **액션 수행 후**: TUI 종료 (셸 복귀). 메뉴 재진입 원하면 `qqq` 재호출

---

## 7. 마이그레이션 단계

순서 + 의존성:

| # | 작업 | 의존성 |
|---|---|---|
| 1 | `agents/*.md` frontmatter에서 `isolation: worktree` 제거 | 없음 |
| 2 | `skills/code-implement/SKILL.md`에 Step 0 (prerequisite check) 추가 (D1−) | 없음 |
| 3 | `hooks/qqq-protect-files.sh` 범위 축소 (~80줄) | 없음 |
| 4 | `hooks/qqq-context.sh` 슬림화 (~30줄) | 없음 |
| 5 | `.gitignore`에 `.claude/worktrees/` 추가 | 없음 |
| 6 | `.worktreeinclude` 생성 (필요시) | 없음 |
| 7 | `scripts/qqq` 신규 작성 (4 primitive, ~500줄) | 1~6 통과 |
| 8 | `scripts/qqq verify` 스모크 테스트 구현 | 7 |
| 9 | `skills/merge-mr/SKILL.md` 신규 작성 + **수동 merge 검증** (기존 `merge-protocol.sh`/`mr-create.sh`/`merge-archive.sh` 폐기 전 GitLab MR 머지 1회 실 검증) | 없음 |
| 10 | **폐기 작업**: `qqq-workflow.sh` + `lib/` 11개 + `test-qqq-workflow-*.sh` + 3 hooks | 7, 8 통과 |
| 11 | `.claude-plugin/plugin.json` hooks 등록 정리 | 10 |
| 12 | `README.md` 갱신 (워크플로우, CLI 명세, 제약사항) | 10 |
| 13 | `UPDATE_GUIDE.md` 갱신 | 12 |

각 단계는 *별도 PR 또는 commit*. #10은 가장 큰 변경이므로 #7·#8 완전 검증 후.

---

## 8. 검증 계획

### 8.1 `qqq verify` 스모크 테스트

`scripts/qqq verify` 명령이 실행하는 자동 검증:

| Gate | 검증 | 자동/수동 |
|---|---|---|
| G1 | `claude --bg --worktree --name --append-system-prompt-file` 4중 조합 (테스트 워크트리 생성 + 짧은 prompt + `claude logs`로 응답 확인 + `claude rm` 정리) | **자동** |
| G2 | `/qqq:<skill>` 첫 prompt dispatch가 슬래시 스킬로 해석되는지 (응답에 스킬 이름이 *문자 그대로* 안 나오면 PASS) | **자동** |
| G3 | `claude attach` 후 conversation 연속성 | **수동** (자동 판정 어려움 — TTY 입력 필요, 별도 PoC 절차) |
| G4 | `claude stop → --resume --print` (F1=b로 *주 운영 경로 외*. 기능 회귀 감지용 보조 검증) | **자동 (선택적)** |
| G5 | `claude --version` >= v2.1.139 | **자동** |
| G6 | fzf, glab, jq, sha256sum (또는 shasum -a 256) 존재 확인 | **자동** |

CI 또는 수동 주기 실행. **PASS 기준**: G1·G2·G5·G6 모두 통과 (필수). G3은 별도 수동 PoC, G4는 기능 회귀 감지용. PoC 결과가 다음 Claude Code 업데이트에 깨지면 빠르게 감지.

### 8.2 Claude Code 버전 게이트

`scripts/qqq` 진입 시 첫 단계:

```bash
required_version="2.1.139"
current=$(claude --version | awk '{print $1}')
if ! version_ge "$current" "$required_version"; then
    echo "qqq requires Claude Code >= $required_version. Run: claude update" >&2
    exit 1
fi
```

---

## 9. 위험 및 받아들인 trade-off

### 9.1 잃는 것 (의도된)

| 항목 | 영향 |
|---|---|
| Leader checkout 워크플로 | 워크트리 만들기 전 임시 작업 X |
| worktree-merge 자동 검증 | 사용자/PR 리뷰가 책임 |
| 페이즈 게이팅 강제력 | 모든 페이즈 진입은 *검증 없음*. Phase 3만 review_loop_completed |
| plan 수정 후 phase3 우회 차단 | 사용자가 plan 수정해도 reviewer 재진입 강제 안 됨 |
| GitLab merge 자동화 | `/qqq:merge-mr`는 검증 없는 wrapper |
| JSONL 로그 후처리 | F2: 분석 흐름 없음 가정 |
| `agent view` UI (nested 환경) | TUI fallback |

### 9.2 Research Preview 의존 위험

`--bg`, `attach`, `logs`, `stop`, `rm`, `respawn`, `--append-system-prompt-file`은 **공식 `claude --help`에 미노출된 숨겨진 옵션**. CLI 표면이 다음 버전에 바뀔 위험.

대응:
- `qqq verify`로 주기적 검증
- `claude --version >= v2.1.139` 강제
- README에 *"Claude Code Research Preview 기능 의존"* 경고

### 9.3 산출물 보존 미보장

워크트리 삭제(`claude rm`, `Ctrl+X` 두 번) 시 *uncommit 산출물 영구 손실*. 

대응:
- `hooks/qqq-context.sh`가 SessionStart에서 uncommit 산출물 경고
- README에 명시
- 강제 commit은 하지 않음 (사용자 자율)

### 9.4 D1− 약화의 정직한 한계 (Codex Q2 "조건부 수용" 반영)

페이즈 사전조건 검증이 *Phase 2→3에만* 있음. 다른 페이즈 진입은 모델 판단 의존. *실수 방지*도 약함. Codex 평가: *"운영자가 PR 리뷰를 최종 책임으로 받아들이는 조건에서만 수용 가능"*.

**조건부 수용**: 이 plan은 다음을 *암묵적 운영 계약*으로 가정한다.
1. **PR 리뷰가 품질 보증의 최종 책임** — qqq의 페이즈 게이트는 *권장 흐름*일 뿐, 코드 변경의 정확성은 PR 단계에서 사람 리뷰어가 보증.
2. **사용자가 페이즈를 건너뛰면 자기 책임** — `phase1-spec.md` 없이 phase2 진입해서 plan이 부실해도 qqq는 책임지지 않음.
3. **plan 수정 후 phase3 우회 가능** — reviewer 재진입 강제 없음. 의도된 손실.

문서화 (README 또는 WORKFLOW.md):
> "qqq의 페이즈 게이팅은 *실수 방지*가 아니다. *모델의 자기 판단*과 *PR 리뷰*에 의존한다. 사용자가 페이즈 순서를 임의로 바꾸거나 산출물을 수동으로 만들 수 있다. 품질 보증의 최종 책임은 PR 리뷰어에게 있다. 이는 의도된 trade-off이다."

---

## 10. 미해결 항목 (추후 결정 가능)

| # | 항목 | 비고 |
|---|---|---|
| 1 | `--fork-session` 활용 방안 | 현재 미사용. 실험적 분기에 유용할 수 있음 |
| 2 | `agent view` UI 사용 가능 환경 vs nested 환경 분기 | 사용자가 직접 `claude agents` 호출하면 됨 |
| 3 | reviewer 토큰 비용 최적화 | 현재 3중 reviewer 그대로. 추후 Haiku-class로 변경 가능 |
| 4 | `phase-detect.sh` 일부 폐기 (review fingerprint 부분) | 단계 #7에서 함께 처리 |
| 5 | 다른 페이즈 게이트도 *minimal* 검증 도입 여부 | 사용자가 D1− 선택. 추후 운영 경험으로 재평가 가능 |
| 6 | history 손실 시 phase 간 맥락 (Codex Q7-c) | F1=b로 phase 간 conversation 연속성 손실. *받아들인 trade-off* — 산출물 템플릿이 충실해야 phase3가 phase1 결정 배경을 이해 가능. 페이즈 에이전트 시스템 프롬프트의 품질에 의존 |
| 7 | merge-mr 슬래시 스킬의 GitLab MR vs GitHub PR 자동 감지 정확도 | `glab` 또는 `gh` 호출 분기. origin URL로 감지 — 의외의 호스팅(gitea, codeberg 등) 대응 필요시 추가 |

---

## 11. 검증된 PoC 결과 (부록)

Claude Code v2.1.141 기준, 2026-05-14 검증:

| Gate | 결과 |
|---|---|
| G1. `--bg + --worktree + --name + --append-system-prompt-file` 4중 조합 | ✅ |
| G2. 첫 prompt에 `/qqq:<skill>` 직접 호출 | ✅ |
| G3. attach 후 conversation 연속성 | ✅ |
| G4-1. stopped 세션에 `--resume --print` (비대화형 후속 prompt) | ✅ (F1=b로 사용 빈도 낮음) |
| G4-2. `--fork-session`으로 history 분기 | ✅ (미사용 예정) |

**숨겨진 CLI 표면 확인**: `--bg`, `claude attach`, `claude logs`, `claude stop`, `claude rm`, `claude respawn`, `--append-system-prompt-file` 모두 메인 `--help`에 미노출이지만 동작.

**Short ID = full UUID prefix**: `~/.claude/jobs/<short-id>/` 디렉토리. state.json에서 full UUID 추출 가능.

**Nested 환경 제약**: 이미 Claude Code 세션 안에서 `claude agents` UI 호출 시 *"not available in this environment"* — fzf TUI fallback이 필수인 이유.

---

## 12. v3.2 — `--agent` dispatch 전환 (부록)

**Date**: 2026-05-19
**Scope**: phase 진입 형태를 슬래시 커맨드(`/qqq:<skill>`)에서 plugin-scoped agent(`--agent qqq:<agent>`)로 전환. `--append-system-prompt-file` 폐기 + initial-prompt 인라인 합류.

### 결정 사항

| | 결정 |
|---|---|
| AG-1 | 모든 phase dispatch는 `claude --bg --agent qqq:<agent> --name <slug>:<agent> --permission-mode bypassPermissions "<initial prompt>"` 형태로 통일. session name은 phase 번호(`:phase1`) 대신 **agent 이름**(`:req-clarifier`)을 단다. |
| AG-2 | `--permission-mode bypassPermissions` 도입. 백그라운드 `auto-deny` 회피 + 권한 prompt 스킵. `AskUserQuestion`은 권한 게이트가 아니라 사용자 대화 흐름 영향 없음. |
| AG-3 | `phase0-issue.md` 본문 + `qqq new -m TEXT` brief가 **첫 user turn의 인라인 텍스트**로 합류. `--append-system-prompt-file` 제거. session_dir은 `session_dir=<abs>` 한 줄로 같은 prompt 안에 포함. |
| AG-4 | aux flow(skill-only: `rebase-conflict-resolve`/`ui-verify`/`debug-frontend-pw`)는 기존 슬래시 dispatch 유지 (`primitive_dispatch_slash`). 매칭 agent가 없는 skill 보존. |
| AG-5 | 슬래시 진입(`/qqq:<skill> <session_dir>`)도 별개로 살아있다 — agent dispatch와 **이중 진입점**. 사용자가 attach 후 임의 시점에 호출 가능. |

### 구현 위치

| 변경 | 파일 |
|---|---|
| `build_initial_prompt` 신설 + `primitive_dispatch_phase` agent 방식 + `primitive_dispatch_slash` aux용 | `scripts/qqq:335-394` |
| `cmd_clarify/ui/nltp/tech_spec/plan/implement` agent 이름 매핑 | `scripts/qqq:489-495` |
| `cmd_new` 인자 파서에 `-m`/`--message` 추가 | `scripts/qqq:477-492` |
| `primitive_new` brief + issue를 initial prompt에 합류 | `scripts/qqq:404-458` |
| `tui_aux_flow` aux 라인 | `scripts/qqq:943` |
| `hooks/qqq-context.sh` next 안내문 agent 이름 노출 | `hooks/qqq-context.sh:28-41` |

### 무수정 영역 (검증 완료)

- 13 agent 파일 — 전부 `skills: - qqq:<skill>` 프론트매터 보유. preload 인프라 완비.
- 14 skill 파일 — agent 메인 thread 환경에서도 sub-agent 호출(`Task(subagent_type: ...)`) 정상 (docs: "main thread agent can spawn subagents").
- `hooks/hooks.json` / `hooks/qqq-protect-files.sh` — session name·intent 라벨 무관.

### 사이드이펙트

- `state.json.intent` 필드 = 슬래시 커맨드 텍스트 기반이라 agent 모드에서 비어있을 수 있음. fzf 라벨에 "— intent"가 비더라도 `--name`이 `<slug>:<agent>`라 식별 정보 손실 없음 — 무수정 결정 (D1-가).
- `--bg`가 frontmatter `background: false`를 override함 — 실증 완료.
- `bypassPermissions` 도입으로 `claude-works-completed/` write 차단 hook은 그대로 동작 (권한이 아닌 hook 경로).

### 공식 docs 근거

- "Pass `--agent <name>` to start a session where the main thread itself takes on that subagent's system prompt, tool restrictions, and model" (code.claude.com/docs/en/sub-agents)
- "skills: Skills to preload into the subagent's context at startup. The full skill content is injected, not just the description."
- "If the parent uses `bypassPermissions` or `acceptEdits`, this takes precedence and cannot be overridden."
- "When an agent runs as the main thread with `claude --agent`, it can spawn subagents using the Agent tool."

---

*Plan v2.3 by Claude (Opus 4.7), based on user decisions and Codex thread a582b0a0926c02783. v3.2 appendix added 2026-05-19.*
