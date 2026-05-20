# qqq — Claude Code용 3-페이즈 개발 하니스

Claude Code 플러그인. 모호한 요청을 *리뷰·검증을 거친 구현*으로 변환한다. 각 페이즈는 분명한 산출물, 사용자와의 Socratic 루프, 다음 단계로 넘어가기 전 reviewer 패스를 갖는다.

```
[Phase 0] → Phase 1 → Phase 2 → Phase 3
issue 등록    요구 명세    코드 계획    구현 + 리뷰
(optional)
```

- **Phase 0** (선택) — GitLab 이슈를 `phase0-issue.md`로 스냅샷해 Phase 1에 공유 컨텍스트로 주입.
- **Phase 1** — 승인된 spec (+ 선택적 UI outline / NLTP) 산출.
- **Phase 2** — 리뷰를 거친 코드 계획 산출.
- **Phase 3** — 계획 실행 + diff 리뷰.

각 페이즈는 `scripts/qqq` CLI를 통해 *새 백그라운드 Claude Code 세션*으로 dispatch된다. 산출물은 worktree의 `claude-works/<date_slug>/` 아래에 누적되며 다음 페이즈가 disk에서 읽어 들인다.

> **v3.0 마이그레이션 메모.** v3.0에서 하니스를 Claude Code v2.1.139+ 표준 인프라(`claude --bg / --worktree`, agent view, `~/.claude/jobs/`)로 옮겼다. 옛 fzf+tmux 런처(`scripts/qqq-workflow.sh`)와 `scripts/lib/`의 대부분이 단일 ~950줄 `scripts/qqq` CLI + 2개 hook으로 대체됐다. 설계 배경은 `MIGRATION_PLAN.md` 참고.
>
> **v3.1 변경.** Hook이 **플러그인 레벨 리소스(`hooks/hooks.json`)**로 이동했다. 옛 `/qqq:install` per-project 단계가 사라지고, `claude --plugin-dir <qqq>` 한 번이면 hook까지 자동 등록된다. 기존 사용자 정리 절차는 아래 [Migration — v3.0 → v3.1](#migration--v30--v31) 항목을 참고할 것.
>
> **v3.3 변경 (worktree 모델 전환).** v3.3는 `qqq new`가 워크트리를 직접 만들지 않고 `claude --bg --worktree <slug>`로 Claude Code 표준 워크트리 메커니즘에 위임했다. v3.5에서 이 결정을 되돌렸다(아래 v3.5 항목 참고).
>
> **v3.4 변경 (TUI 재설계).** `🔍 sessions` 메뉴가 `🌲 worktrees`로 바뀌었다. 최상위 메뉴 → worktree picker(qqq 관리만, status=active/archived/stale 표기) → 액션 메뉴(`claude-sessions` / `next-phase` / `remove-worktree`)의 3-스택 구조다. ESC는 한 단계씩 위로 pop하며 최상위에서만 종료된다. `next-phase`는 sentinel 2번째 줄에 박힌 caller subdir(예: `frontend`)을 그대로 cwd로 재현해 모노레포 컨텍스트가 phase 간에 보존된다 — sentinel 형식이 1줄(legacy)에서 2줄로 확장됐지만 `read_active_session_subdir`이 backward-compatible하다. `remove-worktree`는 `_verify_teardown`의 4-layer 가드를 차용하고 dirty 시 slug 재입력 confirm을 요구한다.
>
> **v3.5 변경 (worktree 모델 재전환 — X8).** v3.3에서 도입한 `claude --bg --worktree` 위임을 거두고 `primitive_new`가 `git worktree add`를 직접 호출하는 모델로 돌아왔다. 동기는 Claude Code v2.1.x의 plugin-scope `WorktreeCreate` dispatch 누락(anthropics/claude-code#46664)이다 — plugin이 자체 `hooks/hooks.json`에 등록한 `WorktreeCreate` hook이 절대 fire되지 않아 v3.3은 user-scope `~/.claude/settings.json`에 hook을 박는 우회 단계(`qqq install`)를 요구했다. v3.5는 worktree 생성을 qqq가 직접 소유함으로써 (a) `qqq install`/`uninstall`/G8 게이트를 제거하고 (b) `~/.claude/settings.json`을 더 이상 만지지 않으며 (c) upstream 패치 일정에 의존하지 않게 한다. v3.3가 v3.x repo_slug 사고를 막기 위해 도입한 두 안전장치(`git rev-parse --path-format=absolute` + sentinel 기반 `read_active_session_dir`)는 그대로 보존된다. **이전 `qqq install`을 한 번이라도 돌렸던 사용자에게**: `~/.claude/settings.json`에 박힌 WorktreeCreate hook 엔트리는 v3.5에서 더 이상 호출되지 않아 무해하다(qqq는 `--worktree` flag를 안 쓴다). 그대로 두거나 다음과 같이 정리해도 된다:
>
> ```bash
> jq 'del(.hooks.WorktreeCreate)' ~/.claude/settings.json | sponge ~/.claude/settings.json
> ```

---

## 설치 / 업데이트 / 삭제

qqq는 **로컬 marketplace** (`hskim-plugins`) 안의 플러그인으로 배포된다. Claude Code의 `/plugin` 슬래시 명령으로 관리한다.

### 사전 준비 — 로컬 marketplace 부트스트랩

> **본 repo 작성자 환경에는 이미 marketplace + qqq 클론이 갖춰져 있다** (`~/.claude/plugins/local/hskim-plugins/.claude-plugin/marketplace.json`이 존재하고 `qqq` 항목 포함). 그 경우 이 절은 건너뛰고 바로 [옵션 A](#옵션-a--marketplace를-통한-영구-설치-권장)로.

다른 머신/계정에서 처음 셋업할 때는 다음 두 가지가 모두 필요하다:

1. **로컬 marketplace 디렉터리 + manifest**

   ```bash
   mkdir -p ~/.claude/plugins/local/hskim-plugins/{.claude-plugin,plugins}
   cat > ~/.claude/plugins/local/hskim-plugins/.claude-plugin/marketplace.json <<'JSON'
   {
     "name": "hskim-plugins",
     "owner": { "name": "hskim" },
     "metadata": { "description": "hskim's local plugins" },
     "plugins": [
       {
         "name": "qqq",
         "source": "./plugins/qqq",
         "description": "Three-phase development harness (clarify → plan → implement) for Claude Code",
         "version": "3.1.0"
       }
     ]
   }
   JSON
   ```

2. **qqq 플러그인 클론** — manifest의 `source`가 가리키는 경로에 그대로 둔다:

   ```bash
   git clone https://github.com/kimosungk/claude-code-harness-qqq.git \
     ~/.claude/plugins/local/hskim-plugins/plugins/qqq
   ```

### 옵션 A — marketplace를 통한 영구 설치 (권장)

새 Claude Code 세션 안에서 한 번만 실행:

```
/plugin marketplace add ~/.claude/plugins/local/hskim-plugins
/plugin install qqq@hskim-plugins
```

이후 어느 디렉터리에서 `claude`를 열어도 `qqq:*` skill + 두 plugin-level hook(PreToolUse, SessionStart)이 자동 활성화된다. `--plugin-dir`를 매번 지정할 필요 없음. v3.5부터는 추가 post-install 단계가 없다(`qqq install`은 폐기). `qqq verify`로 설치 상태 확인 가능.

**Scope** — Claude Code의 install 기본은 `user`(모든 프로젝트에서 자동 활성). 본 repo 작성자 환경은 history상 `scope=project`로 4개 프로젝트에 따로 설치되어 있는데(`~/.claude/plugins/installed_plugins.json` 참고), 이는 명시적 옵션 선택의 결과다. project scope을 원하면 `/plugin` UI에서 scope를 고르거나 다음 CLI를 사용한다:

```bash
claude plugin install qqq@hskim-plugins --scope project   # 현 디렉터리에만
claude plugin install qqq@hskim-plugins                   # 기본: user scope
```

### 옵션 B — `--plugin-dir`로 빠른 시험

설치 절차 없이 매 세션마다 path를 직접 지정:

```bash
claude --plugin-dir ~/.claude/plugins/local/hskim-plugins/plugins/qqq
```

영구 등록되지 않으므로 일회성 시험·디버깅에 유용.

### CLI alias

`qqq` CLI를 PATH 단축어로 두는 alias (셋업은 한 번만):

```bash
# ~/.zshrc 또는 ~/.bashrc
alias qqq="$HOME/.claude/plugins/local/hskim-plugins/plugins/qqq/scripts/qqq"
```

`source ~/.zshrc` 후 `qqq --help`로 검증.

> v2.x 시절 alias가 `scripts/qqq-workflow.sh`를 가리킨다면 위 v3.x 경로로 갱신. v2 launcher는 v3.0에서 폐기됨.

### 업데이트

marketplace install은 Claude Code의 plugin **캐시**(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`)에서 실행되며 marketplace source 디렉터리에서 직접 실행되지 *않는다*. 따라서 git pull만으로는 installed copy가 바뀌지 않는다. 3단계로 갱신한다:

```bash
# 1. marketplace source 코드 갱신 (디스크의 ./plugins/qqq)
git -C ~/.claude/plugins/local/hskim-plugins/plugins/qqq pull --ff-only
```

```
# 2. marketplace manifest 캐시 갱신 (autoUpdate=true면 자동, 명시 실행도 안전)
/plugin marketplace update hskim-plugins

# 3. 실제 plugin 캐시 카피 갱신 — scope별로 따로 실행
/plugin update qqq@hskim-plugins                      # user scope
/plugin update qqq@hskim-plugins --scope project      # project scope (각 프로젝트에서)
```

`~/.claude/plugins/known_marketplaces.json`의 해당 항목에 `"autoUpdate": true`가 켜져 있으면 2단계는 주기적으로 자동 수행되지만, 3단계는 항상 명시적이다. 기존에 v3.0 등 옛 버전으로 설치돼 있는 카피는 모두 3단계를 거쳐야 v3.1로 이동한다.

### 삭제

```
/plugin uninstall qqq@hskim-plugins
```

marketplace 자체도 제거하려면:

```
/plugin marketplace remove hskim-plugins
```

로컬 클론 디렉터리는 위 명령으로 지워지지 않으니 디스크 공간 회수가 필요하면 수동 삭제:

```bash
rm -rf ~/.claude/plugins/local/hskim-plugins/plugins/qqq
```

### 옛 v2/v3.0 흔적 정리 (필요 시)

옛 `/qqq:install`을 돌려 프로젝트 로컬 hook이 박혀 있는 경우는 아래 [Migration — v3.0 → v3.1](#migration--v30--v31) 절차 따라 정리.

---

## 의존성

| 의존성 | 용도 | 비고 |
|---|---|---|
| Claude Code **2.1.139+** | CLI + skill | `scripts/qqq` 진입 시 버전 게이트. `claude --bg`, `claude attach`, `claude rm`, `--append-system-prompt-file` 사용 |
| `bash` 4+ | `scripts/qqq`, hook | macOS 기본 3.2 미지원 |
| `fzf` | `scripts/qqq` TUI + picker | 필수 |
| `jq` | CLI + hook (JSON 파싱) | 필수 |
| `git` | 모든 phase agent | 필수 |
| `sha256sum` 또는 `shasum -a 256` | Phase 2→3 리뷰 fingerprint | 필수 |
| `glab` | `qqq new --issue N`, `/qqq:merge-mr` (GitLab) | 선택 |
| `gh` | `/qqq:merge-mr` (GitHub) | 선택 |
| `codex` CLI | Codex-우선 리뷰 skill | 선택 — 없으면 Claude fallback 자동 |
| `playwright-cli` 플러그인 | `ui-verifier` agent | **별도 플러그인**, qqq와 병행 설치 |

---

## `scripts/qqq` — CLI + TUI

진입점. `qqq --help`로 전체 명령 확인.

| 명령 | 동작 |
|---|---|
| `qqq` | TUI 진입 (fzf 메뉴) |
| `qqq new <slug>` | 이슈 없이 새 worktree에서 빈 세션 시작 |
| `qqq new <slug> -m "TEXT"` | 빈 세션 + 사용자 요구사항을 첫 agent turn에 주입 |
| `qqq new <slug> --issue N` | GitLab 이슈 fetch → worktree에 `phase0-issue.md` 작성 → Phase 1 dispatch |
| `qqq clarify` | agent `qqq:req-clarifier` 를 새 bg 세션으로 dispatch |
| `qqq ui` | agent `qqq:ui-outliner` dispatch (선택) |
| `qqq nltp` | agent `qqq:nltp-interviewer` dispatch (선택) |
| `qqq tech-spec` | agent `qqq:tech-interviewer` dispatch |
| `qqq plan` | agent `qqq:code-planner` dispatch |
| `qqq implement` | agent `qqq:code-implementer` dispatch |
| `qqq attach <id>` | `claude attach <id>` |
| `qqq pick` | fzf → `claude attach` |
| `qqq logs [<id>]` / `qqq stop [<id>]` / `qqq rm [<id>]` | `claude logs/stop/rm` 래퍼 (id 없으면 fzf) |
| `qqq merge-mr` | `/qqq:merge-mr` 실행 (push + MR/PR + merge — thin wrapper, 검증 없음) |
| `qqq verify` | 스모크 테스트 (G1·G2·G4·G5·G6 자동, G3 수동) |

### 페이즈 전환 계약 (F1=b)

모든 페이즈 명령은 **새 백그라운드 세션 dispatch**. 페이즈 전환에 `--resume`을 쓰지 않는다. dispatch 형태는 다음과 같이 표준화되어 있다:

```bash
claude --bg \
  --agent "qqq:<agent>" \
  --name "<slug>:<agent>" \
  --permission-mode bypassPermissions \
  "<initial prompt: session_dir=<abs> + brief + issue 본문>"
```

- `--agent qqq:<agent>` — 메인 thread의 system prompt를 agent 정의로 치환. agent의 `skills:` 프론트매터로 대응 skill이 자동 preload된다.
- `--permission-mode bypassPermissions` — TTY 없는 백그라운드에서 권한 prompt 자동 거부를 피한다. `AskUserQuestion`은 권한 게이트가 아니므로 사용자 대화 흐름은 영향 없음.
- positional prompt = 첫 user turn. `phase0-issue.md` 본문과 `qqq new -m TEXT` brief는 모두 이 한 덩어리에 합쳐져 들어간다 (`--append-system-prompt-file` 제거).

다음 페이즈 agent는 worktree의 `claude-works/<date_slug>/` 안 `phase{N-1}-*.md`를 disk에서 직접 읽는다.

> 슬래시 진입(`/qqq:<skill> <session_dir>`)도 별개로 살아있다. 사용자가 attach 후 임의 시점에 호출 가능 — agent dispatch와 이중 진입점 관계.

### 경쟁 + 격리 (CLI-9)

`scripts/qqq`는 dispatch 전에 다음을 거부한다:

- cwd가 main checkout이면 거부 (linked worktree가 아님)
- 이 worktree에 `working` / `idle` 상태 세션이 있으면 거부
- 이 worktree에 `exited` 상태 세션이 있으면 거부 (비정상 — 먼저 조사)
- 이 worktree에 비-실행 세션이 2개 이상이면 거부 (혼란 상태 — `qqq pick` 또는 `claude rm` 먼저)

상태는 `~/.claude/jobs/<short>/state.json`에서 추론한다 — qqq 자체 잠금 파일 없음.

---

## 구성 요소

`agents/` 13개 페이즈 에이전트, `skills/` 14개 skill, `hooks/` 2개 hook, `scripts/` 1개 스크립트(`qqq`).

### Phase 0 — 이슈 등록 (선택)

| 컴포넌트 | 목적 |
|---|---|
| `qqq new <slug> --issue N` (CLI) | `glab`로 GitLab 이슈 fetch → 새 worktree 안에 `phase0-issue.md` 스냅샷 + auto-commit → 본문이 Phase 1 agent의 **첫 user turn**에 인라인 주입된다(`--append-system-prompt-file`은 v3.2에서 폐기됨). CLI가 소유하며 `phase0-issue.md`는 모든 phase agent에게 read-only 자료로 남는다. |

### Phase 1 — Clarify

| Agent / Skill | 목적 |
|---|---|
| `qqq:req-clarifier` / `qqq:clarify-requirement` | Socratic Q&A로 `phase1-spec.md` 초안 작성 |
| `qqq:ui-outliner` / `qqq:ui-outline` | (선택) 최소 HTML UI outline |
| `qqq:nltp-interviewer` / `qqq:interview-nltp` | (선택) Gherkin 스타일 NLTP. `qqq:nltp-reviewer`가 게이트 |
| `qqq:tech-interviewer` / `qqq:interview-tech` | 동결된 기술 spec(`phase1-tech-spec.md`) — 스택·데이터 모델·제약 잠금 |

### Phase 2 — Plan

| Agent / Skill | 목적 |
|---|---|
| `qqq:code-planner` / `qqq:code-plan` | `phase2-code-plan.md` 초안 + explorer → architect → critic 리뷰 루프 실행 |
| `qqq:code-plan-review-explorer` | Gate 1 — 사실, 재사용, 영향도, 함정 검증 |
| `qqq:code-plan-review-architect` | Gate 2 — 구조, 계층, 계약, 보안 |
| `qqq:code-plan-review-critic` | Gate 3 — premortem (실패 모드, 롤백, 관측성) |

### Phase 3 — Implement

| Agent / Skill | 목적 |
|---|---|
| `qqq:code-implementer` / `qqq:code-implement` | 계획 실행, `phase3-implement-log.md` 작성, reviewer 루프 구동. **D1− 게이트**: `phase2-review-state.json`의 `review_loop_completed: true` 필수. |
| `qqq:code-implement-reviewer` / `qqq:code-implement-review` | Codex-우선 diff 리뷰, Claude fallback. working-tree 범위(tracked + untracked) 리뷰. Codex 실패 시 9-way `Failure category` 기록 — infra 계열만 Claude fallback, bug 계열(`unsupported_config` / `schema` / `unknown`)은 auto-`REJECT`. |

### Merge

| Skill | 목적 |
|---|---|
| `qqq:merge-mr` | `glab`/`gh` thin wrapper. origin URL에서 host 감지, 미커밋 phase 산출물 commit, `claude-works/<slug>/` → `claude-works-completed/<slug>/` 아카이브, push, 렌더링된 description으로 MR/PR 생성, merge. **리뷰 상태 검증 없음** — host 측 branch protection / required approval이 필수. |

### Auxiliary

| 컴포넌트 | 목적 |
|---|---|
| `qqq:rebase-conflict-resolver` / `qqq:rebase-conflict-resolve` | 진행 중인 git rebase conflict 해소 (Codex-우선, Claude fallback) |
| `qqq:ui-verifier` | `playwright-cli` 기반 브라우저 UI 검증. NLTP 시나리오가 있으면 그것을 계약으로 사용. |
| `qqq:debug-frontend-pw` | `playwright-cli` 기반 브라우저 안에서 원인 조사 |

### Hooks (플러그인 레벨, `hooks/hooks.json`으로 자동 등록)

| Hook | 이벤트 | 목적 |
|---|---|---|
| `qqq-protect-files.sh` | `PreToolUse` (Edit\|Write\|Bash) | `claude-works-completed/` (병합 후 동결 산출물) 대상 Edit/Write/Bash 차단 |
| `qqq-context.sh` | `SessionStart` (startup\|resume\|compact) | 산출물 유무로 현재 phase 추론, 미커밋 `phase{N}-*.md` 경고 |

> v3.0에서 옛 3개 hook을 폐기했다. `qqq-log-event.sh`(JSONL 세션 로그)는 `~/.claude/jobs/<id>/state.json` + `claude logs`로 대체. `qqq-stop-guard.sh`(phase-exit 게이트)는 `skills/code-implement/SKILL.md`의 inline D1− 게이트로 대체. `qqq-notify.sh`(OS 알림)는 Claude Code 내장 agent view로 대체.

---

## Quality model — D1−

qqq의 페이즈 게이팅은 v3.0에서 *의도적으로 약화*됐다. Phase 2 → 3 전환만 자동 게이트(`review_loop_completed: true` 체크, implement skill inline)를 가진다. 다른 페이즈는 모델 자체 판단, PR 리뷰어, 운영자 규율에 의존한다. 이는 **운영 계약**이다:

1. **PR 리뷰가 최종 QA**. phase 게이트는 *권장 흐름*일 뿐, validation이 아니다. 코드 정확성은 MR/PR의 사람 reviewer 책임.
2. **페이즈 스킵은 운영자 판단**. Phase 2 진입에 `phase1-spec.md`가 필수는 아니다 — 다만 계획 품질이 떨어질 뿐.
3. **리뷰 후 계획 수정은 Phase 3 재리뷰를 우회한다**. dispatch 시점 fingerprint 강제 없음 — 단 implementer가 진입 시 plan sha256과 리뷰 시점 fingerprint 불일치를 감지하면 `[warn]` 한 줄을 출력한다 (warn-only, D1−와 호환).

트레이드오프는 `MIGRATION_PLAN.md §9.4`에 기록.

---

## Migration — v3.0 → v3.1

v3.1은 hook을 플러그인 레벨 리소스(`hooks/hooks.json`)로 배포한다. per-project `/qqq:install` 단계가 사라졌고, 신규 사용자는 `claude --plugin-dir <qqq>` (또는 marketplace install)만으로 끝난다.

**기존 사용자**(아무 프로젝트에서 `/qqq:install`을 돌렸던 사람)는 v3.1을 받은 뒤 per-project 사본을 정리해야 한다. **qqq-\* 항목만 제거**하고 같은 배열의 다른 hook 객체는 보존한다.

```bash
# Step 1. settings.json 먼저 백업
cp .claude/settings.json .claude/settings.json.bak

# Step 2. qqq-* hook 스크립트 복사본 제거
rm -f .claude/hooks/qqq-protect-files.sh .claude/hooks/qqq-context.sh
```

Step 3. `.claude/settings.json`을 열어 `command` 필드에 `qqq-protect-files` 또는 `qqq-context`가 들어간 hook 명령 객체만 제거. 구체적으로:

- `.hooks.PreToolUse[*].hooks[]` 안에서 `command`가 `qqq-protect-files.sh`를 포함하는 객체 **제거**.
- `.hooks.SessionStart[*].hooks[]` 안에서 `command`가 `qqq-context.sh`를 포함하는 객체 **제거**.
- 같은 `hooks[]` 배열의 다른 명령 객체는 모두 **보존**.
- **선택 정리** (해당 handler/event가 qqq-only가 됐을 때만): handler의 `hooks[]` 배열이 비면 그 handler 객체를 drop해도 된다. event 배열(예: `PreToolUse`)이 비면 그 event 키 자체를 drop해도 된다. **빈 배열이 Claude Code를 깨뜨린다는 보고는 없으나** ([UNVERIFIED]: schema 문서가 배열 정리를 요구하진 않음) 굳이 손대지 않아도 안전 — `.bak` 백업이 안전망.

정리하지 않으면 옛 per-project hook과 신규 플러그인 레벨 hook이 모두 발화한다. 동작은 동일하지만 `PreToolUse`가 Edit/Write/Bash마다 2번 실행(~10-20ms 추가).

---

## 개발

플러그인 반복 작업 중에는 이 repo 안의 파일을 수정하고 Claude Code에서 `/reload-plugins`를 실행해 변경을 재시작 없이 반영한다. 큰 구조 변경(새 skill/agent 디렉터리)은 Claude Code를 재시작해야 새 디렉터리가 감지된다.

```bash
# syntax-check
bash -n scripts/qqq hooks/qqq-protect-files.sh hooks/qqq-context.sh

# 플러그인 manifest 검증
jq empty .claude-plugin/plugin.json

# 가벼운 스모크
./scripts/qqq verify --cheap-only

# 라이브 스모크 (~2-3분, API 토큰 소모 — disposable bg 세션 사용)
./scripts/qqq verify
```

---

## 참고

- `MIGRATION_PLAN.md` — v3.0 설계 (CLI surface, F1=b, D1−, CLI-9, hook 축소)
- [Claude Code 플러그인 docs](https://code.claude.com/docs/en/plugins)
- [Subagent docs](https://code.claude.com/docs/en/sub-agents) — `qqq:ui-verifier`가 사용하는 persistent agent memory 다룸
- [Skill docs](https://code.claude.com/docs/en/skills) — skill frontmatter와 `${CLAUDE_SKILL_DIR}` 치환 다룸
