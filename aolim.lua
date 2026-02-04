_addon.name    = 'aolim'
_addon.author  = 'Ben'
_addon.version = '0.4'
_addon.command = 'aolim'

require('common')
require('imguidef')

local settings = require('aolim_settings')

-- ============================================================
-- Persistence (writes aolim_data.lua next to this addon)
-- Stores: buddies + groups + window settings + presence options
-- ============================================================
local function join_path(a, b)
    if a:sub(-1) == '\\' or a:sub(-1) == '/' then
        return a .. b
    end
    return a .. '\\' .. b
end

local install = (AshitaCore and AshitaCore:GetInstallPath()) or ''
local addon_dir = join_path(join_path(install, 'addons'), _addon.name)
local data_path = join_path(addon_dir, 'aolim_data.lua')

local function serialize_value(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = { '{\n' }
        local nextIndent = indent .. '    '
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
                key = k
            else
                key = '[' .. serialize_value(k, nextIndent) .. ']'
            end
            parts[#parts + 1] = string.format('%s%s = %s,\n', nextIndent, key, serialize_value(val, nextIndent))
        end
        parts[#parts + 1] = indent .. '}'
        return table.concat(parts)
    end
    return 'nil'
end

local function save_data(t)
    local f = io.open(data_path, 'w+')
    if not f then return false end
    f:write('return ' .. serialize_value(t) .. '\n')
    f:close()
    return true
end

local function load_data()
    local ok, chunk = pcall(loadfile, data_path)
    if not ok or not chunk then return nil end
    local ok2, t = pcall(chunk)
    if not ok2 then return nil end
    return t
end

-- ============================================================
-- Helpers
-- ============================================================
local function now() return os.time() end
local function normalize_name(n) return (n or ''):gsub('%s+', '') end

local function chat_print(msg)
    if AshitaCore and AshitaCore:GetChatManager() then
        AshitaCore:GetChatManager():AddChatMessage(string.format('[%s] %s', _addon.name, msg), 200)
    else
        print(string.format('[%s] %s', _addon.name, msg))
    end
end

local function send_cmd(cmd)
    if AshitaCore and AshitaCore:GetChatManager() then
        AshitaCore:GetChatManager():QueueCommand(cmd, 1)
    else
        chat_print('ChatManager unavailable; cannot send commands.')
    end
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- ============================================================
-- State
-- ============================================================
local state = {
    buddies = {},        -- array of { name, group, online(nil/true/false), last_seen, last_checked, last_ping }
    selected = nil,      -- index into buddies
    conversations = {},  -- name -> array { {dir='in'/'out', text, ts} }
    unread = {},         -- name -> count

    groups = { 'Friends' }, -- ordered list
    group_open = {},        -- groupName -> bool (collapsing header state)

    ui = {
        add_name = '',
        add_group = 'Friends',
        msg_input = '',
        status = 'Loaded.',
        lock_window = false,
        focus_msg = false,

        -- blink state
        blink_on = false,
        next_blink_t = 0,
        blink_period = settings.ui and settings.ui.blink_period_seconds or 0.6,

        -- move group popup
        move_group_target_idx = nil,
        new_group_name = ''
    },

    presence = {
        watch_enabled = settings.presence.watch_enabled,
        watch_interval = settings.presence.watch_interval,
        per_buddy_cooldown = settings.presence.per_buddy_cooldown,
        global_cooldown = settings.presence.global_cooldown,
        result_accept_window = settings.presence.result_accept_window or 2,

        queue = {},             -- buddy indices to ping
        next_watch_time = 0,
        global_last_ping = 0,

        pending = nil,          -- { name, sent_ts }
        pending_timeout = 6,
        rr = 0
    }
}

local function ensure_group_exists(g)
    g = (g and g ~= '' and g) or 'Friends'
    for i = 1, #state.groups do
        if state.groups[i] == g then
            return g
        end
    end
    state.groups[#state.groups + 1] = g
    state.group_open[g] = true
    return g
end

local function get_conv(name)
    name = normalize_name(name)
    state.conversations[name] = state.conversations[name] or {}
    return state.conversations[name]
end

local function push_msg(name, dir, text)
    local conv = get_conv(name)
    conv[#conv + 1] = { dir = dir, text = text, ts = now() }
end

local function find_buddy(name)
    name = normalize_name(name)
    for i = 1, #state.buddies do
        if normalize_name(state.buddies[i].name):lower() == name:lower() then
            return i
        end
    end
    return nil
end

local function add_buddy(name, group)
    name = normalize_name(name)
    if name == '' then return false end
    if find_buddy(name) then return false end

    group = ensure_group_exists(group or 'Friends')

    state.buddies[#state.buddies + 1] = {
        name = name,
        group = group,
        online = nil,
        last_seen = nil,
        last_checked = nil,
        last_ping = 0
    }
    state.unread[name] = state.unread[name] or 0
    return true
end

local function remove_buddy(name)
    local idx = find_buddy(name)
    if not idx then return false end

    local n = normalize_name(state.buddies[idx].name)
    table.remove(state.buddies, idx)

    state.unread[n] = nil
    state.conversations[n] = nil

    if state.selected == idx then state.selected = nil end
    if state.selected and state.selected > idx then state.selected = state.selected - 1 end
    return true
end

local function set_buddy_group(idx, group)
    local b = state.buddies[idx]
    if not b then return false end
    b.group = ensure_group_exists(group)
    return true
end

local function save_all()
    local buddies = {}
    for i = 1, #state.buddies do
        buddies[#buddies + 1] = { name = state.buddies[i].name, group = state.buddies[i].group }
    end

    save_data({
        window = {
            is_open = settings.window.is_open,
            x = settings.window.x, y = settings.window.y,
            w = settings.window.w, h = settings.window.h,
            lock = state.ui.lock_window
        },
        presence = {
            watch_enabled = state.presence.watch_enabled,
            watch_interval = state.presence.watch_interval,
            per_buddy_cooldown = state.presence.per_buddy_cooldown,
            global_cooldown = state.presence.global_cooldown,
            result_accept_window = state.presence.result_accept_window
        },
        groups = state.groups,
        buddies = buddies
    })
end

local function load_all()
    local d = load_data()
    if not d then return end

    if d.window then
        settings.window.is_open = (d.window.is_open ~= false)
        settings.window.x = d.window.x or settings.window.x
        settings.window.y = d.window.y or settings.window.y
        settings.window.w = d.window.w or settings.window.w
        settings.window.h = d.window.h or settings.window.h
        state.ui.lock_window = (d.window.lock == true)
    end

    if d.presence then
        state.presence.watch_enabled = (d.presence.watch_enabled == true)
        state.presence.watch_interval = d.presence.watch_interval or state.presence.watch_interval
        state.presence.per_buddy_cooldown = d.presence.per_buddy_cooldown or state.presence.per_buddy_cooldown
        state.presence.global_cooldown = d.presence.global_cooldown or state.presence.global_cooldown
        state.presence.result_accept_window = d.presence.result_accept_window or state.presence.result_accept_window
    end

    if d.groups and type(d.groups) == 'table' and #d.groups > 0 then
        state.groups = {}
        for _, g in ipairs(d.groups) do
            if type(g) == 'string' and g ~= '' then
                state.groups[#state.groups + 1] = g
                state.group_open[g] = true
            end
        end
    else
        ensure_group_exists('Friends')
    end

    if d.buddies then
        for _, b in ipairs(d.buddies) do
            if b.name then
                add_buddy(b.name, b.group or 'Friends')
            end
        end
    end
end

-- ============================================================
-- Presence logic (1 pending /sea at a time)
-- ============================================================
local function enqueue_ping(idx)
    if not idx or idx < 1 or idx > #state.buddies then return end
    state.presence.queue[#state.presence.queue + 1] = idx
end

local function ping_buddy(idx)
    local b = state.buddies[idx]
    if not b then return false end

    local t = now()
    if state.presence.pending ~= nil then return false end
    if (t - state.presence.global_last_ping) < state.presence.global_cooldown then return false end
    if (t - (b.last_ping or 0)) < state.presence.per_buddy_cooldown then return false end

    b.last_ping = t
    state.presence.global_last_ping = t
    state.presence.pending = { name = b.name, sent_ts = t }

    send_cmd(string.format('/sea all %s', b.name))
    return true
end

local function process_presence_queue()
    if state.presence.pending then
        local age = now() - state.presence.pending.sent_ts
        if age > state.presence.pending_timeout then
            local idx = find_buddy(state.presence.pending.name)
            if idx then
                local b = state.buddies[idx]
                b.online = nil
                b.last_checked = now()
            end
            state.presence.pending = nil
        end
        return
    end

    if #state.presence.queue == 0 then return end
    local idx = table.remove(state.presence.queue, 1)
    ping_buddy(idx)
end

local function rotate_watch()
    if not state.presence.watch_enabled then return end
    if now() < state.presence.next_watch_time then return end

    state.presence.next_watch_time = now() + state.presence.watch_interval
    if #state.buddies == 0 then return end

    state.presence.rr = state.presence.rr + 1
    if state.presence.rr > #state.buddies then state.presence.rr = 1 end
    enqueue_ping(state.presence.rr)
end

-- ============================================================
-- Blink state (flash tabs + buddy list on unread)
-- ============================================================
local function update_blink()
    local t = os.clock()
    if t >= state.ui.next_blink_t then
        state.ui.blink_on = not state.ui.blink_on
        state.ui.next_blink_t = t + (state.ui.blink_period or 0.6)
    end
end

local function blink_suffix(unread_count)
    if unread_count and unread_count > 0 and state.ui.blink_on then
        return ' ★'
    end
    return ''
end

-- ============================================================
-- Tell sending
-- ============================================================
local function send_tell(to_name, message)
    to_name = normalize_name(to_name)
    message = message or ''
    if to_name == '' or message == '' then return end

    -- send as one line
    local send_text = message:gsub('\r\n', '\n'):gsub('\r', '\n')
    send_text = send_text:gsub('\n+', ' ')

    send_cmd(string.format('/tell %s %s', to_name, send_text))
    push_msg(to_name, 'out', send_text)
end

-- ============================================================
-- Commands
-- ============================================================
local function cmd_help()
    chat_print('Commands:')
    chat_print('  /aolim (toggle) | /aolim open | /aolim close')
    chat_print('  /aolim add <name> [group] | /aolim del <name>')
    chat_print('  /aolim ping <name> | /aolim watch [on|off] | /aolim interval <sec>')
    chat_print('  /aolim group add <group> | /aolim group del <group> | /aolim lock')
    chat_print('  /aolim clear [name]')
end

-- ============================================================
-- Events
-- ============================================================
ashita.events.register('load', 'load_cb', function ()
    load_all()
    ensure_group_exists('Friends')
    state.ui.add_group = state.ui.add_group or 'Friends'
    state.ui.status = 'Loaded. /aolim help'
    chat_print(state.ui.status)
end)

ashita.events.register('unload', 'unload_cb', function ()
    save_all()
end)

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if #args == 0 then return end
    if not args[1]:any('/aolim') then return end
    e.blocked = true

    local sub = (args[2] and args[2]:lower()) or 'toggle'

    if sub == 'toggle' then
        settings.window.is_open = not settings.window.is_open
        save_all()
        return
    end
    if sub == 'open' then settings.window.is_open = true; save_all(); return end
    if sub == 'close' then settings.window.is_open = false; save_all(); return end

    if sub == 'add' and args[3] then
        local name = args[3]
        local group = args[4] or 'Friends'
        if add_buddy(name, group) then
            state.ui.status = string.format('Added: %s (%s)', name, group)
            save_all()
        else
            state.ui.status = 'Add failed (blank/duplicate).'
        end
        return
    end

    if (sub == 'del' or sub == 'remove') and args[3] then
        if remove_buddy(args[3]) then
            state.ui.status = 'Removed: ' .. args[3]
            save_all()
        else
            state.ui.status = 'Remove failed (not found).'
        end
        return
    end

    if sub == 'ping' and args[3] then
        local idx = find_buddy(args[3])
        if idx then
            enqueue_ping(idx)
            state.ui.status = 'Queued ping: ' .. args[3]
        else
            state.ui.status = 'Buddy not found.'
        end
        return
    end

    if sub == 'watch' then
        local v = args[3] and args[3]:lower()
        if v == 'on' then state.presence.watch_enabled = true
        elseif v == 'off' then state.presence.watch_enabled = false
        elseif v == nil then state.presence.watch_enabled = not state.presence.watch_enabled
        end
        state.ui.status = 'Watch: ' .. (state.presence.watch_enabled and 'ON' or 'OFF')
        save_all()
        return
    end

    if sub == 'interval' and args[3] then
        local n = tonumber(args[3])
        if n then
            n = clamp(n, 3, 300)
            state.presence.watch_interval = n
            state.ui.status = 'Watch interval: ' .. n .. 's'
            save_all()
        else
            state.ui.status = 'interval must be a number (3..300).'
        end
        return
    end

    if sub == 'lock' then
        state.ui.lock_window = not state.ui.lock_window
        state.ui.status = 'Window lock: ' .. (state.ui.lock_window and 'ON' or 'OFF')
        save_all()
        return
    end

    if sub == 'clear' then
        local name = args[3] and normalize_name(args[3])
        if name and name ~= '' then
            state.conversations[name] = {}
            state.unread[name] = 0
            state.ui.status = 'Cleared chat: ' .. name
        else
            state.conversations = {}
            state.unread = {}
            for i = 1, #state.buddies do
                state.unread[normalize_name(state.buddies[i].name)] = 0
            end
            state.ui.status = 'Cleared all chats.'
        end
        return
    end

    if sub == 'group' and args[3] and args[4] then
        local gsub = args[3]:lower()
        local gname = args[4]
        if gsub == 'add' then
            ensure_group_exists(gname)
            state.ui.status = 'Group added: ' .. gname
            save_all()
            return
        elseif gsub == 'del' or gsub == 'remove' then
            -- don't delete Friends
            if gname == 'Friends' then
                state.ui.status = 'Cannot delete group "Friends".'
                return
            end
            local newGroups = {}
            for i = 1, #state.groups do
                if state.groups[i] ~= gname then
                    newGroups[#newGroups + 1] = state.groups[i]
                end
            end
            state.groups = newGroups
            -- move any buddies in that group to Friends
            for i = 1, #state.buddies do
                if state.buddies[i].group == gname then
                    state.buddies[i].group = 'Friends'
                end
            end
            state.ui.status = 'Group removed: ' .. gname
            save_all()
            return
        end
    end

    if sub == 'help' then
        cmd_help()
        return
    end

    state.ui.status = 'Unknown. /aolim help'
end)

-- ============================================================
-- Inbound tell + /sea outputs (HorizonXI exact strings you gave)
-- ============================================================
ashita.events.register('text_in', 'text_in_cb', function (e)
    local txt = tostring(e.message or '')

    -- Inbound tell example:
    -- Puckmi>> : you'll want snk/invis
    local from, msg = txt:match('^%s*([^>]+)>>%s*:%s*(.+)$')
    if from and msg then
        from = normalize_name(from)
        push_msg(from, 'in', msg)

        -- unread if not currently viewing that buddy
        local viewing = false
        if state.selected then
            local sel = state.buddies[state.selected]
            if sel and normalize_name(sel.name):lower() == from:lower() then
                viewing = true
            end
        end
        if not viewing then
            state.unread[from] = (state.unread[from] or 0) + 1
        end

        -- mark buddy online if they exist in list
        local idx = find_buddy(from)
        if idx then
            local b = state.buddies[idx]
            b.online = true
            b.last_seen = now()
            b.last_checked = now()
        end
        return
    end

    -- /sea outputs:
    -- Success: Search result: Only one person found in the entire world.
    -- Fail:    Search result: 0 people found in all known areas.
    if state.presence.pending then
        if (now() - state.presence.pending.sent_ts) > (state.presence.result_accept_window or 2) then
            return
        end

        local pending_name = normalize_name(state.presence.pending.name)

        if txt:find('Search result: Only one person found in the entire world.', 1, true) then
            local idx = find_buddy(pending_name)
            if idx then
                local b = state.buddies[idx]
                b.online = true
                b.last_seen = now()
                b.last_checked = now()
            end
            state.presence.pending = nil
            return
        end

        if txt:find('Search result: 0 people found in all known areas.', 1, true) then
            local idx = find_buddy(pending_name)
            if idx then
                local b = state.buddies[idx]
                b.online = false
                b.last_checked = now()
            end
            state.presence.pending = nil
            return
        end
    end
end)

-- ============================================================
-- UI
-- - Buddy list grouped
-- - Tabs per buddy with blinking star on unread
-- - Multiline input: Enter sends, Shift+Enter newline
-- - Right click buddy menu: Open Chat, Ping, Move Group, Remove
-- ============================================================
ashita.events.register('d3d_present', 'present_cb', function ()
    update_blink()
    rotate_watch()
    process_presence_queue()

    if not settings.window.is_open then return end

    imgui.SetNextWindowSize({ settings.window.w, settings.window.h }, ImGuiCond.FirstUseEver)
    imgui.SetNextWindowPos({ settings.window.x, settings.window.y }, ImGuiCond.FirstUseEver)

    local flags = 0
    if state.ui.lock_window then
        flags = bit.bor(flags, ImGuiWindowFlags.NoMove)
        flags = bit.bor(flags, ImGuiWindowFlags.NoResize)
    end

    local opened, show = imgui.Begin('AOLim (HorizonXI)', true, flags)
    if not show then
        settings.window.is_open = false
        save_all()
        imgui.End()
        return
    end

    -- Save window position/size when unlocked
    if not state.ui.lock_window then
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        settings.window.x, settings.window.y = pos.x, pos.y
        settings.window.w, settings.window.h = size.x, size.y
    end

    imgui.Text(state.ui.status)
    imgui.SameLine()
    imgui.Text('| Watch: ' .. (state.presence.watch_enabled and 'ON' or 'OFF'))
    imgui.Separator()

    imgui.Columns(2, 'cols', true)

    -- -----------------------------
    -- LEFT: Groups + buddy list
    -- -----------------------------
    imgui.Text('Buddies')
    imgui.Separator()

    -- Add controls
    imgui.PushItemWidth(-1)
    local changedAdd, newName = imgui.InputText('##addname', state.ui.add_name, 64)
    if changedAdd then state.ui.add_name = newName end
    imgui.PopItemWidth()

    -- Group dropdown for add
    imgui.PushItemWidth(-1)
    if imgui.BeginCombo('##addgroup', state.ui.add_group) then
        for i = 1, #state.groups do
            local g = state.groups[i]
            if imgui.Selectable(g, (state.ui.add_group == g)) then
                state.ui.add_group = g
            end
        end
        imgui.Separator()
        imgui.Text('New group:')
        local cg, ng = imgui.InputText('##newgroup', state.ui.new_group_name, 32)
        if cg then state.ui.new_group_name = ng end
        if imgui.Button('Create Group') then
            if state.ui.new_group_name and state.ui.new_group_name ~= '' then
                state.ui.add_group = ensure_group_exists(state.ui.new_group_name)
                state.ui.new_group_name = ''
                save_all()
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    if imgui.Button('Add Buddy') then
        if add_buddy(state.ui.add_name, state.ui.add_group) then
            state.ui.status = string.format('Added: %s (%s)', state.ui.add_name, state.ui.add_group)
            state.ui.add_name = ''
            save_all()
        else
            state.ui.status = 'Add failed (blank/duplicate).'
        end
    end
    imgui.SameLine()
    if imgui.Button(state.presence.watch_enabled and 'Stop Watch' or 'Start Watch') then
        state.presence.watch_enabled = not state.presence.watch_enabled
        save_all()
    end
    imgui.SameLine()
    if imgui.Button(state.ui.lock_window and 'Unlock' or 'Lock') then
        state.ui.lock_window = not state.ui.lock_window
        save_all()
    end

    imgui.Separator()

    -- Build grouped view
    for gi = 1, #state.groups do
        local groupName = state.groups[gi]
        if state.group_open[groupName] == nil then state.group_open[groupName] = true end

        local open = imgui.CollapsingHeader(groupName, ImGuiTreeNodeFlags.DefaultOpen)
        state.group_open[groupName] = open

        if open then
            for i = 1, #state.buddies do
                local b = state.buddies[i]
                if b.group == groupName then
                    local name = normalize_name(b.name)
                    local tag =
                        (b.online == true and '[ON] ') or
                        (b.online == false and '[OFF] ') or
                        '[?] '

                    local unread = state.unread[name] or 0
                    local suffix = ''
                    if unread > 0 then
                        suffix = string.format(' (%d)%s', unread, blink_suffix(unread))
                    end

                    if imgui.Selectable(tag .. name .. suffix, state.selected == i) then
                        state.selected = i
                        state.unread[name] = 0
                        state.ui.focus_msg = true
                    end

                    -- Right click buddy menu
                    if imgui.BeginPopupContextItem('buddy_ctx_' .. i) then
                        if imgui.MenuItem('Open Chat') then
                            state.selected = i
                            state.unread[name] = 0
                            state.ui.focus_msg = true
                        end
                        if imgui.MenuItem('Ping (/sea)') then
                            enqueue_ping(i)
                            state.ui.status = 'Queued ping: ' .. name
                        end

                        if imgui.BeginMenu('Move to Group') then
                            for g2i = 1, #state.groups do
                                local g2 = state.groups[g2i]
                                if imgui.MenuItem(g2) then
                                    set_buddy_group(i, g2)
                                    save_all()
                                end
                            end
                            imgui.Separator()
                            if imgui.MenuItem('New Group...') then
                                state.ui.move_group_target_idx = i
                                imgui.OpenPopup('new_group_popup')
                            end
                            imgui.EndMenu()
                        end

                        if imgui.MenuItem('Remove') then
                            remove_buddy(name)
                            save_all()
                        end
                        imgui.EndPopup()
                    end
                end
            end
        end
    end

    -- New group popup
    if imgui.BeginPopup('new_group_popup') then
        imgui.Text('Create group and move buddy')
        local ch, ng = imgui.InputText('##newgroup_popup_name', state.ui.new_group_name, 32)
        if ch then state.ui.new_group_name = ng end
        if imgui.Button('Create & Move') then
            if state.ui.move_group_target_idx and state.ui.new_group_name ~= '' then
                local g = ensure_group_exists(state.ui.new_group_name)
                set_buddy_group(state.ui.move_group_target_idx, g)
                state.ui.new_group_name = ''
                state.ui.move_group_target_idx = nil
                save_all()
                imgui.CloseCurrentPopup()
            end
        end
        imgui.SameLine()
        if imgui.Button('Cancel') then
            state.ui.new_group_name = ''
            state.ui.move_group_target_idx = nil
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end

    imgui.NextColumn()

    -- -----------------------------
    -- RIGHT: Tabbed chats
    -- -----------------------------
    if #state.buddies == 0 then
        imgui.Text('Add a buddy to start chatting.')
        imgui.Columns(1)
        imgui.End()
        return
    end

    if imgui.BeginTabBar('chat_tabs') then
        for i = 1, #state.buddies do
            local b = state.buddies[i]
            local name = normalize_name(b.name)
            local unread = state.unread[name] or 0

            local label = name
            if unread > 0 then
                label = string.format('%s (%d)%s', name, unread, blink_suffix(unread))
            end

            local is_open = true
            if imgui.BeginTabItem(label, is_open) then
                if state.selected ~= i then
                    state.selected = i
                    state.unread[name] = 0
                    state.ui.focus_msg = true
                end

                local conv = get_conv(name)

                imgui.BeginChild('chat_scroll_' .. name, { 0, -92 }, true)
                local start = math.max(1, #conv - 250)
                for k = start, #conv do
                    local m = conv[k]
                    local prefix = (m.dir == 'in') and (name .. ': ') or 'You: '
                    imgui.TextWrapped(prefix .. m.text)
                end
                imgui.EndChild()

                if state.ui.focus_msg then
                    imgui.SetKeyboardFocusHere()
                    state.ui.focus_msg = false
                end

                imgui.PushItemWidth(-1)
                local changedMsg, newMsg = imgui.InputTextMultiline(
                    '##msg_' .. name,
                    state.ui.msg_input,
                    1024,
                    { 0, 60 }
                )
                if changedMsg then state.ui.msg_input = newMsg end
                imgui.PopItemWidth()

                -- Enter sends; Shift+Enter newline
                local io = imgui.GetIO()
                local enterPressed = imgui.IsItemActive() and imgui.IsKeyPressed(ImGuiKey.Enter)
                local shiftHeld = io.KeyShift

                if enterPressed and (not shiftHeld) then
                    local msg = state.ui.msg_input:gsub('\r\n', '\n'):gsub('\r', '\n')
                    msg = msg:gsub('\n+$', '')
                    if msg ~= '' then
                        send_tell(name, msg)
                        state.ui.msg_input = ''
                    end
                    state.ui.focus_msg = true
                end

                if imgui.Button('Send##' .. name) then
                    local msg = state.ui.msg_input:gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n+$', '')
                    if msg ~= '' then
                        send_tell(name, msg)
                        state.ui.msg_input = ''
                        state.ui.focus_msg = true
                    end
                end
                imgui.SameLine()
                if imgui.Button('Ping (/sea)##' .. name) then
                    enqueue_ping(i)
                    state.ui.status = 'Queued ping: ' .. name
                end
                imgui.SameLine()
                if imgui.Button('Clear Chat##' .. name) then
                    state.conversations[name] = {}
                    state.unread[name] = 0
                end

                imgui.EndTabItem()
            end
        end
        imgui.EndTabBar()
    end

    imgui.Columns(1)
    imgui.End()
end)
