# scrap::ohos 契约说明（被控端采集后端）

本目录将实现 `libs/scrap` 的 OHOS 后端。**尚未接入编译**（未在 `libs/scrap/src/lib.rs` 注册），
因为需要先完成 M3 的编码链路 PoC。

## 上游契约

`video_service.rs` 通过 `scrap::create_capturer(display, ...) -> Box<dyn TraitCapturer>` 获取采集器，
`TraitCapturer` 的关键方法（详见 `libs/scrap/src/common/mod.rs`）：

- `frame(&mut self, timeout) -> Option<&Frame>`
- `format(&self) -> FrameFormat`
- `set_quality / set_fps / ...`

## OHOS 实现策略（与 Android 相反）

Android 是「Java 采集原始 RGBA → JNI 交给 Rust → Rust 自己编码」。
OHOS 必须反过来：

```
C++ AVScreenCapture(原始码流) → OH_VideoEncoder(Surface 直连) → 编码 packet
   → 回调 ohos_capture_set_frame_callback(codec, pts, is_key, data, len)
   → Rust 侧 ring buffer（深度 2，拥塞丢旧帧）
   → OhosCapturer::frame() 取出 → 交给上游 video_service 直接推流
```

原因：
1. ArkTS/C 侧才能拿到 AVScreenCapture 的原始码流（ArkTS 版只能写文件）；
2. Surface→编码器零拷贝，避免 RGBA 回传再编码的两次拷贝；
3. 上游 `video_service` 已支持"外部编码帧"路径（`VideoFrame` 消息直接带码流），无需改动。

## 待实现文件

- `mod.rs`：`pub struct OhosCapturer`、`impl TraitCapturer`
- `ring.rs`：深度 2 的丢旧帧队列
- 在 `libs/scrap/src/lib.rs` 增加一行注册（Tier-3 补丁，需登记到 PATCH_INVENTORY）
