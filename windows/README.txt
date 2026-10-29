解压（Unpack）Windows 版
========================

把压缩包拖进「解压.exe」的窗口（或拖到 解压.exe 图标上、双击关联的压缩包）就解开；
拖进文件夹或普通文件则压成 zip（文件名存 UTF-8，到哪台电脑都不乱码）；设置里可改成默认压 7z、调压缩程度。

- 格式：zip / 7z / rar(含 RAR5) / tar / gz / bz2 / xz / zst / iso / cab / wim …
- 分卷：xxx.part1.rar、xxx.7z.001、xxx.z01、xxx.r00，拖哪一卷都行
- 加密：输对的密码存进密码本（用你的 Windows 账户加密，存在 %APPDATA%\Unpack），下次自动先试
- 乱码：别的电脑做的 GBK / 日文 / 繁体 zip 自动识别编码
- 压缩选项：按住 Alt 把文件夹拖进来（或 Ctrl+N），可选 zip / 7z、压缩程度、密码（zip 用 AES-256，7z 可连文件名一起加密）、分卷
- 查看内容：右键压缩包「用「解压」查看内容」、Ctrl+Shift+O，或按住 Alt 把压缩包拖进来；像文件夹一样一层层点进去，
  zip / 7z / tar 能直接往里拖文件、删除（Delete）、改名（F2）；RAR、分卷包、旧编码 zip 只能看。设置里可改成双击就先看
- 设置里可以把「用解压处理」「用解压查看内容」加到资源管理器右键菜单（只改当前用户，不要管理员）

安装：下载 Unpack-Setup.exe 双击，点「安装」就好。不要管理员权限，装在 %LOCALAPPDATA%\Programs\Unpack，桌面和开始菜单各一个「解压」，装完自动打开。
- 完成页上勾着「打开默认应用设置」：Windows 不允许安装程序替你改 zip、rar、7z 的默认打开方式，在那一页点一下「解压」，之后双击压缩包就用它解开，图标也换成「解压」的
- 自动更新：有新版本就在后台下好，关掉「解压」时悄悄装上，下次打开就是新版；状态栏点「现在装」可立刻更新（设置里可关）
- 卸载：「设置 → 应用 → 已安装的应用」里找「解压」，会把文件、文件类型登记、右键菜单、设置和密码本都删干净
- 用过 v1.0 的 zip 版：直接装安装版，然后把原来那个 解压.exe 所在的文件夹删掉即可

7z.exe / 7z.dll 来自 7-Zip（www.7-zip.org，Igor Pavlov），GNU LGPL + unRAR 限制，见「7-Zip License.txt」。

Unpack for Windows: drop archives on the window to extract, drop folders/files to zip.
Install with Unpack-Setup.exe (no admin needed). 7-Zip is © Igor Pavlov, GNU LGPL (see "7-Zip License.txt").
