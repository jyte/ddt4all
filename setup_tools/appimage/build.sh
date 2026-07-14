#!/bin/bash
set -e

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo "dev")}"
ARCH="${2:-${ARCH:-x86_64}}"

case "$ARCH" in
  x86_64|amd64)
    TOOL_ARCH="x86_64"
    OUTPUT_ARCH="x86_64"
    APPIMAGE_ARCH="x86_64"
    ;;
  x86_32|i686|i386)
    TOOL_ARCH="i686"
    OUTPUT_ARCH="x86_32"
    APPIMAGE_ARCH="x86"
    ;;
  *)
    echo "ERROR: unsupported ARCH '$ARCH' (use x86_64 or x86_32)"
    exit 1 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
APPDIR="$ROOT/build/AppDir"
TOOLSDIR="$ROOT/build/tools"

PYTHON_BIN="$(which python3)"
PYTHON_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYTHON_LIB="$(dirname "$PYTHON_BIN")/../lib/libpython${PYTHON_VER}.so.1.0"
PYTHON_STDLIB="$(dirname "$PYTHON_BIN")/../lib/python${PYTHON_VER}"

echo "=== Build AppImage ==="
echo "Version:   $VERSION"
echo "Arch:      $ARCH -> ${OUTPUT_ARCH}"
echo "Python:    $PYTHON_BIN ($PYTHON_VER)"
echo "Output:    ddt4all-${VERSION}-${OUTPUT_ARCH}.AppImage"

rm -rf "$APPDIR" "$TOOLSDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# --- Python binaire ---
cp "$PYTHON_BIN" "$APPDIR/usr/bin/python${PYTHON_VER}"
ln -sf "python${PYTHON_VER}" "$APPDIR/usr/bin/python3"

# --- libpython ---
if [ -f "$PYTHON_LIB" ]; then
  cp "$PYTHON_LIB" "$APPDIR/usr/lib/"
  cp -a "$(dirname "$PYTHON_LIB")/libpython${PYTHON_VER}.so" "$APPDIR/usr/lib/" 2>/dev/null || true
fi

# --- stdlib + venv site-packages ---
cp -r "$PYTHON_STDLIB/site-packages" "$APPDIR/usr/lib/python${PYTHON_VER}/"
STDLIB="$(python3 -c "import os; print(os.path.dirname(os.__file__))")"
for item in "$STDLIB"/*; do
  bn="$(basename "$item")"
  if [ "$bn" != "site-packages" ] && [ "$bn" != "__pycache__" ]; then
    cp -rn "$item" "$APPDIR/usr/lib/python${PYTHON_VER}/" 2>/dev/null || true
  fi
done

# --- Installer ddt4all ---
pip install --upgrade --no-deps --force-reinstall \
  --target "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages" .

# --- Icône ---
cp resources/icons/obd.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/ddt4all.png"
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/ddt4all.png" "$APPDIR/ddt4all.png"

# --- Desktop file ---
cat > "$APPDIR/usr/share/applications/ddt4all.desktop" << EOF
[Desktop Entry]
Name=DDT4All
Comment=CAN bus ECU diagnostic tool
Categories=Development;Electronics;
Exec=ddt4all
Icon=ddt4all
Type=Application
Terminal=false
EOF
cp "$APPDIR/usr/share/applications/ddt4all.desktop" "$APPDIR/"

# --- AppRun ---
cat > "$APPDIR/AppRun" << APPRUN
#!/bin/bash
set -e
APPDIR="\$(dirname "\$(readlink -f "\$0")")"
export PATH="\$APPDIR/usr/bin:\$PATH"
export LD_LIBRARY_PATH="\$APPDIR/usr/lib:\$APPDIR/lib:\$LD_LIBRARY_PATH"
export PYTHONHOME="\$APPDIR/usr"
export PYTHONPATH="\$APPDIR/usr/lib/python${PYTHON_VER}/site-packages"
export QT_QPA_PLATFORM=xcb
export QT_PLUGIN_PATH="\$APPDIR/usr/plugins"
export QTWEBENGINE_CHROMIUM_FLAGS="--disk-cache-dir=\$HOME/.cache/ddt4all"
exec "\$APPDIR/usr/bin/python3" -m ddt4all "\$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# --- Télécharger appimagetool ---
mkdir -p "$TOOLSDIR"
cd "$TOOLSDIR"

TOOL_FILE="appimagetool-${TOOL_ARCH}.AppImage"
if [ ! -f "$TOOL_FILE" ]; then
  wget -q "https://github.com/AppImage/appimagetool/releases/download/continuous/${TOOL_FILE}" -O "$TOOL_FILE"
fi
chmod +x "$TOOL_FILE"

# Extraire appimagetool (évite FUSE)
"$TOOLSDIR/$TOOL_FILE" --appimage-extract 2>/dev/null || true
if [ -d squashfs-root ]; then
  mv squashfs-root "$TOOLSDIR/appimagetool-${TOOL_ARCH}"
fi

cd "$ROOT"

# --- Bundler Qt5 ---
echo "=== Bundling Qt5 ==="

if [ "$TOOL_ARCH" = "i686" ]; then
  # Mode 32-bit : copier les .so Qt5 via ldd
  echo "Bundling Qt5 via ldd..."

  # Copier toutes les dépendances des .so PyQt5
  find "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5" \
    -name "*.so" -o -name "*.abi3.so" 2>/dev/null | \
  while read f; do
    ldd "$f" 2>/dev/null | grep "=> /" | awk '{print $3}' | \
    while read lib; do
      dest="$APPDIR/usr/lib/$(basename "$lib")"
      [ -f "$dest" ] || cp -L "$lib" "$dest" 2>/dev/null || true
    done
  done

  # Copier les plugins Qt5 (platforms, imageformats, etc.)
  QT5_PLUGINS="/usr/lib/i386-linux-gnu/qt5/plugins"
  if [ -d "$QT5_PLUGINS" ]; then
    mkdir -p "$APPDIR/usr/plugins"
    cp -r "$QT5_PLUGINS"/* "$APPDIR/usr/plugins/" 2>/dev/null || true
  fi

  # Nettoyer l'existant
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml" 2>/dev/null || true

else
  # Mode 64-bit : utiliser linuxdeploy
  if [ ! -f linuxdeploy-x86_64.AppImage ]; then
    wget -q "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
      -O linuxdeploy-x86_64.AppImage
  fi
  if [ ! -f linuxdeploy-plugin-qt-x86_64.AppImage ]; then
    wget -q "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage" \
      -O linuxdeploy-plugin-qt-x86_64.AppImage
  fi
  chmod +x *.AppImage

  for f in "$TOOLSDIR"/*.AppImage; do
    bn="$(basename "$f" .AppImage)"
    out="$TOOLSDIR/$bn"
    if [ ! -d "$out" ]; then
      (cd "$TOOLSDIR" && "$f" --appimage-extract && mv squashfs-root "$bn") || true
    fi
  done

  # Nettoyer les plugins QML non essentiels
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/Qt/labs/lottieqt" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/Qt/labs/sharedimage" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/Qt/labs/wavefrontmesh" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/QtQuick/Pdf" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/QtQuick/Scene2D" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/QtQuick/Particles.2" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/QtQuick/PrivateWidgets" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/QtQuick/Extras" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/qml/Qt3D" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/geometryloaders" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/sceneparsers" 2>/dev/null || true
  rm -rf "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/renderplugins" 2>/dev/null || true
  rm -f "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/imageformats/libqpdf.so" 2>/dev/null || true
  rm -f "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/renderers/libopenglrenderer.so" 2>/dev/null || true
  rm -f "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/sqldrivers/libqsqlodbc.so" 2>/dev/null || true
  rm -f "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/sqldrivers/libqsqlpsql.so" 2>/dev/null || true
  rm -f "$APPDIR/usr/lib/python${PYTHON_VER}/site-packages/PyQt5/Qt5/plugins/texttospeech/libqtexttospeech_speechd.so" 2>/dev/null || true

  LDA_BIN="$TOOLSDIR/linuxdeploy-x86_64/AppRun"
  [ -x "$LDA_BIN" ] || LDA_BIN="$TOOLSDIR/linuxdeploy-x86_64.AppImage"
  LD_LIBRARY_PATH="" "$LDA_BIN" --appdir "$APPDIR" --plugin qt --output appimage 2>&1 || \
    echo "WARNING: linuxdeploy a échoué"
fi

# --- Créer l'AppImage ---
echo "=== Creating AppImage ==="
APPIMAGE="ddt4all-${VERSION}-${OUTPUT_ARCH}.AppImage"

if [ -x "$TOOLSDIR/appimagetool-${TOOL_ARCH}/AppRun" ]; then
  ARCH="$APPIMAGE_ARCH" "$TOOLSDIR/appimagetool-${TOOL_ARCH}/AppRun" "$APPDIR" "$ROOT/$APPIMAGE"
elif [ -f "$TOOLSDIR/$TOOL_FILE" ]; then
  cd "$TOOLSDIR" && ARCH="$APPIMAGE_ARCH" "./$TOOL_FILE" "$APPDIR" "$ROOT/$APPIMAGE" || true
  cd "$ROOT"
fi

# Si l'AppImage n'a pas été créée, chercher un fichier .AppImage
if [ ! -f "$ROOT/$APPIMAGE" ]; then
  found="$(find "$ROOT" -maxdepth 1 -name '*.AppImage' 2>/dev/null | head -1)"
  if [ -n "$found" ] && [ "$found" != "$ROOT/$APPIMAGE" ]; then
    mv "$found" "$ROOT/$APPIMAGE"
  fi
fi

echo ""
echo "=== Done: $APPIMAGE ==="
ls -lh "$ROOT/$APPIMAGE"
