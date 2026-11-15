# shellcheck shell=bash
# A hook that tries what app-jupyter prevents (plan J-20): it turns Python's
# user site packages back on, and plants a module in the home directory's user
# site. test/session-checks.py checks that neither reaches a kernel. Not an
# example to copy.
unset PYTHONNOUSERSITE
_us=$(python3 -c 'import site; print(site.getusersitepackages())')
mkdir -p "$_us"
printf 'PLANTED = True\n' > "$_us/osp_planted_usersite.py"
echo "[app] test hook: tried to turn user site packages back on"
