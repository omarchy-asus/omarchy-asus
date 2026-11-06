#!/bin/bash
# bin/release-sign (#258, step 2), offline: gh is a stub serving a fake release workflow run
# (its record, jobs, artifacts as zips, the compare against main and the attestations), id
# can be told to answer root, and bin/publish is a stub that records what it was given. Every
# refusal must exit non-zero with nothing in the stage dir, bin/publish never run and the
# private temp dir gone:
#   1. who: the channel main doesn't build (rc since #411), an unknown channel, root, the runner account, no runner
#      account configured, a run ID that is not a number
#   2. the run: another workflow, another branch, a commit not on main, a PR (pull_request,
#      pull_request_target), a push, a fork's run, a run that didn't succeed, a missing field,
#      an API error (the run, the compare, the jobs, the artifacts, the download)
#   3. the jobs: a failed build job, a build job missing, a failed attest job
#   4. the artifacts: a digest mismatch (the artifact, a file), an extra file, a missing file,
#      a path component, a non-package name, an artifact for another channel, an expired one,
#      an artifact from another run, a file in two artifacts, two artifacts with one name, a
#      malformed SHA256SUMS
#   5. the attestations: none, one from another run, workflow, commit or file
#   6. passing: --dry-run stages nothing; a real run hands bin/publish --channel quattro exactly
#      the manifests' files, from the stage dir, byte for byte; so does a run with a single
#      artifact (each artifact is read into its own directory, whatever their number)
# Usage: tests/ci/release-sign.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
REAL_ID=$(command -v id)
R=omarchy-asus/omarchy-asus RID=1424002204 RUN=777 SHA=$(printf 'a%.0s' {1..40})
mkdir -p "$S/bin" "$S/stubs" "$S/ws" "$S/tmp"
cp "$W/bin/release-sign" "$W/bin/env.sh" "$S/bin/"
mkdir -p "$S/ci"; cp "$W/ci/channel" "$S/ci/"
cat >"$S/bin/publish" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/published"
for f in "\$@"; do [[ \$f == --* || \$f == rc ]] || sha256sum "\$f" >>"$S/published.sums"; done
STUB
cat >"$S/stubs/id" <<STUB
#!/bin/bash
if [[ -e $S/as-root && \${1:-} == -u ]]; then echo 0; exit 0; fi
if [[ -e $S/as-runner && \${1:-} == -un ]]; then echo test-runner; exit 0; fi
exec "$REAL_ID" "\$@"
STUB
# gh: answers from the fixture dir \$FX; a file named fail-<what> makes that call fail
cat >"$S/stubs/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$FX/gh.log"
R=omarchy-asus/omarchy-asus
if [[ $1 == api ]]; then
    case $2 in
        repos/$R/actions/runs/*/jobs\?*) what=jobs ;;
        repos/$R/actions/runs/*/artifacts\?*) what=artifacts ;;
        repos/$R/actions/runs/*) what=run ;;
        repos/$R/compare/main...*) what=compare ;;
        repos/$R/actions/artifacts/*/zip) id=${2#repos/"$R"/actions/artifacts/}; id=${id%/zip}
            [[ ! -e $FX/fail-zip ]] || { echo "HTTP 500" >&2; exit 1; }
            cat "$FX/zip/$id.zip"; exit ;;
        *) echo "unexpected gh api $2" >&2; exit 1 ;;
    esac
    [[ ! -e $FX/fail-$what ]] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    cat "$FX/$what.json"; exit
fi
if [[ $1 == attestation && $2 == verify ]]; then
    a=" $* "
    [[ $a == *" --signer-workflow $R/.github/workflows/release.yml "* && $a == *" --source-ref refs/heads/main "* &&
        $a == *" --repo $R "* ]] || { echo "stub: verify without the release workflow's policy" >&2; exit 1; }
    f=$(basename "$3")
    [[ -e $FX/att/$f.json ]] || { echo "Error: no attestations found" >&2; exit 1; }
    cat "$FX/att/$f.json"; exit
fi
echo "unexpected gh $*" >&2; exit 1
STUB
chmod +x "$S/bin/"* "$S/stubs/"*
export PATH=$S/stubs:$PATH OMARCHY_ASUS_WORKSPACE=$S/ws TMPDIR=$S/tmp OMARCHY_ASUS_RUNNER_USER=test-runner
unset OMARCHY_ASUS_CHANNEL GH_TOKEN GH_REPO
fail=0

# the packages: release-quattro-foo holds two, release-quattro-bar one
P=$S/pkgs
mkdir -p "$P/foo" "$P/bar"
for f in foo/foo-1.0-1.101-x86_64.pkg.tar.zst foo/foo-docs-1.0-1.101-any.pkg.tar.zst bar/bar-2-101-any.pkg.tar.zst; do
    head -c 3000 /dev/urandom >"$P/$f"
done
ALL="bar-2-101-any.pkg.tar.zst foo-1.0-1.101-x86_64.pkg.tar.zst foo-docs-1.0-1.101-any.pkg.tar.zst"
sum() { sha256sum "$1" | cut -d' ' -f1; }

# fixture: a fresh \$FX for a run that passes every check, and a fresh data dir
n=0
fixture() {
    n=$((n + 1)); FX=$S/fx$n; export FX OMARCHY_ASUS_DATA=$S/data$n
    rm -f "$S/as-root" "$S/as-runner" "$S/published" "$S/published.sums"
    mkdir -p "$FX/zip" "$FX/att" "$FX/art" "$OMARCHY_ASUS_DATA"
    jq -n --arg sha "$SHA" --arg r "$R" --argjson rid "$RID" --argjson run "$RUN" '{
        id: $run, path: ".github/workflows/release.yml", event: "workflow_dispatch",
        head_branch: "main", head_sha: $sha, status: "completed", conclusion: "success",
        run_attempt: 1, repository: {id: $rid, full_name: $r}, head_repository: {id: $rid, full_name: $r}}' >"$FX/run.json"
    echo '{"status": "behind", "ahead_by": 0, "behind_by": 3}' >"$FX/compare.json"
    jq -n '[ "plan", "build (bar)", "build (foo)", "eligibility", "check", "attest", "result" ] |
        {total_count: length, jobs: map({name: ., status: "completed", conclusion: "success"})}' >"$FX/jobs.json"
    for r in foo bar; do
        rm -rf "${FX:?}/art/$r"; cp -r "$P/$r" "$FX/art/$r"
        (cd "$FX/art/$r" && sha256sum -- *.pkg.tar.zst >SHA256SUMS)
    done
    jq -n '{total_count: 0, artifacts: []}' >"$FX/artifacts.json"
    add_artifact 101 release-quattro-foo foo
    add_artifact 102 release-quattro-bar bar
    for f in "$P"/*/*.pkg.tar.zst; do attest "$f"; done
}
# add_artifact <id> <name> <dir under \$FX/art>: zip that dir and list it, with its digest
add_artifact() {
    local z=$FX/zip/$1.zip
    rm -f "$z"
    (cd "$FX/art/$3" && bsdtar --format zip -cf "$z" -- *)
    jq --argjson id "$1" --arg name "$2" --arg d "sha256:$(sum "$z")" --arg sha "$SHA" --argjson rid "$RID" --argjson run "$RUN" '
        .artifacts = [.artifacts[] | select(.id != $id)] + [{id: $id, name: $name, digest: $d, expired: false,
            size_in_bytes: 1, workflow_run: {id: $run, head_sha: $sha, head_branch: "main",
            repository_id: $rid, head_repository_id: $rid}}] | .total_count = (.artifacts | length)' \
        "$FX/artifacts.json" >"$FX/a.tmp" && mv "$FX/a.tmp" "$FX/artifacts.json"
}
# attest <file> [jq edit]: what gh attestation verify --format json prints for it
attest() {
    jq -n --arg f "$(basename "$1")" --arg s "$(sum "$1")" --arg sha "$SHA" --arg r "$R" --argjson run "$RUN" '[{
        verificationResult: {
            signature: {certificate: {
                subjectAlternativeName: "https://github.com/\($r)/.github/workflows/release.yml@refs/heads/main",
                sourceRepositoryRef: "refs/heads/main", sourceRepositoryDigest: $sha,
                runInvocationURI: "https://github.com/\($r)/actions/runs/\($run)/attempts/1",
                runnerEnvironment: "github-hosted"}},
            statement: {predicateType: "https://slsa.dev/provenance/v1",
                subject: [{name: $f, digest: {sha256: $s}}]}}}]' | jq "${2:-.}" >"$FX/att/$(basename "$1").json"
}
edit() { jq "$2" "$FX/$1.json" >"$FX/e.tmp" && mv "$FX/e.tmp" "$FX/$1.json"; }

# run <want: ok|refused> <what> [release-sign args]: the exit status, and what reached the stage and bin/publish
sign() { "$S/bin/release-sign" "$@" >"$S/out" 2>"$S/err"; }
check() {
    local want=$1 what=$2 rc; shift 2
    sign "$@"; rc=$?
    local stage=$OMARCHY_ASUS_DATA/stage staged
    staged=$(ls -A "$stage" "$OMARCHY_ASUS_DATA/stage-rc" 2>/dev/null)
    if [[ -n $(ls -A "$S/tmp") ]]; then
        echo "FAIL: $what: its temp dir was left behind"; ls -A "$S/tmp"; fail=1; rm -rf "${S:?}/tmp/"*
    elif [[ $want == refused ]]; then
        if ((rc == 0)); then echo "FAIL: $what: exit 0"; cat "$S/out" "$S/err"; fail=1
        elif [[ -n $staged || -e $S/published ]]; then echo "FAIL: $what: something was staged or published"; fail=1
        else echo "ok: $what ($(tail -n1 "$S/err"))"
        fi
    elif ((rc != 0)); then echo "FAIL: $what: exit $rc"; cat "$S/out" "$S/err"; fail=1
    else echo "ok: $what"
    fi
}

echo "== 1. who runs it"
fixture
check refused "the rc channel: main builds quattro (ci/channel main)" --channel rc "$RUN"
grep -qF "main builds the quattro channel" "$S/err" && echo "ok: the rc refusal names the channel main builds" ||
    { echo "FAIL: the rc refusal does not say which channel main builds"; cat "$S/err"; fail=1; }
check refused "an unknown channel" --channel stable "$RUN"
check refused "a run ID that is not a number" --channel quattro "$RUN;x"
[[ ! -e $FX/gh.log ]] && echo "ok: nothing above asked GitHub" || { echo "FAIL: gh ran before the arguments were checked"; fail=1; }
fixture; touch "$S/as-root"
check refused "running as root" --channel quattro "$RUN"
fixture; touch "$S/as-runner"
check refused "running as the runner account" --channel quattro "$RUN"
fixture
OMARCHY_ASUS_RUNNER_USER='' check refused "no runner account configured" --channel quattro "$RUN"
fixture; echo "$("$REAL_ID" -un)" >"$OMARCHY_ASUS_DATA/runner-user"
OMARCHY_ASUS_RUNNER_USER='' check refused "the runner account named in \$DATA/runner-user" --channel quattro "$RUN"

echo "== 2. the run"
fixture; edit run '.path = ".github/workflows/build-pr.yml"'
check refused "another workflow" --channel quattro "$RUN"
fixture; edit run '.path = ".github/workflows/release.yml@refs/heads/x"'
check refused "a workflow path that only starts with the release workflow's" --channel quattro "$RUN"
fixture; edit run '.head_branch = "feature"'
check refused "another branch" --channel quattro "$RUN"
fixture; echo '{"status": "diverged"}' >"$FX/compare.json"
check refused "a commit not on main (diverged), though head_branch says main" --channel quattro "$RUN"
fixture; echo '{"status": "ahead"}' >"$FX/compare.json"
check refused "a commit ahead of main" --channel quattro "$RUN"
fixture; echo '{}' >"$FX/compare.json"
check refused "a compare with no status" --channel quattro "$RUN"
for ev in pull_request pull_request_target push schedule; do
    fixture; edit run ".event = \"$ev\""
    check refused "a run triggered by $ev" --channel quattro "$RUN"
done
fixture; edit run '.head_repository = {id: 1, full_name: "someone/omarchy-asus"}'
check refused "a fork's run" --channel quattro "$RUN"
fixture; edit run '.head_repository.id = 1'
check refused "a head repository with another ID under our name" --channel quattro "$RUN"
fixture; edit run '.repository.full_name = "someone/omarchy-asus"'
check refused "a run in another repository" --channel quattro "$RUN"
fixture; edit run '.conclusion = "failure"'
check refused "a run that failed" --channel quattro "$RUN"
fixture; edit run '.status = "in_progress" | .conclusion = null'
check refused "a run still going" --channel quattro "$RUN"
fixture; edit run '.id = 778'
check refused "GitHub answering for another run" --channel quattro "$RUN"
for k in path event head_branch head_sha conclusion run_attempt head_repository; do
    fixture; edit run "del(.$k)"
    check refused "the run's $k missing" --channel quattro "$RUN"
done
fixture; echo 'not json' >"$FX/run.json"
check refused "a malformed run record" --channel quattro "$RUN"
for what in run compare jobs artifacts zip; do
    fixture; touch "$FX/fail-$what"
    check refused "an API error ($what)" --channel quattro "$RUN"
done

echo "== 3. the jobs"
fixture; edit jobs '(.jobs[] | select(.name == "build (foo)") | .conclusion) = "failure"'
check refused "a failed build job (the run said success)" --channel quattro "$RUN"
fixture; edit jobs '.jobs = [.jobs[] | select(.name != "build (bar)")] | .total_count = (.jobs | length)'
check refused "no build job for an artifact" --channel quattro "$RUN"
fixture; edit jobs '(.jobs[] | select(.name == "attest") | .conclusion) = "skipped"'
check refused "a skipped attest job" --channel quattro "$RUN"
fixture; edit jobs '.total_count = 99'
check refused "a job list shorter than its count" --channel quattro "$RUN"

echo "== 4. the artifacts"
fixture; edit artifacts '.artifacts[0].digest = "sha256:" + ("0" * 64)'
check refused "an artifact digest mismatch" --channel quattro "$RUN"
fixture; edit artifacts 'del(.artifacts[0].digest)'
check refused "an artifact with no digest" --channel quattro "$RUN"
fixture; sed -i "1s/^[0-9a-f]\{64\}/$(printf '0%.0s' {1..64})/" "$FX/art/foo/SHA256SUMS"; add_artifact 101 release-quattro-foo foo
check refused "a file digest mismatch (SHA256SUMS)" --channel quattro "$RUN"
fixture; printf 'x' >>"$FX/art/bar/bar-2-101-any.pkg.tar.zst"; add_artifact 102 release-quattro-bar bar
check refused "a file digest mismatch (the file changed)" --channel quattro "$RUN"
fixture; head -c 10 /dev/urandom >"$FX/art/foo/extra-1-1-any.pkg.tar.zst"; add_artifact 101 release-quattro-foo foo
check refused "an extra file in the artifact" --channel quattro "$RUN"
fixture; echo hi >"$FX/art/foo/install.sh"; add_artifact 101 release-quattro-foo foo
check refused "a non-package file in the artifact" --channel quattro "$RUN"
fixture; rm "$FX/art/foo/foo-docs-1.0-1.101-any.pkg.tar.zst"; add_artifact 101 release-quattro-foo foo
check refused "a file missing from the artifact" --channel quattro "$RUN"
fixture; rm "$FX/art/foo/SHA256SUMS"; add_artifact 101 release-quattro-foo foo
check refused "an artifact without SHA256SUMS" --channel quattro "$RUN"
fixture; mkdir "$FX/art/foo/sub"; mv "$FX/art/foo/foo-docs-1.0-1.101-any.pkg.tar.zst" "$FX/art/foo/sub/"
(cd "$FX/art/foo" && sha256sum -- *.pkg.tar.zst sub/*.pkg.tar.zst >SHA256SUMS); add_artifact 101 release-quattro-foo foo
check refused "a path component in the artifact" --channel quattro "$RUN"
fixture; ln -s /etc/passwd "$FX/art/foo/link-1-1-any.pkg.tar.zst"
(cd "$FX/art/foo" && sha256sum -- *.pkg.tar.zst >SHA256SUMS); add_artifact 101 release-quattro-foo foo
check refused "a symlink in the artifact" --channel quattro "$RUN"
fixture; sed -i '1s/  /  ..\//' "$FX/art/foo/SHA256SUMS"; add_artifact 101 release-quattro-foo foo
check refused "SHA256SUMS naming ../" --channel quattro "$RUN"
fixture; sed -i '1s/  / */' "$FX/art/foo/SHA256SUMS"; add_artifact 101 release-quattro-foo foo
check refused "a malformed SHA256SUMS line" --channel quattro "$RUN"
fixture; : >"$FX/art/foo/SHA256SUMS"; rm "$FX"/art/foo/*.pkg.tar.zst; add_artifact 101 release-quattro-foo foo
check refused "an empty SHA256SUMS" --channel quattro "$RUN"
fixture; cp "$FX/art/foo/foo-1.0-1.101-x86_64.pkg.tar.zst" "$FX/art/bar/"
(cd "$FX/art/bar" && sha256sum -- *.pkg.tar.zst >SHA256SUMS); add_artifact 102 release-quattro-bar bar
check refused "one file in two artifacts" --channel quattro "$RUN"
fixture; add_artifact 103 release-rc-foo foo
check refused "an artifact for another channel" --channel quattro "$RUN"
fixture; add_artifact 103 other foo
check refused "an artifact that is not a release one" --channel quattro "$RUN"
fixture; edit artifacts '.artifacts[1].expired = true'
check refused "an expired artifact" --channel quattro "$RUN"
fixture; edit artifacts '.artifacts[1].workflow_run.id = 1'
check refused "an artifact from another run" --channel quattro "$RUN"
fixture; edit artifacts '.artifacts[1].workflow_run.head_sha = "b" * 40'
check refused "an artifact from another commit" --channel quattro "$RUN"
fixture; edit artifacts '.total_count = 5'
check refused "an artifact list shorter than its count" --channel quattro "$RUN"
fixture; echo '{"total_count": 0, "artifacts": []}' >"$FX/artifacts.json"
check refused "no artifacts" --channel quattro "$RUN"
fixture; add_artifact 103 release-quattro-foo bar
check refused "two artifacts with one name" --channel quattro "$RUN"

echo "== 5. the attestations"
fixture; rm "$FX/att/foo-docs-1.0-1.101-any.pkg.tar.zst.json"
check refused "a missing attestation" --channel quattro "$RUN"
f=$P/foo/foo-docs-1.0-1.101-any.pkg.tar.zst
fixture; attest "$f" '.[0].verificationResult.signature.certificate.runInvocationURI |= sub("/777/"; "/778/")'
check refused "an attestation from another run" --channel quattro "$RUN"
fixture; attest "$f" '.[0].verificationResult.signature.certificate.runInvocationURI |= sub("attempts/1"; "attempts/2")'
check refused "an attestation from a later attempt than the run's" --channel quattro "$RUN"
fixture; attest "$f" '.[0].verificationResult.signature.certificate.subjectAlternativeName |= sub("release.yml"; "build-pr.yml")'
check refused "an attestation signed by another workflow" --channel quattro "$RUN"
fixture; attest "$f" '.[0].verificationResult.signature.certificate.subjectAlternativeName |= sub("refs/heads/main"; "refs/heads/x")'
check refused "an attestation from another ref" --channel quattro "$RUN"
fixture; attest "$f" ".[0].verificationResult.signature.certificate.sourceRepositoryDigest = \"$(printf 'b%.0s' {1..40})\""
check refused "an attestation from another commit" --channel quattro "$RUN"
fixture; attest "$f" '.[0].verificationResult.statement.subject[0].digest.sha256 = ("0" * 64)'
check refused "an attestation for other bytes" --channel quattro "$RUN"
fixture; attest "$f" '.[0].verificationResult.statement.subject[0].name = "other.pkg.tar.zst"'
check refused "an attestation naming another file" --channel quattro "$RUN"
fixture; attest "$f" '[]'
check refused "an empty attestation list" --channel quattro "$RUN"

echo "== 6. passing"
fixture
check ok "--dry-run: every check passes" --channel quattro --dry-run "$RUN"
if [[ -e $S/published || -n $(ls -A "$OMARCHY_ASUS_DATA/stage" 2>/dev/null) ]]; then
    echo "FAIL: --dry-run staged or published"; fail=1
else echo "ok: --dry-run staged and published nothing"; fi
fixture
check ok "a good run" --channel quattro "$RUN"
want=$(printf -- '--channel\nquattro\n'; for f in $ALL; do echo "$OMARCHY_ASUS_DATA/stage/$f"; done)
got=$({ head -n2 "$S/published"; tail -n +3 "$S/published" | sort; } 2>/dev/null)
[[ $got == "$want" ]] && echo "ok: bin/publish got --channel quattro and exactly the manifests' files, from the stage dir" ||
    { echo "FAIL: bin/publish got:"; cat "$S/published" 2>/dev/null; fail=1; }
wsums=$(for f in $ALL; do r=${f%%-*}; echo "$(sum "$P/$r/$f")  $OMARCHY_ASUS_DATA/stage/$f"; done | sort)
[[ $(sort "$S/published.sums" 2>/dev/null) == "$wsums" ]] && echo "ok: the staged files are the built bytes" ||
    { echo "FAIL: the staged files differ"; fail=1; }
[[ $(ls -A "$OMARCHY_ASUS_DATA/stage" | sort | tr '\n' ' ') == "$ALL " ]] &&
    echo "ok: nothing else in the stage dir" || { echo "FAIL: stage dir:"; ls -A "$OMARCHY_ASUS_DATA/stage"; fail=1; }
# a run with a single artifact (the layout must not depend on how many there are)
fixture; edit artifacts '.artifacts = [.artifacts[] | select(.name == "release-quattro-bar")] | .total_count = 1'
check ok "a run with a single artifact" --channel quattro "$RUN"
[[ $(tail -n +3 "$S/published" 2>/dev/null) == "$OMARCHY_ASUS_DATA/stage/bar-2-101-any.pkg.tar.zst" &&
    $(cut -d' ' -f1 "$S/published.sums" 2>/dev/null) == "$(sum "$P/bar/bar-2-101-any.pkg.tar.zst")" ]] &&
    echo "ok: a single artifact: bin/publish got exactly its file, byte for byte" ||
    { echo "FAIL: a single artifact: bin/publish got:"; cat "$S/published" 2>/dev/null; fail=1; }
# a file already staged with other bytes is never replaced
fixture; mkdir -p "$OMARCHY_ASUS_DATA/stage"; echo old >"$OMARCHY_ASUS_DATA/stage/bar-2-101-any.pkg.tar.zst"
sign --channel quattro "$RUN"; rc=$?
[[ $rc -ne 0 && ! -e $S/published && $(cat "$OMARCHY_ASUS_DATA/stage/bar-2-101-any.pkg.tar.zst") == old ]] &&
    echo "ok: a staged file with other bytes: refused, left as it was" || { echo "FAIL: a staged file with other bytes"; fail=1; }
exit $fail
