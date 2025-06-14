-- enhanced_player.lua
-- Version 2.1 Enhanced: multiple speaker support, progressive buffer bar, optimized structure

-- APIs
local http = http
local textutils = textutils
local paintutils = paintutils
local term = term
local peripheral = peripheral
local parallel = parallel
local colors = colors
local os = os

-- Configuration
local API_BASE_URL = "https://ipod-2to6aryna-uc.a.run.app/"
local VERSION = "2.1"

-- UI color scheme
local UI = {
  bg          = colors.black,
  tabBg       = colors.gray,
  tabFg       = colors.white,
  tabActiveBg = colors.white,
  tabActiveFg = colors.black,
  text        = colors.white,
  subtext     = colors.lightGray,
  error       = colors.red,
  progressBg  = colors.gray,
  progressFg  = colors.lightGray
}

-- Terminal dimensions
local termW, termH = term.getSize()

-- Global state
local state = {
  tab            = 1,    -- 1=Now Playing, 2=Search
  waiting        = false,
  lastSearch     = nil,
  lastSearchUrl  = nil,
  results        = nil,
  searchError    = false,
  detail         = false,
  selected       = 1,

  playing        = false,
  queue          = {},
  now            = nil,
  loopMode       = 0,    -- 0=off,1=queue,2=song
  volume         = 1.5,  -- 0..3

  playId         = nil,
  downloadUrl    = nil,
  handle         = nil,
  loading        = false,
  error          = false,

  bytesLoaded    = 0,
  bytesTotal     = 0
}

-- Locate speakers
local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
  error("No speakers found! Attach at least one speaker.", 0)
end

-- Draw tabs
local function drawTabs()
  local labels = {" Now Playing ", " Search "}
  for i, label in ipairs(labels) do
    term.setBackgroundColor(state.tab == i and UI.tabActiveBg or UI.tabBg)
    term.setTextColor(state.tab == i and UI.tabActiveFg or UI.tabFg)
    local x = math.floor((termW / #labels) * (i - 0.5)) - math.floor(#label / 2)
    term.setCursorPos(math.max(1, x), 1)
    term.write(label)
  end
end

local function msg(x, y, text, color)
  term.setCursorPos(x, y)
  term.setBackgroundColor(UI.bg)
  term.setTextColor(color or UI.subtext)
  term.clearLine()
  term.write(text)
end

local function drawBar(x1, y, x2, pct)
  paintutils.drawLine(x1, y, x2, y, UI.progressBg)
  local fill = math.floor((x2 - x1) * pct)
  paintutils.drawLine(x1, y, x1 + fill, y, UI.progressFg)
end

-- Draw Now Playing
local function drawNow()
  if state.now then
    msg(2, 3, state.now.name, UI.text)
    msg(2, 4, state.now.artist, UI.subtext)
  else
    msg(2, 3, "Not playing", UI.subtext)
  end
  if state.loading then
    msg(2, 5, "Buffering...", UI.subtext)
  elseif state.error then
    msg(2, 5, "Network error", UI.error)
  end
  if state.playId and state.bytesTotal > 0 then
    drawBar(2, 7, termW - 5, state.bytesLoaded / state.bytesTotal)
    msg(termW - 4, 7, string.format("%d%%", math.floor(state.bytesLoaded / state.bytesTotal * 100)), UI.text)
  end
  -- Controls
  local y, x = 6, 2
  local function btn(label, enabled)
    term.setBackgroundColor(UI.tabBg)
    term.setTextColor(enabled and UI.text or UI.subtext)
    term.setCursorPos(x, y)
    term.write(" " .. label .. " ")
    x = x + #label + 3
  end
  btn(state.playing and "Stop" or "Play", state.now or #state.queue > 0)
  btn("Skip", state.now or #state.queue > 0)
  local loopLabel = state.loopMode == 1 and "Loop Q" or state.loopMode == 2 and "Loop S" or "Loop Off"
  btn(loopLabel, true)
  -- Volume
  drawBar(2, 8, termW - 5, state.volume / 3)
  msg(termW - 4, 8, string.format("%d%%", math.floor(state.volume / 3 * 100)), UI.text)
  -- Queue
  for i, t in ipairs(state.queue) do
    msg(2, 10 + (i-1)*2, t.name, UI.text)
    msg(2, 11 + (i-1)*2, t.artist, UI.subtext)
  end
end

-- Draw Search
local function drawSearch()
  paintutils.drawFilledBox(2,3,termW-1,5,colors.lightGray)
  term.setCursorPos(3,4); term.setBackgroundColor(colors.lightGray); term.setTextColor(colors.black)
  term.write(state.lastSearch or "Search...")
  if state.results then
    for i, r in ipairs(state.results) do
      msg(2,7+(i-1)*2, r.name, UI.text)
      msg(2,8+(i-1)*2, r.artist, UI.subtext)
    end
  else
    if state.searchError then msg(2,7,"Network error",UI.error)
    elseif state.lastSearchUrl then msg(2,7,"Searching...",UI.subtext)
    else msg(2,7,"Tip: paste YouTube links",UI.subtext) end
  end
  if state.detail then
    term.clear(); msg(2,2,state.results[state.selected].name,UI.text);
    msg(2,3,state.results[state.selected].artist,UI.subtext)
    local opts={"Play Now","Play Next","Add to Queue","Cancel"}
    for i,o in ipairs(opts) do msg(2,4+i*2,o,UI.text) end
  end
end

-- Redraw
local function redraw()
  if state.waiting then return end
  term.setCursorBlink(false); term.setBackgroundColor(UI.bg); term.clear();
  term.setCursorPos(1,1); term.setBackgroundColor(UI.tabBg); term.clearLine()
  drawTabs()
  if state.tab==1 then drawNow() else drawSearch() end
end

-- Search
local function doSearch(query)
  state.lastSearch = query
  state.lastSearchUrl = API_BASE_URL .. "?v=" .. VERSION .. "&search=" .. textutils.urlEncode(query)
  state.results = nil; state.searchError = false
  http.request(state.lastSearchUrl)
end

-- Playback
local function startPlayback(item, clearQ)
  state.detail=false
  if clearQ then state.queue={} end
  if item.type=="playlist" then
    state.now = item.playlist_items[1]
    for i=2,#item.playlist_items do table.insert(state.queue,item.playlist_items[i]) end
  else state.now=item end
  state.playId=nil; state.playing=true; state.error=false
  os.queueEvent("audio_update")
end
local function enqueue(item,pos)
  pos = pos or #state.queue+1
  if item.type=="playlist" then for i=#item.playlist_items,1,-1 do table.insert(state.queue,pos,item.playlist_items[i]) end
  else table.insert(state.queue,pos,item) end
end

-- UI loop
local function uiLoop()
  redraw()
  while true do
    if state.waiting then
      term.setCursorBlink(true); term.setCursorPos(3,4)
      term.setBackgroundColor(colors.white); term.setTextColor(colors.black)
      local input = read()
      state.waiting=false
      if #input>0 then doSearch(input) end
      os.queueEvent("redraw")
    else
      local ev,btn,x,y=os.pullEvent("mouse_click")
      if btn==1 then
        if not state.detail and y==1 then state.tab=x<=termW/2 and 1 or 2; redraw() end
        if state.tab==2 then
          if not state.detail and y>=3 and y<=5 then state.waiting=true; redraw() end
          if not state.detail and state.results then
            for i in ipairs(state.results) do local y0=7+(i-1)*2; if y==y0 or y==y0+1 then state.detail=true; state.selected=i; redraw() end end
          elseif state.detail then
            if y==6 then startPlayback(state.results[state.selected],true)
            elseif y==8 then enqueue(state.results[state.selected],1)
            elseif y==10 then enqueue(state.results[state.selected])
            elseif y==12 then state.detail=false
            end; redraw()
          end
        elseif state.tab==1 and not state.detail then
          if y==6 then
            if x>=2 and x<8 then
              if state.playing then state.playing=false; os.queueEvent("audio_update")
              elseif state.now or #state.queue>0 then if not state.now then state.now=table.remove(state.queue,1) end; state.playing=true; os.queueEvent("audio_update") end
            elseif x>=9 and x<15 then
              if state.playing then state.playing=false; os.queueEvent("audio_update") end
              if #state.queue>0 then if state.loopMode==1 then table.insert(state.queue,state.now) end; state.now=table.remove(state.queue,1); state.playId=nil; state.playing=true; os.queueEvent("audio_update") else state.now=nil; state.playing=false; state.playId=nil end
            elseif x>=16 and x<25 then state.loopMode=(state.loopMode+1)%3; redraw() end
          elseif y==8 and x>=2 and x<=termW-5 then state.volume=((x-2)/(termW-7))*3; redraw() end
        end
      elseif ev=="redraw" then redraw() end
    end
  end
end

-- HTTP loop (fixed to handle success and failure concurrently)
local function httpLoop()
  while true do
    parallel.waitForAny(
      function()
        local _,url,handle = os.pullEvent("http_success")
        if url==state.lastSearchUrl then
          state.results = textutils.unserializeJSON(handle.readAll())
          os.queueEvent("redraw")
        elseif url==state.downloadUrl then
          state.loading=false; state.handle=handle
          local hdrs = handle.getResponseHeaders()
          state.bytesTotal = tonumber(hdrs["Content-Length"]) or 0
          state.bytesLoaded = 0
          os.queueEvent("audio_update"); os.queueEvent("redraw")
        end
      end,
      function()
        local _,url = os.pullEvent("http_failure")
        if url==state.lastSearchUrl then
          state.searchError=true; os.queueEvent("redraw")
        elseif url==state.downloadUrl then
          state.loading=false; state.error=true; state.playing=false
          os.queueEvent("audio_update"); os.queueEvent("redraw")
        end
      end
    )
  end
end

-- Audio loop
local decoder = require("cc.audio.dfpwm").make_decoder()
local function audioLoop()
  while true do
    os.pullEvent("audio_update")
    if state.playing and state.now then
      if state.playId~=state.now.id then
        state.playId=state.now.id
        state.downloadUrl = API_BASE_URL.."?v="..VERSION.."&id="..textutils.urlEncode(state.now.id)
        state.loading=true; state.handle=nil
        http.request({url=state.downloadUrl,binary=true})
      elseif state.handle then
        while true do
          local chunk = state.handle.read(16*1024)
          if not chunk then
            state.handle:close(); state.handle=nil
            if state.loopMode==2 or (state.loopMode==1 and #state.queue==0) then state.playId=nil
            elseif state.loopMode==1 then enqueue(state.now,1); state.now=table.remove(state.queue,1); state.playId=nil
            elseif #state.queue>0 then state.now=table.remove(state.queue,1); state.playId=nil
            else state.now=nil; state.playing=false; state.playId=nil; state.loading=false end
            os.queueEvent("redraw"); break
          else
            state.bytesLoaded = state.bytesLoaded + #chunk
            local buf = decoder(chunk)
            for _,sp in ipairs(speakers) do sp.playAudio(buf,state.volume); repeat until os.pullEvent("speaker_audio_empty") end
            os.queueEvent("audio_update")
          end
        end
      end
    end
  end
end

-- Launch
parallel.waitForAny(uiLoop, httpLoop, audioLoop)
