// XComponent Surface 渲染循环。
//
// 为什么在 C++ 里做，而不是把帧交给 ArkTS 画：
//
//   1080x1920 的 RGBA 帧是 8.3MB。如果走 napi 传 ArrayBuffer 给 ArkTS，
//   每帧就要一次跨语言拷贝（napi 没有真正的零拷贝 ArrayBuffer 复用），
//   30fps 就是 250MB/s 的内存带宽，手机上直接卡死。
//
//   而 XComponent 的 Surface 本来就是 C++ 拿得到的 OHNativeWindow，
//   Rust 那边又已经用「槽 + 背压」把帧缓冲准备好了（见
//   src/platform/ohos/ui_handler.rs 的 mem::swap 设计）。所以最短路径是：
//
//     rustdesk_ohos_frame_acquire → memcpy 进 Surface buffer → flush → release
//
//   全程不经过 ArkTS，ArkTS 只负责 UI 和手势。
//
// 帧的语义（与 Rust 侧对齐，不能误解）：
//   - acquire 返回 nullptr = 没有新帧（画面静止），此时不要 flush，
//     让屏幕上保持上一帧。
//   - 拿到非空指针后**必须** release，否则 Rust 侧背压会把后续帧全丢掉，
//     表现为「画面停在第一帧」。
//   - 所以 release 要放在 flush 之后、且必须无条件执行（包括异常路径）。

#include "bridge.h"
#include "rustdesk_ohos.h"

#include <hilog/log.h>
#include <native_window/external_window.h>

#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "RustDeskRender"

namespace {

// 没新帧时的轮询间隔。8ms ≈ 125Hz 探测频率，足够跟手，
// 又比 1ms 忙等省电得多（画面静止时几乎不耗 CPU）。
constexpr int kIdleSleepMs = 8;

std::mutex g_render_mu;
std::thread g_render_thread;
std::atomic<bool> g_running{false};
std::atomic<bool> g_active{false};

OHNativeWindow* g_window = nullptr;
int32_t g_surface_w = 0;
int32_t g_surface_h = 0;

void RenderLoop() {
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "render loop enter");

    int32_t configured_w = 0;
    int32_t configured_h = 0;
    // buffer 的实际几何尺寸（= 最近一帧的尺寸），与 Surface 尺寸无关。
    int32_t buffer_w = 0;
    int32_t buffer_h = 0;
    // geometry 与帧尺寸不一致时的连续重试计数（见下面的自愈分支）。
    int32_t drift_retry = 0;

    while (g_running.load(std::memory_order_acquire)) {
        if (!g_active.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(32));
            continue;
        }

        OHNativeWindow* window = nullptr;
        int32_t want_w = 0, want_h = 0;
        {
            std::lock_guard<std::mutex> lk(g_render_mu);
            window = g_window;
            want_w = g_surface_w;
            want_h = g_surface_h;
        }
        if (window == nullptr) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMs));
            continue;
        }

        // Surface 尺寸变化（旋转 / 分屏 / 折叠屏展开 / 2in1 拉窗口）时记下来。
        //
        // **不**用它设置 buffer geometry（buffer 恒等于帧尺寸，见下），但必须
        // 让下一帧重新钉一次 geometry：窗口尺寸一变，框架会把 native window 的
        // 默认 buffer 尺寸重置成新窗口尺寸，`request_buffer` 就会给出窗口尺寸的
        // 缓冲。此时我们仍然按帧尺寸拷，只会拷进左上角一部分（画面被裁、比例
        // 错乱），或者干脆对不上号。之前这里只记录、不重设，就是「拉窗口画面
        // 不跟随」的直接原因。
        if (want_w != configured_w || want_h != configured_h) {
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "surface resized %{public}dx%{public}d -> %{public}dx%{public}d",
                         configured_w, configured_h, want_w, want_h);
            configured_w = want_w;
            configured_h = want_h;
            buffer_w = -1;
            buffer_h = -1;
        }

        int32_t frame_w = 0, frame_h = 0;
        const uint8_t* frame = rustdesk_ohos_frame_acquire(0, &frame_w, &frame_h);
        if (frame == nullptr || frame_w <= 0 || frame_h <= 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMs));
            continue;
        }

        // buffer 的几何尺寸取**帧**尺寸，不是 Surface 尺寸。
        //
        // 这样 memcpy 就是一次行对行的大拷贝（没有缩放），而合成器会把
        // buffer 缩放到 Surface 上显示。ArkTS 那边把 XComponent 的
        // aspectRatio 设成帧的宽高比，两者比例一致，所以拉伸后不变形。
        //
        // 反过来（用 Surface 尺寸建 buffer）就得在 CPU 上做软件缩放，
        // 1080p 每帧几十毫秒，完全不可行。
        if (buffer_w != frame_w || buffer_h != frame_h) {
            OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY,
                                                  frame_w, frame_h);
            buffer_w = frame_w;
            buffer_h = frame_h;
        }

        // --- 写 Surface ---------------------------------------------------
        // request → mmap → memcpy → munmap → flush。
        // 每帧 mmap/munmap 看着重，但 OHOS 的 buffer 是 gralloc 分配的，
        // map 的是已存在的物理页，只是建页表项，比多留一份 8MB 副本便宜。
        OHNativeWindowBuffer* buffer = nullptr;
        Region region{nullptr, 0};
        // 第三个参数是 fence fd（不是 dirty region，那是 FlushBuffer 的参数）。
        // request 时传 -1 进来表示「不关心上一帧的同步点」。
        int fence_fd = -1;
        int32_t ret = OH_NativeWindow_NativeWindowRequestBuffer(window, &buffer, &fence_fd);
        if (ret != 0 || buffer == nullptr) {
            // 失败（常见于 Surface 正在销毁）：release 再重试下一帧。
            if (fence_fd >= 0) close(fence_fd);
            rustdesk_ohos_frame_release(0);
            std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMs));
            continue;
        }
        // request 拿到的 fence 我们在本线程同步写完，不需要等；
        // 但按文档要求必须自己 close，否则泄漏 fd（每帧一个，很快就满）。
        if (fence_fd >= 0) close(fence_fd);

        BufferHandle* handle = OH_NativeWindow_GetBufferHandleFromNative(buffer);
        if (handle == nullptr) {
            OH_NativeWindow_NativeWindowAbortBuffer(window, buffer);
            rustdesk_ohos_frame_release(0);
            std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMs));
            continue;
        }

        // 只在第一帧打印一次：像素格式与 stride 是排查「颜色不对」的第一现场。
        // Rust 侧解码输出固定为 `ImageFormat::ABGR`（libyuv 的 ABGR = 内存
        // R,G,B,A），对应这里的 `PIXEL_FMT_RGBA_8888`（=12）。若这里是
        // `PIXEL_FMT_BGRA_8888`（=20），红蓝就会互换。
        static bool format_logged = false;
        if (!format_logged) {
            format_logged = true;
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "buffer fmt=%{public}d stride=%{public}d size=%{public}dx%{public}d "
                         "frame=%{public}dx%{public}d",
                         handle->format, handle->stride, handle->width, handle->height,
                         frame_w, frame_h);
            if (handle->format != 12) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "unexpected buffer format %{public}d (want 12 = RGBA_8888), "
                             "colors will be wrong",
                             handle->format);
            }
        }

        // 自愈：request 出来的缓冲尺寸和帧尺寸不一致，说明 window 的默认
        // buffer 尺寸被框架改回去了（窗口 resize / 旋转最常见）。这一帧先扔，
        // 下一轮会重新 SET_BUFFER_GEOMETRY 把它钉回帧尺寸。
        //
        // 加计数上限：万一 SET_BUFFER_GEOMETRY 不生效（厂商实现差异），无上限
        // 重试会把每一帧都扔掉 —— 画面直接冻住，比裁切更难排查。超过上限就
        // 老老实实按实际缓冲尺寸裁着画。
        if (handle->width != frame_w || handle->height != frame_h) {
            if (drift_retry < 30) {
                ++drift_retry;
                OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                             "buffer geometry drifted %{public}dx%{public}d "
                             "(want %{public}dx%{public}d), re-apply #%{public}d",
                             handle->width, handle->height, frame_w, frame_h, drift_retry);
                buffer_w = -1;
                buffer_h = -1;
                OH_NativeWindow_NativeWindowAbortBuffer(window, buffer);
                rustdesk_ohos_frame_release(0);
                continue;
            }
        } else {
            drift_retry = 0;
        }

        void* mapped = mmap(handle->virAddr, handle->size, PROT_READ | PROT_WRITE,
                            MAP_SHARED, handle->fd, 0);
        if (mapped == MAP_FAILED) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "mmap buffer failed: %{public}d", errno);
            OH_NativeWindow_NativeWindowAbortBuffer(window, buffer);
            rustdesk_ohos_frame_release(0);
            std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMs));
            continue;
        }

        // 逐行拷贝：Surface 的 stride 通常等于 width*4，但不保证
        // （厂商可能按 16/32 字节对齐补齐）。按行拷最安全，
        // 而且当 stride == width*4 时就是一次大 memcpy，编译器会走 memmove 优化。
        {
            const auto* src = frame;
            auto* dst = static_cast<uint8_t*>(mapped);
            const size_t src_stride = static_cast<size_t>(frame_w) * 4;
            const size_t dst_stride = static_cast<size_t>(handle->stride);
            const size_t copy_w = src_stride < dst_stride ? src_stride : dst_stride;
            const int32_t rows = handle->height < frame_h ? handle->height : frame_h;
            if (copy_w == dst_stride && dst_stride == src_stride) {
                std::memcpy(dst, src, src_stride * static_cast<size_t>(rows));
            } else {
                for (int32_t y = 0; y < rows; ++y) {
                    std::memcpy(dst + dst_stride * static_cast<size_t>(y),
                                src + src_stride * static_cast<size_t>(y), copy_w);
                }
            }
        }

        munmap(mapped, handle->size);
        OH_NativeWindow_NativeWindowFlushBuffer(window, buffer, -1, region);

        // 必须 release：Rust 侧靠它把缓冲还回视频管线复用。
        rustdesk_ohos_frame_release(0);
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "render loop exit");
}

}  // namespace

namespace rustdesk_ohos {

void OnSurfaceCreated(void* nativeWindow, int32_t width, int32_t height) {
    std::thread to_join;
    {
        std::lock_guard<std::mutex> lk(g_render_mu);
        // 重复创建（例如 XComponent 重建）时先停旧的。
        if (g_running.exchange(false)) {
            if (g_render_thread.joinable()) to_join = std::move(g_render_thread);
        }
        g_window = static_cast<OHNativeWindow*>(nativeWindow);
        g_surface_w = width;
        g_surface_h = height;
    }
    if (to_join.joinable()) to_join.join();

    {
        std::lock_guard<std::mutex> lk(g_render_mu);
        g_running.store(true, std::memory_order_release);
        g_render_thread = std::thread(RenderLoop);
    }
    g_active.store(true, std::memory_order_release);

    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "surface created %{public}dx%{public}d", width, height);
}

void OnSurfaceChanged(int32_t width, int32_t height) {
    std::lock_guard<std::mutex> lk(g_render_mu);
    g_surface_w = width;
    g_surface_h = height;
}

void OnSurfaceDestroyed() {
    std::thread to_join;
    {
        std::lock_guard<std::mutex> lk(g_render_mu);
        if (g_running.exchange(false)) {
            if (g_render_thread.joinable()) to_join = std::move(g_render_thread);
        }
        g_window = nullptr;
        g_surface_w = 0;
        g_surface_h = 0;
    }
    // join 放在锁外：见 StopThreadLocked 的注释。
    if (to_join.joinable()) to_join.join();
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "surface destroyed");
}

void SetRenderActive(bool active) {
    g_active.store(active, std::memory_order_release);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "render %{public}s", active ? "resumed" : "paused");
}

}  // namespace rustdesk_ohos
