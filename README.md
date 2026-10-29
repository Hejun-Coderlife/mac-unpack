# 解压（Unpack）

Mac 上的解压/压缩小工具：把压缩包拖进窗口（或双击、拖到 Dock 图标、访达右键「服务 → 用「解压」处理」）就解开。

- 格式：zip / 7z / rar(含 RAR5) / tar / gz / bz2 / xz / zst / iso / cab / wim / arj / lzh …（引擎：内置 7-Zip 26；RAR 用内置 unar，因为 Homebrew 版 7-Zip 不带 RAR 解码器）
- 分卷：xxx.part1.rar、xxx.7z.001、xxx.z01、xxx.r00，拖哪一卷都行，自动从第一卷开始
- 加密：输对的密码存进钥匙串「密码本」，下次遇到加密包先自动挨个试
- 乱码：Windows 做的 GBK / 日文 / 繁体 zip 自动识别编码（读 zip 中央目录原始字节判断，交给系统 bsdtar 按正确编码解）
- 智能放置：只有一个顶层文件夹就直接放出来，零散多个就装进以压缩包命名的文件夹；重名自动加编号
- .tar.gz 一次解到底；去掉 __MACOSX / .DS_Store / Thumbs.db；保留下载隔离标记
- 解之前查空间；进度、速度、剩余时间；可只勾选几个文件解；空格键快速预览包里的文件
- 拖进文件夹或普通文件 → 压成 zip（UTF-8 文件名，发给 Windows 也不乱码）

编译：`./build.sh`（只要命令行开发工具），装到 /Applications/解压.app。
自测（不弹窗）：`UNPACK_TEST=a.zip:b.7z UNPACK_DEST=/tmp/out [UNPACK_PW=密码] /Applications/解压.app/Contents/MacOS/Unpack`

vendor/7zz 来自 7-Zip（www.7-zip.org，GNU LGPL）；vendor/unar 来自 The Unarchiver（LGPL）。
