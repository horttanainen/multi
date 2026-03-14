---
name: sync-skills
description: Use this skill whenever a skill in the project's skills/ folder has been created or modified. Copies all project-owned skill files to the agent's skill cache so the changes take effect immediately.
---

# Sync Skills

The project's `skills/` directory is the source of truth for all project-owned skills. The AI coding agent you are running in loads skills from a cache or skills directory specific to that agent.

Whenever a skill in `skills/` is created or modified, copy each skill's SKILL.md to the agent's skill cache so the updated version is used.

## Steps

### 1. Discover the agent's skill cache location

Find where the current agent stores and reads its skills from. This varies by agent:

- **Claude Code (skill-creator plugin):** `~/.claude/plugins/cache/claude-plugins-official/skill-creator/<hash>/skills/<skill-name>/SKILL.md` — list the hash directory first with `ls ~/.claude/plugins/cache/claude-plugins-official/skill-creator/`
- **Codex:** `~/.codex/skills/<skill-name>/SKILL.md`
- **Other agents:** Check the agent's documentation or configuration for its skill storage path.

### 2. Sync all project skills to the cache

For each skill directory under `skills/`, copy its SKILL.md to the corresponding location in the agent's cache. Create destination directories with `mkdir -p` if they don't exist.

Example (adjust paths for your agent):

```bash
for skill_dir in skills/*/; do
  skill_name=$(basename "$skill_dir")
  mkdir -p "<agent-cache-path>/skills/$skill_name"
  cp "$skill_dir/SKILL.md" "<agent-cache-path>/skills/$skill_name/SKILL.md"
done
```

### 3. Confirm

List the cache skills directory to confirm all files are present:

```bash
ls <agent-cache-path>/skills/
```
