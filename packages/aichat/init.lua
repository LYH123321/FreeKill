-- SPDX-License-Identifier: GPL-3.0-or-later
-- AI 角色卡 · 边打边聊
-- 依赖：src/swig/qt.i 中的 fkHttpPost（本仓库已加入）
local extension = Package:new("aichat")
extension.extensionName = "aichat"

-- ============ 默认人设卡（可自行仿写追加） ============
local CARDS = {
  zhangfei = {
    name = "张飞",
    persona = "你是燕人张飞，性如烈火，嗓门极大，说话直来直去，爱骂人但重情义，最佩服大哥刘备和二哥关羽。",
    style = "台词极短（10字内），粗鲁豪迈，常用『俺』自称。",
  },
  guanyu = {
    name = "关羽",
    persona = "你是汉寿亭侯关羽，忠义无双，傲上而不辱下，话少而每句都重若千钧。",
    style = "台词极短（15字内），沉稳傲然，自称『关某』。",
  },
  caocao = {
    name = "曹操",
    persona = "你是魏武帝曹操，枭雄多疑，爱才也爱调侃，得意时喜欢大笑。",
    style = "台词极短（15字内），霸气中带戏谑，常笑。",
  },
  zhaoyun = {
    name = "赵云",
    persona = "你是常山赵子龙，忠勇谦逊，冷静可靠。",
    style = "台词极短（15字内），谦和沉稳，自称『赵某』或『末将』。",
  },
  default = {
    name = "武将",
    persona = "你是一名三国武将，正在牌局中，会对战局的重大变化发出简短感叹。",
    style = "台词极短（12字内），符合三国人物语气。",
  },
}

local function getCard(general)
  return CARDS[general] or CARDS.default
end

-- ============ API 调用 ============
local function chatCompletion(room, messages)
  local ok, ret = pcall(function()
    local cfg = room:getSettings("_mode") or {}
    local base = cfg.ai_api_url or ""
    local key = cfg.ai_api_key or ""
    local model = cfg.ai_api_model or ""
    if base == "" or model == "" then return nil end
    local payload = json.encode({
      model = model,
      messages = messages,
      max_tokens = 64,
      temperature = 0.9,
    })
    local url = base:gsub("/+$", "")
    if not url:match("/chat/completions$") then
      url = url .. "/chat/completions"
    end
    local resp, httpCode, httpErr = fkHttpPost(url, payload, 25000, key)
    if httpErr ~= nil and httpErr ~= "" then
      fk.qWarning("[aichat] HTTP error: %s", tostring(httpErr))
      return nil
    end
    if httpCode ~= 200 then
      fk.qWarning("[aichat] HTTP %s: %s", tostring(httpCode), tostring(resp):sub(1, 200))
      return nil
    end
    local data = json.decode(resp)
    if type(data) == "table" and data.choices and data.choices[1] then
      local msg = data.choices[1].message or {}
      return msg.content
    end
    return nil
  end)
  if ok then return ret end
  fk.qWarning("[aichat] error: %s", tostring(ret))
  return nil
end

-- ============ 台词生成 ============
local function speak(room, player, eventDesc, historyTag)
  if not room or not player or player.dead then return end
  local general = player.general
  if not general or general == "" then return end
  local card = getCard(general)
  local tag = historyTag or ("aichat_hist_" .. player.id)
  local history = room:getTag(tag) or {}
  local messages = {
    { role = "system", content =
      card.persona .. "\n" .. card.style ..
      "\n你正在一场三国杀牌局中。只输出一句台词本身，不要任何前后缀、引号或解释。" },
    { role = "user", content = eventDesc },
  }
  -- 带上最近几条历史，让台词有上下文连贯性
  for _, h in ipairs(history) do
    table.insert(messages, h)
  end
  local reply = chatCompletion(room, messages)
  if not reply or reply == "" then return end
  -- 截断过长的回复
  if #reply > 60 then reply = reply:sub(1, utf8.offset(reply, 15) or 61 - 1) end
  reply = reply:gsub("^[%s\n]+", ""):gsub("[%s\n]+$", "")
  if reply == "" then return end
  -- 记录历史（保留最近 4 条）
  table.insert(history, { role = "assistant", content = reply })
  while #history > 4 do table.remove(history, 1) end
  room:setTag(tag, history)
  -- 广播聊天气泡（走官方聊天通道，全员可见）
  pcall(function() player:chat(reply) end)
end

local function robotPlayers(room)
  local ret = {}
  for _, p in ipairs(room.players) do
    if p:getState() == fk.Player_Robot then
      table.insert(ret, p)
    end
  end
  return ret
end

local function aiEnabled(room)
  local cfg = room:getSettings("_mode") or {}
  return cfg.ai_chat_enabled == true
    and (cfg.ai_api_url or "") ~= "" and (cfg.ai_api_model or "") ~= ""
end

-- ============ 全局触发技能 ============
local skill = fk.CreateSkill{ name = "aichat_narrator", global = true }

-- 开局问候
skill:addEffect(fk.GamePrepared, {
  global = true,
  priority = 0,
  can_trigger = function(self, event, target, player, data)
    return player and (player == player.room.players[1] or target == nil)
  end,
  on_trigger = function(self, event, target, player, data)
    local room = player.room
    if not aiEnabled(room) then return end
    local robots = robotPlayers(room)
    for i, p in ipairs(robots) do
      if i <= 3 then -- 开局最多 3 个说话，防刷屏
        speak(room, p, "牌局刚刚开始，全场入座。用一句话向大家打招呼。", "aichat_hist_" .. p.id)
      end
    end
  end,
})

-- 被打 -> 反应
skill:addEffect(fk.Damaged, {
  global = true,
  priority = 0,
  can_trigger = function(self, event, target, player, data)
    return target ~= nil and target:getState() == fk.Player_Robot
  end,
  on_trigger = function(self, event, target, player, data)
    local room = target.room
    if not aiEnabled(room) then return end
    local fromName = "有人"
    if data.from then
      fromName = Fk:translate(data.from.general) or "有人"
    end
    speak(room, target,
      string.format("你被 %s 打了一下（%s），掉了一滴血。用一句话回怼或哀嚎。",
        fromName, tostring(data.damage or 1)),
      "aichat_hist_" .. target.id)
  end,
})

-- 濒死 -> 求救/遗言前奏
skill:addEffect(fk.AskForPeaches, {
  global = true,
  priority = 0,
  can_trigger = function(self, event, target, player, data)
    return target ~= nil and target:getState() == fk.Player_Robot
  end,
  on_trigger = function(self, event, target, player, data)
    local room = target.room
    if not aiEnabled(room) then return end
    speak(room, target, "你已濒死，正在等人救你。用一句话求救或不甘地嘶吼。",
      "aichat_hist_" .. target.id)
  end,
})

-- 阵亡 -> 遗言
skill:addEffect(fk.Deathed, {
  global = true,
  priority = 0,
  can_trigger = function(self, event, target, player, data)
    return target ~= nil and target:getState() == fk.Player_Robot
  end,
  on_trigger = function(self, event, target, player, data)
    local room = target.room
    if not aiEnabled(room) then return end
    local killer = "天意"
    if data.killer then killer = Fk:translate(data.killer.general) or killer end
    speak(room, target,
      string.format("你被 %s 杀死了。用一句遗言收场（可以认命、可以不甘、可以预言大局）。",
        killer),
      "aichat_hist_" .. target.id)
  end,
})

Fk:loadTranslationTable{
  ["aichat_narrator"] = "AI角色卡·旁白",
  [":aichat_narrator"] = "AI 武将边打边聊（需在模式设置中配置 API）",
}

extension:loadSkillSkels({ skill })

return extension
