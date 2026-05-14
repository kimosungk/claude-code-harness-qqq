# qqq Update Guide

`~/private/claude-code-harness-qqq` 를 단일 source-of-truth 로 운영하면서, 같은 머신의 다른 레포에서 최신 qqq 를 git 기반으로 받아 쓰는 절차를 설명한다.

## 운영 모델

```
~/private/claude-code-harness-qqq                            (개발 트리, push 대상)
                ↓ git push                ↓ install-qqq-hooks.sh
        GitHub origin                <target>/.claude/hooks/qqq-*.sh
                ↓ git pull
~/.claude/plugins/local/hskim-plugins/plugins/qqq            (marketplace 사본)
                ↓ /plugin install → cache
~/.claude/plugins/cache/hskim-plugins/qqq/<ver>              (Claude Code 가 로드)
```

## 디렉토리 역할

| 역할 | 경로 | 갱신 방법 |
|---|---|---|
| 개발 트리 | `~/private/claude-code-harness-qqq` | 직접 편집 + `git push` |
| marketplace 사본 | `~/.claude/plugins/local/hskim-plugins/plugins/qqq` | `git pull --ff-only` |
| Claude Code cache | `~/.claude/plugins/cache/hskim-plugins/qqq/<version>` | `/plugin install` 사이클 (수동 편집 금지) |
| target 레포 hooks | `<target>/.claude/hooks/qqq-*.sh` | `install-qqq-hooks.sh` 재실행 |

## 일상 업데이트 절차

### 1) 개발 트리에서 작업 + push

```bash
cd ~/private/claude-code-harness-qqq
# 코드 수정...
git add <files>
git commit -m "..."
git push
```

### 2) marketplace 사본 갱신

```bash
git -C ~/.claude/plugins/local/hskim-plugins/plugins/qqq pull --ff-only
```

`~/.zshrc` 에 함수로 두면 한 줄이 줄어든다.

```bash
qqq-pull() {
  git -C ~/.claude/plugins/local/hskim-plugins/plugins/qqq pull --ff-only
}
```

### 3) Claude Code 안에서 cache 재생성

```
/plugin uninstall qqq@hskim-plugins
/plugin install qqq@hskim-plugins
```

`/reload-plugins` 만으로는 cache 가 갱신되지 않는다 — uninstall + install 사이클이 필수.

### 4) Hook 갱신 (필요한 target 레포마다)

두 가지 entrypoint 중 선택:

#### A. Claude Code 안에서 (권장 — 짧음)

target 레포에서 띄운 Claude Code 세션에서:

```
/qqq:install
```

(다른 target 을 지정하려면 `/qqq:install /path/to/target`.) `disable-model-invocation: true` 인 skill 이라 사용자가 명시적으로 입력해야 동작한다.

#### B. 셸에서

```bash
bash ~/private/claude-code-harness-qqq/scripts/install-qqq-hooks.sh <target-repo>
```

#### A vs B 의 중요한 차이

| 항목 | A: `/qqq:install` | B: 셸 명령 |
|---|---|---|
| 사용하는 source | plugin cache (`~/.claude/plugins/cache/hskim-plugins/qqq/<ver>/hooks/`) | private 트리 (`~/private/claude-code-harness-qqq/hooks/`) |
| push 필요? | ✅ — push + marketplace pull + cache 재생성 필요 | ❌ — private 트리 직접 사용, push 안 한 변경도 반영 |
| 일관성 | release 된 버전이 어디서나 동일하게 깔림 | 로컬 작업 트리에 종속 |

A 는 시나리오 2 (push 후 다른 target 으로 배포) 용. B 는 시나리오 1 (개발 중, push 전 빠른 검증) 용.

스크립트가 `.claude/settings.json` 백업과 hook 파일 5개 교체를 처리한다.

### 5) target 레포에서 사용

```bash
cd <target-repo>
claude          # qqq slash command + hooks 모두 동작
```

## Hook 만 수정한 경우 (push 가 필요한가?)

답: **선택한 entrypoint 에 따라 다르다.**

- **셸 방식 (B)**: `install-qqq-hooks.sh` 는 private 트리의 `hooks/` 디렉토리에서 직접 복사하므로 push 안 해도 target 에 즉시 반영. 빠른 개발 사이클에 적합.
- **`/qqq:install` 방식 (A)**: skill 내부에서도 결국 `install-qqq-hooks.sh` 를 호출하지만, **plugin cache 안의 사본**을 부른다. cache 가 갱신되지 않은 상태면 옛 hook 이 깔린다. 즉 push + marketplace pull + `/plugin uninstall; /plugin install` 사이클이 선행되어야 의미가 있음.

같은 머신에서 본인만 쓰는 dev cycle 이라면 셸 방식 (B) 가 빠름. push 후 다른 머신/target 으로 배포할 때는 A 가 자연스럽다.

마지막으로 marketplace 사본 자체도 옛 hook 을 유지하므로, 다른 머신/사용자가 같은 hook 을 받으려면 push 후 그쪽에서도 marketplace pull 이 필요하다.

## Troubleshooting

### `/qqq:*` slash command 가 안 보인다
1. `/plugin` 으로 `qqq@hskim-plugins` 설치 상태 확인.
2. 미설치라면 `/plugin install qqq@hskim-plugins`.
3. 설치돼 있는데도 안 보이면 `/reload-plugins`.

### 수정한 내용이 cache 에 안 들어왔다
3단계(`/plugin uninstall` → `/plugin install`)를 다시 실행. `/reload-plugins` 만으로는 cache 가 안 갱신된다 (Claude Code 의 현재 동작, 라이브 테스트로 확인됨).

### marketplace 사본 `git pull` 시 충돌
marketplace 사본을 수동 편집하지 말 것. 충돌 발생 시:
```bash
cd ~/.claude/plugins/local/hskim-plugins/plugins/qqq
git stash
git pull --ff-only
git stash drop   # 수정 사항을 버릴 때만
```

### hook 이 동작하지 않는다
```bash
bash ~/private/claude-code-harness-qqq/scripts/validate-qqq-hooks.sh <target-repo>
```
실패 시 메시지에 따라 `install-qqq-hooks.sh` 재실행 또는 `<target>/.claude/settings.json` 백업본 (`settings.json.bak.*`) 복원.

### marketplace 사본을 통째로 다시 만들고 싶다
```bash
rm -rf ~/.claude/plugins/cache/hskim-plugins/qqq
rm -rf ~/.claude/plugins/local/hskim-plugins/plugins/qqq
cd ~/.claude/plugins/local/hskim-plugins/plugins
git clone https://github.com/kimosungk/claude-code-harness-qqq.git qqq
```
이후 Claude Code 안에서 `/plugin install qqq@hskim-plugins`.

## 가정 / 제한

- **가정**: 단일 사용자, 단일 머신 운영. private 트리가 GitHub origin 과 `push` / `pull` 가능한 상태.
- **가정**: marketplace 매니페스트(`~/.claude/plugins/local/hskim-plugins/.claude-plugin/marketplace.json`)에 `qqq` 항목이 등록되어 있음.
- **제한**: cache 갱신은 `/plugin install` 사이클이 유일한 표준 경로(현재 Claude Code 버전 기준). 향후 `/plugin update` 같은 명령이 도입되면 절차가 단축될 수 있다.
- **제한**: target 레포의 hooks 는 자동 추적되지 않는다. plugin 코드와 함께 hook 도 수정했다면 4) 단계를 잊지 말 것.

## 다른 머신으로 옮길 때

1. 그 머신에 `~/private/claude-code-harness-qqq` clone.
2. 그 머신의 marketplace 사본도 별도 clone:
   ```bash
   mkdir -p ~/.claude/plugins/local/hskim-plugins/plugins
   cd ~/.claude/plugins/local/hskim-plugins/plugins
   git clone https://github.com/kimosungk/claude-code-harness-qqq.git qqq
   ```
3. marketplace 매니페스트 생성 또는 갱신 (이 가이드의 "marketplace 사본을 통째로 다시 만들고 싶다" 절 참조).
4. Claude Code 안에서 `/plugin install qqq@hskim-plugins`.
5. 각 target 레포에서 `bash scripts/install-qqq-hooks.sh <target>`.

## 참조

- `README.md` — plugin 전체 개요
- `qqq-hooks-companion-pack.md` — hook 설치/검증 상세
- [Claude Code plugin docs](https://code.claude.com/docs/en/plugins)

## Design Note — 왜 `hooks/hooks.json` 자동 등록을 안 쓰는가

Claude Code plugin spec 은 plugin root 의 `hooks/hooks.json` 파일로 hook 을 자동 등록하는 메커니즘을 지원한다 (출처: [공식 plugin docs](https://code.claude.com/docs/en/plugins) Migration 절 — *"Hooks in `settings.json` → Hooks in `hooks/hooks.json`"*). 그 방식을 채택하면 `/plugin install` 만으로 hook 도 함께 등록된다.

qqq 는 의도적으로 이 메커니즘을 사용하지 않는다:

1. **target-local scope 유지** — plugin auto-register 는 user-level 로 hook 이 깔리지만, qqq hook 은 target 프로젝트의 `.qqq/`, `claude-works/`, `phase0-issue.md` 같은 artifact 를 보호하므로 해당 프로젝트에서만 활성화되는 것이 의미 있다.
2. **Mixed handler 보존** — target 의 `.claude/settings.json` 에 사용자가 추가한 비-qqq hook 과 공존해야 한다. `install-qqq-hooks.sh` 의 merge 로직은 qqq-owned command 만 strip 후 재삽입한다.
3. **라이프사이클 분리** — `/plugin uninstall` 이 target hook 까지 같이 사라지게 만들면 안 된다.
4. **target 별 설치/해제** — 어느 프로젝트엔 깔고 어느 프로젝트엔 안 깔 수 있어야 한다.

`qqq-hooks-companion-pack.md` 의 Non-Goals 가 이 결정을 명시한다: *"No install into `~/.claude/settings.json`"*.
