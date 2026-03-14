---
name: sync-skills
description: Use this skill whenever a skill in the project's skills/ folder has been created or modified. Copies all project-owned skill files to the skill-creator plugin cache so the changes take effect immediately.
---

# Sync Skills

The project's `skills/` directory is the source of truth for all project-owned skills. The skill-creator plugin loads skills from its cache at:

```
~/.claude/plugins/cache/claude-plugins-official/skill-creator/{hash}/skills/
```

Whenever a skill in `skills/` is created or modified, copy it to the cache so the updated version is used in the current session.

## Steps

### 1. Find the current cache path

```bash
ls ~/.claude/plugins/cache/claude-plugins-official/skill-creator/
```

This prints the current hash directory (e.g. `d5c15b861cd2`). Use it in the next step.

### 2. Sync all project skills to the cache

For each skill directory under `skills/`, copy the SKILL.md to the corresponding location in the cache. Example:

```bash
cp skills/build-and-smoke-test/SKILL.md ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/build-and-smoke-test/SKILL.md
cp skills/zig-guard-clause/SKILL.md ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/zig-guard-clause/SKILL.md
cp skills/zig-defensive-logging/SKILL.md ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/zig-defensive-logging/SKILL.md
cp skills/code-style/SKILL.md ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/code-style/SKILL.md
cp skills/sync-skills/SKILL.md ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/sync-skills/SKILL.md
```

If new skills have been added to `skills/`, include them here and also create the destination directory if needed (`mkdir -p`).

### 3. Update the hash if needed

If the hash from step 1 differs from the one above, update the `cp` commands in this skill file to use the new hash, then re-sync.

### 4. Confirm

List the cache skills directory to confirm all files are present:

```bash
ls ~/.claude/plugins/cache/claude-plugins-official/skill-creator/d5c15b861cd2/skills/
```
