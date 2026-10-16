addon.name = 'pyxis'
addon.author = 'Integrity'
addon.version = '0.6.1'
addon.desc = 'Manual one-command, one-chest Abyssea Forbidden Key trades for Ashita v4.'

require 'common'
local imgui = require 'imgui'
local bit = require 'bit'
-- Use Direct3D textures inside ImGui, avoiding the incompatible vector
-- access and external sprite positioning from earlier HUD versions.
local ffi = require 'ffi'
local d3d = require 'd3d8'
local textures = {}
local image_error_reported = false
local texture_load_failed = {}
local texture_dir = AshitaCore:GetInstallPath() .. '\\addons\\pyxis\\images\\'
local function load_chest_images()
    local device = d3d.get_device()
    for _, color in ipairs({ 'blue', 'gold', 'red' }) do
        if not textures[color] and not texture_load_failed[color] then
            local path = texture_dir .. color .. '.png'
            local ok, tex = pcall(function()
                local out = ffi.new('IDirect3DTexture8*[1]')
                if ffi.C.D3DXCreateTextureFromFileA(device, path, out) ~= ffi.C.S_OK then
                    return nil
                end
                return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
            end)
            if ok and tex then textures[color] = tex else texture_load_failed[color] = true end
        end
    end
end
local RANGE = 5.9
local RANGE_SQ = RANGE * RANGE
local settings = { blue = true, red = false, gold = false, show = true }
local colors = { [965] = 'blue', [968] = 'red', [969] = 'gold' }
local state = { nearby = {}, counts = { blue = 0, red = 0, gold = 0, unknown = 0 }, last = 0 }
local capture_until = 0
local capture_count = 0
-- Track trade attempts by both entity index and server ID so an opened chest
-- that remains in the entity list is not selected on the next macro press.
local attempted = {}
local ATTEMPT_TTL = 120 -- seconds; /py reset clears immediately
local function chest_key(c)
    return tostring(c.index) .. ':' .. tostring(c.server_id)
end
local function prune_attempts()
    local now = os.clock()
    for k, t in pairs(attempted) do
        if now - t >= ATTEMPT_TTL then attempted[k] = nil end
    end
end
local function say(s) print('[Pyxis] ' .. s) end
local function position(entity)
    local m = entity and entity.Movement
    local p = m and m.LocalPosition
    if not p then return nil end
    return tonumber(p.X), tonumber(p.Z)
end
local function distance_squared(a, b)
    local ax, az = position(a)
    local bx, bz = position(b)
    if not ax or not az or not bx or not bz then return math.huge end
    return (ax - bx)^2 + (az - bz)^2
end
local function model_of(entity)
    local ok, result = pcall(function() return entity.Look.Hair end)
    if ok then return tonumber(result) end
    return nil
end
local function scan()
    local player = GetPlayerEntity()
    local nearby = {}
    local counts = { blue = 0, red = 0, gold = 0, unknown = 0 }
    if player then
        for i = 0, 2303 do
            local ent = GetEntity(i)
            if ent and type(ent.Name) == 'string' and ent.Name:lower() == 'sturdy pyxis' then
                local dsq = distance_squared(player, ent)
                if dsq <= RANGE_SQ then
                    local model = model_of(ent)
                    local color = colors[model] or 'unknown'
                    counts[color] = counts[color] + 1
                    nearby[#nearby + 1] = {
                        index = i, server_id = tonumber(ent.ServerId),
                        model = model, color = color, distance = math.sqrt(dsq)
                    }
                end
            end
        end
    end
    table.sort(nearby, function(a, b) return a.distance < b.distance end)
    state.nearby = nearby
    state.counts = counts
end
local function ready_count()
    local n = 0
    for _, c in ipairs({ 'blue', 'red', 'gold' }) do
        if settings[c] then n = n + state.counts[c] end
    end
    return n
end
local function status()
    say(string.format('5.9y | Blue %s (%d) | Red %s (%d) | Gold %s (%d) | Unknown %d | Ready %d',
        settings.blue and 'ON' or 'OFF', state.counts.blue,
        settings.red and 'ON' or 'OFF', state.counts.red,
        settings.gold and 'ON' or 'OFF', state.counts.gold,
        state.counts.unknown, ready_count()))
end
-- Packet trade: keep the confirmed working implementation unchanged.
-- 0x036 NPC trade packet layout: target @ 0x04, count @ 0x08,
-- item inventory index @ 0x30, target index @ 0x3A, item count @ 0x3C.
-- See README for limitations; do not enable on servers that prohibit packet automation.
local function find_key()
    -- Ashita v4 exposes inventory through the memory manager.
    local memory = AshitaCore:GetMemoryManager()
    local resources = AshitaCore:GetResourceManager()
    local inv = memory and memory:GetInventory()
    if not resources or not inv then return nil, 'Inventory unavailable.' end
    local res = resources:GetItemByName('Forbidden Key', 2)
    if not res then res = resources:GetItemByName('Forbidden key', 2) end
    if not res then return nil, 'Cannot resolve Forbidden Key item ID.' end
    local item_id = tonumber(res.Id or res.ItemId)
    if not item_id then return nil, 'Forbidden Key resource has no usable item ID.' end
    local max_slots = tonumber(inv:GetContainerCountMax(0)) or 80
    for slot = 1, math.min(max_slots, 80) do
        local item = inv:GetContainerItem(0, slot)
        if item and tonumber(item.Id) == item_id and tonumber(item.Count or 0) > 0 then
            return slot
        end
    end
    return nil, 'No Forbidden Key found in main inventory.'
end
-- Count Forbidden Keys in the main inventory for the HUD.
-- Uses the same item lookup as the working trade function.
local function count_keys()
    local ok, total = pcall(function()
        local memory = AshitaCore:GetMemoryManager()
        local resources = AshitaCore:GetResourceManager()
        local inv = memory and memory:GetInventory()
        if not inv or not resources then return nil end
        local res = resources:GetItemByName('Forbidden Key', 2)
                    or resources:GetItemByName('Forbidden key', 2)
        if not res then return nil end
        local item_id = tonumber(res.Id or res.ItemId)
        if not item_id then return nil end
        local count = 0
        local slots = math.min(tonumber(inv:GetContainerCountMax(0)) or 80, 80)
        for slot = 1, slots do
            local item = inv:GetContainerItem(0, slot)
            if item and tonumber(item.Id) == item_id then
                count = count + (tonumber(item.Count) or 0)
            end
        end
        return count
    end)
    return ok and total or nil
end
local key_display = { count = nil, updated = 0 }

local function trade_one(quiet)
    scan()
    prune_attempts()
    local chest
    local skipped = 0
    for _, c in ipairs(state.nearby) do
        if settings[c.color] then
            if attempted[chest_key(c)] then
                skipped = skipped + 1
            else
                chest = c
                break
            end
        end
    end
    if not chest then
        if not quiet then say(string.format('No new enabled chest within 5.9y (%d previously attempted). /py reset to retry.', skipped)) end
        return false, 'none'
    end
    local entity = GetEntity(chest.index)
    local player = GetPlayerEntity()
    if not entity or not player or entity.Name ~= 'Sturdy Pyxis' or
       model_of(entity) ~= chest.model or
       tonumber(entity.ServerId) ~= chest.server_id or
       distance_squared(player, entity) > RANGE_SQ then
        say('Chest changed or moved out of range; aborted.')
        return false, 'changed'
    end
    local slot, err = find_key()
    if not slot then say(err); return false, 'key' end
    if slot < 1 or slot > 255 or chest.index > 65535 or not chest.server_id then
        say('Invalid chest or inventory slot; aborted.'); return false, 'invalid'
    end
    local packet = ffi.new('uint8_t[64]')
    -- Ashita writes the outgoing packet header itself when injecting.
    ffi.cast('uint32_t*', packet + 0x04)[0] = chest.server_id
    ffi.cast('uint32_t*', packet + 0x08)[0] = 1
    packet[0x30] = slot
    ffi.cast('uint16_t*', packet + 0x3A)[0] = chest.index
    packet[0x3C] = 1
    local bytes = ffi.string(packet, 64):totable()
    local ok, result = pcall(function()
        AshitaCore:GetPacketManager():AddOutgoingPacket(0x036, bytes)
    end)
    if ok and result ~= false then
        attempted[chest_key(chest)] = os.clock()
        -- Quiet successful trade attempt; the game still reports actual key use.
        return true
    else
        say('Trade API failed: ' .. tostring(result))
        return false, 'api'
    end
end
ashita.events.register('command', 'pyxis_command', function(e)
    local args = e.command:args()
    if #args == 0 or not args[1]:any('/py', '/pyxis') then return end
    e.blocked = true
    local cmd = (args[2] or 'open'):lower()
    if cmd == 'blue' or cmd == 'red' or cmd == 'gold' then
        local mode = (args[3] or ''):lower()
        if mode == 'on' then settings[cmd] = true
        elseif mode == 'off' then settings[cmd] = false
        else settings[cmd] = not settings[cmd] end
        -- HUD and command toggles are silent.
    elseif cmd == 'hud' then
        local mode = (args[3] or ''):lower()
        if mode == 'on' or mode == 'show' then settings.show = true
        elseif mode == 'off' or mode == 'hide' then settings.show = false
        else settings.show = not settings.show end
        -- Silent HUD visibility control.
    elseif cmd == 'huddebug' then
        state.hud_debug_requested = true
        say('HUD coordinate diagnostic queued. Keep HUD visible for one frame.')
    elseif cmd == 'status' then
        scan(); status()
    elseif cmd == 'debug' then
        scan(); status()
        for _, chest in ipairs(state.nearby) do
            say(string.format('Index=%d ServerId=%s Distance=%.2fy Look.Hair=%s Color=%s',
                chest.index, tostring(chest.server_id), chest.distance,
                tostring(chest.model), chest.color))
        end
    elseif cmd == 'reset' then
        attempted = {}
        say('Attempt history cleared. Previously attempted chests may be retried.')
    elseif cmd == 'learn' then
        capture_until = os.clock() + 30
        capture_count = 0
        say('Capture ON for 30 seconds. Manually trade ONE Forbidden Key to ONE chest now.')
        say('Only outgoing trade packets 0x036 will be displayed; no packets are injected.')
    elseif cmd == 'open' then
        -- One explicit user command sends at most one trade attempt.
        -- No frame callback, timer, or batch loop can send another trade.
        trade_one(true)
    else
        say('Commands: /py | /py blue|red|gold [on|off] | /py status | /py debug | /py hud | /py learn | /py reset')
    end
end)
-- Observe a real, successful Forbidden Key trade before implementing packet sending.
-- Capture only the relevant outgoing NPC trade packet (0x036).
ashita.events.register('packet_out', 'pyxis_trade_capture', function(e)
    if os.clock() > capture_until or e.id ~= 0x036 then return end
    capture_count = capture_count + 1
    if capture_count > 3 then return end
    local ok, err = pcall(function()
        local bytes = e.data
        if type(bytes) ~= 'string' then
            say('0x036 detected, but packet bytes are not a Lua string: ' .. type(bytes))
            return
        end
        local hex = {}
        for i = 1, math.min(#bytes, 80) do
            hex[#hex + 1] = string.format('%02X', bytes:byte(i))
        end
        say(string.format('TRADE 0x036 size=%d hex=%s', #bytes, table.concat(hex, ' ')))
    end)
    if not ok then say('Capture error: ' .. tostring(err)) end
end)
ashita.events.register('d3d_present', 'pyxis_present', function()
    if os.clock() - state.last >= 0.25 then
        state.last = os.clock()
        scan()
    end
    if not settings.show then return end
    if not textures.blue or not textures.gold or not textures.red then
        load_chest_images()
    end
    -- Ashita v4 ImGui expects a numeric D3D8 texture pointer, not FFI cdata.
    -- Convert once at the draw site, without reading ImGui vector coordinates.
    local function texture_id(texture)
        local ok, n = pcall(function()
            return tonumber(ffi.cast('uintptr_t', texture))
        end)
        if ok then return n end
        return nil
    end

    -- Dark navy / cyan styling; always pop only styles successfully pushed.
    local pushed = 0
    local function push_color(key, rgba)
        local id = _G[key]
        if id ~= nil then
            local ok = pcall(imgui.PushStyleColor, id, rgba)
            if ok then pushed = pushed + 1 end
        end
    end
    push_color('ImGuiCol_WindowBg', { 0.035, 0.085, 0.16, 0.97 })
    push_color('ImGuiCol_TitleBg', { 0.035, 0.14, 0.27, 1 })
    push_color('ImGuiCol_TitleBgActive', { 0.06, 0.25, 0.43, 1 })
    push_color('ImGuiCol_Button', { 0.07, 0.19, 0.33, 1 })
    push_color('ImGuiCol_ButtonHovered', { 0.11, 0.36, 0.55, 1 })
    push_color('ImGuiCol_ButtonActive', { 0.09, 0.48, 0.65, 1 })
    push_color('ImGuiCol_Border', { 0.12, 0.39, 0.58, 1 })
    local flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize,
                          ImGuiWindowFlags_NoScrollbar,
                          ImGuiWindowFlags_NoCollapse)
    imgui.SetNextWindowBgAlpha(0.97)
    if imgui.Begin('PYXIS  |  ABYSSEA##pyxis_hud', nil, flags) then
        -- Close the overlay without unloading the addon. /py hud shows it again.
        imgui.Text('PYXIS')
        imgui.SameLine()
        if imgui.Button('X##pyxis_close', { 24, 22 }) then
            settings.show = false
        end
        imgui.Separator()
        -- Equal-width columns keep the chest artwork and buttons aligned.
        local entries = { 'blue', 'gold', 'red' }
        for i, color in ipairs(entries) do
            if i > 1 then imgui.SameLine() end
            imgui.BeginGroup()
            local count = state.counts[color] or 0
            -- Fixed-size header also provides a large, easy-to-hit toggle.
            if imgui.Button(string.format('%s  %d##header_%s', color:upper(), count, color), { 94, 24 }) then
                settings[color] = not settings[color]
            end
            local clicked = false
            local tex = textures[color]
            local tid = tex and texture_id(tex)
            if tid and tid ~= 0 then
                local ok, err = pcall(function()
                    imgui.Image(tid, { 94, 72 })
                    clicked = imgui.IsItemClicked(0)
                end)
                if not ok then
                    texture_load_failed[color] = true
                    textures[color] = nil
                    if not image_error_reported then
                        say('Image draw failed: ' .. tostring(err))
                        image_error_reported = true
                    end
                    tid = nil
                end
            end
            if not tid or tid == 0 then
                if imgui.Button(color:upper() .. '##chest_' .. color, { 94, 72 }) then
                    clicked = true
                end
            end
            if clicked then settings[color] = not settings[color] end
            local label = (settings[color] and 'O   ON' or 'X   OFF') .. '##toggle_' .. color
            if imgui.Button(label, { 94, 26 }) then
                settings[color] = not settings[color]
            end
            imgui.EndGroup()
        end
        imgui.Separator()
        if os.time() ~= key_display.updated then
            key_display.updated = os.time()
            key_display.count = count_keys()
        end
        local keys = key_display.count
        imgui.TextColored({ 0.48, 0.81, 1.0, 1.0 },
            'FORBIDDEN KEYS   ' .. (keys ~= nil and tostring(keys) or '--'))
    end
    imgui.End()
    if pushed > 0 then imgui.PopStyleColor(pushed) end
end)
-- No chat output on load.
