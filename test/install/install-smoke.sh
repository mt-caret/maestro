set -eu

workspace_root=$(CDPATH= cd -- "$1/../.." && pwd -P)
test_root=$(mktemp -d)
prefix="$test_root/prefix"
fake_home="$test_root/home"
fake_switch="$test_root/switch"
build_root="$test_root/build"

cleanup()
{
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$prefix" "$fake_home" "$fake_switch"

(
  cd "$workspace_root"
  dune build --build-dir "$build_root" @install
  grep -A1 '^bin:' "$build_root/default/maestro.install" | grep -q '/bin/maestro"'
  HOME="$fake_home" XDG_CACHE_HOME="$build_root/cache" OPAM_SWITCH_PREFIX="$fake_switch" \
    dune install --build-dir "$build_root" --prefix "$prefix" maestro
)

"$prefix/bin/maestro" --help >/dev/null

if find "$fake_home" "$fake_switch" -mindepth 1 -print -quit | grep -q .
then
  echo "installation wrote outside the temporary prefix" >&2
  find "$fake_home" "$fake_switch" -mindepth 1 -print >&2
  exit 1
fi

(
  cd "$workspace_root"
  HOME="$fake_home" XDG_CACHE_HOME="$build_root/cache" OPAM_SWITCH_PREFIX="$fake_switch" \
    dune uninstall --build-dir "$build_root" --prefix "$prefix" maestro
)

if find "$prefix" -type f -print -quit | grep -q .
then
  echo "uninstall left files in the temporary prefix" >&2
  exit 1
fi
