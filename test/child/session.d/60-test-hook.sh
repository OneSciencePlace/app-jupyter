# shellcheck shell=bash
# A child's own session hook, as osp/session.d/README.md describes: installed by
# install.sh, sourced at session start; test/session-checks.py looks for its
# variable in a kernel's environment.
if osp_has_module json; then
    export OSP_TEST_HOOK=ran
    echo "[app] test hook: ran"
fi
