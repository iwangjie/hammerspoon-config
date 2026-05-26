# Hammerspoon 配置

## 使用方法

1. 安装 [Hammerspoon](http://www.hammerspoon.org/)
2. 克隆配置：

```
git clone git@github.com:iwangjie/hammerspoon-config.git ~/.hammerspoon
```

主要配置在 `config.lua` 文件中，当前配置按这台 MacBook Pro 的已安装应用、输入法和音频设备整理。

> 注：修改 `.lua` 文件会自动加载。

### 窗口管理

* <kbd>Control</kbd><kbd>Command</kbd> + <kbd>Return</kbd> `最大化窗口`
* <kbd>Control</kbd><kbd>Command</kbd> + <kbd>→</kbd> `把窗口移动到右边显示器`
* <kbd>Control</kbd><kbd>Command</kbd> + <kbd>←</kbd> `把窗口移动到左边显示器`
* <kbd>Control</kbd><kbd>Command</kbd> + <kbd>F</kbd> `全屏或者退出全屏`

### 快速启动

* <kbd>Option</kbd> + <kbd>G</kbd> `Google Chrome`
* <kbd>Option</kbd> + <kbd>E</kbd> `Microsoft Edge`
* <kbd>Option</kbd> + <kbd>A</kbd> `Antigravity`
* <kbd>Option</kbd> + <kbd>T</kbd> `Ghostty`
* <kbd>Option</kbd> + <kbd>X</kbd> `Xcode`
* <kbd>Option</kbd> + <kbd>W</kbd> `WeChat`
* <kbd>Option</kbd> + <kbd>Y</kbd> `企业微信`
* <kbd>Option</kbd> + <kbd>N</kbd> `网易云音乐`
* <kbd>Option</kbd> + <kbd>M</kbd> `Microsoft To Do`
* <kbd>Option</kbd> + <kbd>S</kbd> `System Settings`

### 自动切换输入法

具体看 `config.lua` 文件里面的 `appInputMethod` 值。当前英文输入法为 `com.apple.keylayout.ABC`，中文输入法为 `com.tencent.inputmethod.wetype.pinyin`。

PS：目前配置的中文输入法是微信输入法。使用命令 `defaults read ~/Library/Preferences/com.apple.HIToolbox.plist | grep "Input Mode"` 获取输入法的 SourceID，然后配置 `defaultInput.lua` 文件。

### 自动开关蓝牙

锁屏自动关闭蓝牙，解锁自动开启蓝牙。使用这个功能之前先要安装 `blueutil`。Apple Silicon 默认路径为 `/opt/homebrew/bin/blueutil`，Intel Homebrew 路径为 `/usr/local/bin/blueutil`；如果未安装，模块会跳过蓝牙切换。

```sh
brew install blueutil
```

### 连接公司 Wi-Fi 自动静音

修改配置文件中的 `workWifis` 为公司 Wi-Fi 名称列表。如果为空，则不会启用自动静音。当前配置为 `jishufuwuqi` 和 `SBY`，并且只会在当前输出设备为 `MacBook Pro扬声器` 时静音。
