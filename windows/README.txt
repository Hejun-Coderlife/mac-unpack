解压（Unpack）Windows 版
========================

把压缩包拖进「解压.exe」的窗口（或拖到 解压.exe 图标上、双击关联的压缩包）就解开；
拖进文件夹或普通文件则压成 zip（文件名存 UTF-8，到哪台电脑都不乱码）。

- 格式：zip / 7z / rar(含 RAR5) / tar / gz / bz2 / xz / zst / iso / cab / wim …
- 分卷：xxx.part1.rar、xxx.7z.001、xxx.z01、xxx.r00，拖哪一卷都行
- 加密：输对的密码存进密码本（用你的 Windows 账户加密，存在 %APPDATA%\Unpack），下次自动先试
- 乱码：别的电脑做的 GBK / 日文 / 繁体 zip 自动识别编码
- 设置里可以把「用解压处理」加到资源管理器右键菜单（只改当前用户，不要管理员）

两种用法：
- 安装版 Unpack-Setup-x64.exe：双击压缩包就用「解压」打开，压缩包显示「解压」的文件图标；默认只装给当前用户，不要管理员；在「设置 → 应用」里能卸载，卸载会把注册的东西清干净
- 免安装版：解压.exe 要和 7z.exe、7z.dll 放在同一个文件夹
7z.exe / 7z.dll 来自 7-Zip（www.7-zip.org，Igor Pavlov），GNU LGPL + unRAR 限制，见「7-Zip License.txt」。

Unpack for Windows: drop archives on the window to extract, drop folders/files to zip.
Keep 解压.exe next to 7z.exe and 7z.dll. 7-Zip is © Igor Pavlov, GNU LGPL (see "7-Zip License.txt").
