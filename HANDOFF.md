# qqq Migration Handoff — 2026-05-15

> **다음 세션은 이 문서와 `MIGRATION_PLAN.md`를 먼저 읽고 시작할 것.**
> 이 문서는 *어디까지 왔고 어디서 이어가는지*만 다룬다. *왜 그렇게 결정했는지*는 모두 `MIGRATION_PLAN.md`에 있다.

## 1. 한 줄 요약

qqq 하니스를 Claude Code v2.1.139+ 표준 인프라(agent view, `--bg`, `--worktree`)로 마이그레이션 중. **10개 task 중 5개 완료**, 누적 ~281줄 감소. 큰 작업(`scripts/qqq` 신규 작성, 대량 폐기) 남음.

## 2. 이번 세션에 완료한 것

| Task | 작업 | 라인 변경 |
|---|---|---|
| #7 (마이그레이션 #1) | `agents/*.md` frontmatter 정리 | no-op (이미 깨끗) |
| #8 (마이그레이션 #2) | `skills/code-implement/SKILL.md`에 **D1− 게이트 추가** (Hard Rules + Phase 0 Required inputs) | +6줄 |
| #9 (마이그레이션 #3) | `hooks/qqq-protect-files.sh` 범위 축소 → `claude-works-completed/`만 frozen | **332 → 66** |
| #10 (마이그레이션 #4) | `hooks/qqq-context.sh` 슬림화 → 페이즈 추론 + uncommit 경고만 | **66 → 51** |
| #11 (마이그레이션 #5) | `.gitignore`에 `.claude/worktrees/` 추가 | +1줄 |
| 문서 작성 | `MIGRATION_PLAN.md` v2.3.1 (전체 설계) | 신규 ~600줄 |

→ 마이그레이션 코드 부분 *281줄 감소*, 설계 문서 추가.

## 3. 다음에 할 작업 (Task ID 순서)

| Task # | 작업 | 의존성 | 추정 크기 |
|---|---|---|---|
| **#14** | `skills/merge-mr/SKILL.md` 신규 + 수동 머지 검증 1회 | 없음 (독립) | ~50줄 + 검증 |
| **#12** | `scripts/qqq` 신규 작성 (4 primitive + TUI + fzf + glab + 버전 게이트 + race 검사) | 없음 | **~750줄** (가장 큰 작업) |
| **#13** | `qqq verify` 스모크 테스트 (G1·G2·G5·G6 자동, G3 수동) | #12 | ~100줄 |
| **#15** | 대량 폐기 — `qqq-workflow.sh` + `lib/` 11개 + `test-qqq-workflow-*.sh` + 3 hooks | #12·#13·#14 | **~6,307줄 삭제** |
| **#16** | `.claude-plugin/plugin.json` hooks 등록 정리 + `README.md` + `UPDATE_GUIDE.md` 갱신 | #15 | 문서 |

### 권장 시작점

**Task #14를 먼저** 처리 권장. 독립적이고 작은 작업이라 *#12에 들어가기 전 모든 작은 작업 정리* 가능.

## 4. 핵심 결정사항 (Quick Reference)

> 자세한 근거와 trade-off는 `MIGRATION_PLAN.md` 본문 참조.

### 워크플로우 (모두 보존)
- W1~W6: 3-phase 분리, 산출물 영구 기록, 3중 reviewer, NLTP/UI Optional, Phase 0 이슈 주입, 1 이슈 = 1 워크트리

### 인프라 (대폭 단순화)
- **D1−**: 페이즈 게이팅 = *기본 검증 없음* + Phase 2→3에서만 `review_loop_completed === true` (skill inline)
- **D2**: `.qqq.lock`, `.qqq/session.json` 완전 폐기
- **D3**: 머지 = `/qqq:merge-mr` 슬래시 스킬 (검증 없는 wrapper)
- **D4**: CLI 명령 + fzf TUI (TUI가 메인 진입점)
- **F1=b**: 페이즈 전환 = **새 백그라운드 세션 dispatch + 산출물 파일 read** (resume 사용 안 함)
- **F2**: JSONL 로그 완전 폐기 (분석 흐름 없음 가정)
- **Q1**: 작업 단위 세션 (1 워크트리에 페이즈 순차)
- **Q2**: `claude-works-completed/`만 frozen
- **Q3**: SessionStart 시 uncommit 경고만
- **Q4**: fzf 필수

### CLI 명령 (`scripts/qqq` 신규 작성 시 필요)
```
qqq                              # TUI 진입 (fzf 메뉴)
qqq new <slug>                   # 이슈 없이 새 작업
qqq new <slug> --issue N         # GitLab 이슈 + Phase 0/1
qqq clarify / ui / nltp / tech-spec / plan / implement
                                 # 각 페이즈: 새 백그라운드 세션 dispatch (F1=b)
qqq attach <id>                  # 직접 attach
qqq pick                         # fzf → claude attach
qqq logs [<id>]                  # 인자 없으면 fzf
qqq stop [<id>]
qqq rm [<id>]
qqq verify                       # 스모크 테스트
```

## 5. 다음 세션에서 *반드시* 알아야 할 함정

1. **F1=b 일관성** — `scripts/qqq`에서 **절대 `claude --resume --print`로 후속 prompt 보내지 말 것**. 페이즈 전환은 *항상 새 백그라운드 세션 dispatch* (이전 산출물은 워크트리 파일에서 read). `MIGRATION_PLAN.md §2.6` 케이스 #3 참조.

2. **CLI-9 fail-closed 5케이스** (`MIGRATION_PLAN.md §2.6`):
   - 한 워크트리에 2+ 세션 → dispatch 거부
   - cwd가 메인 체크아웃 → 페이즈 명령 실패 처리
   - stopped 세션 → 새 세션 dispatch (resume 안 함)
   - exited/removed → 거부
   - **동일 워크트리에 running 세션 있으면 dispatch 거부 (race 방지)**

3. **숨겨진 CLI 표면 의존** — `claude --bg`, `attach`, `logs`, `stop`, `rm`, `respawn`, `--append-system-prompt-file`은 `claude --help` 메인 목록에 *미노출* (v2.1.141 기준). Research Preview라 다음 업데이트에 변경될 수 있음.

4. **버전 게이트** — `scripts/qqq` 진입 시 `claude --version >= v2.1.139` 검사 필수.

5. **D1− 약화 인정** — 페이즈 게이팅이 의도적으로 약함. 우회 가능. README에 *"PR 리뷰가 품질 보증 최종 책임"* 명시 필수 (#16에서).

6. **`scripts/qqq` 라인 추정** — 낙관 ~500, 현실 **~750**. plan v2.3.1은 현실 추정 채택.

7. **재사용 후보**:
   - `scripts/lib/phase-detect.sh` (313줄) → review fingerprint 부분 제거 후 ~200줄 재사용 *or* `scripts/qqq` 내 재작성 — 단계 #12에서 결정
   - `scripts/lib/glab-cache.sh` (89줄) → 그대로 재사용
   - `scripts/lib/phase0-issue.sh` (340줄) → 그대로 재사용 (`qqq new --issue N`이 호출)

## 6. 검증된 PoC 사실 (Claude Code v2.1.141)

| Gate | 결과 |
|---|---|
| `claude --bg --worktree --name --append-system-prompt-file` 4중 조합 | ✅ |
| 첫 prompt에 `/qqq:<skill>` 직접 dispatch | ✅ |
| `claude attach` 후 conversation 연속성 | ✅ |
| `claude stop` → `claude --resume <uuid> --print` 비대화형 후속 | ✅ (F1=b로 *미사용*) |
| `claude --resume <uuid> --fork-session --print` | ✅ (현재 미사용) |
| Short ID (`backgrounded · 7c5dcf5d`) = full UUID prefix | ✅. `~/.claude/jobs/<short>/state.json`에 UUID 있음 |
| Nested Claude Code 환경에서 `claude agents` UI | ❌ "not available in this environment" — fzf TUI fallback 필수 이유 |

## 7. 외부 검토 이력

- **Codex thread 1** (`a582b0a0926c02783`): plan v2.2 검토 → Q1~Q7 7항목, CONDITIONAL-GO. 위험 평가 + 보완 권고.
- **Codex thread 2** (`a3f7b0584d75fd2bf`): plan v2.3 검토 → CONDITIONAL-GO + 3개 확인 권장 (stopped 세션 처리, race, PR 산출물 형식). 모두 *plan v2.3.1에 반영 완료*.

다음 세션에서 추가 Codex 검토 필요 시 위 thread ID 사용 가능 (SendMessage 도구가 deferred에 있을 때).

## 8. 빠른 재개 절차

```bash
cd /home/hskim/private/claude-code-harness-qqq
cat HANDOFF.md           # 이 문서
cat MIGRATION_PLAN.md    # 설계 문서 (필수)
git log --oneline -10    # 최근 commit
# TaskList로 미완료 task 확인 (TaskCreate/TaskUpdate가 세션 간 보존되는지는 환경 의존)
```

권장 첫 작업: **Task #14** (`/qqq:merge-mr` 스킬 신규).
다음 큰 작업: **Task #12** (`scripts/qqq` 신규, ~750줄, 별도 commit 권장).

## 9. 파일 위치

| 경로 | 역할 |
|---|---|
| `MIGRATION_PLAN.md` | 전체 설계 (v2.3.1) — *가장 중요* |
| `HANDOFF.md` | 이 문서 |
| `agents/*.md` | 13개 페이즈 에이전트 (변경 없음, 유지) |
| `skills/*/SKILL.md` | 14개 스킬 (`code-implement`만 변경됨) |
| `hooks/qqq-protect-files.sh` | 축소 완료 (66줄) |
| `hooks/qqq-context.sh` | 슬림화 완료 (51줄) |
| `hooks/qqq-stop-guard.sh` | **폐기 대상** (Task #15에서) |
| `hooks/qqq-log-event.sh` | **폐기 대상** (Task #15에서) |
| `hooks/qqq-notify.sh` | **폐기 대상** (Task #15에서) |
| `scripts/qqq-workflow.sh` (263줄) + `scripts/lib/` (4,895줄) | **대부분 폐기 대상** (Task #15) |
| `scripts/qqq` | **신규 작성 대상** (Task #12) |
| `skills/merge-mr/` | **신규 작성 대상** (Task #14) |

---

*Generated by Claude (Opus 4.7) at session end, 2026-05-15.*
*다음 세션의 Claude: 시작하기 전 이 문서 + MIGRATION_PLAN.md 둘 다 읽기.*
