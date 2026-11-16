# PhoneBridge

A small native macOS app for the two things you keep opening Android Studio (or fumbling with your iPhone) for:

- **Screenshots** of any USB / adb-connected Android device and of a USB-connected iPhone. One click (or ⌘S): preview, saved to a folder, copied to the clipboard, drag it anywhere.
- **Files**: browse an Android device, drag files in to upload, download files and folders to your Mac. Import photos and videos from an iPhone.

No Xcode project, no dependencies beyond `adb` for Android.

> 中文说明见下方。

## Requirements

- macOS 14 or later. Tested on Apple Silicon (macOS 26); Intel is untested.
- Android: [platform-tools](https://developer.android.com/tools/releases/platform-tools) (`adb`) and USB debugging enabled
- iPhone: connected by USB and "Trust This Computer" accepted. No developer disk image and no sudo. The screen-capture channel is the one QuickTime uses, so developer mode should not be needed, but so far it has only been tested on a phone with developer mode on.

## Build and install

```sh
git clone <this repo> && cd phonebridge
scripts/build-app.sh --install     # builds build/PhoneBridge.app and copies it to /Applications
```

Requires the Swift toolchain that comes with Xcode or the Command Line Tools.

The build is signed with your first local "Apple Development" identity if you have one (set `PB_SIGN_IDENTITY` to pick another), otherwise ad-hoc. macOS ties the camera permission to the signature: with an ad-hoc signature it asks again after every rebuild.

## How it works

| | How |
|---|---|
| Android screenshot | `adb exec-out screencap -p` (multi-display devices get a display picker) |
| Android files | `adb shell stat` for listing, `adb push` / `adb pull` for transfer |
| iPhone screenshot | The macOS USB screen-capture channel (the one QuickTime uses for iPhone recording), via CoreMediaIO + AVFoundation |
| iPhone photos | ImageCaptureCore (the framework behind Image Capture.app) |

Notes:

- **adb lookup**: GUI apps don't get your shell `PATH`, so PhoneBridge asks your login shell (`$SHELL -lc 'command -v adb'`) for `adb` and falls back to common install locations. Using the same `adb` as your terminal matters: a different `adb` version restarts the running adb server and drops wireless connections. You can set the path in Settings.
- **Never touches the adb server**: no `kill-server`, `connect`, `disconnect`. Files are only written where you drop or download them. There is no delete, rename or APK install on purpose.
- **iPhone status bar**: while its screen is being captured, iOS shows a clean status bar (9:41, full battery, full signal). Screenshots show that, not the real status bar.
- **Why the screen-capture switch stays on**: once the process that enabled it exits, the iPhone takes several seconds to reappear, so back-to-back screenshots would fail. PhoneBridge keeps it on while running, opens a capture session per screenshot and stops it right after.
- **Camera permission**: macOS treats the iPhone screen as a camera-class device, so the first iPhone screenshot asks for camera access. Nothing is recorded or uploaded.
- **Copying files to an iPhone** is not supported: Apple has no public API for it. Use AirDrop.
- **Same-name files are overwritten**, both when uploading to Android and when downloading to the Mac (that is what `adb push` / `adb pull` do).
- **iPhone photo library**: large libraries load in batches, the grid fills in over a few seconds. If the photo channel stops answering (seen after opening and closing it many times in a row), unlock the phone and re-plug the cable.

## Self test

```sh
open -W -n /Applications/PhoneBridge.app --args --selftest /tmp/pb-selftest
cat /tmp/pb-selftest/report.txt
```

Screenshots every connected device, does an upload / list / download round trip on each Android device (in `/sdcard/Download/phonebridge-selftest/`, removed afterwards), opens the iPhone photo library, then quits. Unit tests: `swift test`.

## License

MIT

---

## 中文

PhoneBridge 是一个 macOS 小工具，用来替代「只为截图打开 Android Studio」：

- **截图**：USB / adb 连接的 Android 设备、USB 连接的 iPhone，点一下（或按 ⌘S）出预览，自动存到文件夹并复制到剪贴板，也可以直接把图拖走。多屏设备（比如带副屏的机器）可以选截哪块屏。
- **传文件**：浏览 Android 设备里的文件，把 Mac 上的文件拖进去就上传，选中后下载到 Mac。iPhone 可以导入照片和视频。
- 保存目录在设置（⌘,）里改。

安装：`scripts/build-app.sh --install`，装到「应用程序」，之后像普通 App 一样打开、关闭。

需要知道的：

- iPhone 截图走 macOS 自带的 USB 屏幕采集（QuickTime 录 iPhone 屏用的就是它），不用 sudo。理论上不需要开发者模式，但目前只在开着开发者模式的手机上测过。第一次会请求摄像头权限。
- iPhone 截图里的状态栏是系统替换后的（9:41、满电、满信号），不是真实状态栏。
- 不支持往 iPhone 里传文件，苹果没有公开接口，请用 AirDrop。
- 同名文件会被覆盖（上传到 Android、下载到 Mac 都是）。
- iPhone 照片多时分批加载，几秒内陆续补全；如果照片一直读不出来，解锁手机、拔插一次数据线。
- 不会动 adb 服务（不执行 kill-server / connect / disconnect），也没有删除、重命名、装 APK 功能。
