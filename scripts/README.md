# Deploy to Android from Windows / VS Code

The deployment task uses Android Debug Bridge (ADB) over USB. MTP file transfer can stay enabled, but the script transfers files through ADB.

## One-time setup

1. Download [SDK Platform-Tools for Windows](https://developer.android.com/tools/releases/platform-tools), extract the ZIP, and add the extracted `platform-tools` directory to your Windows user `PATH`. Android Studio is not required. Restart VS Code after changing `PATH`.
2. Enable **Developer options > USB debugging** on the Android device. Connect it by USB, unlock it, and accept the debugging authorization prompt for this PC. See the [Android ADB setup instructions](https://developer.android.com/tools/adb#Enabling).
3. Run `adb devices` in VS Code's terminal. Your device should have status `device`. If it says `unauthorized`, accept the prompt on the device.
4. Check the KOReader plugins path with `adb -d shell ls /sdcard/koreader/plugins`. The task assumes this path; if your installation uses another location, edit the `-PluginsPath` value in [tasks.json](../.vscode/tasks.json). Use an Android path, not the MTP breadcrumb shown by Windows Explorer. The directory must already exist.

The deployment script also detects ADB at `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` when it is not yet on the current process's PATH, so a standard SDK installation works in an already-open VS Code window.

## Each deployment

1. Save your code.
2. Press **Ctrl+Shift+B** in VS Code, or choose **Terminal > Run Task > Deploy plugin to Android**.
3. Once synchronization succeeds, the task opens KOReader automatically. An existing instance is closed and restarted; if KOReader was closed, it is simply launched.

Automatic launch targets the standard `org.koreader.launcher` Android package, including when it is running in the background. It uses Android's force-stop and launch commands, not KOReader's normal Exit action, so unsaved app state can be lost. Finish active lookups or edits before deploying, and avoid interacting with KOReader during the short copy step. If you need KOReader to save and exit normally, use its Exit action before deployment.

The script synchronizes the current working files, including uncommitted and new files, into `AI_Dictionary.koplugin` on the device. It uploads a temporary snapshot to `/data/local/tmp`, copies it into the installed plugin, then removes obsolete files and empty directories. Temporary staging directories are cleaned up afterward. On a first installation, configure the plugin on the device after deployment.

Like the built-in updater, deployment leaves every `configuration.lua` file, the root `Lookups/` directory and all its contents, and root `.update-*` working files/directories untouched. Local settings, lookup history, audio cache, and update working files are excluded from the upload. Other files missing from the snapshot are deleted, including obsolete code, assets, and audio-cache files; renamed files are replaced by their new names. Other plugins are unaffected.

Copying multiple files is not atomic. Obsolete files are pruned only after the upload and copy succeed, and KOReader is opened only after synchronization succeeds. If synchronization fails, the task does not stop or launch KOReader; rerun the deployment before using the plugin. A launch failure is reported separately from a successful file deployment. Android confirms that the activity started; plugin behavior still needs testing in KOReader. The script rejects symbolic links in managed files/directories rather than following them into another location.

## Terminal use and multiple devices

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-android.ps1
```

To use a different path, select one device from `adb devices`, or use ADB without adding it to PATH:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy-android.ps1 -PluginsPath /sdcard/koreader/plugins -Serial YOUR_DEVICE_SERIAL -AdbPath 'C:\Tools\platform-tools\adb.exe'
```

You can also add `"-Serial", "YOUR_DEVICE_SERIAL"` and/or `"-AdbPath", "C:/Tools/platform-tools/adb.exe"` to the task's `args` array. Without `-Serial`, the script targets a USB device using `adb -d` and fails if more than one USB device is connected. An emulator is not selected by default.

Pass `-SkipLaunch` (or add `"-SkipLaunch"` to the task's `args`) to copy files without stopping or launching KOReader, for example when deploying into a temporary test directory.

The task uses VS Code's [built-in task support](https://code.visualstudio.com/docs/debugtest/tasks); no VS Code extension is needed. It runs on demand, not automatically on every save.

## Isolated checks

Run `python tests/deploy_android_spec.py` from the repository root. The tests use Python's standard library and `sh` (included with Git for Windows) to exercise synchronization in temporary local folders. On Windows they also check the PowerShell upload flow with a fake ADB command. They never connect to a device. Actual Android deployment and reloading the plugin in KOReader still require device testing.
