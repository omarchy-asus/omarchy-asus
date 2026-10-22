#!/bin/bash
# Job-started hook for the build host's kernel runner (docs/kernel-runner.md):
# installed root-owned outside the runner's reach and named by
# ACTIONS_RUNNER_HOOK_JOB_STARTED in the runner's .env, so the runner runs it
# before every job, ahead of any step from the workflow. The workflow's runs-on
# keeps forks off this runner only while the workflow is ours: a fork's PR runs
# the fork's copy of build-pr.yml, which can name this runner itself. This is
# the check a workflow can't change.
#
# A failing hook is not enough: the runner treats it as a failed step and still
# runs any step whose condition is `if: always()`, and a fork's workflow picks
# its own conditions. So a refusal kills the job's Runner.Worker, the process
# that runs the job's steps (this hook is one of them), and nothing else of
# that job can run. The runner's listener sees the worker die, reports the job
# failed and takes the next one. The runner starts the hook as the worker's own
# child, so only the hook's parent and grandparent are looked at: a Runner.Worker
# further up is some other runner's (this repo's CI runs these tests on one),
# not this job's. If neither is a Runner.Worker, it fails closed: it kills its
# whole process group instead.
#
# The runner picks a hook's interpreter by its extension, so the installed copy
# must end in .sh.
#
# It lets through only, on this repository:
#   - pull_request from a branch of this repository (never a fork),
#   - workflow_dispatch (needs write access to start),
# and only the kernel job of build-pr.yml.
set -euo pipefail
# Fixed, not from the environment: a workflow's env must not be able to move it.
REPO=omarchy-asus/omarchy-asus
# worker_pid: the hook's parent or grandparent, if it is named Runner.Worker
worker_pid() {
    local pid=$$ _
    for _ in 1 2; do
        pid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null) || return 1
        (( pid > 1 )) || return 1
        [[ $(cat "/proc/$pid/comm" 2>/dev/null) == Runner.Worker ]] && { echo "$pid"; return 0; }
    done
    return 1
}
refuse() {
    echo "kernel runner: refused: $*" >&2
    local w
    if w=$(worker_pid); then
        echo "kernel runner: ending the job (Runner.Worker $w)" >&2
        kill -KILL "$w"
    else
        echo "kernel runner: no Runner.Worker above this hook; killing its process group" >&2
        kill -KILL -- "-$(ps -o pgid= $$ | tr -d ' ')"
    fi
    exit 1
}

[[ ${GITHUB_REPOSITORY:-} == "$REPO" ]] || refuse "repository '${GITHUB_REPOSITORY:-}' is not $REPO"
[[ ${GITHUB_JOB:-} == kernel ]] || refuse "job '${GITHUB_JOB:-}' is not build-pr.yml's kernel job"
case ${GITHUB_WORKFLOW_REF:-} in
    "$REPO/.github/workflows/build-pr.yml@"*) ;;
    *) refuse "workflow '${GITHUB_WORKFLOW_REF:-}' is not $REPO's build-pr.yml" ;;
esac
case ${GITHUB_EVENT_NAME:-} in
    workflow_dispatch) ;;
    pull_request)
        [[ -r ${GITHUB_EVENT_PATH:-} ]] || refuse "no event payload to check the PR's head repository"
        head=$(jq -r '.pull_request.head.repo.full_name // empty' "$GITHUB_EVENT_PATH")
        [[ $head == "$REPO" ]] || refuse "pull request from '${head:-unknown}', not a branch of $REPO"
        ;;
    *) refuse "event '${GITHUB_EVENT_NAME:-}' (only pull_request and workflow_dispatch)" ;;
esac
echo "kernel runner: ${GITHUB_EVENT_NAME} on $REPO accepted"
