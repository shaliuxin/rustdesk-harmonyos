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

  // 必须在其他调用之前执行一次。appDir 传 UIAbility 的 context.filesDir。
  init(appDir: string): number;

  // 最近一次错误；没有错误时返回 null。
  lastError(): string | null;

  // 连接远端。立即返回，进度通过 onEvent 的 connected / msgbox 上报。
  sessionStart(peerId: string, password: string, forceRelay: number): number;
  sessionClose(): void;
  sessionRefresh(display: number): void;

  // 状态快照（JSON 字符串）。页面重建后用它恢复 UI。
  stateJson(): string | null;

  // 服务器配置（JSON 字符串，键为 custom-rendezvous-server / relay-server /
  // api-server / key / effective-rendezvous-server）。没初始化时返回 null。
  configJson(): string | null;

  // 写服务器配置。json 是上面那些键的对象；空串表示删除该项。
  configSet(json: string): number;

  // 鼠标：mask 见 ohos/include/rustdesk_ohos.h，坐标是远端画面坐标系。
  mouse(mask: number, x: number, y: number, alt: number, ctrl: number,
        shift: number, command: number): number;

  // 键盘：name 必须是 RustDesk 的 VK_* 键名，单字符直接传字符。
  key(name: string, down: number, press: number, alt: number, ctrl: number,
      shift: number, command: number): number;

  ctrlAltDel(): number;
  switchDisplay(index: number): number;
  sendChat(text: string): number;

  // 重新读系统显示器列表。
  displaysSync(): number;

  // 连通性自检。
  logProbe(msg: string): void;

  // 切后台时关掉渲染循环，省电。
  setRenderActive(active: boolean): void;

  // 注册 UI 事件回调。只有最后一个生效。
  onEvent(callback: (json: string) => void): boolean;
}

declare const rustdesk: RustDeskNative;
export default rustdesk;
