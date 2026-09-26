local async = require("neotest.async")
local context_manager = require("plenary.context_manager")
local dap = require("neotest-rust.dap")
local util = require("neotest-rust.util")
local errors = require("neotest-rust.errors")
local Job = require("plenary.job")
local open = context_manager.open
local Path = require("plenary.path")
local lib = require("neotest.lib")
local with = context_manager.with
local xml = require("neotest.lib.xml")

local adapter = { name = "neotest-rust" }

-- 新增：存储配置选项
local config = {
    args = {},
    env = {}, -- 新增环境变量支持
    dap_adapter = "codelldb",
}

local cargo_metadata = setmetatable({}, {
    __call = function(self, cwd)
        local metadata = self[cwd]
        if metadata ~= nil then
            return metadata
        else
            local output = nil
            local job = Job:new({
                command = "cargo",
                args = { "metadata", "--no-deps" },
                cwd = cwd,
                timeout = 30000,
                on_exit = function(j, return_val)
                    local result = j:result()
                    output = (result and #result > 0) and result[1] or nil
                end,
            })
            job:sync()

            if output and output ~= "" then
                metadata = vim.json.decode(output)
            else
                metadata = { packages = {}, workspace_root = cwd, target_directory = cwd .. "/target" }
            end

            self[cwd] = metadata
            return metadata
        end
    end,
})

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
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
    local manifest_path = package_root .. "Cargo.toml"
    local metadata = cargo_metadata(package_root)

    return vim.tbl_filter(function(p)
        return p.manifest_path == manifest_path
    end, metadata.packages)[1].name
end

local get_args = function()
    return config.args
end

local get_dap_adapter = function()
    return config.dap_adapter
end

local get_env = function()
    return config.env
end

-- 新增：构建带环境变量的命令
local function build_command_with_env(cmd_parts, env_vars)
    local cmd = table.concat(cmd_parts, " ")

    if not env_vars or vim.tbl_isempty(env_vars) then
        return cmd
    end

    -- 构建环境变量字符串
    local env_strings = {}
    for key, value in pairs(env_vars) do
        table.insert(env_strings, string.format("%s=%s", key, value))
    end

    return table.concat(env_strings, " ") .. " " .. cmd
end

local is_callable = function(obj)
    return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

---@async
---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
    return vim.endswith(file_path, ".rs") and #adapter.discover_positions(file_path):to_list() ~= 1
end

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
function adapter.filter_dir(name, rel_path, root)
    return root .. Path.path.sep .. rel_path ~= cargo_metadata(root).target_directory
end

local get_package_root = lib.files.match_root_pattern("Cargo.toml")

local function is_unit_test(path)
    return vim.startswith(path, get_package_root(path) .. Path.path.sep .. "src" .. Path.path.sep)
end

local function is_integration_test(path)
    return vim.startswith(path, get_package_root(path) .. Path.path.sep .. "tests" .. Path.path.sep)
end

local function is_alternate_binary(path)
    return vim.startswith(
        path,
        get_package_root(path) .. Path.path.sep .. "src" .. Path.path.sep .. "bin" .. Path.path.sep
    )
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
        path = Path:new(path)
        path = path:make_relative(root .. Path.path.sep .. "src")
    else
        path = Path:new(path)
        path = path:make_relative(root .. Path.path.sep .. "tests")
        if path:find(Path.path.sep) then
            path = path:gsub("^.+" .. Path.path.sep, "")
        else
            return nil
        end
    end

    path = path:gsub(Path.path.sep, "::")

    if path == "." then
        return nil
    else
        return path
    end
end

local function integration_test_name(path)
    local package_root = get_package_root(path)

    path = Path:new(path)
    path = path:make_relative(package_root .. Path.path.sep .. "tests")
    path = path:gsub(".rs$", "")
    return vim.split(path, "/")[1]
end

local function binary_name(path)
    local package_root = get_package_root(path)

    path = Path:new(path)
    path = path:make_relative(package_root .. Path.path.sep .. "src" .. Path.path.sep .. "bin")
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

    local nextest_config = Path:new(cwd .. ".config/nextest.toml")
    if nextest_config:exists() then
        nextest_config:copy({ destination = tmp_nextest_config })
    end

    with(open(tmp_nextest_config, "a"), function(writer)
        writer:write("[profile.neotest.junit]\npath = '" .. junit_path .. "'")
    end)

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
        vim.list_extend(get_args(), args.extra_args or {}),
    })

    if is_integration_test(position.path) then
        vim.list_extend(command, { "--test", integration_test_name(position.path) })
    end

    if is_alternate_binary(position.path) then
        vim.list_extend(command, { "--bin", binary_name(position.path) })
    end

    local workspace_root = adapter.root(position.path) .. Path.path.sep
    local package_root = lib.files.match_root_pattern("Cargo.toml")(position.path)
    local belongs_to_workspace = (package_root:sub(0, #workspace_root) == workspace_root)
    local package_name = belongs_to_workspace and package_name_by_root(package_root .. Path.path.sep)

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

    -- 获取环境变量（合并配置中的和额外传入的）
    local env_vars = vim.tbl_deep_extend("force", get_env(), args.env or {})

    -- Debug
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
            env = env_vars, -- 添加环境变量到 DAP
        }

        if get_dap_adapter() == "codelldb" then
            strategy["stdio"] = { nil, async.fn.tempname() }
        end

        return {
            command = build_command_with_env(command, env_vars), -- 使用增强的命令构建
            cwd = cwd,
            context = context,
            strategy = strategy,
            env = env_vars, -- 添加环境变量到 spec
        }
    end

    -- Run
    return {
        command = build_command_with_env(command, env_vars), -- 使用增强的命令构建
        cwd = cwd,
        context = context,
        env = env_vars, -- 添加环境变量到 spec
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
        local data
        with(open(spec.context.junit_path, "r"), function(reader)
            data = reader:read("*a")
        end)

        local root = xml.parse(data)

        local testsuites
        if root.testsuites.testsuite == nil then
            testsuites = {}
        elseif #root.testsuites.testsuite == 0 then
            testsuites = { root.testsuites.testsuite }
        else
            testsuites = root.testsuites.testsuite
        end
        for _, testsuite in pairs(testsuites) do
            local testcases
            if #testsuite.testcase == 0 then
                testcases = { testsuite.testcase }
            else
                testcases = testsuite.testcase
            end
            for _, testcase in pairs(testcases) do
                if testcase.failure then
                    local output = testcase.failure[1]

                    results[testcase._attr.name] = {
                        status = "failed",
                        short = output,
                        errors = errors.parse_errors(output),
                    }
                else
                    results[testcase._attr.name] = {
                        status = "passed",
                    }
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
        if is_callable(opts.args) then
            get_args = opts.args
        elseif opts.args then
            get_args = function()
                return opts.args
            end
        end

        -- 新增：处理 env 配置
        if opts.env then
            config.env = opts.env
        end

        if is_callable(opts.dap_adapter) then
            get_dap_adapter = opts.dap_adapter
        elseif opts.dap_adapter then
            get_dap_adapter = function()
                return opts.dap_adapter
            end
        end

        return adapter
    end,
})

return adapter
