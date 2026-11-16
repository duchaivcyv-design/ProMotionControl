#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# This project uses automatic patch-version increments for every successful build.
# Ignore a stale one-off override inherited from the caller environment.
unset BUILD_VERSION_OVERRIDE

if [[ -z "${THEOS:-}" ]]; then
  for candidate in "$HOME/theos" "$HOME/Theos" /opt/theos /theos; do
    if [[ -f "$candidate/makefiles/common.mk" ]]; then
      export THEOS="$candidate"
      break
    fi
  done
fi

if [[ -z "${THEOS:-}" || ! -f "$THEOS/makefiles/common.mk" ]]; then
  cat >&2 <<'MSG'
Khong tim thay Theos.
Hay cai Theos truoc, sau do dat bien THEOS, vi du:
  export THEOS="$HOME/theos"
  test -f "$THEOS/makefiles/common.mk"
Roi chay lai:
  ./run-build-ubuntu.sh
MSG
  exit 2
fi

for cmd in bash make python3 dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Thieu lenh bat buoc: $cmd" >&2
    exit 2
  }
done

chmod +x ./build-ubuntu.sh ./layout/DEBIAN/postinst ./layout/DEBIAN/postrm
printf 'THEOS=%s\n' "$THEOS"
printf 'Source VERSION: '; tr -d '\n' < VERSION; printf '\n'
if [[ -n "${BUILD_VERSION_OVERRIDE:-}" ]]; then
  printf 'Build target version (exact): %s\n\n' "$BUILD_VERSION_OVERRIDE"
else
  printf 'Build script se tu tang patch version sau khi build thanh cong.\n\n'
fi
exec ./build-ubuntu.sh
