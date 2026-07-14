#!/bin/bash
set -e

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo "dev")}"
ARCH="${2:-${ARCH:-x86_64}}"

case "$ARCH" in
  x86_64|amd64)
    LDA_ARCH="x86_64"
    PLUGIN_ARCH="x86_64"
    TOOL_ARCH="x86_64"
    OUTPUT_ARCH="x86_64"
    APPIMAGE_ARCH="x86_64"
    LDA_RELEASE="continuous" ;;
  x86_32|i686|i386)
    LDA_ARCH="i386"
    PLUGIN_ARCH="i386"
    TOOL_ARCH="i686"
    OUTPUT_ARCH="x86_32"
    APPIMAGE_ARCH="x86"
    LDA_RELEASE="1-alpha-20251107-1" ;;
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

# --- Télécharger les outils ---
mkdir -p "$TOOLSDIR"
cd "$TOOLSDIR"

LDA_FILE="linuxdeploy-${LDA_ARCH}.AppImage"
PLUGIN_FILE="linuxdeploy-plugin-qt-${PLUGIN_ARCH}.AppImage"
TOOL_FILE="appimagetool-${TOOL_ARCH}.AppImage"

if [ ! -f "$LDA_FILE" ]; then
  wget -q "https://github.com/linuxdeploy/linuxdeploy/releases/download/${LDA_RELEASE}/linuxdeploy-${LDA_ARCH}.AppImage" -O "$LDA_FILE"
fi
if [ ! -f "$PLUGIN_FILE" ]; then
  wget -q "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/${PLUGIN_FILE}" -O "$PLUGIN_FILE"
fi
if [ ! -f "$TOOL_FILE" ]; then
  wget -q "https://github.com/AppImage/appimagetool/releases/download/continuous/${TOOL_FILE}" -O "$TOOL_FILE"
fi

chmod +x *.AppImage

cd "$ROOT"

# --- Bundler Qt5 ---
echo "=== Bundling Qt5 ==="
for f in "$TOOLSDIR"/*.AppImage; do
  bn="$(basename "$f" .AppImage)"
  out="$TOOLSDIR/$bn"
  if [ ! -d "$out" ]; then
    (cd "$TOOLSDIR" && "$f" --appimage-extract && mv squashfs-root "$bn") || true
  fi
done

# Linuxdeploy cherche les plugins dans son répertoire plugins/
LDA_DIR="$TOOLSDIR/linuxdeploy-${LDA_ARCH}"
PLUGIN_DIR="$TOOLSDIR/linuxdeploy-plugin-qt-${PLUGIN_ARCH}"
if [ -x "$PLUGIN_DIR/AppRun" ] && [ -d "$LDA_DIR/plugins" ]; then
  ln -sfT "$PLUGIN_DIR" "$LDA_DIR/plugins/linuxdeploy-plugin-qt"
fi

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

LDA_BIN="linuxdeploy-${LDA_ARCH}/AppRun"
if [ ! -x "$TOOLSDIR/$LDA_BIN" ]; then
  LDA_BIN="linuxdeploy-${LDA_ARCH}.AppImage"
fi

# Lancer linuxdeploy depuis $TOOLSDIR pour qu'il trouve le plugin-qt
(cd "$TOOLSDIR" && LD_LIBRARY_PATH="" ./$LDA_BIN --appdir "$APPDIR" --plugin qt --output appimage) 2>&1 || {
  cd "$ROOT"
  echo "WARNING: linuxdeploy --output appimage a échoué"

  APPIMAGE="ddt4all-${VERSION}-${OUTPUT_ARCH}.AppImage"
  if [ -x "$TOOLSDIR/appimagetool-${TOOL_ARCH}/AppRun" ]; then
    ARCH="$APPIMAGE_ARCH" "$TOOLSDIR/appimagetool-${TOOL_ARCH}/AppRun" "$APPDIR" "$ROOT/$APPIMAGE"
  elif [ -x "$TOOLSDIR/${TOOL_FILE}" ]; then
    cd "$TOOLSDIR" && ARCH="$APPIMAGE_ARCH" "./${TOOL_FILE}" "$APPDIR" "$ROOT/$APPIMAGE" && cd "$ROOT"
  else
    echo "ERROR: aucun outil disponible pour créer l'AppImage"
    exit 1
  fi
}

# Si linuxdeploy --output appimage a créé l'AppImage, on la renomme
APPIMAGE="ddt4all-${VERSION}-${OUTPUT_ARCH}.AppImage"
if [ ! -f "$ROOT/$APPIMAGE" ]; then
  found="$(find "$ROOT" -maxdepth 1 -name '*.AppImage' 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    mv "$found" "$ROOT/$APPIMAGE"
  fi
fi

echo ""
echo "=== Done: $APPIMAGE ==="
ls -lh "$ROOT/$APPIMAGE"
