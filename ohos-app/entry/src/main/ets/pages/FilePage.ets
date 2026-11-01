import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RustDesk, UiEvent, CloseEventData, MsgboxEventData,
  FolderFilesEventData, FileEntryData, JobProgressEventData,
  JobErrorEventData, JobDoneEventData, OverrideConfirmEventData
} from '../common/RustDesk';
import { isPhoneForm } from '../common/DeviceForm';

// 文件传输页。
//
// 三个关键事实，决定了这一页的写法：
//
// 1. **文件传输是一个独立会话**，不是远程桌面的一个面板。
//    进入本页要调 filesStart（ConnType::FILE_TRANSFER），对端会弹
//    「请求文件传输」的授权框；退出时要 closeSession，否则 Rust 的
//    io_loop 线程会一直挂着。
//
// 2. **本机侧完全不经过 Rust**。鸿蒙没有 SAF，沙箱路径就是普通 POSIX 路径，
//    所以本地目录用 @ohos.file.fs 直接读写；只有远端目录、传输任务才走 native。
//    好处是本地列表可以同步立刻刷新，坏处是有两套路径分隔符要处理
//    （远端 Windows 是 `\`，本机永远是 `/`）。
//
// 3. **远端目录是异步事件**。filesList() 只是「发出请求」，内容在
//    folder_files 事件里回来。所以每次导航都要先把 loading 打开，
//    等事件到了再关 —— 不然用户会看到一个空列表还以为目录是空的。

const DOMAIN: number = 0x3200;
const TAG: string = 'RustDeskFiles';

// 与其它页面一致的配色。
const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_ACCENT: string = '#0071FF';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_FAINT: string = '#5A6478';
const C_LINE: string = '#1B2536';
const C_OK: string = '#35C759';
const C_ERR: string = '#FF6B6B';

// 远端目录的「浏览」请求没有任务 id，协议里固定是 0（见 ui_handler::update_folder_files）。
const BROWSE_ID: number = 0;
// 传输进度事件很密（每秒多条），没必要每条都刷 UI。
const PROGRESS_THROTTLE_MS: number = 100;

// 本机沙箱根目录名。所有下载/导入的文件都落在 <filesDir>/RustDesk 下，
// 这样应用被卸载时一起清掉，不会在用户「文件管理」里留垃圾。
const LOCAL_ROOT_NAME: string = 'RustDesk';

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/** 目录里的一项。远端与本机共用 —— 两边字段语义一致，没必要分两个类。 */
class FsItem {
  name: string = '';
  isDir: boolean = false;
  size: number = 0;
  mtime: number = 0; // Unix 秒

  constructor(name: string = '', isDir: boolean = false, size: number = 0, mtime: number = 0) {
    this.name = name;
    this.isDir = isDir;
    this.size = size;
    this.mtime = mtime;
  }
}

/** 传输任务。id 由 Rust 分配，事件里带回来同一个 id。 */
class JobView {
  id: number = 0;
  name: string = '';
  up: boolean = false;     // true = 上传（本机 → 远端）
  total: number = 0;       // 0 表示还不知道（目录任务要等对端回清单）
  done: number = 0;
  speed: number = 0;       // 字节/秒
  state: string = 'run';   // run / done / error / wait
  err: string = '';

  constructor(id: number, name: string, up: boolean) {
    this.id = id;
    this.name = name;
    this.up = up;
  }
}

/** 长按菜单项。做成数据再渲染，理由同 SessionPage 的 MoreItem：
 *  @Builder 里不能写普通语句，菜单内容得先在普通方法里算好。 */
class ActionItem {
  label: string = '';
  danger: boolean = false;
  act: () => void = () => {};

  constructor(label: string, act: () => void, danger: boolean = false) {
    this.label = label;
    this.act = act;
    this.danger = danger;
  }
}

// ---------------------------------------------------------------------------
// 路径与格式化工具
//
// 远端路径分隔符必须**跟着对端走**：连 Windows 拿到的是 `C:\Users\x`，
// 连 Linux/macOS 是 `/home/x`。这里不去问 Rust 要 platform，而是看路径里
// 有没有反斜杠 —— 空串（还没拿到初始目录）时按 `/` 处理，因为那一步
// 只是把用户输入拼上去，真正的规范化在对端做。
// ---------------------------------------------------------------------------

function sepOf(path: string): string {
  return path.indexOf('\\') >= 0 ? '\\' : '/';
}

function joinPath(base: string, name: string): string {
  if (base.length === 0) {
    return name;
  }
  const sep: string = sepOf(base);
  if (base.endsWith(sep)) {
    return `${base}${name}`;
  }
  return `${base}${sep}${name}`;
}

function parentPath(path: string): string {
  if (path.length === 0) {
    return '';
  }
  let p: string = path;
  // 去掉末尾分隔符，否则 `C:\Users\` 会算出 `C:\Users`
  while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
    p = p.substring(0, p.length - 1);
  }
  const idx: number = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  if (idx < 0) {
    return '';
  }
  // Windows 盘符根：`C:\` 的父目录就是它自己，否则会变成 `C:`
  if (idx === 2 && p.charAt(1) === ':') {
    return p.substring(0, 3);
  }
  return p.substring(0, idx);
}

function baseName(path: string): string {
  let p: string = path;
  while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
    p = p.substring(0, p.length - 1);
  }
  const idx: number = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return idx < 0 ? p : p.substring(idx + 1);
}

/** 面包屑：把路径拆成一段段，末段高亮。根目录给一个单独的「/」或盘符。 */
function pathCrumbs(path: string): string[] {
  const out: string[] = [];
  if (path.length === 0) {
    return out;
  }
  const sep: string = sepOf(path);
  const parts: string[] = path.split(sep === '\\' ? '\\' : '/');
  let acc: string = '';
  for (let i = 0; i < parts.length; i++) {
    const p: string = parts[i];
    if (p.length === 0) {
      // 开头的空段是 Unix 根目录；Windows 盘符段（"C:"）不能跳过。
      if (i === 0) {
        acc = sep;
        out.push(sep);
      }
      continue;
    }
    acc = acc.length === 0 ? p : (acc.endsWith(sep) ? `${acc}${p}` : `${acc}${sep}${p}`);
    out.push(p);
  }
  return out;
}

function fmtSize(n: number): string {
  if (n < 1024) {
    return `${n} B`;
  }
  if (n < 1024 * 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  if (n < 1024 * 1024 * 1024) {
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function fmtSpeed(bps: number): string {
  if (bps <= 0) {
    return '';
  }
  return `${fmtSize(bps)}/s`;
}

function fmtTime(sec: number): string {
  if (sec <= 0) {
    return '';
  }
  const d: Date = new Date(sec * 1000);
  const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
  const dd: string = d.getDate().toString().padStart(2, '0');
  const hh: string = d.getHours().toString().padStart(2, '0');
  const mi: string = d.getMinutes().toString().padStart(2, '0');
  return `${mm}-${dd} ${hh}:${mi}`;
}

/** 排目录：目录在前，同类按名字。远端与本机共用同一套排序，避免两栏看起来不一致。 */
function sortItems(items: FsItem[]): FsItem[] {
  const copy: FsItem[] = items.slice();
  copy.sort((a: FsItem, b: FsItem): number => {
    if (a.isDir !== b.isDir) {
      return a.isDir ? -1 : 1;
    }
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
  });
  return copy;
}

// ---------------------------------------------------------------------------
// 页面
// ---------------------------------------------------------------------------

@Entry
@Component
struct FilePage {
  @State peerId: string = '';
  @State connected: boolean = false;
  @State failed: boolean = false;
  @State statusText: string = '正在建立文件传输连接…';

  // --- 远端 ---
  @State remotePath: string = '';
  @State remoteItems: FsItem[] = [];
  @State remoteSel: string[] = [];
  @State remoteLoading: boolean = false;
  @State remoteError: string = '';

  // --- 本机（沙箱）---
  @State localRoot: string = '';
  @State localPath: string = '';
  @State localItems: FsItem[] = [];
  @State localSel: string[] = [];
  @State localLoading: boolean = false;

  // --- 传输任务 ---
  @State jobs: JobView[] = [];
  @State showJobs: boolean = false;

  // --- 弹窗 ---
  @State showPasswordDialog: boolean = false;
  @State passwordInput: string = '';
  @State rememberPassword: boolean = false;
  @State passwordHint: string = '请输入被控机的访问密码';
  @State showInsecure: boolean = false;
  @State showRename: boolean = false;
  @State renameInput: string = '';
  @State renameIsRemote: boolean = true;
  @State renameOldName: string = '';
  @State showOverride: boolean = false;
  @State overrideJobId: number = 0;
  @State overrideFileName: string = '';
  @State overrideIsUpload: boolean = false;
  @State overrideRemember: boolean = false;
  @State showMkdir: boolean = false;
  @State mkdirInput: string = '';
  @State mkdirIsRemote: boolean = true;
  // 长按动作面板
  @State showSheet: boolean = false;
  @State sheetTitle: string = '';
  @State sheetActions: ActionItem[] = [];

  // 非 @State：只在事件回调里读，改动不需要触发重绘。
  private phoneForm: boolean = true;
  @State activeTab: number = 0;
  private lastProgressTs: number = 0;
  private downloadDir: string = '';

  private onCoreEvent = (ev: UiEvent): void => {
    switch (ev.event) {
      case 'connected':
        this.connected = true;
        this.failed = false;
        this.statusText = '';
        // 初始目录传空串 = 让对端给它的默认目录（通常是用户主目录）。
        // 真正的路径在 folder_files 回来时才知道，所以这里只是发请求。
        this.remoteLoading = true;
        RustDesk.filesList('', false);
        break;
      case 'close': {
        const d: CloseEventData = ev.data as CloseEventData;
        this.connected = false;
        this.remoteLoading = false;
        this.failed = true;
        this.statusText = `连接已断开${d !== undefined && d.reason ? `（${d.reason}）` : ''}`;
        break;
      }
      case 'msgbox':
        this.handleMsgbox(ev.data as MsgboxEventData);
        break;
      case 'folder_files':
        this.handleFolderFiles(ev.data as FolderFilesEventData);
        break;
      case 'job_progress':
        this.handleProgress(ev.data as JobProgressEventData);
        break;
      case 'job_done':
        this.handleJobDone(ev.data as JobDoneEventData);
        break;
      case 'job_error':
        this.handleJobError(ev.data as JobErrorEventData);
        break;
      case 'override_file_confirm':
        this.handleOverride(ev.data as OverrideConfirmEventData);
        break;
      default:
        break;
    }
  };

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null && params['peerId'] !== undefined) {
      this.peerId = params['peerId'] as string;
    }
    this.phoneForm = isPhoneForm();

    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.localRoot = `${ctx.filesDir}/${LOCAL_ROOT_NAME}`;
    this.downloadDir = `${this.localRoot}/下载`;
    this.ensureDir(this.localRoot);
    this.ensureDir(this.downloadDir);
    this.localPath = this.localRoot;
    this.loadLocal();

    RustDesk.on(this.onCoreEvent);
    // 传空密码：让对端按自己的策略决定「直接放行 / 要密码」。
    // 要密码时上游会发 msgbox(input-password)，本页弹框回填 —— 与会话页一致。
    const rc: number = RustDesk.filesStart(this.peerId, '', false);
    if (rc !== 0) {
      this.failed = true;
      this.statusText = `发起失败（${rc}）：${RustDesk.getLastError()}`;
    }
    hilog.info(DOMAIN, TAG, 'enter file transfer peer=%{public}s phone=%{public}s root=%{public}s',
      this.peerId, this.phoneForm ? 'Y' : 'N', this.localRoot);
  }

  aboutToDisappear(): void {
    RustDesk.off(this.onCoreEvent);
    // 离开页面必须断开：文件传输会话没有「后台保持」的意义，
    // 不断开的话对端会一直挂着这条连接，且本机 io_loop 线程不退。
    RustDesk.closeSession();
    hilog.info(DOMAIN, TAG, 'left file transfer page');
  }

  // ======================= 事件处理 =======================

  private handleMsgbox(d: MsgboxEventData): void {
    if (d === undefined) {
      return;
    }
    const mt: string = d.type !== undefined ? d.type : '';
    switch (mt) {
      case 'input-password':
        this.passwordHint = '请输入被控机的访问密码';
        this.passwordInput = '';
        this.showPasswordDialog = true;
        break;
      case 're-input-password':
        this.passwordHint = '密码错误，请重新输入';
        this.passwordInput = '';
        this.showPasswordDialog = true;
        break;
      case 'insecure-connection':
      case 'insecure-connection-nocancel-hasclose':
        this.showInsecure = true;
        break;
      case 'error':
        this.failed = true;
        this.statusText = d.text.length > 0 ? this.stripHtml(d.text) : (d.title.length > 0 ? d.title : '出错了');
        break;
      case 'wait-remote-accept-nook':
        this.statusText = '已请求连接，等待对方接受…';
        break;
      default:
        if (!this.connected) {
          this.statusText = d.title.length > 0 ? d.title : this.statusText;
        }
        break;
    }
  }

  private stripHtml(s: string): string {
    const noTags: string = s.replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]*>/g, '');
    return noTags.length > 120 ? `${noTags.substring(0, 120)}…` : noTags;
  }

  private handleFolderFiles(d: FolderFilesEventData): void {
    if (d === undefined) {
      return;
    }
    // only_count=true 是「这个任务里有几个文件」的统计，不是目录内容。
    // 拿它补上任务的 total，列表不要动，否则会把目录刷成传输清单。
    if (d.only_count) {
      let sum: number = 0;
      for (let i = 0; i < d.entries.length; i++) {
        sum += d.entries[i].size;
      }
      const total: number = sum;
      this.updateJob(d.id, (j: JobView) => {
        j.total = total;
      });
      return;
    }
    // 浏览请求的 id 固定是 0；传输任务的文件清单（id>0）不影响当前目录视图。
    if (d.id !== BROWSE_ID) {
      return;
    }
    if (d.is_local) {
      // 理论上不该出现（本地目录不经过 Rust），出现就忽略，避免把沙箱目录刷成远端内容。
      return;
    }
    const items: FsItem[] = [];
    for (let i = 0; i < d.entries.length; i++) {
      const e: FileEntryData = d.entries[i];
      // entry_type: 0=Dir 1=File 2=Symlink。符号链接按文件处理（点进去会失败，
      // 但至少不会当成目录显示成一个空目录）。
      items.push(new FsItem(e.name, e.entry_type === 0, e.size, e.modified_time));
    }
    this.remotePath = d.path;
    this.remoteItems = sortItems(items);
    this.remoteSel = [];
    this.remoteLoading = false;
    this.remoteError = '';
    hilog.info(DOMAIN, TAG, 'remote dir %{public}s entries=%{public}d', d.path, items.length);
  }

  private handleProgress(d: JobProgressEventData): void {
    if (d === undefined) {
      return;
    }
    // 进度事件每秒好几条，全刷会让列表一直重排。100ms 一条足够顺滑，
    // 完成时的最终值由 job_done 补齐（那里不节流）。
    const now: number = Date.now();
    if (now - this.lastProgressTs < PROGRESS_THROTTLE_MS) {
      return;
    }
    this.lastProgressTs = now;
    this.updateJob(d.id, (j: JobView) => {
      j.done = d.finished_size;
      j.speed = d.speed;
      if (j.state === 'wait') {
        j.state = 'run';
      }
    });
  }

  private handleJobDone(d: JobDoneEventData): void {
    if (d === undefined) {
      return;
    }
    this.updateJob(d.id, (j: JobView) => {
      j.state = 'done';
      j.speed = 0;
      if (j.total > 0) {
        j.done = j.total;
      }
    });
    // 传完之后两边目录都可能变了（远端新增文件 / 本地新增目录）。
    this.loadLocal();
    if (this.connected) {
      RustDesk.filesList(this.remotePath, false);
    }
    promptAction.showToast({ message: '传输完成' });
  }

  private handleJobError(d: JobErrorEventData): void {
    if (d === undefined) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'job %{public}d error: %{public}s', d.id, d.err);
    this.updateJob(d.id, (j: JobView) => {
      j.state = 'error';
      j.speed = 0;
      j.err = d.err;
    });
    promptAction.showToast({ message: `传输失败：${d.err}` });
  }

  private handleOverride(d: OverrideConfirmEventData): void {
    if (d === undefined) {
      return;
    }
    this.overrideJobId = d.id;
    this.overrideFileName = baseName(d.to);
    this.overrideIsUpload = d.is_upload;
    this.overrideRemember = false;
    this.showOverride = true;
    this.updateJob(d.id, (j: JobView) => {
      j.state = 'wait';
    });
  }

  private updateJob(id: number, fn: (j: JobView) => void): void {
    let found: boolean = false;
    for (let i = 0; i < this.jobs.length; i++) {
      if (this.jobs[i].id === id) {
        fn(this.jobs[i]);
        found = true;
        break;
      }
    }
    if (!found) {
      // 任务的 folder_files / progress 有可能比 filesDownload 的返回值更早到
      // （Rust 侧建任务的线程与事件派发线程不同），先占个位，元信息后补。
      const j: JobView = new JobView(id, '', false);
      fn(j);
      this.jobs.push(j);
    }
    // 数组引用换新，触发 @State 重绘（元素是同一批对象，但字段已被就地改过）。
    this.jobs = this.jobs.slice();
  }

  // ======================= 本机文件（@ohos.file.fs）=======================

  private ensureDir(path: string): void {
    try {
      fs.accessSync(path);
    } catch (e) {
      try {
        fs.mkdirSync(path, true);
      } catch (e2) {
        hilog.error(DOMAIN, TAG, 'mkdir failed %{public}s', path);
      }
    }
  }

  private loadLocal(): void {
    this.localLoading = true;
    const items: FsItem[] = [];
    try {
      const names: string[] = fs.listFileSync(this.localPath);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        const full: string = `${this.localPath}/${name}`;
        try {
          const st: fs.Stat = fs.statSync(full);
          items.push(new FsItem(name, st.isDirectory(), st.isDirectory() ? 0 : st.size, st.mtime));
        } catch (e) {
          // 读不到 stat 的项（权限/已删）直接跳过，不要让整页列表崩掉。
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'list local failed %{public}s', this.localPath);
    }
    this.localItems = sortItems(items);
    this.localSel = [];
    this.localLoading = false;
  }

  private localRemove(name: string, isDir: boolean): void {
    const full: string = `${this.localPath}/${name}`;
    try {
      if (isDir) {
        fs.rmdirSync(full);
      } else {
        fs.unlinkSync(full);
      }
    } catch (e) {
      promptAction.showToast({ message: `删除失败：${name}` });
    }
  }

  private localRename(oldName: string, newName: string): void {
    if (newName === oldName) {
      return;
    }
    try {
      fs.renameSync(`${this.localPath}/${oldName}`, `${this.localPath}/${newName}`);
    } catch (e) {
      promptAction.showToast({ message: '重命名失败' });
    }
    this.loadLocal();
  }

  // ======================= 远端操作 =======================

  private remoteRefresh(): void {
    if (!this.connected) {
      return;
    }
    this.remoteLoading = true;
    RustDesk.filesList(this.remotePath, false);
  }

  private remoteEnter(name: string): void {
    const next: string = joinPath(this.remotePath, name);
    this.remoteLoading = true;
    this.remoteSel = [];
    RustDesk.filesList(next, false);
  }

  private remoteUp(): void {
    const next: string = parentPath(this.remotePath);
    if (next.length === 0) {
      return;
    }
    this.remoteLoading = true;
    this.remoteSel = [];
    RustDesk.filesList(next, false);
  }

  // ======================= 选择 =======================

  private inList(list: string[], name: string): boolean {
    return list.indexOf(name) >= 0;
  }

  private toggleSel(isRemote: boolean, name: string): void {
    const list: string[] = isRemote ? this.remoteSel : this.localSel;
    const idx: number = list.indexOf(name);
    const next: string[] = list.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(name);
    }
    if (isRemote) {
      this.remoteSel = next;
    } else {
      this.localSel = next;
    }
  }

  private findItem(isRemote: boolean, name: string): FsItem | undefined {
    const list: FsItem[] = isRemote ? this.remoteItems : this.localItems;
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === name) {
        return list[i];
      }
    }
    return undefined;
  }

  // ======================= 传输 =======================

  /** 下载选中的远端条目到本机「下载」目录。 */
  private downloadSelected(): void {
    const sel: string[] = this.remoteSel.slice();
    if (sel.length === 0 || !this.connected) {
      return;
    }
    for (let i = 0; i < sel.length; i++) {
      const name: string = sel[i];
      const remoteFull: string = joinPath(this.remotePath, name);
      const localTo: string = `${this.downloadDir}/${name}`;
      const id: number = RustDesk.filesDownload(remoteFull, localTo);
      if (id > 0) {
        this.jobs.push(new JobView(id, name, false));
      } else {
        promptAction.showToast({ message: `发起下载失败（${id}）：${RustDesk.getLastError()}` });
      }
    }
    this.remoteSel = [];
    this.jobs = this.jobs.slice();
    this.showJobs = true;
    this.loadLocal();
  }

  /** 上传选中的本机条目到当前远端目录。 */
  private uploadSelected(): void {
    const sel: string[] = this.localSel.slice();
    if (sel.length === 0 || !this.connected) {
      return;
    }
    for (let i = 0; i < sel.length; i++) {
      const name: string = sel[i];
      const localFull: string = `${this.localPath}/${name}`;
      const id: number = RustDesk.filesUpload(localFull, this.remotePath);
      if (id > 0) {
        this.jobs.push(new JobView(id, name, true));
      } else {
        promptAction.showToast({ message: `发起上传失败（${id}）：${RustDesk.getLastError()}` });
      }
    }
    this.localSel = [];
    this.jobs = this.jobs.slice();
    this.showJobs = true;
  }

  /**
   * 从系统文件选择器导入文件到当前本机目录。
   *
   * 为什么要先拷进沙箱：`filesUpload` 走的是 std::fs 的绝对路径，而 picker
   * 给的是 uri（`file://docs/storage/...`），Rust 侧不认。拷一份是最省事、
   * 也最不会踩权限坑的做法 —— 好处是上传中途用户可以随便切后台，
   * 坏处是大文件会多占一份空间。
   */
  private async pickAndImport(): Promise<void> {
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 20;
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
      const uris: string[] = await p.select(opts);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i];
        const raw: string = uri.substring(uri.lastIndexOf('/') + 1);
        let name: string = raw;
        try {
          name = decodeURIComponent(raw);
        } catch (e) {
          name = raw;
        }
        const dest: string = `${this.localPath}/${name}`;
        const src: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const dst: fs.File = fs.openSync(dest,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.copyFileSync(src.fd, dst.fd);
        fs.closeSync(src);
        fs.closeSync(dst);
      }
      this.loadLocal();
      promptAction.showToast({ message: `已导入 ${uris.length} 个文件` });
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', err.message);
      promptAction.showToast({ message: `导入失败：${err.message}` });
    }
  }

  /** 把本机选中项导出到系统「文件」里（用户自选目标位置）。 */
  private async exportSelected(): Promise<void> {
    const sel: string[] = this.localSel.slice();
    if (sel.length === 0) {
      return;
    }
    try {
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = sel;
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
      const uris: string[] = await p.save(opts);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      for (let i = 0; i < sel.length && i < uris.length; i++) {
        const srcPath: string = `${this.localPath}/${sel[i]}`;
        const src: fs.File = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
        const dst: fs.File = fs.openSync(uris[i],
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.copyFileSync(src.fd, dst.fd);
        fs.closeSync(src);
        fs.closeSync(dst);
      }
      promptAction.showToast({ message: `已导出 ${Math.min(sel.length, uris.length)} 项` });
    } catch (e) {
      const err: Error = e as Error;
      hilog.error(DOMAIN, TAG, 'export failed: %{public}s', err.message);
      promptAction.showToast({ message: `导出失败：${err.message}` });
    }
  }

  // ======================= 操作入口 =======================

  private askMkdir(isRemote: boolean): void {
    this.mkdirIsRemote = isRemote;
    this.mkdirInput = '';
    this.showMkdir = true;
  }

  private doMkdir(): void {
    const name: string = this.mkdirInput.trim();
    if (name.length === 0) {
      return;
    }
    this.showMkdir = false;
    if (this.mkdirIsRemote) {
      const rc: number = RustDesk.filesMkdir(joinPath(this.remotePath, name));
      if (rc < 0) {
        promptAction.showToast({ message: `新建失败（${rc}）` });
        return;
      }
      // 对端不回显列表，主动刷一次（比等对端推快，也更确定）。
      setTimeout(() => { this.remoteRefresh(); }, 250);
    } else {
      this.ensureDir(`${this.localPath}/${name}`);
      this.loadLocal();
    }
  }

  private askRename(isRemote: boolean): void {
    const sel: string[] = isRemote ? this.remoteSel : this.localSel;
    if (sel.length !== 1) {
      promptAction.showToast({ message: '请选择一项' });
      return;
    }
    this.renameIsRemote = isRemote;
    this.renameOldName = sel[0];
    this.renameInput = sel[0];
    this.showRename = true;
  }

  private doRename(): void {
    const name: string = this.renameInput.trim();
    this.showRename = false;
    if (name.length === 0 || name === this.renameOldName) {
      return;
    }
    if (this.renameIsRemote) {
      const rc: number = RustDesk.filesRename(joinPath(this.remotePath, this.renameOldName), name);
      if (rc < 0) {
        promptAction.showToast({ message: `重命名失败（${rc}）` });
        return;
      }
      setTimeout(() => { this.remoteRefresh(); }, 250);
    } else {
      this.localRename(this.renameOldName, name);
    }
  }

  private doDelete(isRemote: boolean): void {
    const sel: string[] = (isRemote ? this.remoteSel : this.localSel).slice();
    if (sel.length === 0) {
      return;
    }
    const doIt = (): void => {
      for (let i = 0; i < sel.length; i++) {
        const item: FsItem | undefined = this.findItem(isRemote, sel[i]);
        const isDir: boolean = item !== undefined ? item.isDir : false;
        if (isRemote) {
          RustDesk.filesRemove(joinPath(this.remotePath, sel[i]), isDir);
        } else {
          this.localRemove(sel[i], isDir);
        }
      }
      if (isRemote) {
        this.remoteSel = [];
        setTimeout(() => { this.remoteRefresh(); }, 400);
      } else {
        this.loadLocal();
      }
    };
    // 删除是不可逆的（远端尤其如此），先确认一次。
    promptAction.showDialog({
      title: '删除确认',
      message: `确定删除选中的 ${sel.length} 项？此操作不可撤销。`,
      buttons: [
        { text: '取消', color: C_DIM },
        { text: '删除', color: C_ERR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        doIt();
      }
    }).catch(() => {});
  }

  // ======================= 弹窗动作 =======================

  private submitPassword(): void {
    const pwd: string = this.passwordInput;
    if (pwd.length === 0) {
      promptAction.showToast({ message: '请输入密码' });
      return;
    }
    this.showPasswordDialog = false;
    this.statusText = '正在验证密码…';
    const rc: number = RustDesk.login(pwd, this.rememberPassword);
    if (rc !== 0) {
      this.failed = true;
      this.statusText = `提交密码失败（${rc}）：会话可能已断开`;
    }
  }

  private answerInsecure(accept: boolean): void {
    this.showInsecure = false;
    RustDesk.continueInsecure(accept);
    if (!accept) {
      this.failed = true;
      this.statusText = '已取消（未加密连接）';
    }
  }

  private answerOverride(needOverride: boolean): void {
    this.showOverride = false;
    RustDesk.filesConfirm(this.overrideJobId, 0, needOverride, this.overrideRemember,
      this.overrideIsUpload);
    if (!needOverride) {
      this.updateJob(this.overrideJobId, (j: JobView) => {
        j.state = 'done';
      });
    } else {
      this.updateJob(this.overrideJobId, (j: JobView) => {
        j.state = 'run';
      });
    }
  }

  // ======================= 渲染：小部件 =======================

  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor(C_TEXT)
        .width(40)
        .textAlign(TextAlign.Center)
        .onClick(() => { router.back(); })

      Column() {
        Text('文件传输')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(C_TEXT)
        Text(this.statusText.length > 0
          ? this.statusText
          : `${this.peerId} · ${this.connected ? '已连接' : '连接中'}`)
          .fontSize(11)
          .fontColor(this.failed ? C_ERR : C_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.jobs.length > 0) {
        Text(this.showJobs ? '收起' : `传输 ${this.runningCount()}`)
          .fontSize(13)
          .fontColor(C_ACCENT)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(C_LINE)
          .onClick(() => { this.showJobs = !this.showJobs; })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 4, right: 12 })
    .backgroundColor(C_BG)
  }

  @Builder
  paneTabs() {
    Row() {
      Text('远端')
        .fontSize(14)
        .fontColor(this.activeTab === 0 ? '#FFFFFF' : C_DIM)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(this.activeTab === 0 ? C_ACCENT : Color.Transparent)
        .onClick(() => { this.activeTab = 0; })

      Text('本机')
        .fontSize(14)
        .fontColor(this.activeTab === 1 ? '#FFFFFF' : C_DIM)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(this.activeTab === 1 ? C_ACCENT : Color.Transparent)
        .onClick(() => { this.activeTab = 1; })
    }
    .width('100%')
    .padding(4)
    .borderRadius(10)
    .backgroundColor(C_CARD)
    .margin({ left: 12, right: 12, bottom: 6 })
  }

  /** 面包屑：可横向滚动，点中间任一段直接跳过去。 */
  @Builder
  crumbs(isRemote: boolean) {
    Scroll() {
      Row() {
        ForEach(this.crumbList(isRemote), (seg: string, index: number) => {
          Row() {
            if (index > 0) {
              Text('›')
                .fontSize(12)
                .fontColor(C_FAINT)
                .margin({ left: 2, right: 2 })
            }
            Text(seg)
              .fontSize(13)
              .fontColor(index === this.crumbList(isRemote).length - 1 ? C_TEXT : C_DIM)
              .maxLines(1)
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
              .onClick(() => { this.jumpToCrumb(isRemote, index); })
          }
        }, (seg: string, index: number) => `${seg}-${index}`)
      }
      .padding({ left: 6, right: 6 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(30)
    .backgroundColor(C_BG)
  }

  /** 目录列表。isRemote 决定数据源与操作，UI 完全一样。 */
  @Builder
  fileList(isRemote: boolean) {
    Column() {
      // 第一行永远有「上级目录」，空目录时也有出口。
      List() {
        ListItem() {
          Row() {
            Text('↩')
              .fontSize(17)
              .fontColor(C_DIM)
              .width(30)
            Text('上级目录')
              .fontSize(14)
              .fontColor(C_DIM)
              .layoutWeight(1)
          }
          .width('100%')
          .height(40)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            if (isRemote) {
              this.remoteUp();
            } else {
              this.localUp();
            }
          })
        }

        ForEach(this.itemsOf(isRemote), (item: FsItem) => {
          ListItem() {
            this.fileRow(isRemote, item);
          }
        }, (item: FsItem) => `${isRemote ? 'r' : 'l'}-${item.name}`)
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: C_LINE })
      .scrollBar(BarState.Auto)

      if (this.isEmpty(isRemote) && !this.isLoading(isRemote)) {
        Text('这里什么都没有')
          .fontSize(13)
          .fontColor(C_FAINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 24 })
      }
      if (this.isLoading(isRemote)) {
        Text('加载中…')
          .fontSize(12)
          .fontColor(C_FAINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
      }
      if (isRemote && this.remoteError.length > 0) {
        Text(this.remoteError)
          .fontSize(12)
          .fontColor(C_ERR)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  fileRow(isRemote: boolean, item: FsItem) {
    Row() {
      Text(item.isDir ? '📁' : '📄')
        .fontSize(19)
        .width(32)

      Column() {
        Text(item.name)
          .fontSize(14)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.subtitle(item))
          .fontSize(11)
          .fontColor(C_FAINT)
          .maxLines(1)
          .width('100%')
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 勾选框：目录也能选（下载整个文件夹就靠它）。
      Text(this.isSelected(isRemote, item.name) ? '✓' : '')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .borderRadius(11)
        .borderWidth(1)
        .borderColor(this.isSelected(isRemote, item.name) ? C_ACCENT : C_FAINT)
        .backgroundColor(this.isSelected(isRemote, item.name) ? C_ACCENT : Color.Transparent)
        .margin({ left: 8 })
        .onClick(() => { this.toggleSel(isRemote, item.name); })
    }
    .width('100%')
    .height(48)
    .padding({ left: 14, right: 12 })
    .backgroundColor(this.isSelected(isRemote, item.name) ? '#141F33' : Color.Transparent)
    .onClick(() => {
      // 目录：点行体进目录；文件：点行体切换选中。勾选框对两者都有效。
      if (item.isDir) {
        if (isRemote) {
          this.remoteEnter(item.name);
        } else {
          this.localEnter(item.name);
        }
      } else {
        this.toggleSel(isRemote, item.name);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      this.showItemMenu(isRemote, item);
    }))
  }

  /** 底栏：动作随「当前面板 + 选中数量」变化。 */
  @Builder
  actionBar(isRemote: boolean) {
    Row() {
      if (isRemote) {
        this.actionBtn('下载', isRemote)
        this.actionBtn('新建', isRemote)
        this.actionBtn('改名', isRemote)
        this.actionBtn('删除', isRemote)
        this.actionBtn('刷新', isRemote)
      } else {
        this.actionBtn('上传', isRemote)
        this.actionBtn('导入', isRemote)
        this.actionBtn('导出', isRemote)
        this.actionBtn('新建', isRemote)
        this.actionBtn('删除', isRemote)
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 6, right: 6 })
    .backgroundColor(C_BG)
  }

  // ---------------------------------------------------------------------------
  // 底栏按钮的实时状态。
  //
  // 注意 @Builder 的坑：**按值传参不建立状态绑定** —— 如果把 enabled/badge/act
  // 当参数传进 actionBtn，它们会在首次渲染时被冻结（当时没选中 → enabled=false
  // 永远 false，点击被 .enabled() 静默吞掉），表现恰好是用户看到的
  // 「能选中文件、按钮看着是亮的、点了没反应」。所以这里只传 label，
  // 可用性 / 徽标 / 动作全部在渲染与点击时从 this 实时求值。
  // ---------------------------------------------------------------------------

  private btnBadge(label: string, isRemote: boolean): string {
    if (label === '下载' && isRemote) {
      const n: number = this.selCount(true);
      return n > 0 ? `(${n})` : '';
    }
    if (label === '上传' && !isRemote) {
      const n: number = this.selCount(false);
      return n > 0 ? `(${n})` : '';
    }
    return '';
  }

  private btnEnabled(label: string, isRemote: boolean): boolean {
    const remoteSel: number = this.selCount(true);
    const localSel: number = this.selCount(false);
    switch (label) {
      case '下载':
        return isRemote && remoteSel > 0 && this.connected;
      case '上传':
        return !isRemote && localSel > 0 && this.connected;
      case '改名':
        return isRemote && remoteSel === 1 && this.connected;
      case '删除':
        return isRemote ? (remoteSel > 0 && this.connected) : localSel > 0;
      case '刷新':
        return isRemote && this.connected;
      // 导入 / 导出 / 新建不依赖连接：导入走系统 picker，导出/新建是纯本机操作。
      default:
        return true;
    }
  }

  private btnAct(label: string, isRemote: boolean): void {
    switch (label) {
      case '下载':
        this.downloadSelected();
        break;
      case '上传':
        this.uploadSelected();
        break;
      case '改名':
        this.askRename(isRemote);
        break;
      case '删除':
        this.doDelete(isRemote);
        break;
      case '刷新':
        this.remoteRefresh();
        break;
      case '导入':
        this.pickAndImport();
        break;
      case '导出':
        this.exportSelected();
        break;
      case '新建':
        this.askMkdir(isRemote);
        break;
      default:
        break;
    }
  }

  @Builder
  actionBtn(label: string, isRemote: boolean) {
    Column() {
      Text(this.btnBadge(label, isRemote).length > 0 ? `${label}${this.btnBadge(label, isRemote)}` : label)
        .fontSize(13)
        .fontColor(this.btnEnabled(label, isRemote) ? (label === '删除' ? C_ERR : C_TEXT) : C_FAINT)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .borderRadius(9)
    .backgroundColor(this.btnEnabled(label, isRemote) ? C_CARD : Color.Transparent)
    .enabled(this.btnEnabled(label, isRemote))
    .onClick(() => {
      if (this.btnEnabled(label, isRemote)) {
        this.btnAct(label, isRemote);
      }
    })
  }

  /** 传输面板：底部展开，显示每个任务的进度与状态。 */
  @Builder
  jobsPanel() {
    Column() {
      Row() {
        Text(`传输列表 · ${this.jobs.length}`)
          .fontSize(13)
          .fontColor(C_TEXT)
          .layoutWeight(1)
        Text('清空已完成')
          .fontSize(12)
          .fontColor(C_DIM)
          .padding(6)
          .onClick(() => { this.clearDoneJobs(); })
        Text('收起')
          .fontSize(12)
          .fontColor(C_ACCENT)
          .padding(6)
          .onClick(() => { this.showJobs = false; })
      }
      .width('100%')

      List() {
        ForEach(this.jobs, (job: JobView) => {
          ListItem() {
            Column() {
              Row() {
                Text(job.up ? '↑' : '↓')
                  .fontSize(13)
                  .fontColor(job.up ? C_ACCENT : C_OK)
                  .width(18)
                Text(job.name.length > 0 ? job.name : `任务 ${job.id}`)
                  .fontSize(13)
                  .fontColor(C_TEXT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.jobRightText(job))
                  .fontSize(11)
                  .fontColor(job.state === 'error' ? C_ERR : C_DIM)
                  .margin({ left: 6 })
              }
              .width('100%')

              Progress({
                value: job.total > 0 ? Math.min(100, job.done * 100 / job.total) : 0,
                total: 100,
                type: ProgressType.Linear
              })
                .width('100%')
                .height(4)
                .color(job.state === 'error' ? C_ERR : (job.state === 'done' ? C_OK : C_ACCENT))
                .backgroundColor(C_LINE)
                .margin({ top: 6 })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .onClick(() => {
              if (job.state === 'run') {
                RustDesk.filesCancel(job.id);
                this.updateJob(job.id, (j: JobView) => { j.state = 'error'; j.err = '已取消'; });
              }
            })
          }
        }, (job: JobView) => `${job.id}`)
      }
      .width('100%')
      .height(this.jobs.length > 2 ? 168 : (this.jobs.length * 46 + 8))
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 20 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .backgroundColor('#16203A')
    .borderWidth({ top: 0.5 })
    .borderColor(C_LINE)
  }

  // ======================= 渲染：弹窗 =======================

  @Builder
  passwordDialog() {
    Column() {
      Text('需要密码')
        .fontSize(16)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Medium)
      Text(this.passwordHint)
        .fontSize(12)
        .fontColor(C_DIM)
        .margin({ top: 6, bottom: 14 })
      TextInput({ text: this.passwordInput, placeholder: '访问密码' })
        .type(InputType.Password)
        .height(46)
        .fontSize(15)
        .fontColor(C_TEXT)
        .placeholderColor(C_FAINT)
        .backgroundColor(C_BG)
        .onChange((v: string) => { this.passwordInput = v; })
        .onSubmit(() => { this.submitPassword(); })
      Row() {
        Text('记住密码')
          .fontSize(12)
          .fontColor(C_DIM)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Checkbox, isOn: this.rememberPassword })
          .selectedColor(C_ACCENT)
          .onChange((on: boolean) => { this.rememberPassword = on; })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(C_DIM)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .onClick(() => {
            this.showPasswordDialog = false;
            router.back();
          })
        Text('确定')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .borderRadius(9)
          .backgroundColor(C_ACCENT)
          .onClick(() => { this.submitPassword(); })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('86%')
    .padding(18)
    .borderRadius(14)
    .backgroundColor(C_CARD)
  }

  @Builder
  confirmDialog(title: string, text: string, okText: string, okColor: string, onOk: () => void) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Medium)
      Text(text)
        .fontSize(13)
        .fontColor(C_DIM)
        .margin({ top: 8, bottom: 16 })
        .textAlign(TextAlign.Center)
      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(C_DIM)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .onClick(() => {
            this.showInsecure = false;
            this.showOverride = false;
          })
        Text(okText)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .borderRadius(9)
          .backgroundColor(okColor)
          .onClick(() => { onOk(); })
      }
      .width('100%')
    }
    .width('86%')
    .padding(18)
    .borderRadius(14)
    .backgroundColor(C_CARD)
  }

  @Builder
  inputDialog(title: string, value: string, placeholder: string, onText: (v: string) => void,
              onOk: () => void, onCancel: () => void) {
    Column() {
      Text(title)
        .fontSize(16)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Medium)
      TextInput({ text: value, placeholder: placeholder })
        .height(46)
        .fontSize(15)
        .fontColor(C_TEXT)
        .placeholderColor(C_FAINT)
        .backgroundColor(C_BG)
        .margin({ top: 14 })
        .onChange((v: string) => { onText(v); })
        .onSubmit(() => { onOk(); })
      Row() {
        Text('取消')
          .fontSize(14)
          .fontColor(C_DIM)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .onClick(() => { onCancel(); })
        Text('确定')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(42)
          .borderRadius(9)
          .backgroundColor(C_ACCENT)
          .onClick(() => { onOk(); })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('86%')
    .padding(18)
    .borderRadius(14)
    .backgroundColor(C_CARD)
  }

  // ======================= build =======================

  @Builder
  actionSheet() {
    Column() {
      Text(this.sheetTitle)
        .fontSize(13)
        .fontColor(C_DIM)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ bottom: 6 })

      ForEach(this.sheetActions, (it: ActionItem) => {
        Text(it.label)
          .fontSize(15)
          .fontColor(it.danger ? C_ERR : C_TEXT)
          .width('100%')
          .height(48)
          .textAlign(TextAlign.Start)
          .padding({ left: 4 })
          .onClick(() => {
            this.showSheet = false;
            it.act();
          })
        Divider()
          .color(C_LINE)
          .strokeWidth(0.5)
      }, (it: ActionItem) => it.label)

      Text('取消')
        .fontSize(15)
        .fontColor(C_DIM)
        .width('100%')
        .height(48)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.showSheet = false; })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 12, bottom: 20 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .backgroundColor('#16203A')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.topBar()

        if (this.phoneForm) {
          this.paneTabs()
          Column() {
            this.crumbs(this.activeTab === 0)
            this.fileList(this.activeTab === 0)
            this.actionBar(this.activeTab === 0)
          }
          .layoutWeight(1)
        } else {
          // 2in1 / 平板：左右两栏，左边远端右边本机，拖/点是同一套逻辑。
          Row() {
            Column() {
              this.crumbs(true)
              this.fileList(true)
              this.actionBar(true)
            }
            .layoutWeight(1)
            .height('100%')

            Divider()
              .vertical(true)
              .color(C_LINE)
              .strokeWidth(0.5)

            Column() {
              this.crumbs(false)
              this.fileList(false)
              this.actionBar(false)
            }
            .layoutWeight(1)
            .height('100%')
          }
          .layoutWeight(1)
          .width('100%')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C_BG)

      if (this.showJobs) {
        this.jobsPanel()
      }

      if (this.showSheet) {
        this.actionSheet()
      }

      // 弹窗统一用一层遮罩 + 居中卡片，不使用 CustomDialog：
      // 页面离开时遮罩会跟着一起销毁，不会出现「返回后弹窗还挂在别的页面上」。
      if (this.showPasswordDialog || this.showInsecure || this.showOverride
        || this.showRename || this.showMkdir) {
        Column() {
          if (this.showPasswordDialog) {
            this.passwordDialog()
          } else if (this.showInsecure) {
            this.confirmDialog('未加密连接',
              '本次连接没有端到端加密，继续可能有被窃听的风险。',
              '仍然继续', C_ACCENT, () => { this.answerInsecure(true); })
          } else if (this.showOverride) {
            this.confirmDialog('文件已存在',
              `${this.overrideFileName} 已存在，是否覆盖？`,
              '覆盖', C_ACCENT, () => { this.answerOverride(true); })
          } else if (this.showRename) {
            this.inputDialog('重命名', this.renameInput, '新名称',
              (v: string) => { this.renameInput = v; },
              () => { this.doRename(); },
              () => { this.showRename = false; })
          } else if (this.showMkdir) {
            this.inputDialog('新建文件夹', this.mkdirInput, '文件夹名称',
              (v: string) => { this.mkdirInput = v; },
              () => { this.doMkdir(); },
              () => { this.showMkdir = false; })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .onClick(() => {})
      }
    }
    .width('100%')
    .height('100%')
  }

  // ======================= 渲染辅助（@Builder 里不能写普通语句，逻辑都搬到这里）===

  private crumbList(isRemote: boolean): string[] {
    const p: string = isRemote ? this.remotePath : this.localPath;
    const segs: string[] = pathCrumbs(p);
    if (segs.length === 0) {
      return ['/'];
    }
    // 段太多时只留最后 3 段，前面用 … 代替，免得面包屑撑满整行。
    if (segs.length > 4) {
      return ['…'].concat(segs.slice(segs.length - 3));
    }
    return segs;
  }

  private jumpToCrumb(isRemote: boolean, index: number): void {
    const p: string = isRemote ? this.remotePath : this.localPath;
    const segs: string[] = pathCrumbs(p);
    if (segs.length === 0) {
      return;
    }
    // 「…」这一段的 index 是 0，跳回根。
    const shown: string[] = this.crumbList(isRemote);
    const offset: number = shown.length !== segs.length ? (segs.length - 3) : 0;
    const realIndex: number = index === 0 && offset > 0 ? 0 : index + offset;
    if (realIndex >= segs.length - 1) {
      return;
    }
    const sep: string = sepOf(p);
    if (realIndex === 0 && segs[0] === sep) {
      this.navigate(isRemote, sep);
      return;
    }
    let acc: string = '';
    for (let i = 0; i <= realIndex; i++) {
      const s: string = segs[i];
      if (s === sep) {
        acc = sep;
        continue;
      }
      acc = acc.length === 0 ? s : (acc.endsWith(sep) ? `${acc}${s}` : `${acc}${sep}${s}`);
    }
    this.navigate(isRemote, acc);
  }

  private navigate(isRemote: boolean, path: string): void {
    if (isRemote) {
      if (!this.connected) {
        return;
      }
      this.remoteLoading = true;
      this.remoteSel = [];
      RustDesk.filesList(path, false);
    } else {
      this.localPath = path.length > 0 ? path : this.localRoot;
      this.loadLocal();
    }
  }

  private localEnter(name: string): void {
    this.localPath = `${this.localPath}/${name}`;
    this.loadLocal();
  }

  private localUp(): void {
    if (this.localPath === this.localRoot) {
      return;
    }
    const parent: string = parentPath(this.localPath);
    this.localPath = parent.length >= this.localRoot.length ? parent : this.localRoot;
    this.loadLocal();
  }

  private itemsOf(isRemote: boolean): FsItem[] {
    return isRemote ? this.remoteItems : this.localItems;
  }

  private selCount(isRemote: boolean): number {
    return isRemote ? this.remoteSel.length : this.localSel.length;
  }

  private isSelected(isRemote: boolean, name: string): boolean {
    return this.inList(isRemote ? this.remoteSel : this.localSel, name);
  }

  private isLoading(isRemote: boolean): boolean {
    return isRemote ? this.remoteLoading : this.localLoading;
  }

  private isEmpty(isRemote: boolean): boolean {
    return this.itemsOf(isRemote).length === 0;
  }

  private subtitle(item: FsItem): string {
    if (item.isDir) {
      return '文件夹';
    }
    const size: string = fmtSize(item.size);
    const t: string = fmtTime(item.mtime);
    return t.length > 0 ? `${size} · ${t}` : size;
  }

  private runningCount(): string {
    let n: number = 0;
    for (let i = 0; i < this.jobs.length; i++) {
      if (this.jobs[i].state === 'run' || this.jobs[i].state === 'wait') {
        n++;
      }
    }
    return n > 0 ? `${n}` : '列表';
  }

  private jobRightText(job: JobView): string {
    if (job.state === 'error') {
      return job.err.length > 0 ? job.err.substring(0, 18) : '失败';
    }
    if (job.state === 'done') {
      return '已完成';
    }
    if (job.state === 'wait') {
      return '等待确认';
    }
    const pct: string = job.total > 0
      ? `${Math.floor(job.done * 100 / job.total)}%`
      : fmtSize(job.done);
    const sp: string = fmtSpeed(job.speed);
    return sp.length > 0 ? `${pct} · ${sp}` : pct;
  }

  private clearDoneJobs(): void {
    const next: JobView[] = [];
    for (let i = 0; i < this.jobs.length; i++) {
      if (this.jobs[i].state === 'run' || this.jobs[i].state === 'wait') {
        next.push(this.jobs[i]);
      }
    }
    this.jobs = next;
    if (this.jobs.length === 0) {
      this.showJobs = false;
    }
  }

  /** 长按行：单个条目的快捷操作（底部动作面板）。 */
  private showItemMenu(isRemote: boolean, item: FsItem): void {
    this.sheetTitle = item.name;
    const actions: ActionItem[] = [];
    if (isRemote) {
      actions.push(new ActionItem('下载到本机', () => { this.downloadOne(item.name); }));
    } else {
      actions.push(new ActionItem('上传到远端', () => { this.uploadOne(item.name); }));
      actions.push(new ActionItem('导出到文件', () => { this.exportOne(item.name); }));
    }
    actions.push(new ActionItem('重命名', () => { this.renameOne(isRemote, item.name); }));
    actions.push(new ActionItem('删除', () => { this.deleteOne(isRemote, item.name, item.isDir); }, true));
    this.sheetActions = actions;
    this.showSheet = true;
  }

  private downloadOne(name: string): void {
    if (!this.connected) {
      return;
    }
    const id: number = RustDesk.filesDownload(joinPath(this.remotePath, name), `${this.downloadDir}/${name}`);
    if (id > 0) {
      this.jobs.push(new JobView(id, name, false));
      this.jobs = this.jobs.slice();
      this.showJobs = true;
      this.loadLocal();
    } else {
      promptAction.showToast({ message: `发起下载失败（${id}）` });
    }
  }

  private uploadOne(name: string): void {
    if (!this.connected) {
      return;
    }
    const id: number = RustDesk.filesUpload(`${this.localPath}/${name}`, this.remotePath);
    if (id > 0) {
      this.jobs.push(new JobView(id, name, true));
      this.jobs = this.jobs.slice();
      this.showJobs = true;
    } else {
      promptAction.showToast({ message: `发起上传失败（${id}）` });
    }
  }

  private async exportOne(name: string): Promise<void> {
    try {
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
      const uris: string[] = await p.save(opts);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const src: fs.File = fs.openSync(`${this.localPath}/${name}`, fs.OpenMode.READ_ONLY);
      const dst: fs.File = fs.openSync(uris[0],
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.copyFileSync(src.fd, dst.fd);
      fs.closeSync(src);
      fs.closeSync(dst);
      promptAction.showToast({ message: '已导出' });
    } catch (e) {
      const err: Error = e as Error;
      promptAction.showToast({ message: `导出失败：${err.message}` });
    }
  }

  private renameOne(isRemote: boolean, oldName: string): void {
    this.renameIsRemote = isRemote;
    this.renameOldName = oldName;
    this.renameInput = oldName;
    this.showRename = true;
  }

  private deleteOne(isRemote: boolean, name: string, isDir: boolean): void {
    promptAction.showDialog({
      title: '删除确认',
      message: `确定删除 ${name}？此操作不可撤销。`,
      buttons: [{ text: '取消', color: C_DIM }, { text: '删除', color: C_ERR }]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index !== 1) {
        return;
      }
      if (isRemote) {
        RustDesk.filesRemove(joinPath(this.remotePath, name), isDir);
        setTimeout(() => { this.remoteRefresh(); }, 400);
      } else {
        this.localRemove(name, isDir);
        this.loadLocal();
      }
    }).catch(() => {});
  }
}
