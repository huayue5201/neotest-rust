# neotest-rust

[Neotest](https://github.com/rcarriga/neotest) 的 Rust 适配器,基于
[cargo-nextest](https://nexte.st/)。

> **维护分支。** 上游
> [rouge8/neotest-rust](https://github.com/rouge8/neotest-rust) 已停止维护。本分支
> ([huayue5201/neotest-rust](https://github.com/huayue5201/neotest-rust))
> 在其基础上修复问题以保持可用,对外配置保持兼容。改动见
> [本分支的改动](#本分支的改动)。

需要 [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
以及 Rust 语言解析器。

```lua
require("neotest").setup({
  adapters = {
    require("neotest-rust")
  }
})
```

如果想给 `cargo nextest` 传递额外参数,可以在初始化适配器时指定 `args`:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-rust") {
        args = { "--no-capture" },
    }
  }
})
```

支持标准库测试、[`rstest`](https://github.com/la10736/rstest)、Tokio 的
`[#tokio::test]` 等。不支持 `rstest` 的参数化测试。

## 调试测试

默认使用 codelldb 作为调试适配器。
可以通过初始化时的 `dap_adapter` 属性指定其他适配器。

```lua
require("neotest").setup({
  adapters = {
    require("neotest-rust") {
        args = { "--no-capture" },
        dap_adapter = "lldb",
    }
  }
})
```

参见 [nvim-dap](https://github.com/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation),
以及(如果你使用 rust-tools.nvim)
[rust-tools#debugging](https://github.com/simrat39/rust-tools.nvim/wiki/Debugging)
获取更多信息。

## 环境变量(本 fork 新增)

通过 `env` 选项为测试进程注入环境变量:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-rust") {
        args = { "--no-capture" },
        env = {
          RUST_LOG = "debug",
          RUST_BACKTRACE = "1",
        },
    }
  }
})
```

环境变量只会通过 `spec.env` 传入测试进程,不会拼进命令字符串。

## 本分支的改动

- 移除了 `plenary.nvim` 依赖。
- 新增 `env` 选项(见上),修复 `dap_adapter` 处理。
- panic/错误解析更宽容:兼容新旧 libtest panic 格式与 CRLF 换行。
- 修复 nextest 过滤表达式引号问题:`-E` 表达式与 filterset 现在作为
  独立参数传入,引号不再被当成 filterset 内容。

## 限制

以下限制同时适用于运行测试和调试测试。

- 假定 `main.rs`、`mod.rs` 和 `lib.rs` 中的单元测试位于 `tests` 模块内。
- 不支持 `rstest` 的 `#[case]` 宏。
- 当为集成测试子目录(如 `tests/testsuite/main.rs`)中的 `main.rs` 运行测试时,
  该子目录下的所有测试都会被运行(如 `tests/testsuite/` 下的所有测试)。
  这是因为 Cargo 无法指定单个测试文件。

此外,调试测试时,失败测试的输出不会被捕获到提供给 Neotest 的结果中。
