# WasThat

Version 1.1 · macOS 14.2+ · Developer ID signed

WasThat helps you check which apps were using audio when you heard a sound on your Mac. It also shows notification activity when macOS provides enough information.

[Download for Mac](https://github.com/iacompa/WasThat/releases/download/v1.1/WasThat.dmg) · [Release notes](docs/release/v1.1-notes.md) · [GitHub](https://github.com/iacompa/WasThat)

## Install and use

1. Download the DMG.
2. Open the DMG.
3. Drag WasThat into Applications.
4. Open WasThat from Applications.

Use **Start detection** if detection is off. If approval is needed, choose **Open Login Items**. Allow WasThat in macOS. Return to WasThat. Choose **Check again**.

Click the question-mark bubble in the menu bar to check **Latest activity**. Choose **Open history** for the last hour, 24 hours, or seven days. **Apps using audio now** shows current activity.

For an identified source, **Open app** opens its app when it is available on your Mac. On notification entries, **Notification settings** opens the general Notifications page. Select the named app there if macOS lists it. Recognized background-item alerts can offer **Login Items**.

These actions cannot reopen a specific notification, message, or browser tab. Unidentified senders stay unconfirmed.

Closing or quitting WasThat keeps background detection on when it is enabled. To stop monitoring, choose **Stop detection**. Wait for **Detection is off** before quitting. Saved history remains available when detection is off.

## What to expect

Notification history can be incomplete, and macOS may not identify a sender. A sound inside ongoing app audio may not create a new entry. Audio activity does not prove that a sound was audible. WasThat does not mute or replay sounds, or identify individual browser tabs.

WasThat stores activity details on your Mac. It does not save audio recordings or notification message text. It has no account or analytics.

WasThat removes records older than seven days when detection starts, then checks every ten minutes while running. Cleanup can be delayed while detection is off or if storage is unavailable.

## License and source

WasThat is free software under [GPL v3](https://github.com/iacompa/WasThat/blob/v1.1/LICENSE). You may use, study, modify, and share it under the license terms. © 2026 IA COMPA LLC.

[Complete license](https://github.com/iacompa/WasThat/blob/v1.1/LICENSE) · [Version 1.1 source](https://github.com/iacompa/WasThat/tree/v1.1) · [Corresponding source archive](https://github.com/iacompa/WasThat/archive/refs/tags/v1.1.tar.gz)

## For developers

Build with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
xcodebuild -project WasThat.xcodeproj -scheme WasThat -configuration Debug -derivedDataPath build/DerivedData build
```

The project uses Swift 6. Configure your signing identity in [project.yml](project.yml) for signed builds. The generated Xcode project is not committed.
