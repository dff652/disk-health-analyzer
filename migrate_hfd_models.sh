#!/usr/bin/env bash
# Migrate ~/hfd/llm_models/unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF → /home/data1/llm_models/unsloth/
# Usage:
#   ./migrate_hfd_models.sh check      # Step 1: preflight checks
#   ./migrate_hfd_models.sh compare    # Compare overlapping files
#   ./migrate_hfd_models.sh dry-run    # Step 2: preview rsync
#   ./migrate_hfd_models.sh sync       # Step 3: run rsync (foreground)
#   ./migrate_hfd_models.sh verify     # Step 4: compare source/dest
#   ./migrate_hfd_models.sh finalize   # Step 5: rename source → .bak, create symlink
#   ./migrate_hfd_models.sh rollback   # Restore from .bak (if finalize done but wrong)
#   ./migrate_hfd_models.sh cleanup    # Delete .bak after observation period (frees disk)
#   ./migrate_hfd_models.sh status     # Show current migration state

set -euo pipefail

# ---- configuration ----
SRC_ROOT="/home/dff652/hfd/llm_models/unsloth"
DST_ROOT="/home/data1/llm_models/unsloth"
MODEL_NAME="DeepSeek-R1-Distill-Qwen-32B-GGUF"
SRC_MODEL="$SRC_ROOT/$MODEL_NAME"
DST_MODEL="$DST_ROOT/$MODEL_NAME"
BAK_MODEL="$SRC_ROOT.bak"
LOG_FILE="/home/dff652/dff_project/migrate_hfd_models.log"

# ---- helpers ----
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { echo -e "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }
info() { log "${BLU}[INFO]${NC} $*"; }
ok()   { log "${GRN}[ OK ]${NC} $*"; }
warn() { log "${YLW}[WARN]${NC} $*"; }
err()  { log "${RED}[ERR ]${NC} $*"; }

require_src() {
  if [[ ! -d "$SRC_MODEL" ]]; then
    if [[ -L "$SRC_ROOT" || -L "$SRC_MODEL" ]]; then
      err "Source already migrated (symlink detected). Use 'status' or 'rollback'."
    else
      err "Source not found: $SRC_MODEL"
    fi
    exit 1
  fi
}

# ---- Step 1: preflight ----
cmd_check() {
  info "=== Step 1: preflight checks ==="

  info "[1/5] Source existence"
  if [[ -d "$SRC_MODEL" ]]; then ok "  $SRC_MODEL"
  else err "  NOT FOUND: $SRC_MODEL"; exit 1; fi

  info "[2/5] Destination state"
  if [[ -d "$DST_MODEL" ]]; then ok "  exists: $DST_MODEL"
  else warn "  missing: $DST_MODEL (will be created by rsync)"; fi

  info "[3/5] Disk space"
  local src_size dst_free
  src_size=$(du -sb "$SRC_MODEL" | awk '{print $1}')
  dst_free=$(df -B1 --output=avail /home/data1 | tail -1)
  local src_h dst_h
  src_h=$(numfmt --to=iec "$src_size")
  dst_h=$(numfmt --to=iec "$dst_free")
  log "  source size : $src_h"
  log "  data1 free  : $dst_h"
  if (( dst_free < src_size + 5*1024*1024*1024 )); then
    err "  NOT ENOUGH SPACE (need src + 5G buffer)"
    exit 1
  else
    ok "  space OK (even assuming zero dedup)"
  fi

  info "[4/5] Active file locks on source"
  if command -v lsof &>/dev/null; then
    local lsof_out n
    lsof_out=$({ lsof +D "$SRC_MODEL" 2>/dev/null || true; })
    n=$(printf '%s' "$lsof_out" | grep -c . || true)
    if (( n > 0 )); then
      warn "  $n open handles — migration may conflict:"
      printf '%s\n' "$lsof_out" | head -5 | tee -a "$LOG_FILE"
    else ok "  no open handles"; fi
  else warn "  lsof not available"; fi

  info "[5/5] Hardcoded path references"
  local refs
  refs=$(grep -rl --include='*.py' --include='*.sh' --include='*.yaml' --include='*.yml' --include='*.json' \
    -e "hfd/llm_models" /home/dff652/dff_project /home/dff652/tzzy_project 2>/dev/null | head -5 || true)
  if [[ -n "$refs" ]]; then
    warn "  Files referencing hfd/llm_models:"
    echo "$refs" | tee -a "$LOG_FILE"
    warn "  symlink at original path will keep these working, but worth reviewing"
  else ok "  no hardcoded references found in project dirs"; fi

  ok "preflight complete"
}

# ---- compare overlapping files ----
cmd_compare() {
  require_src
  info "=== Comparing overlapping files ==="
  if [[ ! -d "$DST_MODEL" ]]; then
    info "Destination doesn't exist yet — no overlaps."
    return
  fi
  local f name src_f dst_f src_s dst_s
  for src_f in "$SRC_MODEL"/*; do
    name=$(basename "$src_f")
    dst_f="$DST_MODEL/$name"
    [[ -e "$dst_f" ]] || continue
    if [[ -f "$src_f" && -f "$dst_f" ]]; then
      src_s=$(stat -c%s "$src_f")
      dst_s=$(stat -c%s "$dst_f")
      if [[ "$src_s" == "$dst_s" ]]; then
        ok "  $name : same size ($(numfmt --to=iec $src_s))"
      else
        warn "  $name : DIFFERENT size (src=$(numfmt --to=iec $src_s) dst=$(numfmt --to=iec $dst_s))"
      fi
    elif [[ -d "$src_f" && -d "$dst_f" ]]; then
      warn "  $name/ : both are directories — manual review suggested"
    fi
  done
  info "For files flagged DIFFERENT, run md5sum on both to decide."
}

# ---- Step 2: dry-run ----
cmd_dry_run() {
  require_src
  info "=== Step 2: dry-run rsync ==="
  rsync -ahv --dry-run --ignore-existing --stats \
    "$SRC_MODEL/" "$DST_MODEL/" | tee -a "$LOG_FILE"
}

# ---- Step 3: sync ----
cmd_sync() {
  require_src
  info "=== Step 3: rsync (this may take 10-30+ min) ==="
  mkdir -p "$DST_MODEL"
  rsync -ah --progress --ignore-existing --stats \
    "$SRC_MODEL/" "$DST_MODEL/" 2>&1 | tee -a "$LOG_FILE"
  ok "rsync finished"
}

# ---- Step 4: verify ----
cmd_verify() {
  require_src
  info "=== Step 4: verify ==="
  local src_files dst_files diff_out
  src_files=$(ls -1 "$SRC_MODEL" | sort)
  dst_files=$(ls -1 "$DST_MODEL" | sort)
  diff_out=$(diff <(echo "$src_files") <(echo "$dst_files") || true)
  if [[ -z "$diff_out" ]]; then
    ok "file lists identical"
  else
    warn "file lists differ:"
    echo "$diff_out" | tee -a "$LOG_FILE"
  fi

  local src_size dst_size
  src_size=$(du -sb "$SRC_MODEL" | awk '{print $1}')
  dst_size=$(du -sb "$DST_MODEL" | awk '{print $1}')
  log "  src total: $(numfmt --to=iec $src_size)"
  log "  dst total: $(numfmt --to=iec $dst_size)"
  if (( dst_size >= src_size )); then
    ok "dst >= src (expected: dst may contain extra files)"
  else
    err "dst < src : destination is missing data!"
    exit 1
  fi

  info "Spot-check md5 of largest unique file"
  local biggest
  biggest=$(find "$SRC_MODEL" -maxdepth 1 -type f -name '*.gguf' -printf '%s %p\n' \
            | sort -rn | awk 'NR==1{print $2}')
  if [[ -n "$biggest" ]]; then
    local name=$(basename "$biggest")
    local dst_twin="$DST_MODEL/$name"
    if [[ -f "$dst_twin" ]]; then
      info "  comparing md5 of $name (may take a few minutes)..."
      local s_md d_md
      s_md=$(md5sum "$biggest" | awk '{print $1}')
      d_md=$(md5sum "$dst_twin" | awk '{print $1}')
      if [[ "$s_md" == "$d_md" ]]; then ok "  md5 match: $s_md"
      else err "  md5 MISMATCH! src=$s_md dst=$d_md"; exit 1; fi
    fi
  fi
  ok "verify passed"
}

# ---- Step 5: finalize (rename + symlink) ----
cmd_finalize() {
  require_src
  info "=== Step 5: finalize (mv → .bak, create symlink) ==="
  if [[ -e "$BAK_MODEL" ]]; then
    err "backup already exists: $BAK_MODEL — aborting to avoid overwriting"
    exit 1
  fi
  info "Renaming source to backup:"
  mv "$SRC_ROOT" "$BAK_MODEL"
  ok "  $SRC_ROOT → $BAK_MODEL"

  info "Creating symlink:"
  ln -s "$DST_ROOT" "$SRC_ROOT"
  ok "  $SRC_ROOT → $DST_ROOT"

  info "Verifying symlink target readable:"
  if ls "$SRC_ROOT/$MODEL_NAME/" &>/dev/null; then
    ok "  symlink works"
  else
    err "  symlink NOT working — run 'rollback' immediately"
    exit 1
  fi

  warn "Backup kept at $BAK_MODEL — delete with './migrate_hfd_models.sh cleanup' AFTER observation period"
  df -h / /home/data1 | tee -a "$LOG_FILE"
}

# ---- rollback ----
cmd_rollback() {
  info "=== Rollback ==="
  if [[ ! -e "$BAK_MODEL" ]]; then
    err "no backup found at $BAK_MODEL"
    exit 1
  fi
  if [[ -L "$SRC_ROOT" ]]; then
    info "Removing symlink"
    rm "$SRC_ROOT"
  elif [[ -e "$SRC_ROOT" ]]; then
    err "$SRC_ROOT exists but is not a symlink — manual intervention required"
    exit 1
  fi
  info "Restoring backup"
  mv "$BAK_MODEL" "$SRC_ROOT"
  ok "rollback complete"
}

# ---- cleanup backup ----
cmd_cleanup() {
  info "=== Cleanup backup ==="
  if [[ ! -e "$BAK_MODEL" ]]; then
    warn "no backup to clean"
    return
  fi
  if [[ ! -L "$SRC_ROOT" ]]; then
    err "symlink not in place yet — refusing to delete backup"
    exit 1
  fi
  if ! ls "$SRC_ROOT/$MODEL_NAME/" &>/dev/null; then
    err "symlink target not readable — refusing to delete backup"
    exit 1
  fi
  local sz
  sz=$(du -sh "$BAK_MODEL" | awk '{print $1}')
  info "About to rm -rf $BAK_MODEL ($sz)"
  read -r -p "Confirm? (yes/NO): " ans
  [[ "$ans" == "yes" ]] || { info "aborted"; exit 0; }
  rm -rf "$BAK_MODEL"
  ok "backup deleted"
  df -h / | tee -a "$LOG_FILE"
}

# ---- status ----
cmd_status() {
  info "=== Status ==="
  if [[ -L "$SRC_ROOT" ]]; then
    log "  $SRC_ROOT : symlink → $(readlink "$SRC_ROOT")"
  elif [[ -d "$SRC_ROOT" ]]; then
    log "  $SRC_ROOT : real directory ($(du -sh "$SRC_ROOT" | awk '{print $1}'))"
  else
    log "  $SRC_ROOT : missing"
  fi
  [[ -e "$BAK_MODEL" ]] && log "  backup    : $BAK_MODEL ($(du -sh "$BAK_MODEL" | awk '{print $1}'))" \
                        || log "  backup    : (none)"
  [[ -d "$DST_MODEL" ]] && log "  dst model : $DST_MODEL ($(du -sh "$DST_MODEL" | awk '{print $1}'))"
  df -h / /home/data1 | tee -a "$LOG_FILE"
}

# ---- dispatch ----
case "${1:-}" in
  check)    cmd_check ;;
  compare)  cmd_compare ;;
  dry-run)  cmd_dry_run ;;
  sync)     cmd_sync ;;
  verify)   cmd_verify ;;
  finalize) cmd_finalize ;;
  rollback) cmd_rollback ;;
  cleanup)  cmd_cleanup ;;
  status)   cmd_status ;;
  *)
    cat <<EOF
Usage: $0 {check|compare|dry-run|sync|verify|finalize|rollback|cleanup|status}

Recommended order:
  1. check      — preflight (space, locks, references)
  2. compare    — show overlapping files and size matches
  3. dry-run    — preview rsync (no changes)
  4. sync       — execute rsync (--ignore-existing, won't overwrite data1)
  5. verify     — confirm dst ≥ src and spot-check md5
  6. finalize   — rename src to .bak, create symlink
  7. (observe)  — run workloads, confirm no issues
  8. cleanup    — delete .bak and actually free disk

Any time:   status     — show current state
If wrong:   rollback   — undo finalize (restores from .bak)
EOF
    exit 1
    ;;
esac
