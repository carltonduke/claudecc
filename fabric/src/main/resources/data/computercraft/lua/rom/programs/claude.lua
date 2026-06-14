-- Claude AI interactive shell for CC: Tweaked
-- Requires an operator to run /claudecc api <key> before use.

if not claudecc then
    error("The claudecc API is not available on this computer.", 0)
end

-- ─── Debug log (forge/run/saves/<world>/computercraft/computer/<id>/_chat.log) ─
local _logFile = fs.open("_chat.log", "a")
local function log(msg)
    if _logFile then
        _logFile.writeLine("[" .. os.clock() .. "] " .. tostring(msg))
        _logFile.flush()
    end
end
log("──── session start ────")

-- ─── Layout ──────────────────────────────────────────────────────────────────
local w, h = term.getSize()
local HEADER_ROWS = 2   -- title + separator
local FOOTER_ROWS = 2   -- separator + input line
local CHAT_HEIGHT = h - HEADER_ROWS - FOOTER_ROWS
local INPUT_ROW   = h
local SEP_ROW     = h - 1

-- ─── Colour helpers ──────────────────────────────────────────────────────────
local HAS_COLOUR = term.isColour and term.isColour()
local function col(c) if HAS_COLOUR then term.setTextColour(c) end end
local function bg(c)  if HAS_COLOUR then term.setBackgroundColour(c) end end

local C = {
    white     = colours.white,
    grey      = colours.grey,
    lightGrey = colours.lightGrey,
    yellow    = colours.yellow,
    cyan      = colours.cyan,
    blue      = colours.lightBlue,
    orange    = colours.orange,
    lime      = colours.lime,
    purple    = colours.purple,
    red       = colours.red,
}

-- ─── Token usage tracking ────────────────────────────────────────────────────
local lastInputTokens    = 0
local lastOutputTokens   = 0
local lastRatelimitLeft  = -1   -- -1 = unknown
local MAX_TOOL_ITERS = 25  -- cap consecutive tool calls in one turn (runaway-loop guard)

-- ─── Prompt input history (Up/Down arrow recall) ─────────────────────────────
-- Last few submitted inputs; Up/Down in the input bar cycles through them.
local promptHistory = {}          -- oldest → newest
local MAX_PROMPT_HISTORY = 5
local function recordPrompt(text)
    if not text or text == "" then return end
    if promptHistory[#promptHistory] == text then return end  -- skip consecutive duplicate
    promptHistory[#promptHistory + 1] = text
    while #promptHistory > MAX_PROMPT_HISTORY do
        table.remove(promptHistory, 1)
    end
end
local AUTO_COMPACT_THRESHOLD = 18000  -- auto-compact when input tokens exceed this

-- ─── Scroll buffer ────────────────────────────────────────────────────────────
-- Each entry is a list of {text, colour} segments forming one screen line.
local lineBuf   = {}
local scrollOff = 0  -- 0 = bottom; N = scrolled up N lines
local selA, selB = nil, nil  -- {bufLineIdx, charOffset} pairs, or nil

local function clampScroll()
    local maxOff = math.max(0, #lineBuf - CHAT_HEIGHT)
    scrollOff = math.max(0, math.min(scrollOff, maxOff))
end

-- Convert a screen row (1-based) to a buffer-line index, or nil if outside chat area.
local function screenRowToBufLine(screenRow)
    local chatRow = screenRow - HEADER_ROWS
    if chatRow < 1 or chatRow > CHAT_HEIGHT then return nil end
    clampScroll()
    local total  = #lineBuf
    local bottom = total - scrollOff
    local top    = math.max(1, bottom - CHAT_HEIGHT + 1)
    local li     = top + chatRow - 1
    return (li >= 1 and li <= total) and li or nil
end

-- Return the plain text of lineBuf[i] (all segment texts concatenated).
local function lineText(i)
    if not lineBuf[i] then return "" end
    local t = {}
    for _, seg in ipairs(lineBuf[i]) do t[#t+1] = seg[1] end
    return table.concat(t)
end

-- Return the text of the current selection as a newline-joined string.
local function getSelectedText()
    if not selA or not selB then return "" end
    local a, b = selA, selB
    if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then a, b = b, a end
    local parts = {}
    for i = a[1], b[1] do
        local t  = lineText(i)
        local lo = (i == a[1]) and a[2] + 1 or 1   -- Lua 1-indexed
        local hi = (i == b[1]) and b[2] + 1 or #t
        parts[#parts+1] = t:sub(lo, hi)
    end
    return table.concat(parts, "\n")
end

-- Add one screen-width line (already wrapped) to the buffer.
local function bufLine(segments)
    table.insert(lineBuf, segments)
end

-- Render the chat viewport.
local function renderChat()
    clampScroll()
    local total  = #lineBuf
    local bottom = total - scrollOff
    local top    = math.max(1, bottom - CHAT_HEIGHT + 1)

    local selNorm = nil
    if selA and selB then
        local a, b = selA, selB
        if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then a, b = b, a end
        selNorm = {a = a, b = b}
    end

    for row = 1, CHAT_HEIGHT do
        local li = top + row - 1
        bg(colours.black)
        term.setCursorPos(1, HEADER_ROWS + row)
        term.clearLine()
        if li >= 1 and li <= total then
            local fromCh, toCh = nil, nil
            if selNorm and li >= selNorm.a[1] and li <= selNorm.b[1] then
                fromCh = (li == selNorm.a[1]) and selNorm.a[2] or 0
                toCh   = (li == selNorm.b[1]) and selNorm.b[2] or (w + 1)
            end
            local cp = 0
            for _, seg in ipairs(lineBuf[li]) do
                local txt, clr = seg[1], seg[2]
                if fromCh then
                    for ci = 1, #txt do
                        local c = cp + ci - 1
                        bg(c >= fromCh and c <= toCh and colours.grey or colours.black)
                        col(clr)
                        term.write(txt:sub(ci, ci))
                    end
                else
                    col(clr)
                    term.write(txt)
                end
                cp = cp + #txt
            end
            bg(colours.black)
        end
    end

    -- Scroll indicator
    if scrollOff > 0 then
        term.setCursorPos(w - 2, HEADER_ROWS + 1)
        col(C.grey)
        term.write("↑↑↑")
    end
    col(C.white)
end

-- ─── Output helpers ──────────────────────────────────────────────────────────
-- Wrap a list of {text, colour} segments into screen-width lines and buffer them.
local function pushSegments(segs)
    local lineSegs = {}
    local lineLen  = 0

    local function flush()
        if #lineSegs > 0 or lineLen == 0 then
            bufLine(lineSegs)
            lineSegs = {}
            lineLen  = 0
        end
    end

    for _, seg in ipairs(segs) do
        local txt, clr = seg[1], seg[2]
        while #txt > 0 do
            local remaining = w - lineLen
            if remaining <= 0 then
                flush()
                remaining = w
            end
            if #txt <= remaining then
                table.insert(lineSegs, {txt, clr})
                lineLen = lineLen + #txt
                txt = ""
            else
                -- Try to break at a space
                local chunk = txt:sub(1, remaining)
                local cut   = chunk:match("^(.*%s)%S") or chunk
                table.insert(lineSegs, {cut, clr})
                txt = txt:sub(#cut + 1)
                flush()
            end
        end
    end
    flush()
end

-- Push a single-colour line.
local function pushLine(text, clr)
    pushSegments({{text, clr or C.white}})
end

local function pushBlank()
    bufLine({})
end

-- Snap to bottom and re-render after adding content.
local function newContent()
    scrollOff = 0
    renderChat()
end

-- ─── Markdown renderer ────────────────────────────────────────────────────────
-- Parses inline markdown in `text` → list of {text, colour} segments.
local function inlineSegments(text)
    local segs = {}
    local i    = 1
    local cur  = ""
    local curC = C.white

    local function flush()
        if cur ~= "" then
            table.insert(segs, {cur, curC})
            cur = ""
        end
    end

    while i <= #text do
        local c2 = text:sub(i, i + 1)
        local c1 = text:sub(i, i)

        if c2 == "**" then
            local close = text:find("%*%*", i + 2)
            if close then
                flush()
                table.insert(segs, {text:sub(i + 2, close - 1), C.yellow})
                i = close + 2
            else
                cur = cur .. c1; i = i + 1
            end

        elseif c1 == "`" and text:sub(i, i + 2) ~= "```" then
            local close = text:find("`", i + 1)
            if close then
                flush()
                table.insert(segs, {text:sub(i + 1, close - 1), C.orange})
                i = close + 1
            else
                cur = cur .. c1; i = i + 1
            end

        elseif c1 == "*" and c2 ~= "**" then
            local close = text:find("%*", i + 1)
            if close then
                flush()
                table.insert(segs, {text:sub(i + 1, close - 1), C.lightGrey})
                i = close + 1
            else
                cur = cur .. c1; i = i + 1
            end

        else
            cur = cur .. c1; i = i + 1
        end
    end
    flush()
    return segs
end

-- Render a full markdown string into the scroll buffer.
local function pushMarkdown(text)
    local inCode = false

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^```") then
            inCode = not inCode

        elseif inCode then
            pushLine("  " .. line, C.lime)

        elseif line:match("^# ") then
            pushLine(line:sub(3), C.cyan)
            pushLine(("─"):rep(w), C.grey)

        elseif line:match("^## ") then
            pushLine(line:sub(4), C.blue)

        elseif line:match("^### ") then
            pushLine(line:sub(5), C.blue)

        elseif line:match("^%-%-%-+$") or line:match("^%*%*%*+$") then
            pushLine(("─"):rep(w), C.grey)

        elseif line:match("^%s*[%-%*] ") then
            local rest = line:match("^%s*[%-%*] (.*)")
            local segs = {{"• ", C.grey}}
            for _, s in ipairs(inlineSegments(rest)) do
                table.insert(segs, s)
            end
            pushSegments(segs)

        elseif line == "" then
            pushBlank()

        else
            pushSegments(inlineSegments(line))
        end
    end
end

-- ─── Tool definitions (sent to Anthropic) ────────────────────────────────────
local TOOLS_JSON = textutils.serialiseJSON({
    {
        name = "read_file",
        description = "Read the full contents of a file on this computer.",
        input_schema = {
            type = "object",
            properties = { path = {type = "string", description = "File path"} },
            required   = {"path"},
        },
    },
    {
        name = "write_file",
        description = "Write (or overwrite) a file on this computer.",
        input_schema = {
            type = "object",
            properties = {
                path    = {type = "string", description = "File path"},
                content = {type = "string", description = "Content to write"},
            },
            required = {"path", "content"},
        },
    },
    {
        name = "list_dir",
        description = "List the contents of a directory.",
        input_schema = {
            type = "object",
            properties = { path = {type = "string", description = "Directory path (default: '/')"} },
        },
    },
    {
        name = "list_apis",
        description = "List the Lua globals and APIs available on this computer.",
        input_schema = {type = "object", properties = {}},
    },
    {
        name = "get_api_methods",
        description = "List the callable methods of a Lua API (e.g. 'turtle', 'fs', 'peripheral').",
        input_schema = {
            type = "object",
            properties = { api = {type = "string", description = "API name"} },
            required   = {"api"},
        },
    },
    {
        name = "run_file",
        description = "Run a Lua program file on this computer via the shell.",
        input_schema = {
            type = "object",
            properties = { path = {type = "string", description = "Path to the Lua file to run"} },
            required   = {"path"},
        },
    },
    {
        name = "list_peripherals",
        description = "List all peripherals currently connected to this computer, with their type and available methods.",
        input_schema = {type = "object", properties = {}},
    },
    {
        name = "pastebin_put",
        description = "Upload a file to pastebin.com and return the URL and the 'pastebin get' command.",
        input_schema = {
            type = "object",
            properties = { path = {type = "string", description = "Path to the file to upload"} },
            required   = {"path"},
        },
    },
})

-- ─── Tool executor ───────────────────────────────────────────────────────────
local function execTool(name, input)
    log("tool call: " .. tostring(name) .. " input=" .. textutils.serialiseJSON(input or {}))
    if name == "read_file" then
        local path = input.path
        if not path            then return "Error: missing 'path' argument" end
        if not fs.exists(path) then return "Error: not found: " .. path end
        if fs.isDir(path)       then return "Error: is a directory, use list_dir" end
        local ok, res = pcall(function()
            local f = fs.open(path, "r")
            local s = f.readAll(); f.close(); return s
        end)
        return ok and res or ("Error: " .. res)

    elseif name == "write_file" then
        if not input.path    then return "Error: missing 'path' argument" end
        if not input.content then return "Error: missing 'content' argument" end
        local ok, err = pcall(function()
            local f = fs.open(input.path, "w")
            f.write(input.content); f.close()
        end)
        return ok and "Written successfully." or ("Error: " .. err)

    elseif name == "list_dir" then
        local path = input.path or "/"
        if not fs.exists(path) then return "Error: not found: " .. path end
        local items = {}
        for _, name in ipairs(fs.list(path)) do
            local full = fs.combine(path, name)
            table.insert(items, {
                name = name,
                type = fs.isDir(full) and "dir" or "file",
                size = not fs.isDir(full) and fs.getSize(full) or nil,
            })
        end
        return textutils.serialiseJSON(items)

    elseif name == "list_apis" then
        local apis = {}
        for k, v in pairs(_G) do
            if type(v) == "table" then table.insert(apis, k) end
        end
        table.sort(apis)
        return textutils.serialiseJSON(apis)

    elseif name == "get_api_methods" then
        if not input.api then return "Error: missing 'api' argument" end
        local api = _G[input.api] or peripheral.wrap(input.api)
        if not api then return "Error: '" .. input.api .. "' is not a Lua API or connected peripheral." end
        if type(api) ~= "table" then return "Error: '" .. input.api .. "' is not a table." end
        local methods = {}
        for k, v in pairs(api) do
            if type(v) == "function" then table.insert(methods, k) end
        end
        table.sort(methods)
        return textutils.serialiseJSON(methods)

    elseif name == "list_peripherals" then
        local result = {}
        for _, pname in ipairs(peripheral.getNames()) do
            result[pname] = {
                type    = peripheral.getType(pname),
                methods = peripheral.getMethods(pname),
            }
        end
        if next(result) == nil then return "No peripherals connected." end
        return textutils.serialiseJSON(result)

    elseif name == "run_file" then
        local path = input.path
        if not path            then return "Error: missing 'path' argument" end
        if not fs.exists(path) then return "Error: not found: " .. path end

        -- Run the program against an off-screen window so we can (a) capture its
        -- printed output to feed back to Claude and (b) keep it from drawing over
        -- the claude UI on the real terminal.
        local w = term.getSize()
        local BUF_H = 64                       -- retain up to 64 lines of output
        local capture = window.create(term.current(), 1, 1, w, BUF_H, false)
        local prev = term.redirect(capture)
        local pcOk, shellRet = pcall(shell.run, path)
        term.redirect(prev)

        -- Scrape non-blank lines from the capture buffer.
        local lines = {}
        for y = 1, BUF_H do
            local text = capture.getLine(y)
            if text then table.insert(lines, (text:gsub("%s+$", ""))) end
        end
        while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
        local output = table.concat(lines, "\n")

        local status
        if not pcOk then
            status = "Program crashed: " .. tostring(shellRet)
        elseif shellRet then
            status = "Program exited normally (no Lua error). This does NOT mean it " ..
                "achieved its goal — read the output below to confirm."
        else
            status = "Program stopped (returned false / errored, or the user pressed " ..
                "Ctrl+T to terminate it). If the user terminated it intentionally, do " ..
                "not treat this as an error."
        end

        if output ~= "" then
            return status .. "\n\n--- program output ---\n" .. output
        else
            return status .. "\n\n(no terminal output)"
        end

    elseif name == "pastebin_put" then
        local path = input.path
        if not path            then return "Error: missing 'path' argument" end
        if not fs.exists(path) then return "Error: not found: " .. path end
        local f = fs.open(path, "r")
        if not f then return "Error: could not open file" end
        local content = f.readAll(); f.close()
        local ok, response = pcall(function()
            return http.post(
                "https://pastebin.com/api/api_post.php",
                "api_option=paste" ..
                "&api_dev_key=0ec2eb25b6166c0c27a394ae118ad829" ..
                "&api_paste_code=" .. textutils.urlEncode(content) ..
                "&api_paste_format=lua" ..
                "&api_paste_expire_date=N"
            )
        end)
        if not ok or not response then
            return "Error: HTTP request failed: " .. tostring(response)
        end
        local url = response.readAll(); response.close()
        if url:find("^Bad API request") then return "Error: " .. url end
        local code = url:match("/([^/]+)$") or url
        return "Uploaded!\nURL: " .. url .. "\nTo download on any CC computer: pastebin get " .. code

    else
        return "Error: unknown tool '" .. name .. "'"
    end
end

-- ─── Agentic loop ────────────────────────────────────────────────────────────
local function buildSystemContext()
    local lines = {}
    lines[#lines+1] = "You are running inside a CC:Tweaked computer in Minecraft."
    lines[#lines+1] = "Computer ID: " .. os.computerID() ..
        (os.computerLabel() and (", label: " .. os.computerLabel()) or "")
    lines[#lines+1] = "Is turtle: " .. tostring(turtle ~= nil)

    -- Peripherals
    local names = peripheral.getNames()
    if #names == 0 then
        lines[#lines+1] = "Connected peripherals: none"
    else
        lines[#lines+1] = "Connected peripherals:"
        for _, pname in ipairs(names) do
            local ptype    = peripheral.getType(pname)
            local methods  = peripheral.getMethods(pname)
            table.sort(methods)
            lines[#lines+1] = "  " .. pname .. " (" .. ptype .. "): " .. table.concat(methods, ", ")
        end
    end

    lines[#lines+1] = "ROM APIs are at /rom/apis/ (fs, http, rednet, peripheral, term, textutils, etc.)."
    lines[#lines+1] = "ROM programs are at /rom/programs/. Use read_file to inspect any of them."
    return table.concat(lines, "\n")
end

-- Live environment context (computer ID, peripherals, API hints), passed to the Java
-- side as claudecc.ask's 3rd argument. The behavioural system prompt itself — the
-- default, or the player's `/claudecc system_prompt` override — is resolved server-side
-- in ClaudeCommand.getSystemPrompt and prepended there. Message history stays purely
-- conversational (no faked system-context message pair).
local ENV_CONTEXT = buildSystemContext()

local HISTORY_FILE = "_chat_history.json"
local MAX_HISTORY  = 60  -- max saved messages

local history = {}

-- Persist the full conversation history (the system prompt + env context are sent out-of-band, not here).
local function saveHistory()
    local f = fs.open(HISTORY_FILE, "w")
    if f then f.write(textutils.serialiseJSON(history)); f.close() end
end

-- Load saved history into history table; returns number of messages loaded.
local function loadHistory()
    if not fs.exists(HISTORY_FILE) then return 0 end
    local ok, data = pcall(function()
        local f = fs.open(HISTORY_FILE, "r")
        local s = f.readAll(); f.close()
        return textutils.unserialiseJSON(s)
    end)
    if not ok or type(data) ~= "table" or #data == 0 then return 0 end
    local start = math.max(1, #data - MAX_HISTORY + 1)
    for i = start, #data do history[#history+1] = data[i] end
    return #data - start + 1
end

local pastCount = loadHistory()

-- Push plain (non-markdown) text into lineBuf, respecting newlines and word-wrap.
local function pushPlainText(text)
    local pos, len = 1, #text
    local first = true
    while pos <= len do
        local nl   = text:find("\n", pos, true)
        local line = nl and text:sub(pos, nl - 1) or text:sub(pos)
        if not first then bufLine({}) end
        first = false
        if #line > 0 then pushSegments({{line, C.white}}) end
        pos = nl and nl + 1 or len + 1
    end
    if first then bufLine({}) end
end

local function agentChat(userInput)
    log("user: " .. tostring(userInput))
    table.insert(history, {role = "user", content = userInput})
    claudecc.ask(textutils.serialiseJSON(history), TOOLS_JSON, ENV_CONTEXT)
    log("ask() sent")

    local streamStart = nil  -- lineBuf index where the streaming response begins
    local streamBuf   = ""   -- accumulated text received via claude_chunk
    local toolIters   = 0    -- consecutive tool calls this turn (runaway-loop guard)

    local function finishStream()
        if streamStart then
            while #lineBuf >= streamStart do table.remove(lineBuf) end
            streamStart, streamBuf = nil, ""
        end
    end

    while true do
        local ev, a, b, c, d = os.pullEventRaw()

        if ev == "terminate" then
            finishStream()
            pushLine("(interrupted)", C.grey)
            newContent()
            return false

        elseif ev == "claude_usage" then
            -- a=inputTokens, b=outputTokens, c=ratelimitRemaining
            lastInputTokens  = a or 0
            lastOutputTokens = b or 0
            lastRatelimitLeft = c or -1
            log("usage: in=" .. tostring(a) .. " out=" .. tostring(b) .. " remaining=" .. tostring(c))
            renderHeader()

        elseif ev == "claude_chunk" then
            -- a = incremental text delta from the streaming API
            if not streamStart then streamStart = #lineBuf + 1 end
            streamBuf = streamBuf .. a
            while #lineBuf >= streamStart do table.remove(lineBuf) end
            pushPlainText(streamBuf)
            newContent()

        elseif ev == "claude_response" then
            -- a = full response text (sent after all chunks)
            log("claude_response: " .. tostring(a and #a or 0) .. " chars")
            finishStream()
            if a and a ~= "" then
                pushMarkdown(a)
                table.insert(history, {role = "assistant", content = a})
            end
            saveHistory()
            newContent()
            return true

        elseif ev == "claude_tool_use" then
            -- a=textBefore, b=toolId, c=toolName, d=inputJson
            finishStream()
            local textBefore, toolId, toolName, inputJson = a, b, c, d
            log("claude_tool_use: name=" .. tostring(toolName) .. " inputJson=" .. tostring(inputJson))
            local input = textutils.unserialiseJSON(inputJson) or {}

            if textBefore and textBefore ~= "" then
                pushMarkdown(textBefore)
            end
            pushLine("↳ " .. toolName, C.purple)
            newContent()

            local result = execTool(toolName, input)
            log("tool result: " .. tostring(result and result:sub(1, 200) or "nil"))

            -- Build assistant content array (text + tool_use). The tool_use input
            -- must faithfully record what Claude actually sent — mutating it (e.g.
            -- omitting a large write_file content) corrupts the transcript and makes
            -- Claude distrust its own write and re-issue it endlessly.
            local assistantContent = {}
            if textBefore and textBefore ~= "" then
                table.insert(assistantContent, {type = "text", text = textBefore})
            end
            table.insert(assistantContent, {type = "tool_use", id = toolId, name = toolName, input = input})
            table.insert(history, {role = "assistant", content = assistantContent})

            -- Tool result — truncate large results (e.g. read_file on a big file).
            local histResult = result
            if type(result) == "string" and #result > 800 then
                histResult = result:sub(1, 800) .. "\n...(truncated — use read_file for full content)"
            end
            table.insert(history, {
                role = "user",
                content = {{type = "tool_result", tool_use_id = toolId, content = histResult}},
            })

            pushLine("  ✓ done", C.grey)
            newContent()

            toolIters = toolIters + 1
            if toolIters >= MAX_TOOL_ITERS then
                log("tool iteration cap reached (" .. MAX_TOOL_ITERS .. ")")
                pushLine("Stopped: too many consecutive tool calls (" .. MAX_TOOL_ITERS .. "). Type to continue.", C.red)
                newContent()
                saveHistory()
                return false
            end

            claudecc.ask(textutils.serialiseJSON(history), TOOLS_JSON, ENV_CONTEXT)
            streamStart, streamBuf = nil, ""

        elseif ev == "claude_error" then
            log("claude_error: " .. tostring(a))
            finishStream()
            pushLine("Error: " .. tostring(a), C.red)
            newContent()
            return false
        end
    end
end

-- ─── Concurrent input capture (runs alongside agentChat via parallel) ────────
-- ta = {buf="", pos=1, entered=false}
local function captureTyping(ta)
    term.setCursorPos(1, INPUT_ROW)
    term.clearLine()
    col(C.yellow); term.write("> "); col(C.white)
    term.setCursorBlink(true)

    local scroll = 0
    local function clamp()
        local vw = w - 2
        if ta.pos <= scroll then scroll = ta.pos - 1
        elseif ta.pos > scroll + vw then scroll = ta.pos - vw end
        -- Don't scroll past the end of the (possibly shrunken) buffer, which would
        -- hide the remaining text and show a blank field after backspacing.
        scroll = math.min(scroll, math.max(0, #ta.buf + 1 - vw))
    end
    local function redraw()
        term.setCursorPos(3, INPUT_ROW)
        col(C.white)
        local vis = ta.buf .. " "
        term.write(vis:sub(scroll+1, scroll+(w-2)))
        term.setCursorPos(2 + (ta.pos - scroll), INPUT_ROW)
    end

    while true do
        local ev, p1, p2, p3 = os.pullEventRaw()
        if ev == "terminate" then return end
        if ev == "char" then
            ta.buf = ta.buf:sub(1, ta.pos-1) .. p1 .. ta.buf:sub(ta.pos)
            ta.pos = ta.pos + 1; clamp(); redraw()
        elseif ev == "key" then
            if     p1 == keys.backspace and ta.pos > 1 then
                ta.buf = ta.buf:sub(1, ta.pos-2) .. ta.buf:sub(ta.pos)
                ta.pos = ta.pos - 1; clamp(); redraw()
            elseif p1 == keys.delete and ta.pos <= #ta.buf then
                ta.buf = ta.buf:sub(1, ta.pos-1) .. ta.buf:sub(ta.pos+1)
                clamp(); redraw()
            elseif p1 == keys.left  and ta.pos > 1        then ta.pos = ta.pos - 1; clamp(); redraw()
            elseif p1 == keys.right and ta.pos <= #ta.buf  then ta.pos = ta.pos + 1; clamp(); redraw()
            elseif p1 == keys.home  then ta.pos = 1;            clamp(); redraw()
            elseif p1 == keys["end"] then ta.pos = #ta.buf + 1; clamp(); redraw()
            elseif p1 == keys.enter and #ta.buf > 0 then
                ta.entered = true
                term.setCursorBlink(false)
                term.setCursorPos(1, INPUT_ROW)
                term.clearLine()
                col(C.yellow); term.write("> "); col(C.white)
                while true do                         -- wait to be killed by parallel
                    if os.pullEventRaw() == "terminate" then return end
                end
            end
        elseif ev == "mouse_scroll" then
            scrollOff = math.max(0, math.min(scrollOff - p1, math.max(0, #lineBuf - CHAT_HEIGHT)))
            renderChat()
            term.setCursorPos(2 + (ta.pos - scroll), INPUT_ROW)
        end
    end
end

-- ─── Custom readline (supports scroll, mouse selection, copy/paste) ──────────
local function readline(initBuf, initPos)
    local buf         = initBuf or ""
    local pos         = initPos or (#buf + 1)
    local inputScroll = 0  -- chars scrolled off the left of the input view
    local ctrlHeld    = false
    local navIdx      = nil   -- nil = editing live draft; else index into promptHistory
    local savedDraft  = nil   -- live draft text saved before history navigation

    local function clampInputScroll()
        local visibleW = w - 2
        if pos <= inputScroll then
            inputScroll = pos - 1
        elseif pos > inputScroll + visibleW then
            inputScroll = pos - visibleW
        end
        -- Don't scroll past the end of the (possibly shrunken) buffer, which would
        -- hide the remaining text and show a blank field after backspacing.
        inputScroll = math.min(inputScroll, math.max(0, #buf + 1 - visibleW))
    end

    local function redrawInput()
        term.setCursorPos(3, INPUT_ROW)
        col(C.white)
        local visible = buf .. " "
        term.write(visible:sub(inputScroll + 1, inputScroll + (w - 2)))
        term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
    end

    local function clearSel()
        if selA then
            selA, selB = nil, nil
            renderChat()
            term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
        end
    end

    -- Clear input line and position cursor
    term.setCursorPos(1, INPUT_ROW)
    term.clearLine()
    col(C.yellow); term.write("> "); col(C.white)
    if #buf > 0 then clampInputScroll(); redrawInput() end
    term.setCursorBlink(true)

    while true do
        local ev, p1, p2, p3 = os.pullEventRaw()

        if ev == "terminate" then
            return nil

        elseif ev == "char" then
            clearSel()
            buf = buf:sub(1, pos - 1) .. p1 .. buf:sub(pos)
            pos = pos + 1
            clampInputScroll()
            redrawInput()

        elseif ev == "paste" then
            -- p1 = pasted text (Ctrl+V in the terminal window)
            buf = buf:sub(1, pos - 1) .. p1 .. buf:sub(pos)
            pos = pos + #p1
            clampInputScroll()
            redrawInput()

        elseif ev == "key" then
            if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
                ctrlHeld = true

            elseif p1 == keys.enter then
                term.setCursorBlink(false)
                term.setCursorPos(1, INPUT_ROW)
                term.clearLine()
                col(C.yellow); term.write("> "); col(C.white)
                return buf

            elseif ctrlHeld and p1 == keys.c then
                if selA then
                    claudecc.copyToClipboard(getSelectedText())
                elseif #buf > 0 then
                    claudecc.copyToClipboard(buf)
                end

            elseif p1 == keys.backspace and pos > 1 then
                buf = buf:sub(1, pos - 2) .. buf:sub(pos)
                pos = pos - 1
                clampInputScroll()
                redrawInput()

            elseif p1 == keys.delete and pos <= #buf then
                buf = buf:sub(1, pos - 1) .. buf:sub(pos + 1)
                clampInputScroll()
                redrawInput()

            elseif p1 == keys.left and pos > 1 then
                pos = pos - 1
                clampInputScroll()
                redrawInput()

            elseif p1 == keys.right and pos <= #buf then
                pos = pos + 1
                clampInputScroll()
                redrawInput()

            elseif p1 == keys.home then
                pos = 1
                clampInputScroll()
                redrawInput()

            elseif p1 == keys["end"] then
                pos = #buf + 1
                clampInputScroll()
                redrawInput()

            elseif p1 == keys.up then
                -- Recall an older submitted prompt. Save the live draft on the
                -- first step up so Down can return to it.
                if #promptHistory > 0 then
                    if navIdx == nil then
                        savedDraft = buf
                        navIdx = #promptHistory
                    elseif navIdx > 1 then
                        navIdx = navIdx - 1
                    end
                    buf = promptHistory[navIdx]
                    pos = #buf + 1
                    clampInputScroll()
                    redrawInput()
                end

            elseif p1 == keys.down then
                -- Move toward newer prompts; past the newest, restore the draft.
                if navIdx ~= nil then
                    navIdx = navIdx + 1
                    if navIdx > #promptHistory then
                        navIdx = nil
                        buf = savedDraft or ""
                    else
                        buf = promptHistory[navIdx]
                    end
                    pos = #buf + 1
                    clampInputScroll()
                    redrawInput()
                end

            elseif p1 == keys.pageUp then
                scrollOff = math.min(scrollOff + CHAT_HEIGHT, math.max(0, #lineBuf - CHAT_HEIGHT))
                renderChat()
                term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)

            elseif p1 == keys.pageDown then
                scrollOff = math.max(0, scrollOff - CHAT_HEIGHT)
                renderChat()
                term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
            end

        elseif ev == "key_up" then
            if p1 == keys.leftCtrl or p1 == keys.rightCtrl then
                ctrlHeld = false
            end

        elseif ev == "mouse_click" then
            -- p1=button, p2=col, p3=row
            if p1 == 1 then
                local li = screenRowToBufLine(p3)
                if li then
                    local t = lineText(li)
                    local ch = math.max(0, math.min(p2 - 1, math.max(0, #t - 1)))
                    selA = {li, ch}
                    selB = {li, ch}
                    renderChat()
                    term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
                else
                    clearSel()
                end
            end

        elseif ev == "mouse_drag" then
            -- p1=button, p2=col, p3=row
            if p1 == 1 and selA then
                local li = screenRowToBufLine(p3)
                if li then
                    local t = lineText(li)
                    local ch = math.max(0, math.min(p2 - 1, math.max(0, #t - 1)))
                    selB = {li, ch}
                    renderChat()
                    term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
                end
            end

        elseif ev == "mouse_scroll" then
            -- p1: -1 = up (show older), 1 = down (show newer)
            scrollOff = math.max(0, math.min(scrollOff - p1, math.max(0, #lineBuf - CHAT_HEIGHT)))
            renderChat()
            term.setCursorPos(2 + (pos - inputScroll), INPUT_ROW)
        end
    end
end

-- ─── Header ───────────────────────────────────────────────────────────────────
local function renderHeader()
    term.setCursorPos(1, 1)
    bg(colours.black)
    col(C.cyan)
    term.clearLine()
    term.write("Claude Shell")
    -- Token usage indicator (right-aligned)
    if lastInputTokens > 0 then
        local warn = lastInputTokens >= AUTO_COMPACT_THRESHOLD
        local label
        if lastRatelimitLeft >= 0 then
            label = string.format("[%dk/%dk left]",
                math.floor(lastInputTokens/1000), math.floor(lastRatelimitLeft/1000))
        else
            label = string.format("[%dk tokens]", math.floor(lastInputTokens/1000))
        end
        col(warn and C.red or C.grey)
        term.setCursorPos(w - #label + 1, 1)
        term.write(label)
    end
    col(C.grey)
    term.setCursorPos(#"Claude Shell" + 2, 1)
    term.write("(PgUp/PgDn or scroll to navigate, Ctrl+T quits)")
    term.setCursorPos(1, 2)
    col(C.grey)
    term.clearLine()
    term.write(("─"):rep(w))

    term.setCursorPos(1, SEP_ROW)
    term.clearLine()
    term.write(("─"):rep(w))
    col(C.white)
end

-- ─── Slash commands ──────────────────────────────────────────────────────────
local function handleClear()
    history = {}
    saveHistory()
    lineBuf = {}
    scrollOff = 0
    renderHeader()
    renderChat()
    pushBlank()
    pushLine("History cleared.", C.grey)
    pushBlank()
    newContent()
end

local function handleCompact()
    if #history == 0 then
        pushLine("Nothing to compact yet.", C.grey)
        newContent()
        return
    end

    pushLine("Compacting...", C.grey)
    newContent()

    -- Build a one-shot request: existing history + summary prompt, no tools
    local req = {}
    for _, m in ipairs(history) do req[#req+1] = m end
    req[#req+1] = {
        role    = "user",
        content = "Summarise our conversation so far in 3-5 sentences. " ..
                  "Capture key facts about this computer, tasks completed, outcomes, " ..
                  "and anything needed to continue naturally. Be concise.",
    }
    claudecc.ask(textutils.serialiseJSON(req), nil, ENV_CONTEXT)  -- no tools arg

    local summary, summaryBuf = nil, ""
    while true do
        local ev, a = os.pullEventRaw()
        if ev == "terminate" then return end
        if ev == "claude_chunk" then
            summaryBuf = summaryBuf .. (a or "")
        elseif ev == "claude_response" then
            summary = a ~= "" and a or summaryBuf
            break
        elseif ev == "claude_error" then
            pushLine("Compact failed: " .. tostring(a), C.red)
            newContent()
            return
        end
    end

    if not summary or summary == "" then return end

    local before = #history
    history = {
        {role = "user",      content = "[Conversation summary]: " .. summary},
        {role = "assistant", content = "Got it, I have the context from our previous conversation."},
    }
    saveHistory()

    -- Replace the "Compacting..." line with the result
    if lineBuf[#lineBuf] then table.remove(lineBuf) end
    pushLine("✓ Compacted " .. before .. " messages into summary.", C.grey)
    newContent()
end

local COMMANDS = {
    compact = handleCompact,
    clear   = handleClear,
    help    = function()
        pushLine("Commands: /compact  /clear  /help", C.grey)
        newContent()
    end,
}

-- ─── Main ─────────────────────────────────────────────────────────────────────
term.clear()
renderHeader()
renderChat()

col(C.lightGrey)
pushBlank()
pushLine("Hello! I have access to your filesystem and Lua APIs.", C.lightGrey)
if pastCount > 0 then
    pushLine("Resuming — " .. pastCount .. " messages from last session loaded.", C.grey)
end
pushLine("Ask me anything, or say 'read /startup.lua' to get started.", C.lightGrey)
pushBlank()
newContent()

local _ok, _err = xpcall(function()
    local taheadBuf, taheadPos = "", 1  -- partial input saved from concurrent typing
    local pendingMsg = nil              -- complete message queued while Claude was responding

    while true do
        local input
        if pendingMsg then
            input, pendingMsg = pendingMsg, nil
        else
            input = readline(taheadBuf ~= "" and taheadBuf or nil,
                             taheadBuf ~= "" and taheadPos or nil)
            taheadBuf, taheadPos = "", 1
        end

        if input == nil then break end
        if input ~= "" then
            recordPrompt(input)
            local cmd = input:match("^/(%S*)$")
            if cmd ~= nil then
                local fn = COMMANDS[cmd:lower()]
                if fn then
                    fn()
                else
                    pushLine("Unknown command: /" .. cmd .. "  (try /help)", C.red)
                    newContent()
                end
            else
                pushBlank()
                pushLine("> " .. input, C.yellow)
                pushLine("...", C.lightGrey)
                newContent()

                local ta = {buf = "", pos = 1, entered = false}
                parallel.waitForAny(
                    function() agentChat(input) end,
                    function() captureTyping(ta) end
                )

                -- Auto-compact if context is getting large
                if lastInputTokens >= AUTO_COMPACT_THRESHOLD then
                    pushBlank()
                    pushLine("↻ Auto-compacting (" .. lastInputTokens .. " input tokens)…", C.grey)
                    newContent()
                    handleCompact()
                end

                if ta.entered and ta.buf ~= "" then
                    pendingMsg = ta.buf        -- queue for next loop iteration
                elseif ta.buf ~= "" then
                    taheadBuf = ta.buf         -- pre-fill next readline
                    taheadPos = ta.pos
                end
            end
        end
    end
end, function(e)
    log("CRASH: " .. tostring(e))
    return e
end)

-- Cleanup
if _logFile then _logFile.close() end
term.setCursorPos(1, h)
term.clearLine()
if not _ok then
    col(C.red)
    print("Crashed! Error saved to claude_debug.log")
    print(tostring(_err))
end
col(C.lightGrey)
print("Goodbye!")
col(C.white)
