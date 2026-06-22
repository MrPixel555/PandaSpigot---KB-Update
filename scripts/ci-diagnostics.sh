#!/usr/bin/env bash
set +e

OUT="ci-diagnostics"
rm -rf "$OUT"
mkdir -p "$OUT"

{
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pwd=$(pwd)"
  echo "runner=${RUNNER_OS:-unknown}"
  echo "repo=${GITHUB_REPOSITORY:-unknown}"
  echo "sha=${GITHUB_SHA:-unknown}"
  echo "ref=${GITHUB_REF:-unknown}"
  echo "run_id=${GITHUB_RUN_ID:-unknown}"
  echo "run_number=${GITHUB_RUN_NUMBER:-unknown}"
} > "$OUT/context.txt" 2>&1 || true

git status --short > "$OUT/root-git-status-short.txt" 2>&1 || true
git status > "$OUT/root-git-status.txt" 2>&1 || true
git log -1 --decorate --stat > "$OUT/root-last-commit.txt" 2>&1 || true
git ls-files -s > "$OUT/root-ls-files-s.txt" 2>&1 || true

# Directory and file inventories. The previous diagnostic used only file maxdepth
# and missed generated repositories when they were nested deeper.
find . -maxdepth 6 -type d | sort > "$OUT/root-dir-list-depth6.txt" 2>&1 || true
find . -maxdepth 6 -type f | sort > "$OUT/root-file-list-depth6.txt" 2>&1 || true
find . -type d \( -name PandaSpigot-Server -o -name PandaSpigot-API -o -name PaperSpigot-Server -o -name PaperSpigot-API -o -name rebase-apply -o -name rebase-merge \) -print | sort > "$OUT/generated-repo-dir-candidates.txt" 2>&1 || true

mkdir -p "$OUT/root-files"
cp -a .github "$OUT/root-files/github" 2>/dev/null || true
cp -a scripts "$OUT/root-files/scripts" 2>/dev/null || true
cp -a panda "$OUT/root-files/panda" 2>/dev/null || true
cp -a patches "$OUT/root-files/patches" 2>/dev/null || true
cp -a .gitmodules "$OUT/root-files/gitmodules" 2>/dev/null || true

capture_git_repo() {
  local repo_path="$1"
  local safe_name
  safe_name=$(printf '%s' "$repo_path" | sed 's#^./##; s#[/.]#_#g')
  local dst="$OUT/generated/$safe_name"
  mkdir -p "$dst"

  {
    echo "repo_path=$repo_path"
    echo "safe_name=$safe_name"
  } > "$dst/context.txt" 2>&1 || true

  (
    cd "$repo_path" || exit 0
    git status --short > "$(pwd -P)/../../$dst/git-status-short.txt" 2>&1 || true
  ) 2>/dev/null || true

  (
    cd "$repo_path" || exit 0
    git status > "$(pwd -P)/../../$dst/git-status.txt" 2>&1 || true
  ) 2>/dev/null || true

  (
    cd "$repo_path" || exit 0
    git log --oneline --decorate -40 > "$(pwd -P)/../../$dst/git-log-40.txt" 2>&1 || true
    git rev-parse HEAD > "$(pwd -P)/../../$dst/HEAD.txt" 2>&1 || true
    git ls-files -s > "$(pwd -P)/../../$dst/ls-files-s.txt" 2>&1 || true
    git am --show-current-patch=diff > "$(pwd -P)/../../$dst/current-am-patch.diff" 2>&1 || true
    git am --show-current-patch=raw > "$(pwd -P)/../../$dst/current-am-patch.raw" 2>&1 || true
  ) 2>/dev/null || true

  # Copy git-am/rebase failure metadata.
  cp -a "$repo_path/.git/rebase-apply" "$dst/rebase-apply" 2>/dev/null || true
  cp -a "$repo_path/.git/rebase-merge" "$dst/rebase-merge" 2>/dev/null || true
  cp -a "$repo_path/.git/patch-apply-failed" "$dst/patch-apply-failed" 2>/dev/null || true

  # Copy reject files, if any.
  mkdir -p "$dst/rejects"
  find "$repo_path" -name '*.rej' -type f -exec cp --parents '{}' "$dst/rejects" \; 2>/dev/null || true

  # Copy the specific NMS/config files we are touching.
  mkdir -p "$dst/source-files"
  for f in \
    src/main/java/net/minecraft/server/EntityHuman.java \
    src/main/java/net/minecraft/server/EntityLiving.java \
    src/main/java/net/minecraft/server/EntityArrow.java \
    src/main/java/net/minecraft/server/EntityProjectile.java \
    src/main/java/net/minecraft/server/EntityFishingHook.java \
    src/main/java/net/minecraft/server/Explosion.java \
    src/main/java/net/minecraft/server/Entity.java \
    src/main/java/net/minecraft/server/EntityPlayer.java \
    src/main/java/com/hpfxd/pandaspigot/config/PandaSpigotConfig.java \
    src/main/java/com/hpfxd/pandaspigot/config/PandaSpigotWorldConfig.java; do
    if [ -f "$repo_path/$f" ]; then
      mkdir -p "$dst/source-files/$(dirname "$f")"
      cp "$repo_path/$f" "$dst/source-files/$f" 2>/dev/null || true
      nl -ba "$repo_path/$f" > "$dst/source-files/$f.numbered.txt" 2>&1 || true
    fi
  done

  # Diff for touched files, helpful if git-am partially applied anything.
  (
    cd "$repo_path" || exit 0
    git diff -- src/main/java/net/minecraft/server/EntityHuman.java \
      src/main/java/net/minecraft/server/EntityLiving.java \
      src/main/java/net/minecraft/server/EntityArrow.java \
      src/main/java/net/minecraft/server/EntityProjectile.java \
      src/main/java/net/minecraft/server/EntityFishingHook.java \
      src/main/java/net/minecraft/server/Explosion.java \
      src/main/java/com/hpfxd/pandaspigot/config/PandaSpigotConfig.java \
      src/main/java/com/hpfxd/pandaspigot/config/PandaSpigotWorldConfig.java \
      > "$(pwd -P)/../../$dst/touched-files-diff.txt" 2>&1 || true
  ) 2>/dev/null || true

  # Full generated repository archive. This is the decisive payload.
  tar -czf "$dst/full-repo.tar.gz" "$repo_path" 2> "$dst/tar-full-repo.stderr.txt" || true
}

mkdir -p "$OUT/generated"
while IFS= read -r repo_dir; do
  [ -n "$repo_dir" ] || continue
  capture_git_repo "$repo_dir"
done < "$OUT/generated-repo-dir-candidates.txt"

# Explicit fallback locations used by Panda/Paper patch tooling.
for repo_dir in \
  ./PandaSpigot-Server \
  ./PandaSpigot-API \
  ./base/Paper/PaperSpigot-Server \
  ./base/Paper/PaperSpigot-API \
  ./base/Paper/Spigot-Server \
  ./base/Paper/Spigot-API; do
  if [ -d "$repo_dir" ] && ! grep -Fxq "$repo_dir" "$OUT/generated-repo-dir-candidates.txt"; then
    capture_git_repo "$repo_dir"
  fi
done

# Include top-level setup/apply logs when user creates them later.
for f in setup.log patch.log build.log; do
  cp -a "$f" "$OUT/$f" 2>/dev/null || true
done

tar -czf ci-diagnostics.tar.gz "$OUT" 2> "$OUT/tar-ci-diagnostics.stderr.txt" || true

echo "Diagnostic collection finished. Generated repo candidates:"
cat "$OUT/generated-repo-dir-candidates.txt" || true
echo "Diagnostic files:"
find "$OUT" -maxdepth 4 -type f | sort | sed -n '1,240p' || true
