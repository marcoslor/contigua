# Working in this repo

- Read `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md` before changing anything. The protocol doc is the contract; if code and doc disagree, the doc wins (or propose a doc change in your report).
- Stay inside the directories your task names. Other agents work in parallel in sibling directories.
- **Do not `git commit`, `git add`, branch, or push.** The reviewer commits after review.
- No debug/TEMP leftovers, no commented-out code, no "v48q"-style version tags in comments. Comments explain *why*, briefly.
- Keep dependencies minimal: Android = Shizuku + androidx.core only; macOS = system frameworks only; tools = Python 3.9 stdlib + ffmpeg/dns-sd CLIs.
- Toolchain: `JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=$HOME/Library/Android/sdk` (platform 36, build-tools 36.0.0). Swift 6.4 / macOS 27 SDK, deployment target macOS 15.
- Phone rig (only when `timeout 20 adb devices` lists it): Samsung SM-S936B, Android 16, Shizuku running. Always prefix adb with `timeout 20`.
