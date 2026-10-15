local M = {}

-- Modern panic header (Rust >= 1.65):
--   thread '<name>' panicked at <path>:<line>:<col>:
-- The path is matched non-greedily so paths containing ':' (e.g. Windows
-- drive letters or paths with colons) still resolve to the last
-- ":<line>:<col>:" on the header line.
local MODERN_HEADER = "thread '[^']*' panicked at [^\n]-:(%d+):%d+:\n"

-- Legacy panic format (Rust < 1.65):
--   thread '<name>' panicked at '<message>', <path>:<line>:<col>
local LEGACY_HEADER = "thread '[^']*' panicked at '(.-)', [^\n]-:(%d+):%d+"

---Drop a trailing backtrace note while preserving the newline that precedes
---it, so the parsed message keeps the same shape as before.
---@param message string
---@return string
local function strip_backtrace_note(message)
    local index = message:find("\nnote: run with `RUST_BACKTRACE=1`", 1, true)
    if index then
        return message:sub(1, index)
    end
    return message
end

---Parse panic message(s) out of test output. Supports both the modern and
---legacy rustc panic formats, tolerates CRLF and a missing backtrace note,
---and never requires the `note:` line to be present.
---@param output string|nil
---@return neotest.Error[]
function M.parse_errors(output)
    if output == nil or output == "" then
        return {}
    end

    -- Normalise CRLF so the line-based patterns above stay simple.
    output = output:gsub("\r\n", "\n")

    -- Modern format: everything after the header line is the message.
    local line, message = output:match(MODERN_HEADER .. "(.*)")
    if message ~= nil then
        return {
            { line = tonumber(line) - 1, message = strip_backtrace_note(message) },
        }
    end

    -- Legacy format: the message sits between "panicked at '" and "', ".
    local legacy_message, legacy_line = output:match(LEGACY_HEADER)
    if legacy_message ~= nil then
        return {
            { line = tonumber(legacy_line) - 1, message = legacy_message },
        }
    end

    -- Not a panic we recognise.
    return {}
end

return M
