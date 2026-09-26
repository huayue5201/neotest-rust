local lib = require("neotest.lib")
local sep = require("plenary.path").path.sep
local util = require("neotest-rust.util")

local M = {}

local has_quantified_captures = vim.fn.has("nvim-0.11.0") == 1

--
--{
--  "target": {
--    "src_path": "/home/mark/workspace/Lua/neotest-rust/tests/data/src/lib.rs",
--  },
--  "executable": "/home/mark/workspace/Lua/neotest-rust/tests/data/target/debug/deps/data-<>",
--}
--
-- Return a table containing each 'src_path' => 'executable' listed by
-- 'cargo test --message-format=JSON' (see sample output above).
local function get_src_paths(root)
    local src_paths = {}

    local manifest_path = root .. sep .. "Cargo.toml"
    if not util.file_exists(manifest_path) then
        vim.notify("Cargo.toml not found at: " .. manifest_path, vim.log.levels.WARN)
        return src_paths
    end

    local cmd = {
        "cargo",
        "test",
        "--manifest-path=" .. manifest_path,
        "--message-format=json",
        "--no-run",
        "--quiet",
    }

    local handle = io.popen(table.concat(cmd, " ") .. " 2>&1")
    if not handle then
        vim.notify("Failed to run cargo test command", vim.log.levels.ERROR)
        return src_paths
    end

    -- 获取 JSON 解码函数
    local json_decode = nil
    if vim.json and vim.json.decode then
        json_decode = vim.json.decode
    elseif vim.fn and vim.fn.json_decode then
        json_decode = vim.fn.json_decode
    else
        vim.notify("No JSON decoder available", vim.log.levels.ERROR)
        handle:close()
        return src_paths
    end

    for line in handle:lines() do
        if line and line ~= "" and line:sub(1, 1) == "{" then
            local ok, data = pcall(json_decode, line)
            if ok and type(data) == "table" then
                if data.reason == "compiler-artifact" then
                    local src_path = data.target and data.target.src_path
                    local executable = data.executable

                    if src_path and executable then
                        local exec_type = type(executable)
                        if exec_type == "string" and executable:find("deps", 1, true) then
                            src_paths[src_path] = executable
                        end
                    end
                end
            end
        end
    end

    handle:close()
    return src_paths
end

local function collect(query, source, root)
    local mods = {}

    for _, match in query:iter_matches(root, source) do
        local captured_nodes = {}
        for i, capture in ipairs(query.captures) do
            captured_nodes[capture] = match[i]
        end

        if captured_nodes["mod_name"] then
            local node = captured_nodes["mod_name"]
            if has_quantified_captures then
                node = node[#node]
            end
            local mod_name = vim.treesitter.get_node_text(node, source)
            table.insert(mods, mod_name)
        end
    end

    return mods
end

-- Get the list of <mod_name>s imported via '(pub) mod <mod_name>;'
local function get_mods(path)
    -- 添加路径有效性检查
    if not path or path == "" then
        return {}
    end

    -- 检查文件是否存在
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        return {}
    end

    local content = lib.files.read(path)
    local query = [[
(mod_item
	name: (identifier) @mod_name
	.
)
    ]]

    local root, lang = lib.treesitter.get_parse_root(path, content, {})
    local parsed_query = lib.treesitter.normalise_query(lang, query)

    return collect(parsed_query, content, root)
end

-- Determine if mod is in <mod_name>.rs or <mod_name>/mod.rs
local function construct_mod_path(src_path, mod_name)
    local match_str = "(.-)[^\\/]-%.?([%w_]+)%.?[^\\/]*$"
    local abs_path, parent_mod = string.match(src_path, match_str)

    -- 添加 abs_path 检查
    if not abs_path then
        return nil
    end

    local mod_file = abs_path .. mod_name .. ".rs"
    local mod_dir = abs_path .. mod_name .. sep .. "mod.rs"
    local child_mod = abs_path .. parent_mod .. sep .. mod_name .. ".rs"

    if util.file_exists(mod_file) then
        return mod_file
    elseif util.file_exists(mod_dir) then
        return mod_dir
    elseif child_mod and util.file_exists(child_mod) then
        return child_mod
    end

    return nil
end

-- Recursive search for 'path' amongst all modules declared in 'src_path'
local function search_modules(src_path, path)
    -- 添加路径检查
    if not src_path or not path then
        return false
    end

    local mods = get_mods(src_path)

    for _, mod in ipairs(mods) do
        local mod_path = construct_mod_path(src_path, mod)
        if mod_path and path == mod_path then
            return true
        elseif mod_path and search_modules(mod_path, path) then
            return true
        end
    end

    return false
end

-- 辅助函数：检查路径是否在 workspace 的 member 中，并返回正确的 root
local function get_correct_root(root, path)
    -- 如果 path 在 root 的子目录中，检查是否需要使用 member 的根目录
    local cargo_toml = vim.fs.find("Cargo.toml", { path = path, upward = true, limit = 1 })[1]
    if cargo_toml then
        local member_root = vim.fs.dirname(cargo_toml)
        -- 如果找到了 member 的 Cargo.toml，并且不是原来的 root，使用 member 的根目录
        if member_root ~= root then
            return member_root
        end
    end
    return root
end

-- Debugging is only possible from the generated test binary
-- See: https://github.com/rust-lang/cargo/issues/1924#issuecomment-289764090
-- Identify the binary containing the tests defined in 'path'
M.get_test_binary = function(root, path)
    -- 添加参数检查
    if not root or not path then
        vim.notify("get_test_binary: root or path is nil", vim.log.levels.ERROR)
        return nil
    end

    -- 尝试获取正确的 root（处理 workspace 场景）
    local correct_root = get_correct_root(root, path)

    -- 获取所有 src_path 到 executable 的映射
    local src_paths = get_src_paths(correct_root)

    -- 如果 src_paths 为空，可能是 cargo test 失败了
    if vim.tbl_isempty(src_paths) then
        vim.notify("No test binaries found. Try running 'cargo test --no-run' manually.", vim.log.levels.WARN)
        return nil
    end

    -- 保存 lib.rs 和 main.rs 的二进制作为 fallback
    local lib_binary = nil
    local main_binary = nil

    -- If 'path' is the source of the binary we are done
    for src_path, executable in pairs(src_paths) do
        -- 记录 lib.rs 和 main.rs 的二进制
        if src_path:match("lib%.rs$") then
            lib_binary = executable
        elseif src_path:match("main%.rs$") then
            main_binary = executable
        end

        if path == src_path then
            return executable
        end
    end

    -- 尝试路径包含匹配
    for src_path, executable in pairs(src_paths) do
        if path:find(src_path, 1, true) or src_path:find(path, 1, true) then
            return executable
        end
    end

    -- Otherwise we need to figure out which 'src_path' it is loaded from
    for src_path, executable in pairs(src_paths) do
        local mod_match = search_modules(src_path, path)
        if mod_match then
            return executable
        end
    end

    -- 关键修复：如果找不到精确匹配，使用 lib.rs 的二进制（大多数测试在里面）
    if lib_binary then
        vim.notify("Using lib.rs binary as fallback for module: " .. path, vim.log.levels.INFO)
        return lib_binary
    end

    -- 其次尝试 main.rs
    if main_binary then
        vim.notify("Using main.rs binary as fallback for module: " .. path, vim.log.levels.INFO)
        return main_binary
    end

    -- 如果还是找不到，尝试使用原始 root 再试一次
    if correct_root ~= root then
        return M.get_test_binary(root, path)
    end

    return nil
end

-- Translate plain test output to a neotest results object
M.translate_results = function(output_path)
    -- 添加输出路径检查
    if not output_path or output_path == "" then
        return {}
    end

    local result_map = {
        ok = "passed",
        FAILED = "failed",
        ignored = "skipped",
    }

    local results = {}

    local handle = io.open(output_path)
    if not handle then
        vim.notify("Failed to open output file: " .. output_path, vim.log.levels.ERROR)
        return results
    end

    local line = handle:read("l")

    while line do
        if string.find(line, "^test result:") then
            --
        elseif string.find(line, "^test .+ %.%.%. %w+") then
            local test_name, cargo_result = string.match(line, "^test (.+) %.%.%. (%w+)")
            if test_name and cargo_result then
                results[test_name] = { status = assert(result_map[cargo_result]) }
            end
        end

        line = handle:read("l")
    end

    handle:close()
    return results
end

return M
