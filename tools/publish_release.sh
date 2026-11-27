#!/usr/bin/env bash
#
# publish_release.sh — Publish the packages of a v* tag as a GitHub release
#
# Used by the release job in .github/workflows/build.yml. The release is
# created in this repository, for the tag that was pushed.
#
#   vX.Y.Z-rcN   pre-release, published right away
#   vX.Y.Z       draft; a maintainer checks and publishes it
#
# The packages are uploaded to a draft first, so a release never appears with
# only part of its files. A re-run for the same tag fills in the draft again;
# a release that is already published is never changed.
#
# Usage:
#   tools/publish_release.sh --tag TAG --packages DIR --distros "DISTRO..." \
#       [options]
#
# Options:
#   --tag TAG          vX.Y.Z or vX.Y.Z-rcN; must match the packages' version
#   --repo OWNER/NAME  repository that receives the release; the tag must
#                      already be there (default: $GITHUB_REPOSITORY)
#   --packages DIR     directory searched for .deb, .dmg, .zip and .msi files
#   --distros LIST     the Linux distro tags that must have a .deb, e.g.
#                      "ubuntu24.04 debian13"; every package must be there
#   --out DIR          where the packages and SHA256SUMS are collected
#                      (default: a new temporary directory)
#   --source-url URL   link to this repository, for the release notes
#                      (default: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY)
#   --run-url URL      link to the CI run, for the release notes
#   --sha SHA          the commit the packages were built from; the tag must
#                      still point to it (default: $GITHUB_SHA)
#   --dry-run          collect the files and write the notes, but do not
#                      call GitHub
#   -h, --help         show this help message
#
# Environment: GH_TOKEN with contents: write on --repo (not needed for
# --dry-run). The release notes list the commits since the previous tag, so
# the checkout needs the tags and their history (fetch-depth: 0).
#
set -euo pipefail
export LC_ALL=C     # stable file order in SHA256SUMS and the notes

usage() { sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

tag="" repo="" packages="" distros="" out="" dry_run=0 run_url="" sha="${GITHUB_SHA:-}"
source_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)        tag="${2:?--tag needs a value}"; shift 2 ;;
        --repo)       repo="${2:?--repo needs a value}"; shift 2 ;;
        --packages)   packages="${2:?--packages needs a value}"; shift 2 ;;
        --distros)    distros="${2:?--distros needs a value}"; shift 2 ;;
        --out)        out="${2:?--out needs a value}"; shift 2 ;;
        --source-url) source_url="${2:?--source-url needs a value}"; shift 2 ;;
        --run-url)    run_url="${2:?--run-url needs a value}"; shift 2 ;;
        --sha)        sha="${2:?--sha needs a value}"; shift 2 ;;
        --dry-run)    dry_run=1; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 >&2 ;;
    esac
done

fail() { echo "::error::$*" >&2; exit 1; }

repo="${repo:-${GITHUB_REPOSITORY:-}}"
[[ -n "${tag}" && -n "${repo}" && -n "${packages}" && -n "${distros}" ]] || usage 1 >&2
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Not a repository: ${repo}"
[[ -d "${packages}" ]] || fail "No such directory: ${packages}"
[[ "${tag}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-(rc[1-9][0-9]*))?$ ]] ||
    fail "Tag ${tag} is not vX.Y.Z or vX.Y.Z-rcN"
version="${BASH_REMATCH[1]}"
rc="${BASH_REMATCH[3]}"
# File names carry the version as built by CI (tools/ci_version.sh): with a
# hyphen, and with a tilde in the Debian package version.
file_version="${version}${rc:+-${rc}}"
deb_version="${version}${rc:+~${rc}}"
# The release notes need the tag and its history.
git rev-parse -q --verify "refs/tags/${tag}" >/dev/null || fail "Tag ${tag} is not in this checkout"
# The notes come from the local tag, so it must be the commit that was built.
local_sha="$(git rev-parse "refs/tags/${tag}^{commit}")"
[[ -n "${sha}" ]] || sha="${local_sha}"
[[ "${local_sha}" == "${sha}" ]] ||
    fail "Tag ${tag} in this checkout points to ${local_sha}, but the packages were built from ${sha}"

# ── Collect the packages ────────────────────────────────────────────────────
# The exact set of files is required, so a release never goes out with a
# platform missing or with a package from another build.
#
# GitHub renames release assets with special characters ("~" becomes "."), so
# the .deb files get a public name without the Debian tildes; the Debian
# version inside the package (1.1.0~rc1-1~ubuntu24.04) stays as it is.
declare -a sources=() names=() distro_list=()
# -d '': all lines of the list, not only the first.
read -r -d '' -a distro_list <<<"${distros}" || true
[[ ${#distro_list[@]} -gt 0 ]] || fail "--distros lists no distro"
for distro in "${distro_list[@]}"; do
    [[ "${distro}" =~ ^[a-z]+[0-9.]+$ ]] || fail "Not a distro tag: ${distro}"
    [[ " ${names[*]-} " != *"_${distro}_amd64.deb "* ]] || fail "Distro listed twice: ${distro}"
    sources+=("sql-studio-community_${deb_version}-1~${distro}_amd64.deb")
    names+=("sql-studio-community_${file_version}_${distro}_amd64.deb")
done
for f in "SqlStudio-${file_version}-macos-arm64.dmg" \
         "sql-studio-${file_version}-winx64.zip" \
         "sql-studio-${file_version}-winx64.msi"; do
    sources+=("${f}")
    names+=("${f}")
done

if [[ -z "${out}" ]]; then
    out="$(mktemp -d)"
else
    mkdir -p "${out}"
    [[ -z "$(ls -A "${out}")" ]] || fail "${out} is not empty"
fi

found=()
while IFS= read -r -d '' file; do
    found+=("${file}")
done < <(find "${packages}" -type f \( -name '*.deb' -o -name '*.dmg' -o -name '*.zip' -o -name '*.msi' \) -print0)

for i in "${!sources[@]}"; do
    match=""
    for file in "${found[@]+"${found[@]}"}"; do
        if [[ "$(basename "${file}")" == "${sources[$i]}" ]]; then
            [[ -z "${match}" ]] || fail "Two packages are called ${sources[$i]}"
            match="${file}"
        fi
    done
    [[ -n "${match}" ]] || fail "Missing package: ${sources[$i]}"
    cp "${match}" "${out}/${names[$i]}"
done
[[ ${#found[@]} -eq ${#sources[@]} ]] ||
    fail "Found ${#found[@]} packages in ${packages}, expected ${#sources[@]}: ${sources[*]}"

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
(cd "${out}" && for f in *; do checksum "$f"; done) > "${out}.sums"
mv "${out}.sums" "${out}/SHA256SUMS"
echo "Collected ${#sources[@]} packages in ${out}:"
(cd "${out}" && cat SHA256SUMS)

# ── Release notes ───────────────────────────────────────────────────────────
# The previous release: for an RC the tag just below it (an earlier RC or a
# release), for a release the previous release, so its notes cover all RCs.
# Only release tags that the new tag contains count: a hotfix tagged on an
# older release branch is not part of the next release's history.
previous=""
while IFS= read -r t; do
    [[ "${t}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[1-9][0-9]*)?$ ]] || continue
    [[ "${t}" == "${tag}" ]] && { previous="."; continue; }
    [[ "${previous}" == "." ]] || continue
    if [[ -n "${rc}" || "${t}" != *-rc* ]]; then previous="${t}"; break; fi
done < <(git -c versionsort.suffix=-rc tag -l 'v*' --merged "${tag}" --sort=-v:refname)
[[ "${previous}" != "." ]] || previous=""

notes="${out}.notes.md"
{
    if [[ -n "${rc}" ]]; then
        echo "Release candidate **${file_version}** of SQL Studio, for testing. It is not the final release."
    else
        echo "SQL Studio **${version}**."
    fi
    echo
    echo "Source: [${tag}](${source_url}/tree/${tag})${run_url:+ · built by [this CI run](${run_url})}"
    echo
    if [[ -n "${previous}" ]]; then
        echo "## Changes since ${previous}"
        echo
        git log --no-merges --format='- %s (%h)' "${previous}..${tag}"
        echo
        echo "Full list: ${source_url}/compare/${previous}...${tag}"
    else
        echo "No earlier release tag in this history. History: ${source_url}/commits/${tag}"
    fi
    echo
    echo "## Files"
    echo
    echo "| System | Package |"
    echo "|---|---|"
    for f in "${out}"/*; do
        f="$(basename "${f}")"
        case "${f}" in
            *.deb) system="$(sed -E 's/.*_([a-z]+)([0-9.]+)_amd64\.deb$/\1 \2/' <<<"${f}")"
                   system="$(tr '[:lower:]' '[:upper:]' <<<"${system:0:1}")${system:1}" ;;
            *.dmg) system="macOS (Apple Silicon)" ;;
            *.zip) system="Windows x64 (portable)" ;;
            *.msi) system="Windows x64 (installer)" ;;
            *)     continue ;;
        esac
        echo "| ${system} | \`${f}\` |"
    done
    echo
    echo "Check a download with \`sha256sum -c SHA256SUMS --ignore-missing\`."
} > "${notes}"
echo "Release notes: ${notes}"

if [[ ${dry_run} -eq 1 ]]; then
    echo "Dry run: not publishing ${tag} to ${repo}"
    cat "${notes}"
    exit 0
fi

# ── Publish ─────────────────────────────────────────────────────────────────
title="SQL Studio ${file_version}"

# The packages belong to ${sha}. If the tag was moved since the build, the
# release would show other code than the packages hold.
check_tag() {
    local ref remote
    # The exact tag ref (a short name could also match a branch); an annotated
    # tag points to a tag object, which points to the commit.
    ref="$(gh api "repos/${repo}/git/ref/tags/${tag}" --jq '"\(.object.type) \(.object.sha)"')" ||
        fail "Could not read the tag ${tag} in ${repo}"
    remote="${ref#* }"
    if [[ "${ref%% *}" == tag ]]; then
        remote="$(gh api "repos/${repo}/git/tags/${remote}" --jq '.object.sha')" ||
            fail "Could not read the tag ${tag} in ${repo}"
    fi
    [[ "${remote}" == "${sha}" ]] ||
        fail "Tag ${tag} in ${repo} points to ${remote}, but the packages were built from ${sha}"
}
check_tag

# The list includes drafts, which the single-release endpoint does not find by
# tag. An API error stops here: only a confirmed absence may create a release.
state="$(gh api --paginate "repos/${repo}/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"${tag}\") | .draft")" ||
    fail "Could not list the releases of ${repo}"
case "${state}" in
    "")
        # --verify-tag: use the pushed tag, never create one.
        gh release create "${tag}" --repo "${repo}" --draft --verify-tag \
            --title "${title}" --notes-file "${notes}" ${rc:+--prerelease}
        ;;
    true)
        echo "Draft ${tag} already exists in ${repo}; uploading the packages again"
        gh release edit "${tag}" --repo "${repo}" --title "${title}" --notes-file "${notes}"
        ;;
    false)
        fail "Release ${tag} in ${repo} is already published; it is not changed"
        ;;
    *)
        fail "More than one release for ${tag} in ${repo}: ${state//$'\n'/ }"
        ;;
esac

gh release upload "${tag}" --repo "${repo}" --clobber "${out}"/*

# A draft that is filled in again may still hold files of an earlier attempt
# under other names. Remove them, so the release holds exactly the packages
# and SHA256SUMS; a published release could no longer be changed.
expected="$(cd "${out}" && printf '%s\n' *)"
assets="$(gh release view "${tag}" --repo "${repo}" --json assets --jq '.assets[].name')" ||
    fail "Could not list the files of ${tag} in ${repo}"
while IFS= read -r asset; do
    [[ -n "${asset}" ]] || continue
    if ! grep -qxF -- "${asset}" <<<"${expected}"; then
        echo "::warning::Removing ${asset} from the draft ${tag}: not part of this release"
        gh release delete-asset --repo "${repo}" --yes -- "${tag}" "${asset}"
    fi
done <<<"${assets}"
assets="$(gh release view "${tag}" --repo "${repo}" --json assets --jq '.assets[].name' | grep -v '^$' | sort)" ||
    fail "Could not list the files of ${tag} in ${repo}"
[[ "${assets}" == "$(sort <<<"${expected}")" ]] ||
    fail "The draft ${tag} does not hold exactly the expected files: ${assets//$'\n'/ }"

check_tag
if [[ -n "${rc}" ]]; then
    gh release edit "${tag}" --repo "${repo}" --draft=false --prerelease
    echo "Published pre-release ${tag}"
else
    echo "Draft ${tag} is ready; publish it after checking the packages"
fi

# Best effort: the release is already done at this point.
url="$(gh release view "${tag}" --repo "${repo}" --json url --jq .url 2>/dev/null)" ||
    url="https://github.com/${repo}/releases"
echo "${url}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "Release: ${url}" >> "${GITHUB_STEP_SUMMARY}"
