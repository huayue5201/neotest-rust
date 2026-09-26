local async = require("neotest.async")
local dap = require("neotest-rust.dap")
local util = require("neotest-rust.util")
local errors = require("neotest-rust.errors")
local open = vim.io.open
local lib = require("neotest.lib")
local xml = require("neotest.lib.xml")

local adapter = { name = "neotest-rust" }

-- 统一配置：单一数据源
local config = {
    args = {},
    env = {},
    dap_adapter = "codelldb",
}

local get_args = function()
    return config.args
end

local get_dap_adapter = function()
    return config.dap_adapter
end

local get_env = function()
    return config.env
end

-- 读取文件全部内容（同步）
local function read_file(path)
    local fd = open(path, "r")
    if not fd then
        return nil
    end
    local ok, data = pcall(function()
        return fd:read("*a")
    end)
    fd:close()
    if not ok then
        return nil
    end
    return data
end

-- 写文件（追加/覆盖），保证 close
local function write_file(path, content, mode)
    local fd = open(path, mode or "w")
    if not fd then
        return false
    end
    local ok = pcall(function()
        fd:write(content)
    end)
    fd:close()
    return ok
end

-- 执行外部命令，返回 stdout（成功时）
local function run_capture(cmd, cwd, timeout)
    local ok, result = pcall(function()
        return vim.system(cmd, { cwd = cwd, text = true }, nil):wait(timeout or 30000)
    end)
    if not ok or not result then
        return nil
    end
    if result.code ~= 0 then
        return nil
    end
    local out = result.stdout or ""
    out = out:gsub("%s+$", "")
    if out == "" then
        return nil
    end
    return out
end

-- 相对路径：把 path 相对 base 显示，统一使用 "/"
local function make_relative(path, base)
    path = vim.fs.normalize(path)
    base = vim.fs.normalize(base)
    local rel = vim.fs.relpath(base, path)
    if not rel then
        return path
    end
    return rel
end

local cargo_metadata = setmetatable({}, {
    __call = function(self, cwd)
        local cached = self[cwd]
        if cached ~= nil then
            -- 校验 Cargo.toml mtime，变化则失效
            local manifest = vim.fs.joinpath(cwd, "Cargo.toml")
            local mtime = vim.fn.getftime(manifest)
            if cached.mtime == mtime then
                return cached.data
            end
        end

        local output = run_capture({ "cargo", "metadata", "--no-deps" }, cwd, 30000)

        local metadata
        if output then
            local ok, decoded = pcall(vim.json.decode, output)
            if ok and decoded then
                metadata = decoded
            end
        end

        if not metadata then
            metadata = {
                packages = {},
                workspace_root = cwd,
                target_directory = vim.fs.joinpath(cwd, "target"),
            }
        end

        local manifest = vim.fs.joinpath(cwd, "Cargo.toml")
        self[cwd] = {
            data = metadata,
            mtime = vim.fn.getftime(manifest),
        }
        return metadata
    end,
})

---Find the project root directory given a current directory to work from.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
function adapter.root(dir)
    local cwd = lib.files.match_root_pattern("Cargo.toml")(dir)

    if cwd == nil then
        return vim.fs.root(0, "Cargo.toml")
    end

    return cargo_metadata(cwd).workspace_root
end

local package_name_by_root = function(package_root)
    local manifest_path = vim.fs.joinpath(package_root, "Cargo.toml")
    local metadata = cargo_metadata(package_root)

    local matched = vim.tbl_filter(function(p)
        return vim.fs.normalize(p.manifest_path) == vim.fs.normalize(manifest_path)
    end, metadata.packages)

    if not matched[1] then
        return nil
    end
    return matched[1].name
end

local is_callable = function(obj)
    return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

---@async
---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
    if not vim.endswith(file_path, ".rs") then
        return false
    end
    local ok, tree = pcall(adapter.discover_positions, file_path)
    if not ok or not tree then
        return false
    end
    local nodes = tree:to_list()
    -- 忽略可能的根节点：只要有非根的实际测试节点即视为测试文件
    if #nodes <= 1 then
        -- 只有一个节点时，检查它自身是否带 type == "test"
        local only = nodes[1]
        return only ~= nil and only.type == "test"
    end
    return true
end

---Filter directories when searching for test files
---@async
function adapter.filter_dir(name, rel_path, root)
    local target = cargo_metadata(root).target_directory
    local abs = vim.fs.normalize(vim.fs.joinpath(root, rel_path))
    return abs ~= vim.fs.normalize(target)
end

local get_package_root = lib.files.match_root_pattern("Cargo.toml")

local function is_unit_test(path)
    local root = get_package_root(path)
    return vim.startswith(path, vim.fs.joinpath(root, "src") .. "/")
end

local function is_integration_test(path)
    local root = get_package_root(path)
    return vim.startswith(path, vim.fs.joinpath(root, "tests") .. "/")
end

local function is_alternate_binary(path)
    local root = get_package_root(path)
    return vim.startswith(path, vim.fs.joinpath(root, "src", "bin") .. "/")
end

local function path_to_test_path(path)
    local root = get_package_root(path)
    for _, filename in ipairs({ "main", "lib", "mod" }) do
        path = path:gsub(filename .. ".rs$", "")
    end

    path = path:gsub(".rs$", "")

    if is_unit_test(path) then
        if is_alternate_binary(path) then
            return nil
        end
        path = make_relative(path, vim.fs.joinpath(root, "src"))
    else
        path = make_relative(path, vim.fs.joinpath(root, "tests"))
        if path:find("/") then
            path = path:gsub("^.+/", "")
        else
            return nil
        end
    end

    path = path:gsub("/", "::")

    if path == "." then
        return nil
    else
        return path
    end
end

local function integration_test_name(path)
    local package_root = get_package_root(path)
    path = make_relative(path, vim.fs.joinpath(package_root, "tests"))
    path = path:gsub(".rs$", "")
    return vim.split(path, "/")[1]
end

local function binary_name(path)
    local package_root = get_package_root(path)
    path = make_relative(path, vim.fs.joinpath(package_root, "src", "bin"))
    path = path:gsub(".rs$", "")
    return vim.split(path, "/")[1]
end

local function tbl_flatten(tbl)
    return vim.fn.has("nvim-0.11") == 1 and vim.iter(tbl):flatten(math.huge):totable() or vim.tbl_flatten(tbl)
end

---Given a file path, parse all the tests within it.
---@async
---@param path string Absolute file path
---@return neotest.Tree | nil
function adapter.discover_positions(path)
    local query = [[;; query
    (
        (attribute_item
            [
                (attribute
                    (identifier) @macro_name
                    )
                (attribute
                    [
                        (identifier) @macro_name
                        (scoped_identifier
                            name: (identifier) @macro_name
                            )
                    ]
                    )
            ]
            )
        [
            (attribute_item
                (attribute
                    (identifier)
                    )
                )
            (line_comment)
        ]*
        .
        (function_item
            name: (identifier) @test.name
            ) @test.definition
        (#any-of? @macro_name "test" "rstest" "case")

        )
    (mod_item name: (identifier) @namespace.name)? @namespace.definition
    ]]

    return lib.treesitter.parse_positions(path, query, {
        require_namespaces = false,
        position_id = function(position, namespaces)
            return table.concat(
                tbl_flatten({
                    path_to_test_path(path),
                    vim.tbl_map(function(pos)
                        return pos.name
                    end, namespaces),
                    position.name,
                }),
                "::"
            )
        end,
    })
end

---@param args neotest.RunArgs
---@return nil | neotest.RunSpec | neotest.RunSpec[]
function adapter.build_spec(args)
    local tmp_nextest_config = async.fn.tempname() .. ".nextest.toml"
    local junit_path = async.fn.tempname() .. ".junit.xml"
    local position = args.tree:data()
    local cwd = adapter.root(position.path)

    -- 修复：正确的路径拼接
    local nextest_config = vim.fs.joinpath(cwd, ".config", "nextest.toml")
    if vim.uv.fs_stat(nextest_config) then
        local data = read_file(nextest_config)
        if data then
            write_file(tmp_nextest_config, data, "w")
        end
    end

    write_file(tmp_nextest_config, "\n[profile.neotest.junit]\npath = '" .. junit_path .. "'", "a")

    local command = tbl_flatten({
        "cargo",
        "nextest",
        "run",
        "--workspace",
        "--no-fail-fast",
        "--config-file",
        tmp_nextest_config,
        "--profile",
        "neotest",
        vim.list_extend(vim.deepcopy(get_args()), args.extra_args or {}),
    })

    if is_integration_test(position.path) then
        vim.list_extend(command, { "--test", integration_test_name(position.path) })
    end

    if is_alternate_binary(position.path) then
        vim.list_extend(command, { "--bin", binary_name(position.path) })
    end

    local workspace_root = adapter.root(position.path) .. "/"
    local package_root = lib.files.match_root_pattern("Cargo.toml")(position.path)
    local belongs_to_workspace = (package_root:sub(1, #workspace_root) == workspace_root)
    local package_name = belongs_to_workspace and package_name_by_root(package_root .. "/")

    local package_filter = ""
    if package_name then
        package_filter = "package(" .. package_name .. ") & "
    end

    local position_id
    local test_filter
    if position.type == "test" then
        position_id = position.id
        test_filter = "-E " .. vim.fn.shellescape(package_filter .. "test(/^" .. position_id .. "$/)")
    elseif position.type == "file" then
        if package_name then
            test_filter = "-E " .. vim.fn.shellescape("package(" .. package_name .. ")")
        end

        position_id = path_to_test_path(position.path)

        if is_unit_test(position.path) and position_id == nil then
            position_id = "tests"
        end

        if position_id then
            test_filter = "-E " .. vim.fn.shellescape(package_filter .. "test(/^" .. position_id .. "::/)")
        end
    end
    table.insert(command, test_filter)

    local context = {
        junit_path = junit_path,
        file = position.path,
        test_filter = test_filter,
        position_id = position_id,
        strategy = args.strategy,
    }

    local env_vars = vim.tbl_deep_extend("force", get_env(), args.env or {})

    if args.strategy == "dap" then
        local dap_args = { "--nocapture" }

        if position.type == "test" then
            context.test_filter = position.id
            table.insert(dap_args, "--exact")
        else
            position_id = path_to_test_path(position.path)
            if position_id == nil then
                context.test_filter = "tests"
            else
                context.test_filter = position_id
            end
        end

        table.insert(dap_args, context.test_filter)

        local strategy = {
            name = "Debug Rust Tests",
            type = get_dap_adapter(),
            request = "launch",
            cwd = cwd or "${workspaceFolder}",
            stopOnEntry = false,
            args = dap_args,
            program = dap.get_test_binary(cwd, position.path),
            env = env_vars,
        }

        if get_dap_adapter() == "codelldb" then
            strategy["stdio"] = { nil, async.fn.tempname() }
        end

        return {
            -- 修复：不再把 env 拼进 command 字符串，env 只走 spec.env
            command = command,
            cwd = cwd,
            context = context,
            strategy = strategy,
            env = env_vars,
        }
    end

    return {
        command = command,
        cwd = cwd,
        context = context,
        env = env_vars,
    }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
    ---@type table<string, neotest.Result>
    local results = {}
    local output_path = spec.strategy and spec.strategy.stdio and spec.strategy.stdio[2] or result.output

    if util.file_exists(spec.context.junit_path) then
        local data = read_file(spec.context.junit_path)

        if data then
            local root = xml.parse(data)

            -- 统一单元素/多元素为 array
            local function as_list(v)
                if v == nil then
                    return {}
                end
                if vim.islist(v) then
                    return v
                end
                return { v }
            end

            local testsuites = as_list(root.testsuites and root.testsuites.testsuite)

            for _, testsuite in ipairs(testsuites) do
                local testcases = as_list(testsuite.testcase)
                for _, testcase in ipairs(testcases) do
                    local name = testcase._attr and testcase._attr.name
                    if not name then
                        goto continue
                    end

                    if testcase.failure then
                        local failure = testcase.failure[1] or testcase.failure
                        local output = type(failure) == "string" and failure or failure._text or ""
                        results[name] = {
                            status = "failed",
                            short = output,
                            errors = errors.parse_errors(output),
                        }
                    else
                        results[name] = { status = "passed" }
                    end
                    ::continue::
                end
            end
        end
    elseif spec.context.strategy == "dap" and util.file_exists(output_path) then
        results = dap.translate_results(output_path)
    else
        local output = result.output

        results[spec.context.position_id] = {
            status = "failed",
            output = output,
        }
    end

    return results
end

setmetatable(adapter, {
    __call = function(_, opts)
        -- 统一写入 config，单一数据源
        if is_callable(opts.args) then
            get_args = opts.args
        elseif opts.args then
            config.args = opts.args
        end

        if opts.env then
            config.env = opts.env
        end

        if is_callable(opts.dap_adapter) then
            get_dap_adapter = opts.dap_adapter
        elseif opts.dap_adapter then
            config.dap_adapter = opts.dap_adapter
        end

        return adapter
    end,
})

return adapter
