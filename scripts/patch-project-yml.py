#!/usr/bin/env python3
from pathlib import Path
import sys
p = Path(sys.argv[1] if len(sys.argv) > 1 else "project.yml")
t = p.read_text()
if "OpenGLES" in t and "Embed N64 plugins" in t:
    print(f"already patched {p}")
    raise SystemExit(0)

old = '''        LIBRARY_SEARCH_PATHS: ["$(inherited)", "$(SRCROOT)/Core/third_party/build"]
        OTHER_LDFLAGS: ["$(inherited)", "-ltwinplay_n64", "-ltwinplay_3ds"]
'''
new = '''        LIBRARY_SEARCH_PATHS: ["$(inherited)", "$(SRCROOT)/Core/third_party/build"]
        OTHER_LDFLAGS: ["$(inherited)", "-ltwinplay_n64", "-ltwinplay_3ds", "-lc++", "-lz",
                        "-framework", "OpenGLES", "-framework", "QuartzCore", "-framework", "Foundation",
                        "-framework", "AVFoundation", "-framework", "IOSurface", "-framework", "AudioToolbox",
                        "-framework", "Security"]
        LD_RUNPATH_SEARCH_PATHS: ["$(inherited)", "@executable_path/Frameworks"]
'''
if old not in t:
    raise SystemExit("OTHER_LDFLAGS block not found")
t = t.replace(old, new, 1)

# Insert a copy/sign script after the preBuildScripts block.
old_script = '''    preBuildScripts:
      - name: N64 and 3DS cores
        script: |
          "${SRCROOT}/scripts/build-n64-3ds.sh"
        basedOnDependencyAnalysis: false
'''
new_script = '''    preBuildScripts:
      - name: N64 and 3DS cores
        script: |
          "${SRCROOT}/scripts/build-n64-3ds.sh"
        basedOnDependencyAnalysis: false
    postCompileScripts:
      - name: Embed N64 plugins
        script: |
          PLUGINS="${SRCROOT}/Core/third_party/build/plugins"
          DEST_FW="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
          DEST_RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/plugins"
          mkdir -p "$DEST_FW" "$DEST_RES"
          shopt -s nullglob
          for f in "$PLUGINS"/*.dylib; do
            name="$(basename "$f")"
            cp -a "$f" "$DEST_FW/$name"
            cp -a "$f" "$DEST_RES/$name"
            install_name_tool -id "@rpath/$name" "$DEST_FW/$name" || true
            if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
              codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$DEST_FW/$name" || true
              codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$DEST_RES/$name" || true
            fi
          done
        basedOnDependencyAnalysis: false
'''
if old_script not in t:
    raise SystemExit("preBuildScripts block not found")
t = t.replace(old_script, new_script, 1)
p.write_text(t)
print(f"patched {p}")
