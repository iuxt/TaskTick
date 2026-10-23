# TaskTick

<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="TaskTick Icon">
</p>

<h3 align="center">TaskTick</h3>

<p align="center">
  <strong>A native macOS app for managing scheduled tasks.</strong><br>
  No crontab, no launchd — just TaskTick.
</p>

<p align="center">
  <a href="https://github.com/iuxt/TaskTick/releases/latest"><img src="https://img.shields.io/github/v/release/iuxt/TaskTick?style=flat-square&color=34D399&label=Latest" alt="Latest Release"></a>
  <a href="https://github.com/iuxt/TaskTick/releases"><img src="https://img.shields.io/github/downloads/iuxt/TaskTick/total?style=flat-square&color=7C3AED&label=Downloads" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <a href="https://www.gnu.org/licenses/gpl-3.0.html"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/iuxt/TaskTick/releases/latest">⬇️ <strong>Download Latest</strong></a>
</p>

<p align="center">
  <a href="https://iuxt.github.io/TaskTick/">Website</a> ·
  <a href="https://iuxt.github.io/TaskTick/guide/">Documentation</a> ·
  <a href="README_zh.md">中文文档</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/iuxt/images@master/uPic/2026/03/CS2026-03-16-12.47.53@2x.png" width="800" alt="TaskTick Screenshot">
</p>

## Features

- **Menu Bar Resident** — runs in background, always accessible from menu bar
- **Flexible Scheduling** — date, time, repeat cycle with intuitive UI (like Reminders)
- **Script Execution** — inline scripts or local files (.sh, .py, .rb, .js)
- **Execution Logs** — stdout/stderr capture, exit codes, duration tracking
- **Background Programs** — start, stop, and supervise long-running commands with auto-start, restart policies, file output, and size-based log rotation
- **Notifications** — macOS system notifications on success/failure (per task)
- **Crontab Import** — import from system crontab with one click
- **i18n** — English & Simplified Chinese, switchable in-app
- **macOS 26 Ready** — liquid glass effects on supported systems

## Requirements

### Background programs

After creating a background process, configure its restart policy, log path, maximum file size, and retained files under the editor’s Settings tab.

Use **Start at Login** in the detail view or context menu to launch a background process when you log in. Enabling it also enables TaskTick’s login item. Turning it off leaves the current process running; use Run and Stop to control it. The editor’s Basic tab has the same auto-start setting.

### Log files

Each scheduled execution creates a separate `.log` file under `~/Library/Logs/TaskTick/com.iuxt.TaskTick/<task name>/`, matching its Recent Runs entry. Open the log folder from the task detail view or reveal an individual execution's file in Finder. Characters that cannot be used in folder names are replaced with `-`.

**Clear Logs** deletes completed scheduled executions' `.log` files and clears the displayed output, preserving execution records and execution counts. A running execution's file is emptied in place so it can continue writing new output. Manual tasks and background processes empty their files in place, including rotation archives. Deleting execution records or cleaning up expired history also removes their files.

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac

## Install

### Homebrew (Recommended)

```bash
brew tap iuxt/tap
brew install --cask task-tick
```

Update to the latest version:

```bash
brew upgrade --cask task-tick
```

### Download

Grab the latest `.dmg` from [Releases](https://github.com/iuxt/TaskTick/releases):

| File | Architecture |
|------|-------------|
| `TaskTick-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `TaskTick-x.x.x-x86_64.dmg` | Intel Mac |

When a release is marked **Signed & Notarized**, drag TaskTick to Applications
and open it normally. Ad-hoc releases built without an Apple Developer
certificate may require **Right-click TaskTick.app → Open → Open**, or:

```bash
xattr -cr /Applications/TaskTick.app
```

### Build from Source

```bash
git clone https://github.com/iuxt/TaskTick.git
cd TaskTick
./build.sh
```

The script quits TaskTick, builds a Release app for this Mac, installs it to `/Applications/TaskTick.app`, removes temporary files, and launches the app. Xcode or Xcode Command Line Tools is required. It requests an administrator password if the installation directory is not writable.

## Website development

The official website uses Hugo and deploys automatically to GitHub Pages.
See [website development and deployment](docs/WEBSITE.md) for local preview,
content editing, and build instructions.

## License

GPL-3.0 © [iuxt](https://github.com/iuxt)
