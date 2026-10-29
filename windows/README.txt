解压（Unpack）Windows 版
========================

把压缩包拖进「解压.exe」的窗口（或拖到 解压.exe 图标上、双击关联的压缩包）就解开；
拖进文件夹或普通文件则压成 zip（文件名存 UTF-8，到哪台电脑都不乱码）。

- 格式：zip / 7z / rar(含 RAR5) / tar / gz / bz2 / xz / zst / iso / cab / wim …
- 分卷：xxx.part1.rar、xxx.7z.001、xxx.z01、xxx.r00，拖哪一卷都行
- 加密：输对的密码存进密码本（用你的 Windows 账户加密，存在 %APPDATA%\Unpack），下次自动先试
- 乱码：别的电脑做的 GBK / 日文 / 繁体 zip 自动识别编码
- 设置里可以把「用解压处理」加到资源管理器右键菜单（只改当前用户，不要管理员）

安装：下载 Unpack-Setup.exe 双击，点「安装」就好。不要管理员权限，装在 %LOCALAPPDATA%\Programs\Unpack，桌面和开始菜单各一个「解压」，装完自动打开。
- 完成页上勾着「打开默认应用设置」：Windows 不允许安装程序替你改 zip、rar、7z 的默认打开方式，在那一页点一下「解压」，之后双击压缩包就用它解开，图标也换成「解压」的
- 有新版本时窗口底部会提示，点「更新」才下载安装，装完自动重新打开
- 卸载：「设置 → 应用 → 已安装的应用」里找「解压」，会把文件、文件类型登记、右键菜单、设置和密码本都删干净
- 用过 v1.0 的 zip 版：直接装安装版，然后把原来那个 解压.exe 所在的文件夹删掉即可

7z.exe / 7z.dll 来自 7-Zip（www.7-zip.org，Igor Pavlov），GNU LGPL + unRAR 限制，见「7-Zip License.txt」。

Unpack for Windows: drop archives on the window to extract, drop folders/files to zip.
Install with Unpack-Setup.exe (no admin needed). 7-Zip is © Igor Pavlov, GNU LGPL (see "7-Zip License.txt").
