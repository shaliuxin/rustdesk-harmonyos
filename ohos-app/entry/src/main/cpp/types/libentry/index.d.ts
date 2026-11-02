// libentry.so 的类型声明。
//
// 与 napi_bridge.cpp 里 napi_property_descriptor 的顺序、名字、参数个数
// 必须完全一致 —— ArkTS 是静态检查的，C++ 那边改名字而这里没改，
// 编译期就会报「属性不存在」，比运行时 undefined 好得多。
//
// 每个函数返回 int32 时：0 成功，负数失败（具体值看 Rust 侧 entry.rs）。

export interface RustDeskNative {
  // ABI 版本，启动时与 ohos-build.json 里的期望值比对，避免 .a 与胶水层错配。
  abiVersion(): number;

  // 核心版本号（"1.5.1"），「关于」页显示用。
  version(): string | null;

  // 必须在其他调用之前执行一次。appDir 传 UIAbility 的 context.filesDir。
  init(appDir: string): number;

  // 最近一次错误；没有错误时返回 null。
  lastError(): string | null;

  // 连接远端。立即返回，进度通过 onEvent 的 connected / msgbox 上报。
  sessionStart(peerId: string, password: string, forceRelay: number): number;
  sessionClose(): void;
  sessionRefresh(display: number): void;

  // 提交登录密码（密码弹窗「确定」时调用）。username/osPassword 传空串即可。
  // remember 非 0 表示记住密码。没有活跃会话时返回 -2。
  sessionLogin(password: string, username: string, osPassword: string, remember: number): number;

  // 回应「未加密连接」警告。accept 非 0 = 继续，0 = 取消断开。
  // 缺了这一步上游会一直卡在等确认，表现为连上了但黑屏。
  sessionContinueInsecure(accept: number): number;

  // 状态快照（JSON 字符串）。页面重建后用它恢复 UI。
  stateJson(): string | null;

  // 服务器配置（JSON 字符串，键为 custom-rendezvous-server / relay-server /
  // api-server / key / effective-rendezvous-server，以及 view-style /
  // image-quality / show-remote-cursor / disable-audio / force-always-relay；
  // 另外还带 id 与 temporary-password 两项只读的本机身份）。
  // 没初始化时返回 null。
  configJson(): string | null;

  // 写配置。json 是上面那些键的对象；空串表示删除该项。
  configSet(json: string): number;

  // --- 本机身份 / 最近会话（首页用）---

  // 刷新一次性密码。刷新后要重新 configJson() 才能拿到新值。
  updateTempPassword(): number;
  // 设置固定密码，传空串表示清除。返回 0 成功。
  setPermanentPassword(pw: string): number;
  // 最近连接过的对端，按最后连接时间倒序：[{"id":"...","ts":秒,"fav":bool}]。
  peersJson(): string | null;
  // 收藏列表整体写回（传完整 id 数组的 JSON）。返回 0 成功。
  storeFav(jsonIds: string): number;

  // 鼠标：mask 见 ohos/include/rustdesk_ohos.h，坐标是远端画面坐标系。
  mouse(mask: number, x: number, y: number, alt: number, ctrl: number,
        shift: number, command: number): number;

  // 键盘：name 必须是 RustDesk 的 VK_* 键名，单字符直接传字符。
  key(name: string, down: number, press: number, alt: number, ctrl: number,
      shift: number, command: number): number;

  // 软键盘文字：整段发过去比逐键干净（服务端按 seq 逐字注入，
  // 不吃键位布局）。退格等控制键仍走 key()。
  text(value: string): number;

  // 剪贴板同步：把本机剪贴板文本发给对端（pasteboard on('update') 回调）。
  // 0 = 已发出；负数 = 无会话 / 仅查看 / 剪贴板被禁用。
  clipboardSend(value: string): number;

  // 代理设置：{"proxy","username","password"}。代理不在 options map 里，
  // 存在 Config2.socks，所以单独一对接口。
  proxyJson(): string | null;
  proxySet(json: string): number;

  // 读 / 写单个配置项的原始值（"Y" / "N" / 字符串）。key 必须在 UI 白名单内。
  optionGet(key: string): string | null;
  optionSet(key: string, value: string): number;

  // 读 / 写单个**本地**配置项（LocalConfig）。打洞开关等走这条路。
  localOptionGet(key: string): string | null;
  localOptionSet(key: string, value: string): number;

  // 当前生效 ID 服务器的连接状态：1=已连接、0=正在连接、-1=连接失败。
  // 不阻塞，可放在 UI 定时刷新里。
  serverStatus(): number;

  ctrlAltDel(): number;
  switchDisplay(index: number): number;
  sendChat(text: string): number;

  // --- 被控端（远程协助，仅 2in1）---
  // 不做常驻服务：hostStart 起采集 + 注册，hostStop 全拆。
  // 返回 0 成功，负数失败（细节用 lastError() 读）。
  hostSupported(): number;
  hostStart(): number;
  hostStop(): number;
  /** 0 停止 / 1 运行中 */
  hostState(): number;
  /** 被控端回话给主控。0 成功，-1 表示当前没有连接 */
  hostSendChat(text: string): number;
  /** 当前被控连接数（>0 = 有人正在控制本机） */
  hostSessions(): number;
  /** 键鼠注入授权：0 未授权 / 1 授权中 / 2 已授权 */
  injectionStatus(): number;
  /** 触发系统授权弹窗，结果是异步的，用 injectionStatus() 复查 */
  requestInjection(): number;

  // --- 会话操作（Android 底栏 ⋮「更多」菜单）---
  // 全部是「发一条消息给 io_loop」，返回 0 只代表已入队，不等结果。

  // 锁定远端屏幕。
  lockScreen(): number;
  // 重启远端设备。只有 Windows / Linux / macOS 对端支持。
  restartRemote(): number;
  // 把密码发到远端 OS 登录界面；activate 非 0 = 发完立刻回车。
  inputOsPassword(pw: string, activate: number): number;
  // 提权：direct 用于已是管理员会话；withLogon 用于 UAC 要凭据。
  elevateDirect(): number;
  elevateWithLogon(username: string, password: string): number;
  // 会话录屏开关。start 非 0 开始，0 停止。
  recordScreen(start: number): number;
  // 当前是否在录屏；没有会话时返回 0。
  isRecording(): number;
  // 翻转会话级开关（"block-input" / "show-remote-cursor"…）。
  toggleOption(name: string): number;
  // 对端平台（"Windows" / "Linux" / "MacOS" / "Android"）；没会话时返回空串。
  peerPlatform(): string | null;
  // 按 USB HID usage 发键（Android 被控端的音量/电源）。只认：
  // 0x007f 静音 / 0x0080 音量+ / 0x0081 音量- / 0x0066 电源。
  // 必须成对调用：down=1 之后再 down=0。
  hidKey(usbHid: number, down: number): number;

  // 重新读系统显示器列表。
  displaysSync(): number;

  // 连通性自检。
  logProbe(msg: string): void;

  // 切后台时关掉渲染循环，省电。
  setRenderActive(active: boolean): void;

  // 注册 UI 事件回调。只有最后一个生效。
  onEvent(callback: (json: string) => void): boolean;

  // --- 文件传输（与远程桌面是两个会话类型，进文件管理器前先 filesStart）---

  // 建文件传输会话。参数同 sessionStart。
  filesStart(peerId: string, password: string, forceRelay: number): number;
  // 读远端目录。path 传空串 = 对端默认目录。结果走 folder_files 事件。
  filesList(path: string, includeHidden: number): number;
  // 远端操作，返回操作 id。文件名不是路径（同目录改名）。
  filesMkdir(path: string): number;
  filesRename(path: string, newName: string): number;
  // isDir 非 0 = 递归删除整个目录。
  filesRemove(path: string, isDir: number): number;
  // 下载：remotePath 远端条目 → localTo 本机完整目标路径。返回任务 id。
  filesDownload(remotePath: string, localTo: string): number;
  // 上传：localPath 本机条目 → remoteDir 远端目录。返回任务 id。
  filesUpload(localPath: string, remoteDir: string): number;
  filesCancel(id: number): void;
  // isRemote 与建任务方向一致：下载 1、上传 0。
  filesResume(id: number, isRemote: number): void;
  // 覆盖确认：needOverride 1=覆盖 0=跳过；remember=记住选择。
  filesConfirm(id: number, fileNum: number, needOverride: number,
    remember: number, isUpload: number): void;
}

declare const rustdesk: RustDeskNative;
export default rustdesk;
