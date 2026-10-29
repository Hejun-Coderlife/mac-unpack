# 解压（Unpack）

Mac 上的解压/压缩小工具：把压缩包拖进窗口（或双击、拖到 Dock 图标、访达右键「服务 → 用「解压」处理」）就解开。

- 格式：zip / 7z / rar(含 RAR5) / tar / gz / bz2 / xz / zst / iso / cab / wim / arj / lzh …（引擎：内置 7-Zip 26；RAR 用内置 unar，因为 Homebrew 版 7-Zip 不带 RAR 解码器）
- 分卷：xxx.part1.rar、xxx.7z.001、xxx.z01、xxx.r00，拖哪一卷都行，自动从第一卷开始
- 加密：输对的密码存进钥匙串「密码本」，下次遇到加密包先自动挨个试
- 乱码：Windows 做的 GBK / 日文 / 繁体 zip 自动识别编码（读 zip 中央目录原始字节判断，交给系统 bsdtar 按正确编码解）
- 智能放置：只有一个顶层文件夹就直接放出来，零散多个就装进以压缩包命名的文件夹；重名自动加编号
- .tar.gz 一次解到底；去掉 __MACOSX / .DS_Store / Thumbs.db；保留下载隔离标记
- 解之前查空间；进度、速度、剩余时间；可只勾选几个文件解；空格键快速预览包里的文件
- 拖进文件夹或普通文件 → 压成 zip（UTF-8 文件名，发给 Windows 也不乱码）；设置里可改成默认压 7z、调压缩程度
- 按住 ⌥ 拖进来（或 ⌘N）：先选 zip / 7z、压缩程度、密码（zip 用 AES-256，7z 可连文件名一起加密）、分卷（25 MB / 100 MB / 1 GB / 4 GB）
- 查看内容窗口里：拖出去就解到那里；双击文件用默认程序打开，改完保存自动写回压缩包；「工具」里能检查完整性、转成 zip / 7z
- 新建压缩包时拖进来好几项，可以「每一项各压一个包」
- 设置里：界面语言（跟随系统 / 中文 / English）、版本号和「检查更新」
- 内容窗口有「修改日期」列，点列头按名称 / 大小 / 日期排序；密码本能一个个看、一个个删
- 窗口不在前面时，解完 / 出错 / 要密码弹系统通知，点通知在访达里选中结果
- 右键「用「解压」解压到…」（或 ⇧⌘E）：这次临时选个地方解
- 可选：自动解开「下载」里新下好的压缩包（原包移进废纸篓）；打开后登录自动启动、关窗口不退出
- 自动更新：有新版就在后台下好，退出时换上，下次打开就是新版（设置里可关；状态栏点「现在更新」立刻换）
- 查看内容（访达右键「用「解压」查看内容」、⌘⇧O，或按住 ⌥ 拖进压缩包；设置里可改成双击就先看）：像文件夹一样一层层点进去；zip / 7z / tar 能直接往里拖文件、删除、改名，加密包新加的文件沿用原密码和加密方式（RAR、分卷包、旧编码 zip 只能看）

编译：`./build.sh`（只要命令行开发工具），装到 /Applications/解压.app。
自测（不弹窗）：`UNPACK_TEST=a.zip:b.7z UNPACK_DEST=/tmp/out [UNPACK_PW=密码] /Applications/解压.app/Contents/MacOS/Unpack`
- 压缩选项：对文件夹/普通文件加 `UNPACK_FORMAT=7z UNPACK_LEVEL=9 UNPACK_PW=密码 UNPACK_SPLIT=分卷MB`
- 改包：`UNPACK_EDIT="add<Tab>包里文件夹<Tab>/本机/文件;rename<Tab>旧路径<Tab>新名字;delete<Tab>路径"`，改完列出内容
- 截图：`UNPACK_SHOW=browse:压缩包` / `compose:文件` 直接打开对应窗口

vendor/7zz 来自 7-Zip（www.7-zip.org，GNU LGPL）；vendor/unar 来自 The Unarchiver（LGPL）。

## Windows 版

`windows/` 里是 Windows 版（C# / .NET 8 WinForms，x64 单文件，不用装 .NET），功能和 Mac 版对齐：拖进来就解、分卷、密码本、压缩选项（按住 Alt 拖进来 / Ctrl+N）、查看内容并直接改包（右键 / Ctrl+Shift+O / 按住 Alt 拖进来）、拖出来、双击改完自动写回、检查完整性、转格式、批量压缩、后台自动更新、深色模式（跟随系统）、界面语言可选、按日期排序、密码本逐个管理、后台完成通知（托盘气泡）、右键「解压到…」、自动解开「下载」（开机启动、关窗口收到托盘）；Win11 可在设置里开「右键直接显示」（换回经典右键菜单）（用 Windows 账户 DPAPI 加密存在 `%APPDATA%\Unpack`）、GBK/日文/繁体 zip 自动识别编码、智能放置、.tar.gz 一步解到底、去垃圾文件、勾选部分文件解、拖文件夹压成 UTF-8 zip；设置里可把「用解压处理」加进资源管理器右键菜单（只写 HKCU，不要管理员）。

- 引擎：放在 `解压.exe` 旁边的官方 7-Zip（`7z.exe` + `7z.dll`，自带 RAR 解码，`-mcp=` 在 Windows 上有效，所以不需要 unar / bsdtar）
- 编译和打包在 GitHub Actions 的 Windows 机器上做（`.github/workflows/windows.yml`）：下载官方 7-Zip → `dotnet publish` → 打成 `Unpack-Windows-x64.zip` → 跑 `windows/tests/run_tests.py` 自测
- 自测（不弹窗）：`set UNPACK_TEST=a.zip;b.7z` `set UNPACK_DEST=目录` [`UNPACK_PW=密码`] [`UNPACK_LOG=结果文件`]，再运行 `解压.exe`，有失败退出码为 1
- 7-Zip 来自 www.7-zip.org（Igor Pavlov），GNU LGPL + unRAR 限制，许可证随包附带为「7-Zip License.txt」

## Windows version

`windows/` contains the Windows port (C# / .NET 8 WinForms, self-contained x64 single-file exe) with the same features. It bundles the official 7-Zip (`7z.exe` + `7z.dll`, which includes the RAR decoder) next to the exe. It is built, packaged as `Unpack-Windows-x64.zip` and self-tested by GitHub Actions on Windows. 7-Zip is © Igor Pavlov, licensed under GNU LGPL with the unRAR restriction; its license ships as "7-Zip License.txt".
