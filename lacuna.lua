--- lacuna.lua
--- A second opinion on your prompt, from a global hotkey, in any app.
---
--- Select a draft prompt anywhere on macOS, press the hotkey, and instead of
--- silently rewriting your text this shows what the model on the other end
--- cannot know: a verdict, a rewritten prompt where facts only you have are
--- left as [slots], and short notes. Your text is never touched.
---
--- When the hotkey is pressed inside the Claude desktop app or a terminal, the
--- right Claude Code session transcript is attached from disk, so a reply in an
--- ongoing project is judged as a reply and not as a cold first message.
---
--- Requires Hammerspoon and an OpenRouter API key. MIT licensed.
--- https://github.com/Seryozh/lacuna

local M = {}

M.name = "Lacuna"
M.version = "1.0.0"
M.license = "MIT"

-- ---------------------------------------------------------------- config

local HOME = os.getenv("HOME")

local function expand(path)
  if not path then return nil end
  return (path:gsub("^~", HOME))
end

M.config = {
  -- any OpenAI-compatible chat completions endpoint works
  endpoint = "https://openrouter.ai/api/v1/chat/completions",
  model = "anthropic/claude-sonnet-5",

  -- the key is looked up in this order: config.apiKey, the environment
  -- variable, then each file in apiKeyFiles (a bare key, or KEY=value lines)
  apiKey = nil,
  apiKeyEnv = "OPENROUTER_API_KEY",
  apiKeyFiles = { "~/.config/lacuna/key", "~/.config/lacuna/.env", "~/.env" },

  hotkey = { mods = { "ctrl" }, key = "2" },

  -- reasoning is off on purpose: it made the same answer three times slower
  -- and four times more expensive with no visible gain for this task
  reasoning = false,

  -- when nothing is selected, select the focused field first (never edits it)
  autoSelectWhenEmpty = true,

  -- attach the tail of the matching Claude Code session when pressed in these
  -- apps; set to false to switch context off entirely
  sessionContext = true,
  sessionApps = { "Claude", "Claude Code", "Terminal", "iTerm2", "Ghostty", "Warp", "kitty", "Alacritty" },
  historyMessages = 12,
  historyMessageChars = 600,

  maxChars = 20000,
  requestTimeout = 75, -- seconds before giving up and showing an error
  logFile = "~/.hammerspoon/lacuna.log",
  -- every answer, and every edit you make to one, is appended here, so a
  -- window you closed or replaced can always be read back
  historyFile = "~/.config/lacuna/history.jsonl",
  configFile = "~/.config/lacuna/config.json",
}

-- merge a json config file over the defaults, so users never edit this file
local function loadConfigFile()
  local path = expand(M.config.configFile)
  local f = io.open(path, "r")
  if not f then return end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then
    print("[lacuna] ignoring unreadable config at " .. path)
    return
  end
  for k, v in pairs(data) do M.config[k] = v end
end

-- ---------------------------------------------------------------- log

local function log(line)
  local f = io.open(expand(M.config.logFile), "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n")
    f:close()
  end
end

-- Nothing shown in the window is ever only in the window. Answers are written
-- here when they arrive, and again with your edits before anything replaces
-- them, because losing text you were in the middle of editing is unforgivable.
local function remember(kind, fields)
  local path = expand(M.config.historyFile)
  hs.execute("mkdir -p '" .. path:match("^(.*)/[^/]*$") .. "'")
  local f = io.open(path, "a")
  if not f then return end
  fields.kind = kind
  fields.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local ok, line = pcall(hs.json.encode, fields)
  if ok then f:write(line .. "\n") end
  f:close()
end
M.remember = remember

function M.historyPath()
  return expand(M.config.historyFile)
end

-- ---------------------------------------------------------------- api key

local function readKey()
  if M.config.apiKey and #M.config.apiKey > 0 then return M.config.apiKey end

  local fromEnv = M.config.apiKeyEnv and os.getenv(M.config.apiKeyEnv)
  if fromEnv and #fromEnv > 0 then return fromEnv end

  for _, path in ipairs(M.config.apiKeyFiles or {}) do
    local f = io.open(expand(path), "r")
    if f then
      local pattern = "^" .. (M.config.apiKeyEnv or "OPENROUTER_API_KEY") .. "%s*=%s*(.+)$"
      for line in f:lines() do
        local v = line:match(pattern) or (line:match("^sk%-") and line)
        if v then
          f:close()
          return (v:gsub('^["\']', ''):gsub('["\']%s*$', ''):gsub("%s+$", ""))
        end
      end
      f:close()
    end
  end
  return nil
end

-- ---------------------------------------------------------- session context

-- Which session gets attached: the window title is matched against the session
-- list the Claude app keeps for itself, and otherwise the session you last had
-- open wins. Picking "the most recently written transcript" is wrong, because
-- that is always the session an agent is working in, not the one you type into.
local SESSION_STORE = HOME .. "/Library/Application Support/Claude/claude-code-sessions"
local PROJECTS_DIR = HOME .. "/.claude/projects"
local GENERIC_TITLES = { [""] = true, ["claude"] = true, ["claude code"] = true }

-- Only the newest few session files are read: lastFocusedAt tracks mtime
-- closely, so the session you are typing into is always in this slice, and
-- parsing forty small files is instant.
local function pickSession(winTitle)
  local listing = hs.execute("ls -t '" .. SESSION_STORE .. "'/*/*/*.json 2>/dev/null | head -40")
  local sessions = {}
  for path in (listing or ""):gmatch("[^\n]+") do
    local f = io.open(path, "r")
    if f then
      local ok, data = pcall(hs.json.decode, f:read("*a"))
      f:close()
      if ok and type(data) == "table" and data.cliSessionId and not data.isArchived then
        table.insert(sessions, {
          cli = data.cliSessionId,
          title = (data.title or ""):gsub("^%s+", ""):gsub("%s+$", ""),
          focus = data.lastFocusedAt or 0,
        })
      end
    end
  end
  if #sessions == 0 then return nil, "no Claude Code sessions on disk" end

  local chosen, why = nil, nil
  local wanted = (winTitle or ""):lower()
  if not GENERIC_TITLES[wanted] then
    for _, s in ipairs(sessions) do
      if s.title:lower() == wanted and (not chosen or s.focus > chosen.focus) then
        chosen, why = s, "by window title"
      end
    end
  end
  if not chosen then
    for _, s in ipairs(sessions) do
      if not chosen or s.focus > chosen.focus then chosen = s end
    end
    why = "last session you opened"
  end

  local label = (chosen.title ~= "" and chosen.title) or chosen.cli:sub(1, 8)
  local found = hs.execute("ls '" .. PROJECTS_DIR .. "'/*/'" .. chosen.cli .. "'.jsonl 2>/dev/null | head -1")
  found = (found or ""):gsub("%s+$", "")
  if found == "" then return nil, 'no transcript on disk for session "' .. label .. '"' end

  local attr = hs.fs.attributes(found)
  local ageMin = attr and math.floor((os.time() - attr.modification) / 60) or 9999
  if ageMin > 360 then
    return nil, string.format('session "%s" has been quiet for %d min, not attached', label, ageMin)
  end
  return { jsonl = found, title = label, ageMin = ageMin, why = why }
end

local function sessionTail(appName, winTitle)
  if not M.config.sessionContext then return nil, "session context is off" end

  local allowed = false
  for _, name in ipairs(M.config.sessionApps or {}) do
    if name == appName then allowed = true break end
  end
  if not allowed then
    return nil, "no Claude Code sessions in " .. tostring(appName)
  end

  if not hs.fs.attributes(SESSION_STORE) then
    return nil, "the Claude desktop app session list was not found"
  end

  local pick, why = pickSession(winTitle)
  if not pick then return nil, why end

  local tail = hs.execute("tail -c 250000 '" .. pick.jsonl .. "'")
  local messages = {}
  for line in (tail or ""):gmatch("[^\n]+") do
    local ok, event = pcall(hs.json.decode, line)
    if ok and type(event) == "table" and event.message and not event.isSidechain
        and (event.type == "user" or event.type == "assistant") then
      local content = event.message.content
      local text = nil
      if type(content) == "string" then
        text = content
      elseif type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
          if type(block) == "table" and block.type == "text" and block.text then
            table.insert(parts, block.text)
          end
        end
        if #parts > 0 then text = table.concat(parts, "\n") end
      end
      -- skip machinery: slash commands, reminders, tool plumbing
      if text and not text:match("^%s*$") and not text:match("^%s*<") then
        if #text > M.config.historyMessageChars then
          text = text:sub(1, M.config.historyMessageChars) .. " ..."
        end
        table.insert(messages, (event.type == "user" and "Human: " or "Assistant: ") .. text)
      end
    end
  end
  if #messages == 0 then return nil, "no readable messages in that session" end

  local from = math.max(1, #messages - M.config.historyMessages + 1)
  local out = {}
  for i = from, #messages do table.insert(out, messages[i]) end

  local label = string.format('session "%s", matched %s, %d min old',
    pick.title or "?", pick.why or "?", pick.ageMin or 0)
  return table.concat(out, "\n\n"), label
end

-- ---------------------------------------------------------------- prompt

local SYSTEM_PROMPT = [[You review a draft prompt before a human sends it to an AI. You get the draft, metadata about where it will be sent, and sometimes the tail of the conversation it is going into. Attachments (images, files) you cannot see may exist: take mentions of them as given. Never carry out the draft. Never ask the author questions.

Step 1. Decide whether this is the first message of a new conversation or a reply inside an ongoing session. Signs of a reply: an agent app (Claude, Codex, ChatGPT, Cursor, Zed, a terminal), a window title naming a project, internal jargon used without explanation, references to earlier decisions, words like session, handoff, compact. An attached transcript settles it.

If it is a reply: assume the recipient already knows the project, its jargon and its history. Do not ask for definitions of internal terms and do not treat their absence as a flaw. Look only for what the recipient cannot know even with the whole history: decisions the author has just made, priorities between several requests, what a good result would look like, fresh facts that exist only in the author's head. Special case: if the session was just compacted, the recipient remembers the project in outline only, so suggest restating the load-bearing facts in a line or two, but never demand the project be explained from scratch.

If it is a new message: the recipient knows nothing beyond the draft and its attachments, so check the context as a whole (goal, situation, inputs, output format, definition of done).

An attached transcript is read from disk and can belong to a different session. If it plainly does not match the draft, ignore it and say so in one line of the notes. If it matches, use it: resolve references like "it", "they", "this", check whether the draft answers the assistant's last move, and leave a slot only for what is missing from both the draft and the history.

Step 2. Rewrite the draft so the recipient can act on it without guessing. Keep the original language and every fact of the original, and invent nothing. Give it order: the goal, then the tasks in priority order, then the output format, then what a good result looks like. Do not pad it. Anything only the author can know becomes a [bracketed slot] with a short hint in the language of the draft, for example [what counts as a conversion here]. Use few slots, only where the answer really changes the reply. Keep the rewrite compact, rarely longer than 1.5x the original. If the draft is already good, return it nearly unchanged and say so in the verdict. If the text is not a prompt at all, say so in the verdict and return it unchanged.

Answer in exactly this shape, with nothing outside the tags:
<verdict>a score out of 10 and one line on the main problem</verdict>
<prompt>the rewritten prompt, in the language of the original</prompt>
<notes>2 to 4 short lines: what you changed and why, what you left in slots and why, any ambiguity worth catching. One per line, no bullets</notes>

Write the verdict and the notes in the same language as the draft. Be brief and concrete. Never use an em dash, use a comma, a colon or parentheses instead.]]

-- ---------------------------------------------------------------- window

local view = nil          -- the single reusable webview
local currentRun = nil    -- { cancelled = bool, pending = bool }
local lastPrompt = nil
local editWatcher = nil   -- keeps whatever you are typing on disk
local lastSavedEdit = nil

local function stopEditWatch()
  if editWatcher then
    editWatcher:stop()
    editWatcher = nil
  end
end

-- while an answer is on screen, whatever you type into it is written to the
-- history file every few seconds, so closing or replacing the window is safe
local function startEditWatch()
  stopEditWatch()
  lastSavedEdit = lastPrompt
  editWatcher = hs.timer.doEvery(3, function()
    if not view then return stopEditWatch() end
    view:evaluateJavaScript(
      "var b = document.getElementById('prompt-box'); b ? b.innerText : ''",
      function(text)
        if type(text) == "string" and #text > 0 and text ~= lastSavedEdit then
          lastSavedEdit = text
          remember("edit", { prompt = text })
        end
      end)
  end)
end

local function closeWindow()
  stopEditWatch()
  if currentRun and currentRun.pending then
    currentRun.cancelled = true
    log("CANCELLED by user")
  end
  if view then
    view:delete()
    view = nil
    M.view = nil
  end
end

-- url events arrive lower-cased from macOS, so the names must be lower-case
hs.urlevent.bind("lacunaclose", closeWindow)

hs.urlevent.bind("lacunacopy", function()
  if view then
    view:evaluateJavaScript("document.getElementById('prompt-box').innerText", function(result)
      local text = (type(result) == "string" and #result > 0) and result or lastPrompt
      if text then
        hs.pasteboard.setContents(text)
        if view then view:evaluateJavaScript("window.copied && window.copied()") end
      end
    end)
  elseif lastPrompt then
    hs.pasteboard.setContents(lastPrompt)
  end
end)

local function escapeHtml(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local PAGE_CSS = [[
  :root { color-scheme: light dark;
    --bg: #f7f6f3; --fg: #1e1e1e; --muted: rgba(30,30,30,.55);
    --panel: rgba(120,120,120,.12); --line: rgba(120,120,120,.35);
    --slot: #b3591f; --bad: #b3402a; --accent: #3d7f6f; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #1d1d1c; --fg: #e8e6e1; --muted: rgba(232,230,225,.55);
      --panel: rgba(160,160,160,.12); --line: rgba(160,160,160,.28);
      --slot: #eda35c; --bad: #e06c50; --accent: #7fc0ac; }
  }
  * { box-sizing: border-box; }
  body { font: 15px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif;
         margin: 0; background: var(--bg); color: var(--fg); }
  .pad { padding: 20px 24px 0; }
  .verdict { font-weight: 600; padding: 20px 24px 0; }
  .verdict.bad { color: var(--bad); }
  .prompt { margin: 14px 24px 0; padding: 14px 16px; border-radius: 10px;
            background: var(--panel); white-space: pre-wrap; word-wrap: break-word; }
  .prompt:focus { outline: 1.5px solid var(--line); }
  .slot { font-weight: 600; color: var(--slot); }
  .row { display: flex; align-items: center; gap: 10px; margin: 12px 24px 0; }
  button { padding: 7px 14px; font: 13px -apple-system, system-ui, sans-serif;
           border: 1px solid var(--line); border-radius: 8px; background: transparent;
           color: inherit; cursor: pointer; }
  button:hover { background: var(--panel); }
  .said { font-size: 12.5px; color: var(--accent); opacity: 0; transition: opacity .15s; }
  .said.on { opacity: 1; }
  .notes { padding: 14px 24px 0; white-space: pre-wrap; word-wrap: break-word;
           color: var(--muted); font-size: 13.5px; }
  .meta { padding: 12px 24px 0; font-size: 12px; color: var(--muted); }
  details { margin: 8px 24px 0; font-size: 12.5px; }
  summary { cursor: pointer; color: var(--muted); }
  .sent { margin-top: 8px; padding: 10px 12px; border-radius: 8px; background: var(--panel);
          white-space: pre-wrap; word-wrap: break-word; font-size: 12px; }
  .hint { padding: 14px 24px 18px; font-size: 12px; color: var(--muted); }

  /* loading state */
  .load { padding: 26px 24px 0; font-size: 15px; }
  .bar { height: 3px; margin: 16px 24px 0; border-radius: 3px; background: var(--panel);
         overflow: hidden; position: relative; }
  .bar i { position: absolute; inset: 0; width: 38%; border-radius: 3px;
           background: var(--accent); opacity: .75; animation: slide 1.1s ease-in-out infinite; }
  @keyframes slide { 0% { left: -40%; } 100% { left: 100%; } }
  .draft { margin: 16px 24px 0; padding: 12px 14px; border-radius: 10px; background: var(--panel);
           color: var(--muted); font-size: 13px; max-height: 220px; overflow: hidden;
           white-space: pre-wrap; word-wrap: break-word; }
]]

local PAGE_JS = [[
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") window.location = "hammerspoon://lacunaclose";
  });
  window.copied = function () {
    var el = document.getElementById("said");
    if (!el) return;
    el.classList.add("on");
    setTimeout(function () { el.classList.remove("on"); }, 1400);
  };
  var t = document.getElementById("timer");
  if (t) {
    var n = 0;
    setInterval(function () { n += 1; t.textContent = n + "s"; }, 1000);
  }
  // AppKit scrolls the first focusable element into view on open; stay at the top
  setTimeout(function () { window.scrollTo(0, 0); }, 60);
]]

local function pageHtml(inner)
  return '<!doctype html><meta charset="utf-8"><style>' .. PAGE_CSS .. '</style>'
      .. inner .. '<script>' .. PAGE_JS .. '</script>'
end

-- the window is small while it waits and grows for the answer, so a short
-- reply never sits in a tall empty box
local function render(inner, wantedHeight)
  local html = pageHtml(inner)
  local screen = hs.screen.mainScreen():frame()
  local w = 680
  local h = math.min(wantedHeight or 740, math.floor(screen.h * 0.82))

  if view then
    view:html(html)
    local f = view:frame()
    if math.abs(f.h - h) > 8 then
      view:frame({ x = f.x, y = math.max(screen.y + 40, f.y - (h - f.h) / 2), w = f.w, h = h })
    end
    return
  end

  local rect = hs.geometry.rect(screen.x + (screen.w - w) / 2,
                                screen.y + (screen.h - h) / 2, w, h)

  view = hs.webview.new(rect)
      :windowStyle({ "titled", "closable", "resizable" })
      :windowTitle("Lacuna")
      :allowTextEntry(true)
      :deleteOnClose(true)
      :windowCallback(function(action)
        if action == "closing" then
          stopEditWatch()
          if currentRun and currentRun.pending then
            currentRun.cancelled = true
            log("CANCELLED by user")
          end
          view = nil
          M.view = nil
        end
      end)
      :html(html)
      :show()
      :bringToFront()
  M.view = view

  hs.timer.doAfter(0.15, function()
    if view and view:hswindow() then view:hswindow():focus() end
  end)
end

local function showLoading(draft, contextLine)
  local preview = draft
  if #preview > 700 then preview = preview:sub(1, 700) .. " ..." end
  local lines = math.min(8, math.ceil(#preview / 78))
  render(
    '<div class="load">Reading your prompt <span id="timer">0s</span></div>'
    .. '<div class="bar"><i></i></div>'
    .. '<div class="meta">' .. escapeHtml(contextLine) .. '</div>'
    .. '<div class="draft">' .. escapeHtml(preview) .. '</div>'
    .. '<div class="hint">Esc cancels.</div>',
    200 + lines * 22
  )
end

-- errors are never silent: an error window, and if even that fails, an alert
-- and a system notification, plus a line in the log
local function showError(message, detail)
  log("ERROR " .. message .. (detail and (" | " .. tostring(detail):sub(1, 300)) or ""))
  local inner = '<div class="verdict bad">' .. escapeHtml(message) .. '</div>'
  if detail and #tostring(detail) > 0 then
    inner = inner .. '<details open><summary>Details</summary><div class="sent">'
        .. escapeHtml(tostring(detail):sub(1, 4000)) .. '</div></details>'
  end
  inner = inner .. '<div class="hint">Log: ' .. escapeHtml(M.config.logFile) .. '. Esc closes.</div>'

  local ok = pcall(render, inner)
  if ok and view then
    log("error window shown")
  else
    log("error window FAILED to render")
    hs.alert.show("Lacuna: " .. message, 6)
    local n = hs.notify.new({ title = "Lacuna failed", informativeText = message })
    if n then n:send() end
  end
end
M.showError = showError

local function showResult(answer, info)
  local verdict = answer:match("<verdict>%s*(.-)%s*</verdict>")
  local prompt = answer:match("<prompt>%s*(.-)%s*</prompt>")
  local notes = answer:match("<notes>%s*(.-)%s*</notes>")

  local meta = ""
  if info then
    local bits = {}
    if info.cost then table.insert(bits, string.format("$%.4f", info.cost)) end
    if info.inTok and info.outTok then
      table.insert(bits, info.inTok .. " in, " .. info.outTok .. " out")
    end
    if info.secs then table.insert(bits, string.format("%.0fs", info.secs)) end
    if info.model then table.insert(bits, info.model) end
    if #bits > 0 then
      meta = '<div class="meta">' .. escapeHtml(table.concat(bits, "  ·  ")) .. '</div>'
    end
    if info.context then
      -- the attached session is shown, so a wrong match is obvious at a glance
      meta = meta .. '<div class="meta">Context: ' .. escapeHtml(info.context) .. '</div>'
    end
    if info.request then
      meta = meta .. '<details><summary>What was sent</summary><div class="sent">'
          .. escapeHtml(info.system or "") .. "\n\n"
          .. escapeHtml(info.request) .. '</div></details>'
    end
  end

  if verdict and prompt then
    lastPrompt = prompt
    local body = escapeHtml(prompt):gsub("%[([^%]\n]-)%]", '<span class="slot">[%1]</span>')
    render(
      '<div class="verdict">' .. escapeHtml(verdict) .. '</div>'
      .. '<div class="prompt" id="prompt-box" contenteditable="true" spellcheck="false">' .. body .. '</div>'
      .. '<div class="row"><button tabindex="-1" onclick="window.location=\'hammerspoon://lacunacopy\'">Copy prompt</button>'
      .. '<span class="said" id="said">copied</span></div>'
      .. (notes and ('<div class="notes">' .. escapeHtml(notes) .. '</div>') or '')
      .. meta
      .. '<div class="hint">Fill the [slots], edit anything here, then copy. Everything here is'
      .. ' saved to ' .. escapeHtml(M.config.historyFile) .. '. Esc closes.</div>'
    )
    remember("answer", { verdict = verdict, prompt = prompt, notes = notes,
                         model = info and info.model, context = info and info.context })
    startEditWatch()
  else
    lastPrompt = nil
    render(
      '<div class="verdict">The model answered off-format, showing it raw</div>'
      .. '<div class="prompt" id="prompt-box">' .. escapeHtml(answer) .. '</div>'
      .. meta .. '<div class="hint">Esc closes.</div>'
    )
    remember("raw", { answer = answer })
  end
end

-- an answer on screen may be one you are editing, so it is written down before
-- anything is allowed to replace it
local function replacingOpenAnswer(continue)
  if not (view and lastPrompt) then return continue() end
  local went = false
  local function go()
    if went then return end
    went = true
    continue()
  end
  view:evaluateJavaScript(
    "var b = document.getElementById('prompt-box'); b ? b.innerText : ''",
    function(text)
      if type(text) == "string" and #text > 0 and text ~= lastSavedEdit then
        remember("edit", { prompt = text })
        log("saved the answer that was open before replacing it")
      end
      go()
    end)
  hs.timer.doAfter(0.4, go)
end

-- ---------------------------------------------------------------- request

function M.check(text, appName, winTitle)
  loadConfigFile()

  local key = readKey()
  if not key then
    showError("No API key found",
      "Looked at config.apiKey, the " .. tostring(M.config.apiKeyEnv) .. " environment variable, and: "
      .. table.concat(M.config.apiKeyFiles or {}, ", ")
      .. "\n\nPut your OpenRouter key in ~/.config/lacuna/key or set it in the config file.")
    return
  end

  if #text > M.config.maxChars then
    text = text:sub(1, M.config.maxChars) .. "\n\n[cut off: longer than " .. M.config.maxChars .. " characters]"
  end

  local history, contextNote = sessionTail(appName, winTitle)
  local contextLine = history and ("Context: " .. contextNote) or ("No session context (" .. tostring(contextNote) .. ")")

  local run = { pending = true, cancelled = false }
  currentRun = run
  replacingOpenAnswer(function() showLoading(text, contextLine) end)

  local meta = "Target app: " .. (appName or "unknown")
      .. "\nWindow title: " .. (winTitle or "unknown")
      .. "\nSession transcript: " .. (history and "attached below" or ("not attached (" .. tostring(contextNote) .. ")"))
  local userContent = meta
  if history then
    userContent = userContent .. "\n\nTail of the session transcript from disk ("
        .. contextNote .. "; it may be the wrong session):\n<<<\n" .. history .. "\n>>>"
  end
  userContent = userContent .. "\n\nDraft prompt:\n<<<\n" .. text .. "\n>>>"

  log(string.format("RUN app=%s title=%s chars=%d context=%s",
    tostring(appName), tostring(winTitle), #text, history and "yes" or "no"))

  local started = hs.timer.secondsSinceEpoch()

  -- hs.http has no timeout of its own, so a hung request would otherwise be
  -- the one failure mode you never see
  local watchdog = hs.timer.doAfter(M.config.requestTimeout, function()
    if not run.pending then return end
    run.pending = false
    if run.cancelled then return end
    showError(string.format("No answer in %d seconds", M.config.requestTimeout),
      "The request went out and nothing came back. Usually the network or a stalled provider. Press the hotkey again.")
  end)

  local payload = {
    model = M.config.model,
    max_tokens = 2500,
    usage = { include = true }, -- OpenRouter returns the price of the call
    messages = {
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = userContent },
    },
  }
  if M.config.reasoning == false then payload.reasoning = { enabled = false } end

  hs.http.asyncPost(M.config.endpoint, hs.json.encode(payload), {
    ["Authorization"] = "Bearer " .. key,
    ["Content-Type"] = "application/json",
    ["HTTP-Referer"] = "https://github.com/Seryozh/lacuna",
    ["X-Title"] = "Lacuna",
  }, function(status, response)
    if not run.pending then
      log("LATE response ignored, status=" .. tostring(status))
      return
    end
    run.pending = false
    if watchdog then watchdog:stop() end
    if run.cancelled then
      log("response dropped, window was closed")
      return
    end

    local ok, err = pcall(function()
      if status ~= 200 then
        local why = ({
          [401] = "The API key was rejected",
          [402] = "The OpenRouter account is out of credit",
          [408] = "The request timed out",
          [429] = "Rate limited",
        })[status]
        if not why then
          if status and status >= 500 then why = "OpenRouter or the model provider failed"
          elseif not status or status <= 0 then why = "Could not reach OpenRouter"
          else why = "Unexpected response " .. tostring(status) end
        end
        showError(why .. " (HTTP " .. tostring(status) .. ")", response)
        return
      end

      local decoded, data = pcall(hs.json.decode, response)
      local answer = decoded and data and data.choices and data.choices[1]
          and data.choices[1].message and data.choices[1].message.content
      if not answer then
        showError("The model returned no text", response)
        return
      end

      local info = {
        secs = hs.timer.secondsSinceEpoch() - started,
        model = M.config.model,
        system = SYSTEM_PROMPT,
        request = userContent,
        context = history and contextNote or ("none (" .. tostring(contextNote) .. ")"),
      }
      if data.usage then
        info.inTok = data.usage.prompt_tokens
        info.outTok = data.usage.completion_tokens
        info.cost = data.usage.cost
      end
      log(string.format("OK cost=%s in=%s out=%s secs=%.0f",
        tostring(info.cost), tostring(info.inTok), tostring(info.outTok), info.secs))
      showResult(answer, info)
    end)

    if not ok then
      if not pcall(showError, "Something broke while handling the answer", err) then
        hs.alert.show("Lacuna broke: " .. tostring(err), 8)
      end
    end
  end)
end

-- ------------------------------------------------- selection and hotkey

-- Copying is done in steps on timers rather than by sleeping, so the app we
-- are copying from keeps running and nothing freezes while we wait.
local function grabSelection(done)
  local pb = hs.pasteboard
  local saved = pb.getContents()
  local before = pb.changeCount()

  local function finish(text)
    -- always give the clipboard back, the hotkey must not cost you what you copied
    if saved then pb.setContents(saved) else pb.clearContents() end
    done(text)
  end

  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  hs.timer.doAfter(0.2, function()
    local got = (pb.changeCount() ~= before) and pb.getContents() or nil
    if got and not got:match("^%s*$") then return finish(got) end
    if not M.config.autoSelectWhenEmpty then return finish(nil) end

    -- nothing was selected: take the whole field, which only selects, never edits
    hs.eventtap.keyStroke({ "cmd" }, "a", 0)
    hs.timer.doAfter(0.12, function()
      hs.eventtap.keyStroke({ "cmd" }, "c", 0)
      hs.timer.doAfter(0.2, function()
        local text = (pb.changeCount() ~= before) and pb.getContents() or nil
        finish(text)
      end)
    end)
  end)
end

function M.run()
  local app = hs.application.frontmostApplication()
  local appName = app and app:name() or nil
  local win = hs.window.focusedWindow()
  local winTitle = win and win:title() or nil

  grabSelection(function(selection)
    if not selection or selection:match("^%s*$") then
      hs.alert.show("Nothing to check: select your draft first")
      return
    end
    local ok, err = pcall(M.check, selection, appName, winTitle)
    if not ok then
      if not pcall(showError, "Something broke on start", err) then
        hs.alert.show("Lacuna broke: " .. tostring(err), 8)
      end
    end
  end)
end

function M.start(overrides)
  if type(overrides) == "table" then
    for k, v in pairs(overrides) do M.config[k] = v end
  end
  loadConfigFile()
  if M.hotkey then M.hotkey:delete() end
  M.hotkey = hs.hotkey.bind(M.config.hotkey.mods, M.config.hotkey.key, M.run)
  return M
end

return M
