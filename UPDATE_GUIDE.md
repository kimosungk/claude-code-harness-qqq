# qqq Update Guide

`~/private/claude-code-harness-qqq` 가 단일 source-of-truth. 같은 머신의 다른 레포에서 최신 qqq 를 git 으로 받아 쓰는 절차.

## 자산 위치

| 역할 | 경로 | 갱신 |
|---|---|---|
| 개발 트리 | `~/private/claude-code-harness-qqq` | 편집 + `git push` |
| marketplace 사본 | `~/.claude/plugins/local/hskim-plugins/plugins/qqq` | `git pull --ff-only` |
| Claude Code cache | `~/.claude/plugins/cache/hskim-plugins/qqq/<ver>` | `/plugin install` 사이클 (수동 편집 금지) |
| target hooks | `<target>/.claude/hooks/qqq-*.sh` | `/qqq:install` 또는 `install-qqq-hooks.sh` |

## 업데이트 절차

```bash
# 1. 개발 + push
cd ~/private/claude-code-harness-qqq
git commit -am "..." && git push

# 2. marketplace 사본 pull
git -C ~/.claude/plugins/local/hskim-plugins/plugins/qqq pull --ff-only
```

Claude Code 안에서:

```
# 3. cache 재생성 (필수 — /reload-plugins 로는 불충분)
/plugin uninstall qqq@hskim-plugins
/plugin install qqq@hskim-plugins

# 4. target 레포마다 hook 갱신
/qqq:install                    # 현재 cwd
/qqq:install /path/to/target    # 다른 target
```

## Hook entrypoint A vs B

| | A: `/qqq:install` | B: `bash scripts/install-qqq-hooks.sh <target>` |
|---|---|---|
| 사용 source | plugin cache | private 트리 |
| push 필요 | ✅ | ❌ |
| 용도 | push 후 배포 | 개발 중 빠른 검증 |

## Troubleshooting

| 증상 | 해결 |
|---|---|
| `/qqq:*` 안 보임 | `/plugin install qqq@hskim-plugins` → `/reload-plugins` |
| 수정이 반영 안 됨 | `/plugin uninstall; /plugin install` 사이클. `/reload-plugins` 만으로는 cache 미갱신 |
| hook 동작 X | `bash scripts/validate-qqq-hooks.sh <target>` 로 진단. 필요시 `install-qqq-hooks.sh` 재실행 또는 `<target>/.claude/settings.json.bak.*` 복원 |
| marketplace pull 충돌 | `git stash; git pull --ff-only; git stash drop` (수동 편집 금지) |
| marketplace 사본 초기화 | `rm -rf` 후 `git clone https://github.com/kimosungk/claude-code-harness-qqq.git`, 그 다음 `/plugin install` |

## Design Note — `hooks/hooks.json` 자동 등록 미사용

Claude Code plugin spec 은 `hooks/hooks.json` 자동 등록을 지원하지만([공식 docs](https://code.claude.com/docs/en/plugins)), qqq 는 미사용:

- **target-local scope** — qqq hook 은 프로젝트별 artifact(`<target>/.qqq/`, `claude-works/`) 보호. user-level 등록은 부적합
- **Mixed handler 보존** — target settings.json 의 비-qqq hook 과 공존 필요
- **라이프사이클 분리** — `/plugin uninstall` 이 target hook 까지 지우면 안 됨

`qqq-hooks-companion-pack.md` Non-Goals: *"No install into `~/.claude/settings.json`"*.

## 가정

- 단일 사용자/머신. private 트리가 GitHub origin 과 push/pull 가능.
- marketplace 매니페스트에 `qqq` 항목 등록됨.
- cache 갱신은 `/plugin install` 사이클이 유일한 표준 경로(현 Claude Code 버전 기준).
