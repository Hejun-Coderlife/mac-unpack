#!/bin/sh
# 编译成 解压.app（只要命令行开发工具，不用 Xcode），装到 /Applications
set -e
cd "$(dirname "$0")"
APP="build/解压.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -framework QuickLook -framework Security \
  Unpack.swift -o "$APP/Contents/MacOS/Unpack"
# 引擎：7-Zip 命令行版（vendor/7zz，取自 Homebrew 的 sevenzip，LGPL）；RAR 用 unar（vendor/unar，取自 Homebrew，LGPL，只依赖系统库）
cp vendor/7zz vendor/unar "$APP/Contents/Resources/"
# 图标：tools/icon.swift 画 1024 原稿 → 各尺寸 → icns（已有 AppIcon.icns 就不重画）
if [ ! -f AppIcon.icns ]; then
  ICON=build/AppIcon.iconset; mkdir -p "$ICON"
  swift tools/icon.swift build/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "$ICON/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out "$ICON/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICON" -o AppIcon.icns
fi
cp AppIcon.icns "$APP/Contents/Resources/"
# App 名字跟随系统语言：中文叫「解压」，其他语言叫 Unpack
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
printf '"CFBundleName" = "解压";\n"CFBundleDisplayName" = "解压";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf '"CFBundleName" = "Unpack";\n"CFBundleDisplayName" = "Unpack";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
printf '"用「解压」处理" = "用「解压」处理";\n' > "$APP/Contents/Resources/zh-Hans.lproj/ServicesMenu.strings"
printf '"用「解压」处理" = "Unpack or Zip";\n' > "$APP/Contents/Resources/en.lproj/ServicesMenu.strings"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>解压</string>
  <key>CFBundleDisplayName</key><string>解压</string>
  <key>CFBundleIdentifier</key><string>com.hejun.unpack</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Unpack</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- 能打开的压缩包类型（访达「打开方式」里会出现；Alternate = 不抢系统默认，想默认用它就在「显示简介」里设「全部更改」）-->
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Archive</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array>
        <string>public.zip-archive</string><string>org.7-zip.7-zip-archive</string><string>com.rarlab.rar-archive</string>
        <string>public.tar-archive</string><string>org.gnu.gnu-zip-archive</string><string>org.gnu.gnu-zip-tar-archive</string>
        <string>public.bzip2-archive</string><string>org.tukaani.xz-archive</string><string>public.zstd-archive</string>
        <string>public.iso-image</string><string>com.microsoft.cab</string><string>public.cpio-archive</string>
        <string>public.archive</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Archive Volume</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array>
        <string>001</string><string>z01</string><string>r00</string><string>tgz</string><string>tbz2</string><string>txz</string>
        <string>tzst</string><string>lzh</string><string>lha</string><string>arj</string><string>wim</string><string>zst</string>
      </array>
    </dict>
  </array>
  <!-- 访达右键 → 快速操作/服务 →「用「解压」处理」-->
  <key>NSServices</key><array>
    <dict>
      <key>NSMessage</key><string>unpackFiles</string>
      <key>NSMenuItem</key><dict><key>default</key><string>用「解压」处理</string></dict>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict></plist>
PLIST
# 用钥匙串里固定的本机证书签名：重编译后系统仍认得是同一个程序，钥匙串里的密码本不会每次都弹窗问；没有证书时退回临时签名
if security find-identity -v -p codesigning | grep -q "Hejun Local Code Signing"; then SIGN="Hejun Local Code Signing"; else SIGN=-; fi
codesign --force -s "$SIGN" "$APP/Contents/Resources/7zz" "$APP/Contents/Resources/unar"
codesign --force -s "$SIGN" "$APP"
rm -rf "/Applications/解压.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/解压.app"
echo "OK: /Applications/解压.app"
