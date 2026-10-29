; 解压（Unpack）Windows 安装版：像 WPS 那样一个 exe 点一下就装好——装到 %LOCALAPPDATA%\Programs\Unpack（只给当前用户，不要管理员），
; 桌面和开始菜单各一个「解压」，把压缩包格式登记给解压.exe（压缩包显示自己的文件图标 archive.ico），装完自动打开
; 编译：iscc /DSrc=dist\Unpack windows\installer.iss（GitHub Actions 里做，见 .github/workflows/windows.yml）

#ifndef Src
  #define Src "..\dist\Unpack"
#endif

[Setup]
AppId={{304E1695-683E-415A-98A6-C6036629DBEC}
AppName=解压
#ifndef AppVer
  #define AppVer "0"
#endif
AppVerName=解压 {#AppVer}
AppVersion={#AppVer}
AppPublisher=Hejun
DefaultDirName={autopf}\Unpack
DefaultGroupName=解压
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
DisableDirPage=yes
DisableReadyMemo=yes
ChangesAssociations=yes
CloseApplications=force
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..
OutputBaseFilename=Unpack-Setup
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
zh.TypeName=压缩包
en.TypeName=Archive
zh.AppTitle=解压
en.AppTitle=Unpack
zh.SetDefault=打开「默认应用」设置，把 zip、rar、7z 改成用「解压」打开（Windows 不允许安装程序替你改，点一下就好）
en.SetDefault=Open Default apps settings to make Unpack the default for zip, rar, 7z (Windows doesn't let installers do this)

[Files]
Source: "{#Src}\解压.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7z.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7z.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\7-Zip License.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "archive.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\解压"; Filename: "{app}\解压.exe"
Name: "{autodesktop}\解压"; Filename: "{app}\解压.exe"

; 注册表：只装给当前用户，HKA 就是 HKCU
[Registry]
; 文件类型 Unpack.Archive：名字、图标、双击打开的命令
Root: HKA; Subkey: "Software\Classes\Unpack.Archive"; ValueType: string; ValueName: ""; ValueData: "{cm:TypeName}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Unpack.Archive\Application"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{cm:AppTitle}"
Root: HKA; Subkey: "Software\Classes\Unpack.Archive\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\archive.ico"",0"
Root: HKA; Subkey: "Software\Classes\Unpack.Archive\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\解压.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{cm:AppTitle}"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\解压.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""
; 让「设置 → 应用 → 默认应用」里能找到「解压」
Root: HKA; Subkey: "Software\Unpack"; Flags: uninsdeletekeyifempty
Root: HKA; Subkey: "Software\Unpack\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "解压"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Unpack\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "zip · 7z · rar · 分卷 · 加密包 · 乱码修复"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Unpack"; ValueData: "Software\Unpack\Capabilities"; Flags: uninsdeletevalue
; 这些格式：加进「打开方式」+ 设成默认（系统自己管的 zip/7z/rar 等要用户在「默认应用」里点一次）+ 登记到「默认应用」里
Root: HKA; Subkey: "Software\Classes\.zip\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.zip"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".zip"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.7z\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.7z"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".7z"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.rar\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.rar"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".rar"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.tar\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.tar"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".tar"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.gz\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.gz"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".gz"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.tgz\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.tgz"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".tgz"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.bz2\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.bz2"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".bz2"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.tbz2\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.tbz2"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".tbz2"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.xz\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.xz"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".xz"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.txz\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.txz"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".txz"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.zst\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.zst"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".zst"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.tzst\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.tzst"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".tzst"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.001\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.001"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".001"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.z01\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.z01"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".z01"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.r00\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.r00"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".r00"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.lzh\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.lzh"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".lzh"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.lha\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.lha"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".lha"; ValueData: "Unpack.Archive"
Root: HKA; Subkey: "Software\Classes\.arj\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.arj"; ValueType: string; ValueName: ""; ValueData: "Unpack.Archive"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Unpack\Capabilities\FileAssociations"; ValueType: string; ValueName: ".arj"; ValueData: "Unpack.Archive"
; iso、cab、wim 系统自己会打开（挂载/查看），只加进「打开方式」，不抢默认
Root: HKA; Subkey: "Software\Classes\.iso\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.cab\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.wim\OpenWithProgids"; ValueType: string; ValueName: "Unpack.Archive"; ValueData: ""; Flags: uninsdeletevalue
; 右键菜单安装时不加（程序「设置」里能打开）；打开过的话卸载时一并删掉
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack"; Flags: uninsdeletekey dontcreatekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack"; Flags: uninsdeletekey dontcreatekey
; 从 v1.0 zip 版过来、开过右键菜单的：菜单原来指向旧文件夹里的解压.exe，改指到装好的这个（旧文件夹删了也不坏）
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\解压.exe"",0"; Check: HasMenu('*')
Root: HKA; Subkey: "Software\Classes\*\shell\Unpack\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""; Check: HasMenu('*')
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\解压.exe"",0"; Check: HasMenu('Directory')
Root: HKA; Subkey: "Software\Classes\Directory\shell\Unpack\command"; ValueType: string; ValueName: ""; ValueData: """{app}\解压.exe"" ""%1"""; Check: HasMenu('Directory')

; 卸载干净：设置和密码本（%APPDATA%\Unpack）也删掉
[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\Unpack"

[Run]
; 装完自动打开（点「更新」时的静默安装带 /RELAUNCH=1，也重新打开）
Filename: "{app}\解压.exe"; Flags: nowait; Check: ShouldLaunch
; Windows 10/11 不让安装程序直接改默认打开方式：完成页上勾着这一项，点「完成」就跳到「设置 → 默认应用 → 解压」那一页
Filename: "ms-settings:defaultapps?registeredAppUser=Unpack"; Description: "{cm:SetDefault}"; Flags: shellexec postinstall skipifsilent nowait

[Code]
function HasMenu(Cls: String): Boolean;
begin
  Result := RegKeyExists(HKCU, 'Software\Classes\' + Cls + '\shell\Unpack');
end;

function ShouldLaunch: Boolean;
begin
  Result := (not WizardSilent) or (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;
