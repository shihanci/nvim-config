vim.g.mapleader = " "      -- 將 Leader 鍵設為空白鍵
vim.g.maplocalleader = " " -- 將 Local Leader 鍵也設為空白鍵

-- 這份設定使用 vim.lsp.config / vim.lsp.enable / vim.diagnostic.jump，需要 Neovim 0.11+
-- (Homebrew 的 `brew install neovim` 目前是 0.12.x，可以直接用)
if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("這份設定需要 Neovim 0.11 以上，目前版本太舊。請執行: brew install neovim", vim.log.levels.ERROR)
  return
end

-- ==========================================================================
-- 0. macOS 專用設定
-- ==========================================================================
-- macOS 預設 shell 是 zsh，Neovim 會自動使用 $SHELL，
-- 不需要像 Windows 版那樣設定 pwsh / shellcmdflag / shellredir。
-- 這裡只補上 Homebrew 的路徑：從 GUI (Neovide、Finder 開啟) 啟動時 PATH 會很短，
-- 會找不到 git / node / podman / fzf / rg 等工具。從終端機啟動則沒有影響。
if vim.fn.has("mac") == 1 then
  local path = vim.env.PATH or ""
  for _, dir in ipairs({ "/opt/homebrew/bin", "/usr/local/bin" }) do
    if vim.fn.isdirectory(dir) == 1 and not path:find(dir, 1, true) then
      path = dir .. ":" .. path
    end
  end
  vim.env.PATH = path
end
-- ==========================================================================
-- 1. 自動下載 lazy.nvim 插件管理器 (不需要手動安裝任何東西)
-- ==========================================================================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then -- vim.loop 已 deprecated，0.10+ 用 vim.uv
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")
-- ==========================================================================
-- 2. 安裝 fzf-lua 模糊搜尋
-- ==========================================================================
require("lazy").setup({
  {
    "ibhagwan/fzf-lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local fzf = require("fzf-lua")
      fzf.setup({
        winopts = {
          height = 0.85,
          width = 0.80,
          preview = {
            layout = "flex",
          },
        },
      })
      -- 設定快捷鍵 (與之前 Telescope 相同)
      vim.keymap.set('n', '<leader>ff', fzf.files, { desc = '找檔案' })
      vim.keymap.set('n', '<leader>fg', fzf.live_grep, { desc = '找文字' })
      vim.keymap.set('n', '<leader>fb', fzf.buffers, { desc = '找 Buffer' })
      vim.keymap.set('n', '<leader>fh', fzf.helptags, { desc = '找 Help' })
    end
  },
  -- 新增：Treesitter 語法高亮
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate", -- 安裝完後自動更新語法解析器
    config = function()
      require("nvim-treesitter.install").prefer_git = true

      local status, configs = pcall(require, "nvim-treesitter.configs")
      if not status then
        return
      end
      configs.setup({
        ensure_installed = { "lua", "vim", "vimdoc", "javascript", "typescript", "vue", "css", "html", "rust", "c_sharp", "java" },
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        sync_install = false,
        indent = { enable = true },
      })
    end
  },
  -- LSP
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
    },
    config = function()
      -- 1. 初始化 Mason 基礎設施
      require("mason").setup()
      require("mason-lspconfig").setup({
        ensure_installed = { "lua_ls", "ts_ls", 'vue_ls', "tailwindcss" },
      })
      local mason_registry = require("mason-registry")
      local InstallLocation = require("mason-core.installer.InstallLocation")
      local vue_plugin = ""
      local ok, vue_pkg = pcall(mason_registry.get_package, "vue-language-server")
      if ok and vue_pkg:is_installed() then
        vue_plugin = InstallLocation.global():package("vue-language-server") .. "/node_modules/@vue/typescript-plugin"
      else
        vim.notify("vue-language-server is not installed. Run :MasonInstall vue-language-server", vim.log.levels.WARN)
      end
      -- 2. 使用 Neovim 0.11+ 內建 vim.lsp.config 設定各 LSP
      -- Lua 設定
      vim.lsp.config('lua_ls', {
        settings = {
          Lua = {
            diagnostics = { globals = { "vim" } },
          },
        },
      })
      -- TypeScript 設定
      vim.lsp.config('ts_ls', {
        init_options = {
          plugins = {
            {
              name = "@vue/typescript-plugin",
              location = vue_plugin,
              languages = { "javascript", "typescript", "vue" }
            }
          }
        },
        filetypes = { "javascript", "typescript", "vue" },
      })
      -- Vue language server (Hybrid Mode：由 ts_ls 處理 TS、vue_ls 處理 template)
      vim.lsp.config('vue_ls', {
        init_options = {
          vue = {
            hybridMode = true
          }
        },
        on_init = function(client)
          -- 將 vue_ls 對 tsserver 的請求轉發給 ts_ls，避免 "Unexpected resource" 錯誤
          client.handlers['tsserver/request'] = function(_, result, context)
            local clients = vim.lsp.get_clients({ bufnr = context.bufnr, name = 'ts_ls' })
            if #clients == 0 then
              vim.notify('Could not find `ts_ls` lsp client, vue_ls would not work without it.', vim.log.levels.ERROR)
              return
            end
            local ts_client = clients[1]
            local param = unpack(result)
            local id, command, payload = unpack(param)
            ts_client:exec_cmd({
              title = 'vue_request_forward',
              command = 'typescript.tsserverRequest',
              arguments = { command, payload },
            }, { bufnr = context.bufnr }, function(_, r)
              local response_data = { { id, r.body } }
              ---@diagnostic disable-next-line: param-type-mismatch
              client:notify('tsserver/response', response_data)
            end)
          end
        end,
      })
      -- tailwindcss LSP server
      vim.lsp.config('tailwindcss', {
        filetypes = { "html", "vue", "javascript", "typescript", "css" },
      })
      -- C# LSP server (OmniSharp 跑在 podman 容器內：macOS -> podman machine)
      -- 與 Windows 版的差異：
      --   1. 不需要 `wsl` 前綴，直接呼叫 podman
      --   2. macOS 路徑本來就是 POSIX 格式，不需要 D:\ -> /mnt/d 的轉換
      --   3. 容器掛載 $HOME:$HOME，讓容器內的路徑與主機完全相同
      --   4. 所有 podman 指令都用 list 形式呼叫，不經過 shell 解析
      local home = vim.uv.os_homedir()
      local has_podman = vim.fn.executable("podman") == 1
      vim.lsp.config('omnisharp', {
        cmd = function(dispatchers)
          local root = vim.fs.root(0, { "*.sln", "*.csproj", "omnisharp.json" }) or vim.fn.getcwd()

          local container = "omnisharp-persistent"

          local function podman(args)
            local cmd = { "podman" }
            for _, a in ipairs(args) do table.insert(cmd, a) end
            return vim.fn.system(cmd)
          end

          -- 檢查容器是否正在運行
          local running = podman({ "ps", "--format", "{{.Names}}", "--filter", "name=^" .. container .. "$" })
          if not running:find(container, 1, true) then
            -- 檢查容器是否存在但已停止
            local exists = podman({ "ps", "-a", "--format", "{{.Names}}", "--filter", "name=^" .. container .. "$" })
            if exists:find(container, 1, true) then
              podman({ "start", container })
              vim.notify("OmniSharp 容器已重新啟動", vim.log.levels.INFO)
            else
              -- 建立新容器
              podman({
                "run", "-d",
                "--name", container,
                "--network=host",
                "--userns=keep-id",
                "-v", home .. ":" .. home,
                "--entrypoint", "tail",
                "omnisharp-lsp",
                "-f", "/dev/null",
              })
              vim.notify("OmniSharp 容器已建立", vim.log.levels.INFO)
            end
          end

          -- 注意：Neovim 0.10 起 vim.lsp.rpc.start 的第一個參數必須是整個指令的 table
          -- (舊的 rpc.start("cmd", { args }) 寫法會被 validate 擋下：cmd: expected table, got string)
          return vim.lsp.rpc.start(
            {
              "podman", "exec", "-i",
              "-e", "DOTNET_CLI_TELEMETRY_OUTPUT=1",
              "-w", root,
              container,
              "/opt/omnisharp/OmniSharp",
              "--source", root,
              "--stdio"
            },
            dispatchers
          )
        end,
        root_dir = function(bufnr)
          return vim.fs.root(bufnr, { "*.sln", "*.csproj", "omnisharp.json" })
        end,
        filetypes = { "cs" },
        on_attach = function()
          vim.notify("Omnisharp LSP 已連接(macOS -> podman machine)", vim.log.levels.INFO)
        end
      })
      -- Rust LSP server (installed via rustup)
      vim.lsp.config('rust_analyzer', {
        settings = {
          ["rust-analyzer"] = {
            check = {
              command = "clippy", -- 使用 clippy 做檢查（比預設更嚴格）
            },
            diagnostics = {
              enable = true,
            }
          },
        },
      })
      -- 啟用所有已設定的 LSP
      -- omnisharp 只在找得到 podman 時啟用，否則開 .cs 檔時提示一次，不會跳錯誤
      local servers = { 'lua_ls', 'ts_ls', 'vue_ls', 'tailwindcss', 'rust_analyzer' }
      if has_podman then
        table.insert(servers, 'omnisharp')
      else
        vim.api.nvim_create_autocmd("FileType", {
          pattern = "cs",
          once = true,
          callback = function()
            vim.notify("找不到 podman，OmniSharp 不會啟動 (brew install podman && podman machine init)",
              vim.log.levels.WARN)
          end,
        })
      end
      vim.lsp.enable(servers)

      -- 3. [重要] LSP 快捷鍵設定 (使用 0.11+ 推薦的 Autocmd 方式)
      vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(ev)
          local opts = { buffer = ev.buf }
          vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
          vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
          vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
        end,
      })
    end
  },
  -- gitsign
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require('gitsigns').setup({
        -- 1. 開啟行末的 Blame 資訊
        current_line_blame = true,
        current_line_blame_opts = {
          virt_text = true,
          virt_text_pos = 'eol', -- 顯示在行末
          delay = 1000,
          ignore_whitespace = false,
        },
        -- 2. 自定義顯示的文字格式
        -- <author> - <author_time:%Y-%m-%d> - <summary>
        current_line_blame_formatter = '   <author> • <author_time:%Y-%m-%d> • <summary>',

        -- 這裡也可以順便設定常用的快捷鍵
        on_attach = function(bufnr)
          local gs = package.loaded.gitsigns

          local function map(mode, l, r, opts)
            opts = opts or {}
            opts.buffer = bufnr
            vim.keymap.set(mode, l, r, opts)
          end

          -- 設定一個快捷鍵來手動切換開關 (例如 <leader>tb 代表 Toggle Blame)
          map('n', '<leader>tb', gs.toggle_current_line_blame, { desc = 'Toggle Git Blame' })
          -- 預覽該段修改的詳細內容 (Floating Window)
          map('n', '<leader>gp', gs.preview_hunk, { desc = 'Preview Git Hunk' })
          map('n', '<leader>gu', gs.reset_hunk, { desc = 'Undo Git Hunk' })
          map('n', '<leader>gs', gs.stage_hunk, { desc = 'Stage Git Hunk' })
        end
      })
    end
  },
  -- nvim-tree
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("nvim-tree").setup({
        sort_by = "case_sensitive",
        view = {
          width = 30,
          side = "left",
        },
        renderer = {
          group_empty = true,
          icons = {
            show = {
              file = true,
              folder = true,
              git = true,
            }
          }
        },
        filters = {
          dotfiles = false,
        },
        git = {
          enable = true,
          timeout = 2000, -- 預設 400ms，大專案容易超時，改為 2 秒
        },
        filesystem_watchers = {
          enable = true,
          ignore_dirs = { "node_modules", "dist", ".git" },
        },
      })
    end
  },
  -- colorscheme
  {
    "catppuccin/nvim",
    name = "catppuccin",
    config = function()
      require("catppuccin").setup({
        flavour = "mocha",
        -- flavour = "macchiato",
        transparent_background = false,
        term_colors = true,
        styles = {
          comments = { "italic" },
          conditionals = { "italic" },
          keywords = {},
          functions = {},
          variables = {},
        },
        integrations = {
          blink_cmp = true,
          gitsigns = true,
          fzf = true,
          nvimtree = true,
          treesitter = true,
          native_lsp = {
            enabled = true,
          },
          semantic_tokens = true,
        },
        -- custom_highlights 要放在 integrations 外面
        custom_highlights = function(colors)
          return {
            -- VSCode catppuccin: 註解是 overlay0 (灰色斜體)
            Comment = { fg = colors.overlay0, style = { "italic" } },
            -- VSCode: 物件屬性偏 teal
            ["@variable.member"] = { fg = colors.teal },
            ["@property"] = { fg = colors.teal },
            -- VSCode: tag attribute 偏 peach
            ["@tag.attribute"] = { fg = colors.peach, style = { "italic" } },
            -- VSCode: 型別參數 (泛型) 用 yellow
            ["@type.parameter"] = { fg = colors.yellow },
            -- VSCode: 標點括號不要太暗
            ["@punctuation.bracket"] = { fg = colors.subtext0 },
          }
        end,
      })
      vim.cmd.colorscheme "catppuccin"
    end
  },
  -- blink.cmp 自動補全
  {
    "saghen/blink.cmp",
    version = "v1.10.1",
    dependencies = {
      "rafamadriz/friendly-snippets",
    },
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config
    opts = {
      keymap = { preset = "default" },
      appearance = {
        nerd_font_variant = "mono",
      },
      completion = {
        documentation = { auto_show = true },
      },
      sources = {
        default = { "lsp", "path", "snippets", "buffer" },
      },
      fuzzy = { implementation = "prefer_rust_with_warning" },
    },
  },
  -- autopairs
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {
      check_ts = true,
    }
  },
  -- vim-visual-multi (multi-cursor)
  { "mg979/vim-visual-multi" },
  -- comment.nvim
  {
    "numToStr/Comment.nvim",
    dependencies = {
      {
        "JoosepAlviste/nvim-ts-context-commentstring",
        opts = {
          enable_autocmd = false,
        },
      },
    },
    config = function()
      require("Comment").setup({
        padding = true,
        sticky = true,
        pre_hook = function(ctx)
          -- Force treesitter to parse injections so comment style is detected correctly in Vue files
          local parser = vim.treesitter.get_parser(0)
          if parser then
            parser:parse(true)
          end
          return require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook()(ctx)
        end,
        toggler = {
          line = "gcc",
          block = "gbc",
        },
        opleader = {
          line = "gc",
          block = "gb",
        }
      })
    end
  },
  -- conform.nvim (格式化)
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    config = function()
      require("conform").setup({
        formatters_by_ft = {
          javascript = { "prettier" },
          typescript = { "prettier" },
          vue = { "prettier" },
          css = { "prettier" },
          html = { "prettier" },
          json = { "prettier" },
        },
        format_on_save = {
          timeout_ms = 1500,
          lsp_format = "fallback",
        },
      })
    end
  },
  -- harpoon
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
  },
  -- diffview (Git diff 檢視)
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    config = function()
      require("diffview").setup()
      vim.keymap.set("n", "<leader>gd", ":DiffviewOpen<CR>", { desc = "開啟 Git Diff", silent = true })
      vim.keymap.set("n", "<leader>gh", ":DiffviewFileHistory %<CR>", { desc = "目前檔案 Git 歷史", silent = true })
      vim.keymap.set("n", "<leader>gH", ":DiffviewFileHistory<CR>", { desc = "整個專案 Git 歷史", silent = true })
      vim.keymap.set("n", "<leader>gc", ":DiffviewClose<CR>", { desc = "關閉 Diffview", silent = true })
    end
  },
  -- -- augment code
  -- {
  --   "mfussenegger/nvim-jdtls",
  --   ft = { "java" },
  --   config = function()
  --     -- 找 Maven multi-module reactor root: 一路往上找最外層含 pom.xml 的目錄
  --     -- 避免子 module (e.g. workspace_etl_v62/mes/pom.xml) 被誤判為 root,
  --     -- 導致 jdtls 無法解析 parent pom -> "Given URI does not belong to any Java project"
  --     local function find_maven_root(start)
  --       local current = vim.fs.root(start, { 'pom.xml' })
  --       if not current then
  --         return vim.fs.root(start, { 'build.gradle', 'mvnw', 'gradlew', '.git' })
  --             or vim.fn.getcwd()
  --       end
  --       while true do
  --         local parent = vim.fs.dirname(current)
  --         if not parent or parent == current then break end
  --         if vim.uv.fs_stat(parent .. '/pom.xml') then
  --           current = parent
  --         else
  --           break
  --         end
  --       end
  --       return current
  --     end
  --
  --     local warned_no_podman = false
  --
  --     local function start_jdtls()
  --       -- macOS: 沒裝 podman 就不啟動，只提示一次
  --       if vim.fn.executable("podman") == 0 then
  --         if not warned_no_podman then
  --           warned_no_podman = true
  --           vim.notify("找不到 podman，jdtls 不會啟動 (brew install podman && podman machine init)",
  --             vim.log.levels.WARN)
  --         end
  --         return
  --       end
  --
  --       local jdtls = require('jdtls')
  --       local root_dir = find_maven_root(0)
  --       -- macOS 路徑本來就是 POSIX 格式，容器內掛載 $HOME:$HOME，
  --       -- 所以主機路徑 = 容器路徑，不需要像 Windows 版那樣做 D:\ -> /mnt/d 轉換
  --       local home = vim.uv.os_homedir()
  --
  --       -- 每個專案獨立 workspace (jdtls 慣例, 避免index混雜)
  --       local project_name = vim.fn.fnamemodify(root_dir, ":p:h:t")
  --       local workspace_dir = "/home/ubuntu/.cache/jdtls/workspace/" .. project_name
  --
  --       local container = "jdtls-persistent"
  --
  --       -- 用 list 形式呼叫，不經過 shell 解析，參數不會被破壞
  --       local function podman(args)
  --         local cmd = { "podman" }
  --         for _, a in ipairs(args) do table.insert(cmd, a) end
  --         local out = vim.fn.system(cmd)
  --         return out, vim.v.shell_error
  --       end
  --
  --       -- exit 0 = 存在, exit 1 = 不存在
  --       local _, exists_err = podman({ "container", "exists", container })
  --       if exists_err == 0 then
  --         -- 已存在 → 直接 start (若已 running 也是 no-op 回 0)
  --         local out, err = podman({ "start", container })
  --         if err ~= 0 then
  --           vim.notify("jdtls 容器啟動失敗:\n" .. out, vim.log.levels.ERROR)
  --         end
  --       else
  --         local out, err = podman({
  --           "run", "-d",
  --           "--name", container,
  --           "--network=host",
  --           "--userns=keep-id",
  --           "-v", home .. ":" .. home,
  --           "--entrypoint", "tail",
  --           "jdtls-lsp",
  --           "-f", "/dev/null",
  --         })
  --         if err ~= 0 then
  --           vim.notify("jdtls 容器建立失敗:\n" .. out, vim.log.levels.ERROR)
  --         else
  --           vim.notify("jdtls 容器已建立", vim.log.levels.INFO)
  --         end
  --       end
  --
  --       local config = {
  --         cmd = {
  --           "podman", "exec", "-i",
  --           "-w", root_dir, container,
  --           "/opt/jdtls/bin/jdtls",
  --           "-data", workspace_dir,
  --         },
  --         root_dir = root_dir,
  --         settings = {
  --           java = {
  --             configuration = {
  --               runtimes = {
  --                 {
  --                   name = "JavaSE-1.8",
  --                   path = "/opt/java/openjdk-8",
  --                   default = true,
  --                 },
  --               },
  --             },
  --             signatureHelp = { enabled = true },
  --             completion = {
  --               favoriteStaticMembers = {
  --                 "org.junit.Assert.*",
  --                 "org.junit.Assume.*",
  --                 "org.junit.jupiter.api.Assertions.*",
  --                 "org.mockito.Mockito.*",
  --               },
  --             },
  --             sources = {
  --               organizeImports = {
  --                 starThreshold = 9999,
  --                 staticStarThreshold = 9999,
  --               },
  --             },
  --           },
  --         },
  --         init_options = {
  --           bundles = {},
  --         },
  --         on_attach = function(_, bufnr)
  --           vim.notify("jdtls 已連接 (macOS -> podman machine)", vim.log.levels.INFO)
  --           local function bmap(mode, lhs, rhs, desc)
  --             vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  --           end
  --           bmap('n', '<leader>jo', jdtls.organize_imports, 'Java: organize imports')
  --           bmap('n', '<leader>jv', jdtls.extract_variable, 'Java: extract variable')
  --           bmap('n', '<leader>jc', jdtls.extract_constant, 'Java: extract constant')
  --           bmap('v', '<leader>jm', function() jdtls.extract_method(true) end, 'Java: extract method')
  --         end,
  --       }
  --       jdtls.start_or_attach(config)
  --     end
  --     -- 觸發此 config 載入的buffer
  --     if vim.bo.filetype == "java" then
  --       start_jdtls()
  --     end
  --
  --     -- 之後新開的java自動啟動
  --     vim.api.nvim_create_autocmd("FileType", {
  --       pattern = "java",
  --       callback = start_jdtls
  --     })
  --   end
  -- },
  {
    'MeanderingProgrammer/render-markdown.nvim',
    opts = {}
  }
})

-- ==========================================================================
-- 3. 基本設定
-- ==========================================================================
-- Diagnostic: 在行尾顯示錯誤訊息
vim.diagnostic.config({
  virtual_text = true,      -- 行尾顯示錯誤/警告訊息
  signs = true,             -- 左側符號欄顯示圖示
  underline = true,         -- 底線標記有問題的程式碼
  update_in_insert = false, -- 插入模式下不即時更新（避免干擾）
})

-- Diagnostic 跳轉快捷鍵
-- goto_next / goto_prev 在 0.11 起 deprecated (0.13 移除，0.12 會跳警告)，改用 vim.diagnostic.jump()
-- 跳過去後開浮動視窗顯示訊息（跟 goto_next 的預設行為一樣）：
--   0.12+ 用 on_jump；0.11 用 float = true（這個參數 0.12 起 deprecated）
local function diag_jump(count, severity)
  local opts = { count = count, severity = severity }
  if vim.fn.has("nvim-0.12") == 1 then
    opts.on_jump = function(_, bufnr)
      vim.diagnostic.open_float({ bufnr = bufnr, scope = "cursor", focus = false })
    end
  else
    opts.float = true
  end
  vim.diagnostic.jump(opts)
end
vim.keymap.set("n", "]d", function() diag_jump(1) end, { desc = "下一個 Diagnostic" })
vim.keymap.set("n", "[d", function() diag_jump(-1) end, { desc = "上一個 Diagnostic" })
vim.keymap.set("n", "]e", function() diag_jump(1, vim.diagnostic.severity.ERROR) end, { desc = "下一個 Error" })
vim.keymap.set("n", "[e", function() diag_jump(-1, vim.diagnostic.severity.ERROR) end, { desc = "上一個 Error" })
vim.keymap.set("n", "<leader>dl", vim.diagnostic.setloclist, { desc = "Diagnostic 列表" })

vim.opt.number = true                             -- 顯示行號
vim.opt.relativenumber = true                     -- 顯示相對行號 (對工程師跳行很有幫助)
vim.opt.termguicolors = true                      -- 開啟真彩色支持
vim.opt.cursorline = true                         -- 顯示光標列
vim.opt.wrap = true                               -- 開啟文字折行
vim.opt.scrolloff = 10                            -- 保持光標附近有 10 行的視野
vim.opt.sidescrolloff = 10                        -- 保持光標附近有 10 行的視野
vim.opt.tabstop = 2                               -- 2 個空格為一 Tab
vim.opt.shiftwidth = 2                            -- 2 個空格為一 Tab
vim.opt.softtabstop = 2                           -- 2 個空格為一 Tab
vim.opt.expandtab = true                          -- 將 Tab 轉換為空格
vim.opt.smartindent = true                        -- 智能縮排
vim.opt.autoindent = true                         -- 自動縮排
vim.opt.ignorecase = true                         -- 搜尋時忽略大小寫
vim.opt.smartcase = true                          -- 如果搜尋字串包含大寫，則區分大小寫
vim.opt.incsearch = true                          -- 顯示即時搜尋結果
vim.opt.hlsearch = true                           -- 高亮搜尋結果
vim.opt.signcolumn = "yes"                        -- 顯示符號欄 (例如 Git 標記)
vim.opt.colorcolumn = "100"                       -- 在第 100 列顯示垂直線
vim.opt.showmatch = true                          -- 顯示匹配的括號
vim.opt.cmdheight = 1                             -- 增加命令列高度
vim.opt.completeopt = "menuone,noinsert,noselect" -- 自動完成選項
vim.opt.showmode = false                          -- 關閉模式提示 (因為在狀態列顯示)
vim.opt.pumheight = 10                            -- 自動完成選項高度
vim.opt.pumblend = 10                             -- 自動完成選項背景模糊度
vim.opt.winblend = 0                              -- 視窗背景模糊度
vim.opt.conceallevel = 0                          -- 顯示隱藏文字
vim.opt.concealcursor = ""
vim.opt.lazyredraw = true                         -- 開啟延遲重繪 (提高性能)
vim.opt.synmaxcol = 300                           -- 限制語法高亮的最大列數
vim.opt.fillchars = { eob = " " }                 -- 隱藏行尾符號

--- Undo directory setup
local undodir = vim.fn.stdpath("data") .. "/undo"
if vim.fn.isdirectory(undodir) == 0 then
  vim.fn.mkdir(undodir, "p")
end
vim.opt.undodir = undodir

vim.opt.backup = false                  -- 關閉備份檔案
vim.opt.swapfile = false                -- 關閉交換檔案
vim.opt.undofile = true                 -- 開啟 undo 檔案
vim.opt.updatetime = 300                -- 更新時間 (毫秒)
vim.opt.timeoutlen = 500                -- 鍵映射超時時間 (毫秒)
vim.opt.ttimeoutlen = 0                 -- 鍵映射超時時間 (毫秒)
vim.opt.autoread = true                 -- 自動讀取檔案變更
vim.opt.autowrite = false               -- 關閉自動寫入檔案
vim.opt.hidden = true                   -- 開啟背景視窗
vim.opt.errorbells = false              -- 關閉錯誤提示音
vim.opt.backspace = "indent,eol,start"  -- 開啟退格刪除
vim.opt.autochdir = false               -- 關閉自動切換工作目錄
vim.opt.iskeyword:append("-")           -- 將連字符視為單詞的一部分
vim.opt.path:append("**")               -- 包含子目錄在檔案搜尋中
vim.opt.selection = "inclusive"         -- 選擇範圍包含結束位置
vim.opt.mouse = "a"                     -- 開啟滑鼠支援
vim.opt.clipboard:append("unnamedplus") -- 使用系統剪貼簿 (macOS 自動使用 pbcopy / pbpaste)
vim.opt.modifiable = true               -- 開啟檔案修改
vim.opt.encoding = "utf-8"              -- 開啟 UTF-8 編碼
vim.opt.guicursor =
"n-v-c:block,i-ci-ve:block,r-cr:hor20,o:hor50,a:blinkwait700-blinkoff400-blinkon250-Cursor/lCursor,sm:block-blinkwait175-blinkoff150-blinkon175"

vim.opt.foldmethod = "expr" -- 使用 Treesitter 進行折疊
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.opt.foldlevel = 99      -- 預設折疊層級
vim.opt.foldlevelstart = 99 -- 開啟檔案時預設展開所有折疊

-- 在 {} () [] 上按 zf% 折疊配對區塊（切換為 manual 模式）
vim.keymap.set("n", "zf%", function()
  vim.wo.foldmethod = "manual"
  vim.cmd("normal! zf%")
end, { desc = "折疊配對的括號區塊" })

-- 按 zE 恢復 Treesitter 折疊
vim.keymap.set("n", "z<CR>", function()
  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
end, { desc = "恢復 Treesitter 折疊" })

vim.opt.splitbelow = true              -- 新視窗在下方
vim.opt.splitright = true              -- 新視窗在右方
vim.opt.wildmenu = true                -- 開啟命令列選項卡
vim.opt.wildmode = "longest:full,full" -- 開啟命令列選項卡
vim.opt.diffopt:append("linematch:60") -- 顯示更多差異
vim.opt.redrawtime = 10000             -- 開啟重新繪製時間
vim.opt.maxmempattern = 20000          -- 開啟最大模式

-- Alt-j/k 行移動
-- macOS 注意：Option 鍵預設不會當成 Alt/Meta 送出，需要在終端機設定：
--   iTerm2      : Profiles > Keys > Left Option key = Esc+
--   Terminal.app: 描述檔 > 鍵盤 > 勾選「將 Option 鍵作為 Meta 鍵」
--   Kitty       : macos_option_as_alt yes
--   Ghostty     : macos-option-as-alt = true
--   WezTerm     : send_composed_key_when_left_alt_is_pressed = false
-- 沒設定的話 Option+j / Option+k 會送出 ∆ / ˚ 這兩個字元，下面同時綁定作為備援
vim.keymap.set("n", "<A-j>", ":m .+1<CR>==")
vim.keymap.set("n", "<A-k>", ":m .-2<CR>==")
vim.keymap.set("v", "<A-j>", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "<A-k>", ":m '<-2<CR>gv=gv")
vim.keymap.set("n", "∆", ":m .+1<CR>==")
vim.keymap.set("n", "˚", ":m .-2<CR>==")
vim.keymap.set("v", "∆", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "˚", ":m '<-2<CR>gv=gv")

-- J 連接下一行，但保持光標位置不動
vim.keymap.set("n", "J", "mzJ`z")

-- 複製檔案路徑到剪貼簿
vim.keymap.set("n", "<leader>pa", function()
  local path = vim.fn.expand("%:p")
  vim.fn.setreg("+", path)
  print("file:", path)
end)

-- 視窗切換與NvimTree
vim.keymap.set("n", "<C-h>", "<C-w>h")
vim.keymap.set("n", "<C-j>", "<C-w>j")
vim.keymap.set("n", "<C-k>", "<C-w>k")
vim.keymap.set("n", "<C-l>", "<C-w>l")
vim.keymap.set("n", "<leader>|", ":vsplit<CR>", { desc = "垂直分割視窗", silent = true })
vim.keymap.set("n", "<leader>-", ":split<CR>", { desc = "水平分割視窗", silent = true })
vim.keymap.set("n", "<leader>q", ":close<CR>", { desc = "關閉當前分割視窗", silent = true })
vim.keymap.set("n", "<leader>=", "<C-w>=", { desc = "均分視窗大小", silent = true })

-- 調整視窗寬度
-- macOS 注意：Ctrl+Left / Ctrl+Right 預設被 Mission Control「移至左/右側的空間」攔截，
-- 需到 系統設定 > 鍵盤 > 鍵盤快速鍵 > Mission Control 取消那兩個快速鍵，終端機才收得到
local function adjust_width(delta)
  vim.cmd("vertical resize " .. (delta > 0 and "+" or "") .. delta)
end
vim.keymap.set("n", "<C-Left>", function() adjust_width(-5) end, { desc = "縮小視窗寬度", silent = true })
vim.keymap.set("n", "<C-Right>", function() adjust_width(5) end, { desc = "放大視窗寬度", silent = true })

vim.keymap.set("n", "<leader>e", ":NvimTreeToggle<CR>", { desc = "Toggle NvimTree", noremap = true, silent = true })
vim.keymap.set("n", "<leader>ef", ":NvimTreeFindFile<CR>", { desc = "Find current file in NvimTree" })

-- View mode 縮排
vim.keymap.set("v", "<", "<gv", { desc = "Indent left" })
vim.keymap.set("v", ">", ">gv", { desc = "Indent right" })
vim.keymap.set("n", "<leader>i", "mmgg=G`m", { desc = "Reindent file" })

-- Floating terminal
local term_state = { buf = -1, win = -1 }
local function toggle_terminal()
  if vim.api.nvim_win_is_valid(term_state.win) then
    vim.api.nvim_win_hide(term_state.win)
  else
    if not vim.api.nvim_buf_is_valid(term_state.buf) then
      term_state.buf = vim.api.nvim_create_buf(false, true)
    end
    term_state.win = vim.api.nvim_open_win(term_state.buf, true, {
      relative = "editor",
      width = math.floor(vim.o.columns * 0.8),
      height = math.floor(vim.o.lines * 0.8),
      col = math.floor(vim.o.columns * 0.1),
      row = math.floor(vim.o.lines * 0.1),
      border = "rounded"
    })
    if vim.bo[term_state.buf].buftype ~= "terminal" then
      -- macOS: 使用 $SHELL (預設 /bin/zsh)；Windows 版是 pwsh
      -- termopen() 在 0.11 起 deprecated，改用 jobstart() + term = true
      vim.fn.jobstart({ vim.o.shell }, { term = true })
    end
  end
end

vim.keymap.set({ "n", "t" }, "<leader>tt", toggle_terminal, { desc = "Toggle terminal" })

-- ==========================================================================
-- 4. harpoon 設定
-- ==========================================================================
local harpoon = require("harpoon")
harpoon:setup()

vim.keymap.set("n", "<leader>a", function() harpoon:list():add() end, { desc = "Harpoon add file" })
vim.keymap.set("n", "<C-e>", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = "Harpoon menu" })

vim.keymap.set("n", "<leader>h1", function() harpoon:list():select(1) end, { desc = "Harpoon file 1" })
vim.keymap.set("n", "<leader>h2", function() harpoon:list():select(2) end, { desc = "Harpoon file 2" })
vim.keymap.set("n", "<leader>h3", function() harpoon:list():select(3) end, { desc = "Harpoon file 3" })
vim.keymap.set("n", "<leader>h4", function() harpoon:list():select(4) end, { desc = "Harpoon file 4" })

vim.keymap.set("n", "<leader>hp", function() harpoon:list():prev() end, { desc = "Harpoon prev" })
vim.keymap.set("n", "<leader>hn", function() harpoon:list():next() end, { desc = "Harpoon next" })

-- ==========================================================================
-- 5. new setting
-- ==========================================================================
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

vim.keymap.set("x", "<leader>p", [["_dP]])
vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]])

vim.keymap.set("i", "<C-c>", "<Esc>")
vim.keymap.set("n", "Q", "<nop>")

vim.keymap.set("n", "*", "*zzzv")
vim.keymap.set("n", "#", "#zzzv")
