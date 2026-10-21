# Neovim 設定 — macOS 版

這個資料夾是上一層 Windows 版 `init.lua` 的 macOS 移植版。
插件清單、快捷鍵、外觀、LSP 行為全部相同，只改了跟作業系統有關的部分；
`lazy-lock.json` 直接沿用，兩邊安裝到的插件版本會一致。

## Neovim 版本

- **最低需求：Neovim 0.11**（`vim.lsp.config` / `vim.lsp.enable` / `vim.diagnostic.jump` 都是 0.11 才有）。
  版本太舊的話 `init.lua` 一開頭會直接跳錯誤訊息並停止載入，不會噴一整串紅字。
- **建議：直接 `brew install neovim`**，Homebrew 的穩定版目前是 0.12.6，可以直接用。
  這份 macOS 版已經把 0.12 會跳 deprecated 警告的呼叫換掉
  （`vim.diagnostic.goto_next` → `jump`、`termopen` → `jobstart`、`vim.loop` → `vim.uv`），
  所以 0.11 和 0.12 都能跑、不會有警告。
- 不需要、也不建議刻意裝舊版。真的需要固定某個版本時：
  - `brew install bob` 再 `bob use 0.11.5`（Neovim 版本管理器，可以同時裝多版切換）
  - 或到 GitHub Releases 下載 `nvim-macos-arm64.tar.gz`（Intel 是 `nvim-macos-x86_64.tar.gz`）解壓後把 `bin/nvim` 加進 PATH
  - Homebrew 本身沒有 `neovim@0.11` 這種固定版本的 formula

裝好後用 `nvim --version` 確認第一行是 `NVIM v0.11.x` 或 `v0.12.x`。

## 安裝

```sh
# 1. 把這個資料夾的內容放到 ~/.config/nvim
mkdir -p ~/.config/nvim
cp -R init.lua lazy-lock.json after ~/.config/nvim/

# 2. Neovim + 基本工具 (git / clang 由 Xcode Command Line Tools 提供，treesitter 編譯需要)
xcode-select --install
brew install neovim fzf ripgrep fd bat node
nvim --version   # 應顯示 NVIM v0.12.x (至少 0.11)

# 3. 格式化 (conform.nvim 用 prettier)
npm install -g prettier

# 4. Rust (rust_analyzer 由 rustup 提供)
brew install rustup && rustup-init
rustup component add rust-analyzer

# 5. Nerd Font (nvim-tree / fzf-lua 的圖示)
brew install --cask font-jetbrains-mono-nerd-font   # 或任一 Nerd Font，記得在終端機選用

# 6. 第一次啟動會自動下載 lazy.nvim 並安裝所有插件
nvim
```

Mason 會自動裝 `lua_ls`、`ts_ls`、`vue_ls`、`tailwindcss`（需要 node）。

## 與 Windows 版的差異

| 項目 | Windows 版 | macOS 版 |
|---|---|---|
| Shell | 強制設定 `pwsh` + 一串 `shellcmdflag` / `shellredir` | 不設定，直接用 `$SHELL`（預設 `/bin/zsh`） |
| PATH | — | 啟動時把 `/opt/homebrew/bin`、`/usr/local/bin` 補進 PATH，從 Neovide / Finder 啟動時才找得到 git、node、podman |
| OmniSharp 容器 | `wsl podman ...`，並把 `D:\` 轉成 `/mnt/d` | 直接 `podman ...`，路徑不用轉換，掛載 `$HOME:$HOME` |
| jdtls 容器 | 同上 | 同上 |
| podman 不存在時 | 啟動 LSP 會直接報錯 | 開 `.cs` / `.java` 檔時提示一次，其它 LSP 照常運作 |
| 浮動終端 `<leader>tt` | `termopen("pwsh")` | `jobstart({ vim.o.shell }, { term = true })` |
| `Alt+j` / `Alt+k` 行移動 | 直接可用 | 另外綁定 `∆` / `˚`（Option 鍵沒設成 Alt 時 macOS 送出的字元） |
| Diagnostic 跳轉 `]d` `[d` `]e` `[e` | `vim.diagnostic.goto_next/prev`（0.12 會跳 deprecated 警告） | `vim.diagnostic.jump()`，行為相同 |
| 版本檢查 | — | 開頭檢查 `has("nvim-0.11")`，太舊直接提示並停止 |

### 順便修了一個 Windows 版也有的 bug

Windows 版 OmniSharp 的 `cmd` 寫的是 `vim.lsp.rpc.start("wsl", { "podman", ... }, dispatchers)`。
從 Neovim 0.10 開始 `vim.lsp.rpc.start` 的第一個參數就必須是**整個指令的 table**
（內部有 `validate('cmd', cmd, 'table')`），字串會直接被擋下來，OmniSharp 根本起不來。
macOS 版已改成 `vim.lsp.rpc.start({ "podman", "exec", ... }, dispatchers)`；
Windows 版要修的話同樣改成 `vim.lsp.rpc.start({ "wsl", "podman", "exec", ... }, dispatchers)` 即可。

## 容器 (OmniSharp / jdtls) 注意事項

Windows 版是 `Windows → WSL2 → podman`，macOS 版是 `macOS → podman machine`：

```sh
brew install podman
podman machine init     # 預設會把 /Users 掛進 VM，所以 -v $HOME:$HOME 可以直接用
podman machine start
```

- `omnisharp-lsp`、`jdtls-lsp` 這兩個 image 需要在 Mac 上重新 build 或 `podman load` 進去。
- Apple Silicon：原本在 WSL 裡 build 的是 amd64 image。
  要嘛重新 build arm64 版，要嘛確認 `podman machine` 有開 Rosetta（applehv 預設開啟），
  amd64 image 才跑得動，但會慢一些。
- 容器內的路徑直接等於主機路徑（例如 `/Users/你/source/proj`），
  因為 `$HOME` 被掛到容器裡同一個位置。如果專案不在 `$HOME` 底下，要另外加 `-v`。
- `jdtls` 的 workspace 仍然在容器內的 `/home/ubuntu/.cache/jdtls/workspace/`，跟 Windows 版相同。

## 鍵盤注意事項（終端機設定，不是 nvim 設定）

- **Option 當 Alt**：`<A-j>` / `<A-k>` 要能用，需把終端機的 Option 鍵設成 Esc+ / Meta：
  - iTerm2：Profiles → Keys → Left Option key → `Esc+`
  - Terminal.app：描述檔 → 鍵盤 → 勾「將 Option 鍵作為 Meta 鍵」
  - Kitty：`macos_option_as_alt yes`
  - Ghostty：`macos-option-as-alt = true`
  - WezTerm：`send_composed_key_when_left_alt_is_pressed = false`

  沒設定也沒關係，`init.lua` 已同時綁定 `∆` / `˚`（Option+j / Option+k 在美式鍵盤送出的字元）。
- **Ctrl+← / Ctrl+→**（調整視窗寬度）預設被 macOS Mission Control「移至左/右側的空間」吃掉。
  到 系統設定 → 鍵盤 → 鍵盤快速鍵 → Mission Control 取消那兩項，終端機才收得到。
- 系統剪貼簿：`unnamedplus` 在 macOS 會自動走 `pbcopy` / `pbpaste`，不需要額外設定。
