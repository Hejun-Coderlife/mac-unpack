; 解压（Unpack）Windows 安装版：装到「程序」文件夹，把压缩包格式注册给解压.exe，压缩包显示自己的文件图标（archive.ico）
; 默认只装给当前用户（写 HKCU，不要管理员）；安装界面里也能选「为所有用户安装」
; 编译：iscc /DSrc=dist\Unpack windows\installer.iss（GitHub Actions 里做，见 .github/workflows/windows.yml）

#ifndef Src
  #define Src "..\dist\Unpack"
#endif

[Setup]
AppId={{304E1695-683E-415A-98A6-C6036629DBEC}
AppName=解压
AppVerName=解压 1.0
AppVersion=1.0.0
AppPublisher=Hejun
DefaultDirName={autopf}\Unpack
DefaultGroupName=解压
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ChangesAssociations=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..
OutputBaseFilename=Unpack-Setup-x64
SetupIconFile=app.ico
UninstallDisplayIcon={app}\解压.exe
UninstallDisplayName=解压
WizardStyle=modern
ShowLanguageDialog=no
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "zh"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
zh.Assoc=双击压缩包用「解压」打开，并显示「解压」的文件图标
en.Assoc=Open archives with Unpack and show its file icon
zh.Menu=在右键菜单里加「用「解压」处理」
en.Menu=Add "Open with Unpack" to the right-click menu
zh.Desktop=在桌面放快捷方式
en.Desktop=Create a desktop shortcut
zh.TypeName=压缩包
en.TypeName=Archive
zh.MenuText=用「解压」处理
en.MenuText=Open with Unpack
zh.Launch=打开「解压」
en.Launch=Launch Unpack

[Tasks]
Name: "assoc"; Description: "{cm:Assoc}"
Name: "menu"; Description: "{cm:Menu}"
Name: "desktop"; Description: "{cm:Desktop}"; Flags: unchecked

[Files]
Source: "{#Src}\解压.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7z.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7z.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7-Zip License.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "archive.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\解压"; Filename: "{app}\解压.exe"
Name: "{autodesktop}\解压"; Filename: "{app}\解压.exe"; Tasks: desktop

; 注册表：HKA = 只给当前用户装时是 HKCU，为所有用户装时是 HKLM
[Registry]
; 文件类型 Unpack.Archive：名字、图标、双击打开的命令
Root: HKA; Subkey: "Software\Classes\Unpack.Archive"; ValueType: string; ValueName: ""; ValueData: "{cm:TypeName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Unpack.Archive\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\archive.ico"",0"
Root: HKA; Subkey: "Software\Classes\Unpack.Archive\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\解压.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{cm:MenuText}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\解压.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""
; 让「设置 → 应用 → 默认应用」里能找到「解压」
Root: HKA; Subkey: "Software\Unpack\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "解压"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Unpack\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "zip · 7z · rar · 分卷 · 加密包 · 乱码修复"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Unpack"; ValueData: "Software\Unpack\Capabilities"; Flags: uninsdeletevalue
#define Exts "zip 7z rar tar gz tgz bz2 tbz2 xz txz zst tzst 001 z01 r00 lzh lha arj"
#sub AddExt
  #define E Copy(Exts, 1, Pos(" ", Exts + " ") - 1)
Root: HKA; Subkey: "Software\Classes\.{#E}\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.{#E}"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue; Tasks: assoc
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".{#E}"; ValueData: "Unpack.Archive"
  #define Exts Copy(Exts, Pos(" ", Exts + " ") + 1, Len(Exts))
#endsub
#for {0; Len(Exts) > 0; 0} AddExt
; iso、cab、wim 系统自己会打开（挂载/查看），只加进「打开方式」，不抢默认
Root: HKA; Subkey: "Software\Classes\.iso\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.cab\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.wim\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
; 右键菜单：和程序「设置」里那个开关写的是同一处，两边能互相关掉
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack"; ValueType: string; ValueName: ""; ValueData: "{cm:MenuText}"; Flags: uninsdeletekey; Tasks: menu
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\解压.exe"",0"; Tasks: menu
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"; Tasks: menu
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""; Tasks: menu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack"; ValueType: string; ValueName: ""; ValueData: "{cm:MenuText}"; Flags: uninsdeletekey; Tasks: menu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\解压.exe"",0"; Tasks: menu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"; Tasks: menu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""; Tasks: menu

[Run]
Filename: "{app}\解压.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent
