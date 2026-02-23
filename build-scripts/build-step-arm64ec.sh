#!/bin/bash
set -euo pipefail

export ARCH="aarch64"
export WIN_ARCH="arm64ec,aarch64,i386"
export JOBS="${JOBS:-4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/out/compiled-files-aarch64}"

export deps="${deps:-$PROJECT_ROOT/out/termuxfs/aarch64/data/data/com.termux/files/usr}"
export RUNTIME_PATH="${RUNTIME_PATH:-/data/data/com.termux/files/usr}"
export install_dir=$deps/../opt/wine
export CCACHE_DIR="${CCACHE_DIR:-$PROJECT_ROOT/out/.ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-$PROJECT_ROOT/out/.ccache-tmp}"
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"

#export TOOLCHAIN="$HOME/Android/android-ndk-r27d/toolchains/llvm/prebuilt/linux-x86_64/bin"
export TOOLCHAIN="${TOOLCHAIN:-$HOME/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin}"
export LLVM_MINGW_TOOLCHAIN="${LLVM_MINGW_TOOLCHAIN:-$HOME/toolchains/llvm-mingw-20250920-ucrt-ubuntu-22.04-x86_64/bin}"
export TARGET="${TARGET:-aarch64-linux-android28}"
export PATH="$LLVM_MINGW_TOOLCHAIN:$PATH"

HOST_ARG=(--host="$TARGET")
SYSROOT="$TOOLCHAIN/../sysroot"
if [ -x "$TOOLCHAIN/$TARGET-clang" ]; then
  export CC="$TOOLCHAIN/$TARGET-clang"
  export AS="$CC"
  export CXX="$TOOLCHAIN/$TARGET-clang++"
  export AR="$TOOLCHAIN/llvm-ar"
  export LD="$TOOLCHAIN/ld"
  export RANLIB="$TOOLCHAIN/llvm-ranlib"
  export STRIP="$TOOLCHAIN/llvm-strip"
  export DLLTOOL="$LLVM_MINGW_TOOLCHAIN/llvm-dlltool"
else
  echo "Info: Android NDK not found, using native Ubuntu toolchain fallback."
  HOST_ARG=()
  SYSROOT=""
  export CC="${CC:-ccache clang}"
  export AS="${AS:-clang}"
  export CXX="${CXX:-ccache clang++}"
  export AR="${AR:-llvm-ar}"
  export LD="${LD:-ld.lld}"
  export RANLIB="${RANLIB:-llvm-ranlib}"
  export STRIP="${STRIP:-llvm-strip}"
  export DLLTOOL="${DLLTOOL:-llvm-dlltool}"
fi

if [ ! -x "$LLVM_MINGW_TOOLCHAIN/aarch64-w64-mingw32-clang" ] || [ ! -x "$LLVM_MINGW_TOOLCHAIN/i686-w64-mingw32-clang" ]; then
  echo "Error: llvm-mingw toolchain not found in $LLVM_MINGW_TOOLCHAIN"
  exit 1
fi

# Force a dedicated ARM64EC cross-compiler name so Wine configure
# does not fall back to plain "clang" with unsupported "arm64ec-windows".
export ARM64EC_WRAPPER_DIR="${ARM64EC_WRAPPER_DIR:-$PROJECT_ROOT/out/toolchains/arm64ec-wrapper/bin}"
mkdir -p "$ARM64EC_WRAPPER_DIR"
cat > "$ARM64EC_WRAPPER_DIR/arm64ec-w64-mingw32-clang" <<EOF
#!/bin/sh
exec "$LLVM_MINGW_TOOLCHAIN/clang" --target=arm64ec-w64-mingw32 "\$@"
EOF
chmod +x "$ARM64EC_WRAPPER_DIR/arm64ec-w64-mingw32-clang"

# Provide weak fallback aliases for arm64ec-only unresolved stubs generated from .spec files.
ARM64EC_STUB_ALIAS_SRC="$ARM64EC_WRAPPER_DIR/arm64ec-stub-aliases.S"
ARM64EC_STUB_ALIAS_OBJ="$ARM64EC_WRAPPER_DIR/arm64ec-stub-aliases.o"
cat > "$ARM64EC_STUB_ALIAS_SRC" <<'EOF'
    .text
    .p2align 2
    .globl __wine_arm64ec_unimplemented
__wine_arm64ec_unimplemented:
    mov w0, #1
    ret

    .section .drectve
EOF

{
  echo '    .ascii " /alternatename:DllCanUnloadNow=__wine_arm64ec_unimplemented"'
  echo '    .ascii " /alternatename:DllRegisterServer=__wine_arm64ec_unimplemented"'
  echo '    .ascii " /alternatename:DllUnregisterServer=__wine_arm64ec_unimplemented"'
  find "$PROJECT_ROOT/dlls" -name '*.spec' -type f | sort | while IFS= read -r spec; do
    awk '
      /^[[:space:]]*(@|[0-9]+)/ {
        for (i=1; i<=NF; i++) if ($i == "stub") {
          sym = $NF
          gsub(/[^A-Za-z0-9_]/, "", sym)
          if (sym != "" && sym != "stub") print sym
          break
        }
      }
    ' "$spec"
  done | sort -u | while IFS= read -r sym; do
        case "$sym" in
          ''|*[!A-Za-z0-9_]*)
            continue
            ;;
        esac
        alias="__wine_stub_${sym}"
        alias_escaped=${alias//\\/\\\\}
        alias_escaped=${alias_escaped//\"/\\\"}
        printf '    .ascii " /alternatename:%s=__wine_arm64ec_unimplemented"\n' "$alias_escaped"
      done
  find "$PROJECT_ROOT/dlls" -name '*.spec' -type f | sort | while IFS= read -r spec; do
    mod=$(basename "$spec" .spec)
    mod=${mod//[^A-Za-z0-9_]/_}
    awk -v m="$mod" '
      /^[[:space:]]*[0-9]+[[:space:]]+stub([[:space:]]|$)/ {
        ord=$1
        gsub(/[^0-9]/,"",ord)
        if (ord != "") print "__wine_stub_" m "_dll_" ord
      }
    ' "$spec"
  done | sort -u | while IFS= read -r alias; do
    alias_escaped=${alias//\\/\\\\}
    alias_escaped=${alias_escaped//\"/\\\"}
    printf '    .ascii " /alternatename:%s=__wine_arm64ec_unimplemented"\n' "$alias_escaped"
  done
} >> "$ARM64EC_STUB_ALIAS_SRC"

"$LLVM_MINGW_TOOLCHAIN/clang" --target=arm64ec-w64-mingw32 -c "$ARM64EC_STUB_ALIAS_SRC" -o "$ARM64EC_STUB_ALIAS_OBJ"

# Some Wine link paths still invoke *-gcc and can request libgcc.a which is
# not present in this llvm-mingw setup. Provide gcc-compatible wrappers that
# forward to clang and drop explicit -lgcc/-lgcc_eh requests.
make_gcc_wrapper() {
  local name="$1"
  local target="$2"
  local extra_obj="${3:-}"
  local force_unresolved="${4:-0}"
  cat > "$ARM64EC_WRAPPER_DIR/$name" <<EOF
#!/usr/bin/env bash
set -e
args=()
compile_only=0
for a in "\$@"; do
  case "\$a" in
    -lgcc|-lgcc_eh) continue ;;
    -c|-S|-E|-M|-MM|-fsyntax-only) compile_only=1; args+=("\$a") ;;
    *) args+=("\$a") ;;
  esac
done
if [ "\$compile_only" -eq 0 ] && [ -n "$extra_obj" ]; then
  args+=("$extra_obj")
fi
if [ "\$compile_only" -eq 0 ] && [ "$force_unresolved" = "1" ]; then
  args+=("-Wl,/force:unresolved")
fi
exec "$LLVM_MINGW_TOOLCHAIN/clang" --target="$target" -rtlib=compiler-rt "\${args[@]}"
EOF
  chmod +x "$ARM64EC_WRAPPER_DIR/$name"
}

make_gcc_wrapper "i686-w64-mingw32-gcc" "i686-w64-mingw32"
make_gcc_wrapper "x86_64-w64-mingw32-gcc" "x86_64-w64-mingw32"
make_gcc_wrapper "aarch64-w64-mingw32-gcc" "aarch64-w64-mingw32"
make_gcc_wrapper "arm64ec-w64-mingw32-gcc" "arm64ec-w64-mingw32" "$ARM64EC_STUB_ALIAS_OBJ" "1"

HOST_CLANG_REAL="${HOST_CLANG_REAL:-$(command -v clang || true)}"
HOST_CLANGXX_REAL="${HOST_CLANGXX_REAL:-$(command -v clang++ || true)}"

if [ -n "$HOST_CLANG_REAL" ]; then
  cat > "$ARM64EC_WRAPPER_DIR/clang" <<EOF
#!/usr/bin/env bash
set -e
target_arg=""
for a in "\$@"; do
  case "\$a" in
    --target=*) target_arg="\${a#--target=}" ;;
  esac
done
if [ -z "\$target_arg" ]; then
  args=()
  for a in "\$@"; do
    [ "\$a" = "-mabi=ms" ] && continue
    args+=("\$a")
  done
  exec "$HOST_CLANG_REAL" "\${args[@]}"
fi
exec "$HOST_CLANG_REAL" "\$@"
EOF
  chmod +x "$ARM64EC_WRAPPER_DIR/clang"
fi

if [ -n "$HOST_CLANGXX_REAL" ]; then
  cat > "$ARM64EC_WRAPPER_DIR/clang++" <<EOF
#!/usr/bin/env bash
set -e
target_arg=""
for a in "\$@"; do
  case "\$a" in
    --target=*) target_arg="\${a#--target=}" ;;
  esac
done
if [ -z "\$target_arg" ]; then
  args=()
  for a in "\$@"; do
    [ "\$a" = "-mabi=ms" ] && continue
    args+=("\$a")
  done
  exec "$HOST_CLANGXX_REAL" "\${args[@]}"
fi
exec "$HOST_CLANGXX_REAL" "\$@"
EOF
  chmod +x "$ARM64EC_WRAPPER_DIR/clang++"
fi

export PATH="$ARM64EC_WRAPPER_DIR:$PATH"
export arm64ec_CC="$ARM64EC_WRAPPER_DIR/arm64ec-w64-mingw32-clang"
export aarch64_CC="$LLVM_MINGW_TOOLCHAIN/aarch64-w64-mingw32-clang"
export i386_CC="$LLVM_MINGW_TOOLCHAIN/i686-w64-mingw32-clang"
export x86_64_CC="$LLVM_MINGW_TOOLCHAIN/x86_64-w64-mingw32-clang"

export PKG_CONFIG_LIBDIR=$deps/lib/pkgconfig:$deps/share/pkgconfig
export ACLOCAL_PATH=$deps/lib/aclocal:$deps/share/aclocal
if [ -n "$SYSROOT" ]; then
  export CPPFLAGS="-I$deps/include --sysroot=$SYSROOT"
else
  export CPPFLAGS="-I$deps/include"
fi

export C_OPTS="-Wno-declaration-after-statement -Wno-implicit-function-declaration -Wno-int-conversion"
export CFLAGS=$C_OPTS
export CXXFLAGS=$C_OPTS
export LDFLAGS="-L$deps/lib -Wl,-rpath=$RUNTIME_PATH/lib"

export FREETYPE_CFLAGS="-I$deps/include/freetype2"
export PULSE_CFLAGS="-I$deps/include/pulse"
export PULSE_LIBS="-L$deps/lib/pulseaudio -lpulse"
export SDL2_CFLAGS="-I$deps/include/SDL2"
export SDL2_LIBS="-L$deps/lib -lSDL2"
export X_CFLAGS="-I$deps/include/X11"
export X_LIBS="-landroid-sysvshm"
export GSTREAMER_CFLAGS="-I$deps/include/gstreamer-1.0 -I$deps/include/glib-2.0 -I$deps/lib/glib-2.0/include -I$deps/glib-2.0/include -I$deps/lib/gstreamer-1.0/include"
export GSTREAMER_LIBS="-L$deps/lib -lgstgl-1.0 -lgstapp-1.0 -lgstvideo-1.0 -lgstaudio-1.0 -lglib-2.0 -lgobject-2.0 -lgio-2.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0"
export FFMPEG_CFLAGS="-I$deps/include/libavutil -I$deps/include/libavcodec -I$deps/include/libavformat"
export FFMPEG_LIBS="-L$deps/lib -lavutil -lavcodec -lavformat"

if [ -z "$SYSROOT" ]; then
  # In VM fallback mode rely on system pkg-config paths instead of termux-style deps.
  export CPPFLAGS=""
  export LDFLAGS=""
  unset PKG_CONFIG_LIBDIR ACLOCAL_PATH
  unset FREETYPE_CFLAGS PULSE_CFLAGS PULSE_LIBS SDL2_CFLAGS SDL2_LIBS
  unset X_CFLAGS X_LIBS GSTREAMER_CFLAGS GSTREAMER_LIBS FFMPEG_CFLAGS FFMPEG_LIBS
fi

for arg in "$@"
do
  if [ "$arg" == "--build-sysvshm" ];
  then
    # Build android_sysvshm library
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

    if [ -d "$PROJECT_ROOT/android/android_sysvshm" ]; then
        echo "Building android_sysvshm library..."
        cd "$PROJECT_ROOT/android/android_sysvshm"
        ./build-aarch64.sh
        if [ $? -eq 0 ]; then
            echo "android_sysvshm built successfully"
            # Copy the library to deps/lib for linking
            mkdir -p "$deps/lib"
            cp build-aarch64/libandroid-sysvshm.so "$deps/lib/"
            echo "Copied libandroid-sysvshm.so to $deps/lib/"
        else
            echo "Warning: android_sysvshm build failed"
        fi
        cd "$PROJECT_ROOT"
    fi
  fi

  if [ "$arg" == "--configure" ];
  then
    for cc in "$arm64ec_CC" "$aarch64_CC" "$i386_CC"; do
      if [ ! -x "$cc" ]; then
        echo "Error: cross-compiler not found or not executable: $cc"
        exit 1
      fi
    done

    WINE_TOOLS_ARG=()
    if [ -d "./wine-tools" ]; then
      WINE_TOOLS_ARG=(--with-wine-tools=./wine-tools)
    fi

    ./configure \
      --enable-archs=$WIN_ARCH \
      "${HOST_ARG[@]}" \
      --prefix $install_dir \
      --bindir $install_dir/bin \
      --libdir $install_dir/lib \
      --exec-prefix $install_dir \
      "${WINE_TOOLS_ARG[@]}" \
      --enable-win64 \
      --enable-nls \
      --disable-amd_ags_x64 \
      --enable-wineandroid_drv=no \
      --disable-win16 \
      --disable-tests \
      --with-alsa \
      --without-capi \
      --without-coreaudio \
      --without-cups \
      --without-dbus \
      --without-ffmpeg \
      --with-fontconfig \
      --with-freetype \
      --without-gcrypt \
      --without-gettext \
      --with-gettextpo=no \
      --without-gphoto \
      --with-gnutls \
      --without-gssapi \
      --with-gstreamer \
      --without-inotify \
      --without-krb5 \
      --without-netapi \
      --without-opencl \
      --without-opengl \
      --without-osmesa \
      --without-oss \
      --without-pcap \
      --without-pcsclite \
      --without-piper \
      --with-pthread \
      --with-pulse \
      --without-sane \
      --with-sdl \
      --without-udev \
      --without-unwind \
      --without-usb \
      --without-v4l2 \
      --without-vosk \
      --without-vulkan \
      --without-wayland \
      --without-xcomposite \
      --without-xcursor \
      --without-xfixes \
      --without-xinerama \
      --without-xinput \
      --without-xinput2 \
      --without-xrandr \
      --without-xrender \
      --without-xshape \
      --without-xshm \
      --without-xxf86vm

    echo "Applying patches..."

    PATCHES=(
      # android network patch
      "android_network.patch"
      "dlls_nsiproxy_sys_ip_c.patch"

      # midi support
      "midi_support.patch"

      # sdl patch
      "dlls_winebus_sys_bus_sdl_c.patch"

      # shm_utils
      "dlls_ntdll_unix_esync_c.patch"
      "dlls_ntdll_unix_fsync_c.patch"
      "server_esync_c.patch"
      "server_fsync_c.patch"

      # winex11
      "dlls_winex11_drv_x11drv_h.patch"
      "dlls_winex11_drv_bitblt_c.patch"
      "dlls_winex11_drv_desktop_c.patch"
      "dlls_winex11_drv_mouse_c.patch"
      "dlls_winex11_drv_window_c.patch"
      "dlls_winex11_drv_x11drv_main_c.patch"

      # address space patches
      "dlls_ntdll_unix_virtual_c.patch"
      "loader_preloader_c.patch"

      # syscall Patches
      "dlls_ntdll_unix_signal_x86_64_c.patch"

      # pulse Patches
      "dlls_winepulse_drv_pulse_c.patch"

      # desktop patches
      "programs_explorer_desktop_c.patch"

      # path patches
      "dlls_ntdll_unix_server_c.patch"

      # winlator patches
      "dlls_amd_ags_x64_unixlib_c.patch"
      "dlls_winex11_drv_opengl_c.patch"

      # advapi32 patches
      "dlls_advapi32_advapi_c.patch"

      # browser patches
      "programs_winebrowser_makefile_in.patch"
      "programs_winebrowser_main_c.patch"

      # clipboard patches
      "dlls_user32_makefile_in.patch"
      "dlls_user32_clipboard_c.patch"
      "dlls_win32u_clipboard_c.patch"

      # fexcore patch
      "dlls_ntdll_loader_c.patch"
      "dlls_ntdll_unix_loader_c.patch"
      "dlls_wow64_syscall_c.patch"
      "loader_wine_inf_in.patch"

      # bylaws patch
#      "test-bylaws/dlls_ntdll_signal_arm64_c.patch"
#      "test-bylaws/dlls_ntdll_signal_arm64ec_c.patch"
#      "test-bylaws/dlls_ntdll_signal_x86_64_c.patch"
#      "test-bylaws/dlls_ntdll_unwind_h.patch"
#      "test-bylaws/include_winnt_h.patch"
      "programs_wineboot_wineboot_c.patch"
      "dlls_wdscore_wdscore_spec.patch"
#      "test-bylaws/dlls_ntdll_ntdll_spec.patch"
#      "test-bylaws/dlls_ntdll_ntdll_misc_h.patch"
#      "test-bylaws/dlls_wow64_process_c.patch"
#      "test-bylaws/dlls_wow64_wow64_spec.patch"
#      "test-bylaws/dlls_wow64_virtual_c.patch"
#      "test-bylaws/include_winternl_h.patch"
#      "test-bylaws/server_thread_h.patch"
#      "test-bylaws/server_thread_c.patch"
#      "test-bylaws/server_process_c.patch"
#      "test-bylaws/dlls_ntdll_unix_thread_c.patch"
#      "test-bylaws/tools_makedep_c.patch"
#      "test-bylaws/dlls_ntdll_unix_process_c.patch"
    )

    for patch in "${PATCHES[@]}"; do
      patch_file="./android/patches/$patch"
      if git apply --check "$patch_file" 2>/dev/null; then
        echo "Applying $patch"
        git apply "$patch_file"
      else
        echo "Skipping incompatible patch: $patch"
      fi
    done
  fi

  if [ "$arg" == "--build" ]
  then
    echo "Building..."
    # arm64ec link stage in this tree can fail on stub/native exports with EC symbols.
    # Strip prefer-native for the generated Makefile in this build to keep stubs linkable.
    if [ -f Makefile ]; then
      sed -i 's/[[:space:]]-Wb,--prefer-native//g' Makefile
    fi
    rm -rf $OUTPUT_DIR/bin
    rm -rf $OUTPUT_DIR/lib
    rm -rf $OUTPUT_DIR/share
    rm -rf $install_dir
    make -j"$JOBS"
  fi

  if [ "$arg" == "--install" ]
  then
    echo "Installing..."
    mkdir -p $OUTPUT_DIR/bin
    mkdir -p $OUTPUT_DIR/lib
    mkdir -p $OUTPUT_DIR/share
    mkdir -p $install_dir

    if make -n install >/dev/null 2>&1; then
      make install -j"$JOBS"
    elif make -n install-lib >/dev/null 2>&1; then
      echo "Target 'install' not found, using 'install-lib'"
      make install-lib -j"$JOBS"
      if make -n install-dev >/dev/null 2>&1; then
        make install-dev -j"$JOBS"
      fi
    else
      echo "Error: no install target found in Makefile"
      exit 1
    fi

    if [ ! -d "$install_dir/bin" ] || [ ! -d "$install_dir/lib/wine" ] || [ ! -d "$install_dir/share/wine" ]; then
      echo "Error: install output is incomplete in $install_dir"
      exit 1
    fi
    if [ ! -f "$install_dir/lib/wine/arm64ec-windows/ntdll.dll" ]; then
      echo "Error: arm64ec ntdll.dll is missing in $install_dir/lib/wine/arm64ec-windows"
      exit 1
    fi

    shopt -s nullglob
    wine_bins=($install_dir/bin/wine*)
    reg_bins=($install_dir/bin/reg*)
    msi_bins=($install_dir/bin/msi*)

    if [ ${#wine_bins[@]} -eq 0 ]; then
      echo "Error: wine binaries not found in $install_dir/bin"
      exit 1
    fi

    cp -r "${wine_bins[@]}" "$OUTPUT_DIR/bin"
    if [ ${#reg_bins[@]} -gt 0 ]; then cp -r "${reg_bins[@]}" "$OUTPUT_DIR/bin"; fi
    if [ ${#msi_bins[@]} -gt 0 ]; then cp -r "${msi_bins[@]}" "$OUTPUT_DIR/bin"; fi
    if [ -e "$install_dir/bin/notepad" ]; then cp -r "$install_dir/bin/notepad" "$OUTPUT_DIR/bin"; fi
    cp -r $install_dir/lib/wine  $OUTPUT_DIR/lib
    cp -r $install_dir/share/wine  $OUTPUT_DIR/share
  fi
done
