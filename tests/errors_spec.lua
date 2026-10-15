local errors = require("neotest-rust.errors")

describe("parses errors from output", function()
    it("non-parsable errors in output", function()
        local output = "something\nwent\nwrong"
        local results = errors.parse_errors(output)

        assert.is_true(#results == 0)
    end)

    it("assert_eq", function()
        local output = "thread 'tests::failed_math' panicked at src/main.rs:16:9:\n"
            .. "assertion `left == right` failed\n"
            .. "  left: `2`,\n"
            .. " right: `3`\n"
            .. "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace"

        local results = errors.parse_errors(output)
        local expected = {
            {
                line = 15,
                message = "assertion `left == right` failed\n  left: `2`,\n right: `3`\n",
            },
        }

        assert.are.same(expected, results)
    end)

    it("parses when the backtrace note is missing", function()
        local output = "thread 'tests::failed_math' panicked at src/main.rs:16:9:\n"
            .. "assertion `left == right` failed\n"
            .. "  left: `2`,\n"
            .. " right: `3`"

        local results = errors.parse_errors(output)
        local expected = {
            {
                line = 15,
                message = "assertion `left == right` failed\n  left: `2`,\n right: `3`",
            },
        }

        assert.are.same(expected, results)
    end)

    it("parses the legacy panic format", function()
        local output = "thread 'main' panicked at 'boom', src/lib.rs:42:5"

        local results = errors.parse_errors(output)
        local expected = { { line = 41, message = "boom" } }

        assert.are.same(expected, results)
    end)

    it("parses paths that contain a colon", function()
        local output = "thread 'main' panicked at C:\\Users\\me\\src\\main.rs:7:3:\noh no"

        local results = errors.parse_errors(output)
        local expected = { { line = 6, message = "oh no" } }

        assert.are.same(expected, results)
    end)

    it("parses CRLF output", function()
        local output = "thread 'main' panicked at src/main.rs:1:1:\r\nboom"

        local results = errors.parse_errors(output)
        local expected = { { line = 0, message = "boom" } }

        assert.are.same(expected, results)
    end)

    it("returns nothing for nil/empty output", function()
        assert.is_true(#errors.parse_errors(nil) == 0)
        assert.is_true(#errors.parse_errors("") == 0)
    end)
end)
