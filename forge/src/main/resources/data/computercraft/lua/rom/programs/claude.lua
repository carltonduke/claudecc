-- Claude AI interactive shell for CC: Tweaked
-- Requires an operator to run /claudecc api <key> before use.

if not claudecc then
    error("The claudecc API is not available on this computer.", 0)
end

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

-- Return the plain text of lineBuf[i] (all segment texts concatenated).
local function lineText(i)
    if not lineBuf[i] then return "" end
    local t = {}
    for _, seg in ipairs(lineBuf[i]) do t[#t+1] = seg[1] end
    return table.concat(t)
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
})

-- ─── Tool executor ───────────────────────────────────────────────────────────
local function execTool(name, input)
    if name == "read_file" then
        local path = input.path
        if not fs.exists(path)  then return "Error: not found: " .. path end
        if fs.isDir(path)       then return "Error: is a directory, use list_dir" end
        local ok, res = pcall(function()
            local f = fs.open(path, "r")
            local s = f.readAll(); f.close(); return s
        end)
        return ok and res or ("Error: " .. res)

    elseif name == "write_file" then
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
        local api = _G[input.api]
        if not api then return "Error: API '" .. input.api .. "' not found." end
        if type(api) ~= "table" then return "'" .. input.api .. "' is not a table." end
        local methods = {}
        for k, v in pairs(api) do
            if type(v) == "function" then table.insert(methods, k) end
        end
        table.sort(methods)
        return textutils.serialiseJSON(methods)

    else
        return "Error: unknown tool '" .. name .. "'"
    end
end

-- ─── Agentic loop ────────────────────────────────────────────────────────────
local history = {}

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
    table.insert(history, {role = "user", content = userInput})
    claudecc.ask(textutils.serialiseJSON(history), TOOLS_JSON)

    local streamStart = nil  -- lineBuf index where the streaming response begins
    local streamBuf   = ""   -- accumulated text received via claude_chunk

    local function finishStream()
        if streamStart then
            while #lineBuf >= streamStart do table.remove(lineBuf) end
            streamStart, streamBuf = nil, ""
        end
    end

    while true do
        local ev, a, b, c, d = os.pullEvent()

        if ev == "claude_chunk" then
            -- a = incremental text delta from the streaming API
            if not streamStart then streamStart = #lineBuf + 1 end
            streamBuf = streamBuf .. a
            while #lineBuf >= streamStart do table.remove(lineBuf) end
            pushPlainText(streamBuf)
            newContent()

        elseif ev == "claude_response" then
            -- a = full response text (sent after all chunks)
            finishStream()
            if a and a ~= "" then
                pushMarkdown(a)
                table.insert(history, {role = "assistant", content = a})
            end
            newContent()
            return true

        elseif ev == "claude_tool_use" then
            -- a=textBefore, b=toolId, c=toolName, d=inputJson
            finishStream()
            local textBefore, toolId, toolName, inputJson = a, b, c, d
            local input = textutils.unserialiseJSON(inputJson) or {}

            if textBefore and textBefore ~= "" then
                pushMarkdown(textBefore)
            end
            pushLine("↳ " .. toolName, C.purple)
            newContent()

            local result = execTool(toolName, input)

            -- Build assistant content array (text + tool_use)
            local assistantContent = {}
            if textBefore and textBefore ~= "" then
                table.insert(assistantContent, {type = "text", text = textBefore})
            end
            table.insert(assistantContent, {type = "tool_use", id = toolId, name = toolName, input = input})
            table.insert(history, {role = "assistant", content = assistantContent})

            -- Tool result
            table.insert(history, {
                role = "user",
                content = {{type = "tool_result", tool_use_id = toolId, content = result}},
            })

            pushLine("  ✓ done", C.grey)
            newContent()

            claudecc.ask(textutils.serialiseJSON(history), TOOLS_JSON)
            streamStart, streamBuf = nil, ""

        elseif ev == "claude_error" then
            finishStream()
            pushLine("Error: " .. tostring(a), C.red)
            newContent()
            return false
        end
    end
end

-- ─── Custom readline (supports scroll, mouse selection, copy/paste) ──────────
local function readline()
    local buf      = ""
    local pos         = 1  -- 1-indexed insert position
    local inputScroll = 0  -- chars scrolled off the left of the input view
    local ctrlHeld    = false

    local function clampInputScroll()
        local visibleW = w - 2
        if pos <= inputScroll then
            inputScroll = pos - 1
        elseif pos > inputScroll + visibleW then
            inputScroll = pos - visibleW
        end
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
                return buf

            elseif ctrlHeld and p1 == keys.c and selA then
                claudecc.copyToClipboard(getSelectedText())

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

-- ─── Main ─────────────────────────────────────────────────────────────────────
term.clear()
renderHeader()
renderChat()

col(C.lightGrey)
pushBlank()
pushLine("Hello! I have access to your filesystem and Lua APIs.", C.lightGrey)
pushLine("Ask me anything, or say 'read /startup.lua' to get started.", C.lightGrey)
pushBlank()
newContent()

while true do
    local input = readline()
    if input == nil then break end
    if input ~= "" then
        -- Show the user's message in the chat area
        pushBlank()
        pushLine("> " .. input, C.yellow)
        pushLine("...", C.lightGrey)
        newContent()

        -- Clear the "thinking" indicator after response
        agentChat(input)
        -- Remove the "..." line (last pushed before agentChat added content)
        -- Actually just leave it; the response follows naturally
    end
end

-- Cleanup
term.setCursorPos(1, h)
term.clearLine()
col(C.lightGrey)
print("Goodbye!")
col(C.white)
