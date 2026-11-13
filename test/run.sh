#!/bin/bash
# test/run.sh <app-jupyter image> [--negative] - test an app-jupyter image as the
# base for images built on it. Needs Docker; run from anywhere.
#
#   bash test/run.sh ghcr.io/onescienceplace/app-jupyter:sha-<short>
#
# 1. Builds test/child/ FROM the image, as the README tells people to: Dask,
#    Ray, jupyter-console (brings debugpy back) and sudo (setuid), plus a hook
#    of its own. Checks the build log and the image: debugpy removed, hooks
#    installed and checked, Ray's version accepted, no setuid files.
# 2. Starts a session of it (docker run, as uid 1000, the token through the
#    environment only) and runs test/session-checks.py: as a notebook would
#    (the hooks' settings, Dask and Ray clusters that work), then as an
#    outsider without the session's secrets (each refused).
# 3. With --negative, five builds that must fail, each for its stated reason.
#
# This tests what app-jupyter itself promises (osp/install.sh,
# osp/finish-build.sh, the session hooks). It is not part B: an image's part B
# is tools/validate.sh in osp-ops, under the run profile.
#
# OSP_TEST_BUILD_ARGS: extra `docker build` arguments (a proxy, --network host).
# On Apple Silicon everything runs as linux/amd64, under emulation: slow.
set -u
base=${1:?usage: test/run.sh <app-jupyter image> [--negative]}
negative=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
plat="--platform linux/amd64"
# shellcheck disable=SC2206  # word-splitting wanted
extra=(${OSP_TEST_BUILD_ARGS:-})
tag="osp-test-child:$$"
name="osp-test-session-$$"
work=$(mktemp -d)
failed=0
report() {  # ok|fail, what, detail
    [ "$1" = ok ] && p=PASS || { p=FAIL; failed=$((failed + 1)); }
    printf '%s  %-52s %s\n' "$p" "$2" "${3:-}"
}
cleanup() { docker rm -f "$name" >/dev/null 2>&1; docker rmi -f "$tag" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

echo "== 1. build the test child FROM $base"
if docker build $plat "${extra[@]}" --progress plain --build-arg BASE="$base" -t "$tag" "$here/child" \
        > "$work/build.log" 2>&1; then
    report ok "the child builds"
else
    report fail "the child builds" "log: tail of it below"; tail -30 "$work/build.log"; exit 1
fi
has() { grep -q -- "$1" "$work/build.log"; }
has "\[install\] session hook 60-test-hook.sh" && report ok "install.sh added the child's hook" || report fail "install.sh added the child's hook"
has "removed (ipykernel" && report ok "finish-build.sh removed the debugpy pip brought back" || report fail "finish-build.sh removed the debugpy pip brought back"
has "\[finish\]    50-dask-tls.sh" && has "\[finish\]    50-ray-token.sh" && has "\[finish\]    60-test-hook.sh" \
    && report ok "finish-build.sh checked all three hooks" || report fail "finish-build.sh checked all three hooks"
has "token authentication available" && report ok "finish-build.sh accepted Ray's version" || report fail "finish-build.sh accepted Ray's version"
has "\[finish\] ok" && report ok "finish-build.sh: ok" || report fail "finish-build.sh: ok"

img=$(docker run --rm $plat --entrypoint sh "$tag" -c '
    printf "setuid=%s " "$(find / -xdev -type f -perm /6000 | wc -l)"
    pip show debugpy >/dev/null 2>&1 && printf "debugpy=present " || printf "debugpy=absent "
    printf "hooks=%s" "$(ls /app/osp/session.d | tr "\n" ,)"' 2>/dev/null)
case $img in *"setuid=0 "*) report ok "no setuid/setgid files (sudo stripped)";; *) report fail "no setuid/setgid files" "$img";; esac
case $img in *"debugpy=absent"*) report ok "debugpy absent";; *) report fail "debugpy absent";; esac

echo "== 2. a session of it"
OSP_APP_TOKEN=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
export OSP_APP_TOKEN
docker run -d $plat --name "$name" --user 1000:1000 --shm-size 1g -e OSP_APP_TOKEN "$tag" >/dev/null
unset OSP_APP_TOKEN
up=
for _ in $(seq 240); do
    docker logs "$name" 2>&1 | grep -q '\[supervise\] supervising:' && { up=1; break; }
    sleep 0.5
done
[ -n "$up" ] && report ok "the session started" || { report fail "the session started"; docker logs "$name" 2>&1 | grep -v -i token | tail -20; exit 1; }
for l in "Dask: TLS with this session's certificate" "Ray: token authentication (token)" "test hook: ran"; do
    docker logs "$name" 2>&1 | grep -qF "[app] $l" && report ok "log: $l" || report fail "log: $l"
done
docker cp "$here/session-checks.py" "$name:/tmp/session-checks.py" >/dev/null
jpid=$(docker exec "$name" pgrep -f 'bin/jupyter-lab' | head -1)
docker exec -u 1000:1000 "$name" python3 /tmp/session-checks.py inside "$jpid" > "$work/inside.log" 2>&1 &
inside=$!
for _ in $(seq 360); do
    docker exec "$name" test -f /tmp/osp-test/ready 2>/dev/null && break
    kill -0 "$inside" 2>/dev/null || break
    sleep 0.5
done
if docker exec "$name" test -f /tmp/osp-test/ready 2>/dev/null; then
    docker exec -u 1000:1000 "$name" python3 /tmp/session-checks.py outsider > "$work/outsider.log" 2>&1
    out_rc=$?
else
    echo "(the in-session clusters never came up)" > "$work/outsider.log"; out_rc=1
fi
docker exec -u 1000:1000 "$name" touch /tmp/osp-test/done 2>/dev/null
wait "$inside"; in_rc=$?
echo "-- as a notebook in the session:"; grep -E '^(PASS|FAIL)' "$work/inside.log" || tail -15 "$work/inside.log"
echo "-- as another session (no secrets):"; grep -E '^(PASS|FAIL)' "$work/outsider.log" || tail -15 "$work/outsider.log"
[ "$in_rc" = 0 ] || failed=$((failed + 1))
[ "$out_rc" = 0 ] || failed=$((failed + 1))
docker rm -f "$name" >/dev/null 2>&1

if [ "$negative" = --negative ]; then
    echo "== 3. builds that must fail"
    neg() {  # what, expected text in the log, Dockerfile body after FROM, [file=content ...]
        local what=$1 expect=$2 body=$3; shift 3
        local d; d=$(mktemp -d -p "$work")
        printf 'ARG BASE\nFROM ${BASE}\n%b\n' "$body" > "$d/Dockerfile"
        for f in "$@"; do mkdir -p "$d/$(dirname "${f%%=*}")"; printf '%b\n' "${f#*=}" > "$d/${f%%=*}"; done
        if docker build $plat "${extra[@]}" --progress plain --build-arg BASE="$base" "$d" > "$d/log" 2>&1; then
            report fail "refused: $what" "the build succeeded"
        elif grep -qF -- "$expect" "$d/log"; then
            report ok "refused: $what"
        else
            report fail "refused: $what" "failed, but without: $expect"
        fi
    }
    std='COPY . /tmp/osp/\nRUN /app/osp/install.sh /tmp/osp\nRUN /app/osp/finish-build.sh'
    neg "a package that needs another JupyterLab" "install.sh: pip could not install" "$std" "requirements.txt=jupyterlab==4.5.0"
    neg "a hook named like one of the image's" "already has a hook of that name" "$std" "session.d/50-dask-tls.sh=true"
    neg "a hook that is not valid bash" "not valid bash" "$std" "session.d/60-bad.sh=if then fi"
    neg "pip around install.sh moves a pinned package" "jupyter_pins: tornado is" 'RUN pip install --no-cache-dir tornado==6.5.2\nRUN /app/osp/finish-build.sh'
    neg "a USER line before finish-build.sh" "must run as root" 'USER 1000\nRUN /app/osp/finish-build.sh'
fi

echo
[ "$failed" = 0 ] && echo "all passed" || echo "$failed failed"
[ "$failed" = 0 ]
