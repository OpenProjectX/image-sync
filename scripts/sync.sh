#!/usr/bin/env bash
#
# Mirror the images declared in images.yaml into ghcr.io/openprojectx
# using skopeo.
#
# Environment variables:
#   GHCR_NAMESPACE   Destination namespace      (default: ghcr.io/openprojectx)
#   IMAGES_FILE      Path to the image list     (default: images.yaml)
#   DRY_RUN          If "true", print actions instead of running skopeo
#   FORCE            If "true", re-copy even when the destination is up to date
#   GHCR_USERNAME    Username for skopeo login  (optional; login skipped if unset)
#   GHCR_TOKEN       Token/password for login   (optional; login skipped if unset)
#
set -euo pipefail

GHCR_NAMESPACE="${GHCR_NAMESPACE:-ghcr.io/openprojectx}"
IMAGES_FILE="${IMAGES_FILE:-images.yaml}"
DRY_RUN="${DRY_RUN:-false}"

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v skopeo >/dev/null 2>&1 || die "skopeo is not installed"
command -v yq     >/dev/null 2>&1 || die "yq is not installed"
[[ -f "$IMAGES_FILE" ]]           || die "images file not found: $IMAGES_FILE"

# Optionally authenticate to GHCR so we can push.
if [[ -n "${GHCR_USERNAME:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  log "Logging in to ghcr.io as ${GHCR_USERNAME}"
  echo "$GHCR_TOKEN" | skopeo login ghcr.io -u "$GHCR_USERNAME" --password-stdin
else
  warn "GHCR_USERNAME/GHCR_TOKEN not set; assuming skopeo is already authenticated"
fi

# Map a source registry host to a short, friendly namespace so that images
# with the same name from different registries don't collide in GHCR.
# Unknown hosts fall back to the host itself (with any port colon sanitized).
alias_for() {
  case "$1" in
    docker.io|index.docker.io|registry-1.docker.io) echo "dockerhub" ;;
    registry.k8s.io|k8s.gcr.io)                      echo "k8s" ;;
    quay.io)                                         echo "quay" ;;
    gcr.io)                                          echo "gcr" ;;
    ghcr.io)                                         echo "ghcr" ;;
    mcr.microsoft.com)                               echo "mcr" ;;
    public.ecr.aws)                                  echo "ecr" ;;
    *)                                               echo "${1//:/_}" ;;
  esac
}

# Derive a default target ("alias/repo:tag") from a source reference when the
# config does not specify one explicitly. The source registry is encoded as a
# leading namespace and the full upstream repo path is preserved, e.g.
#   docker.io/library/busybox:1.36 -> dockerhub/library/busybox:1.36
#   registry.k8s.io/pause:3.10     -> k8s/pause:3.10
default_target() {
  local source="$1" host rest first repo tag lastseg

  # Split off the registry host. A leading component is a host only if it
  # looks like one (contains a dot or port colon, or is localhost); otherwise
  # the reference is a Docker Hub shorthand.
  if [[ "$source" == */* ]]; then
    first="${source%%/*}"
    if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
      host="$first"
      rest="${source#*/}"
    else
      host="docker.io"
      rest="$source"
    fi
  else
    host="docker.io"
    rest="library/$source"      # e.g. "nginx" -> "library/nginx"
  fi

  # Separate the tag/digest from the repo path (the tag is the part after the
  # last colon, but only when that colon follows the last path separator).
  if [[ "$rest" == *@* ]]; then
    repo="${rest%@*}"
    tag="latest"                # digest pulls have no tag; override 'target' to set one
  else
    lastseg="${rest##*/}"
    if [[ "$lastseg" == *:* ]]; then
      tag="${lastseg##*:}"
      repo="${rest%:*}"
    else
      repo="$rest"
      tag="latest"
    fi
  fi

  printf '%s/%s:%s' "$(alias_for "$host")" "$repo" "$tag"
}

count="$(yq '.images | length' "$IMAGES_FILE")"
[[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "no images found in $IMAGES_FILE"
log "Found $count image(s) to mirror into $GHCR_NAMESPACE"

# Return success when the destination already holds the exact same manifest
# as the source, so the image can be skipped (a cross-run "pull cache"). Set
# FORCE=true to always re-copy. The raw manifests are compared byte-for-byte,
# which works for both single images and multi-arch manifest lists.
already_mirrored() {
  local source="$1" dest="$2" src_raw dst_raw
  dst_raw="$(skopeo inspect --raw "docker://$dest" 2>/dev/null)" || return 1
  src_raw="$(skopeo inspect --raw "docker://$source" 2>/dev/null)" || return 1
  [[ -n "$src_raw" && "$src_raw" == "$dst_raw" ]]
}

failures=0
skipped=0
for i in $(seq 0 $((count - 1))); do
  source="$(yq -r ".images[$i].source" "$IMAGES_FILE")"
  target="$(yq -r ".images[$i].target // \"\"" "$IMAGES_FILE")"
  all="$(yq -r ".images[$i].all // \"true\"" "$IMAGES_FILE")"

  [[ -n "$source" && "$source" != "null" ]] || die "images[$i] is missing 'source'"
  [[ -n "$target" ]] || target="$(default_target "$source")"

  dest="${GHCR_NAMESPACE}/${target}"

  copy_args=(--retry-times 3)
  [[ "$all" == "true" ]] && copy_args+=(--all)

  log "[$((i + 1))/$count] $source  ->  $dest"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    DRY_RUN: skopeo copy ${copy_args[*]} docker://$source docker://$dest"
    continue
  fi

  if [[ "${FORCE:-false}" != "true" ]] && already_mirrored "$source" "$dest"; then
    echo "    cache hit: destination already up to date, skipping"
    skipped=$((skipped + 1))
    continue
  fi

  if ! skopeo copy "${copy_args[@]}" "docker://$source" "docker://$dest"; then
    warn "failed to copy $source"
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  die "$failures image(s) failed to sync ($skipped cached, $((count - failures - skipped)) copied)"
fi
log "All images synced successfully ($skipped cached, $((count - skipped)) copied)"
