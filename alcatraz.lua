local ffi = require 'ffi'
local vector = require 'vector'
local base64 = require 'gamesense/base64'
local images = require 'gamesense/images'
local http = require 'gamesense/http'
local vector = require 'vector'
local antiaim_funcs = require 'gamesense/antiaim_funcs'

local native_GetClientEntity = vtable_bind('client.dll', 'VClientEntityList003', 3, 'void*(__thiscall*)(void*, int)')
local classptr = ffi.typeof('void***')
local latency_ptr = ffi.typeof('float(__thiscall*)(void*, int)')

local rawivengineclient = client.create_interface('engine.dll', 'VEngineClient014') or error('VEngineClient014 wasnt found', 2)
local ivengineclient = ffi.cast(classptr, rawivengineclient) or error('rawivengineclient is nil', 2)
local is_in_game = ffi.cast('bool(__thiscall*)(void*)', ivengineclient[0][26]) or error('is_in_game is nil')

local screen = client.screen_size
local elements = {}
local callback = {}
local history = {}
local config_system = {}
callback.history = {}

callback.thread = 'main'
local hitgroup_names = {'generic', 'head', 'chest', 'stomach', 'left arm', 'right arm', 'left leg', 'right leg', 'neck', '?', 'gear'}

local clipboard = {
    ffi = ffi.cdef([[
        typedef int(__thiscall* get_clipboard_text_count)(void*);
        typedef void(__thiscall* set_clipboard_text)(void*, const char*, int);
        typedef void(__thiscall* get_clipboard_text)(void*, int, const char*, int);
    ]]),
    set = function(arg)
        local pointer = ffi.cast(ffi.typeof('void***'), client.create_interface('vgui2.dll', 'VGUI_System010'))
        local func = ffi.cast('set_clipboard_text', pointer[0][9])
        func(pointer, arg, #arg)
    end,
    get = function()
        local pointer = ffi.cast(ffi.typeof('void***'), client.create_interface('vgui2.dll', 'VGUI_System010'))
        local func = ffi.cast('get_clipboard_text_count', pointer[0][7])
        local sizelen = func(pointer)
        local output = ""
        if sizelen > 0 then
            local buffer = ffi.new("char[?]", sizelen)
            local sizefix = sizelen * ffi.sizeof("char[?]", sizelen)
            local extrafunc = ffi.cast('get_clipboard_text', pointer[0][11])
            extrafunc(pointer, 0, buffer, sizefix)
            output = ffi.string(buffer, sizelen-1)
        end
        return output
    end
}

--print(clipboard.set('gearsense'))

--print(clipboard.get())
hotkey_states = {
    [0] = 'Always on',
    'On hotkey',
    'Toggle',
    'Off hotkey'
}

conditions = {
    'Stand',
    'Move',
    'Slow-motion',
    'Crouch',
    'Air',
    'Air + Crouch',
}

conditions_num = {
    '[1]',
    '[2]',
    '[3]',
    '[4]',
    '[5]',
    '[6]',
}

function get_localplayer()
    local localplayer = entity.get_local_player()
    if localplayer == nil then return end
    local me = localplayer
    return me
end

set_visible = function(x, b)
    if type(x) == 'table' then
        for k, v in pairs(x) do
            set_visible(v, b)
        end

        return
    end
    ui.set_visible(x, b)
end

override = function(self, ...)
    pcall(override, self.m_reference, ...)
end

callback.new = function(key, event_name, func)
    local this = {}
    this.m_key = key
    this.m_event_name = event_name
    this.m_func = func
    this.m_result = {}

    local handler = function(...)
        callback.thread = event_name
        this.m_result = { func(...) }
    end

    local protect = function(...)
        local success, result = pcall(handler, ...)

        if success then
            return
        end

        if isDebug then
            result = f('%s, debug info: key = %s, event_name = %s', result, key, event_name)
        end

        die('|!| callback::new - %s', result)
    end

    client.set_event_callback(event_name, protect)
    this.m_protect = protect

    callback.history[key] = this
    return this
end

local decrypt = function(x, key)
    if key == nil then
        key = 11
    end
    local ran_check = false
    local junkcheck, returnget = pcall(function()
        ran_check = true
        x = base64.decode(x)
        local output = ""
        local t = {}
        for str in string.gmatch(x, "([^\\]+)") do
            t[#t+1] = str
        end
        local fix = #t + key
        for i = 1, #t do
            fix = fix + 1 + key
            output = output .. string.char(t[i]-fix)
        end
        return output
    end)
    if junkcheck and ran_check then
        return returnget
    else
        return ""
    end
end

local function encrypt(x, key)
    if key == nil then
        key = 11
    end
    local output = ""
    local algorithm = #x + key
    for i = 1, #x do
        local z = string.sub(x, i,i)
        algorithm = algorithm + 1 + key
        output = output .. "\\" .. (string.byte(z) + algorithm)
    end
    return base64.encode(output)
end

override = function(id, ...)
    if history[callback.thread] == nil then
        history[callback.thread] = {}

        local handler = function()
            local dir = history[callback.thread]

            for k, v in pairs(dir) do
                if v.active then
                    v.active = false;
                    goto skip;
                end

                ui.set(k, unpack(v.value));
                dir[k] = nil;

                ::skip::
            end
        end

        callback.new('override::' .. callback.thread, callback.thread, handler)
    end

    local args = { ... }

    if #args == 0 then
        return
    end

    if history[callback.thread][id] == nil then
        local item = { };
        local value = { ui.get(id) };

        if ui.type(id) == "hotkey" then
            value = {hotkey_states[value[2]]};
        end

        item.value = value;
        history[callback.thread][id] = item;
    end

    history[callback.thread][id].active = true;
    ui.set(id, ...);
end

contains = function(tbl, arg)
    for index, value in next, tbl do 
        if value == arg then 
            return true end 
        end 
    return false
end

local function get_curtime(offset)
    return globals.curtime() - (offset * globals.tickinterval())
end

local function normalize(x, min, max)
    local delta = max - min
    while x < min do
        x = x + delta
    end

    while x > max do
        x = x - delta
    end

    return x
end

function lerp(start, vend, time)
    return start + (vend - start) * time
end

function gradient_text_animated(color1, color2, text, speed)
    local r1, g1, b1, a1 = color1[1], color1[2], color1[3], color1[4]
    local r2, g2, b2, a2 = color2[1], color2[2], color2[3], color2[4]
    local highlight_fraction =  (globals.realtime() / 2 % 0.8 * speed) - 1.5
    local output = ""
    for idx = 1, #text do
        local character = text:sub(idx, idx)
        local character_fraction = idx / #text
        local r, g, b, a = r1, g1, b1, a1
        local highlight_delta = (character_fraction - highlight_fraction)
        if highlight_delta >= 0.2 and highlight_delta <= 1.5 then
            if highlight_delta > 0.8 then
                highlight_delta = 1.5 - highlight_delta
            end
            local r_fraction, g_fraction, b_fraction, a_fraction = r2 - r, g2 - g, b2 - b, a2 - a
            r = r + r_fraction * highlight_delta
            g = g + g_fraction * highlight_delta
            b = b + b_fraction * highlight_delta
            a = a + a_fraction * highlight_delta
        end
        output = output .. ('\a%0x%0x%0x%0x%s'):format(r, g, b, a, text:sub(idx, idx))
    end
    return output
end

--[[
handle_tickbase = function()
    if not entity.is_alive(entity.get_local_player()) then
        return
    end
    local tickbase = entity.get_prop(entity.get_local_player(), "m_nTickBase")
    cache.defensive = math.abs(tickbase - cache.checker)
    cache.checker = math.max(tickbase, cache.checker or 0)

    cache.defensive_bool = cache.defensive > 3 and cache.defensive < 10
end]]

elements = {
    tab_list = ui.new_combobox('AA', 'Anti-aimbot angles', 'Tab', {'Ragebot', 'Anti-Aim', 'Anti-Aim tweaks', 'Visual', 'Misc', 'Config'}),
    rage = {
       ideal_tick = ui.new_checkbox('AA', 'Anti-aimbot angles', 'Ideal tick'),
       ideal_tick_settings = ui.new_multiselect('AA', 'Anti-aimbot angles', 'Ideal tick settings', {'Doubletap', 'Freestanding', 'Edge Yaw'}),
	   exploit_manipulation = ui.new_combobox('AA', 'Anti-aimbot angles', 'Exploit FL manipulation', {'None', 'Disable'}),
       aimbot_logging = ui.new_checkbox('AA', 'Anti-aimbot angles', 'Aimbot logging'),
    },
    anti_aim = {
        enable = ui.new_checkbox('AA', 'Anti-aimbot angles', 'alcatraz ~ anti-aimbot switch'),
        tweaks_selector = ui.new_multiselect('AA', 'Anti-aimbot angles', 'Tweaks', {'Avoid Backstab', 'Defensive anti-aim', 'Adjust on-shot fakelag', 'Force defensive in air', 'Fast ladder', 'Manual anti-aim', 'Freestanding', 'Edge yaw'}),
        condition_selector = ui.new_combobox('AA', 'Anti-aimbot angles', 'Condition', conditions),
    },
    tweaks = {
        left_manual = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Left manual', false, 0),
        backward_manual = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Backward manual', false, 0),
        forward_manual = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Forward manual', false, 0),
        right_manual = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Right manual', false, 0),
        freestanding = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Freestanding', false, 0),
        edge_yaw = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Edge yaw', false, 0),
    },
    visuals = {
        selector = ui.new_multiselect('AA', 'Anti-aimbot angles', 'Visual features', {'Screen indication', 'Screen logging', 'Damage indicator', 'Peek assist color based on exploit'}),
        fade_animation = ui.new_checkbox('AA', 'Anti-aimbot angles', 'Fade animation')
        --ui = {
        --    select = ui.new_multiselect('AA', 'Anti-aimbot angles', 'UI', {'Watermark', 'Keybinds'}),
        --    alpha = ui.new_slider('AA', 'Anti-aimbot angles', 'Alpha', 0, 255, 125, true, '' , 1),
        --    color = ui.new_color_picker('AA', 'Anti-aimbot angles', 'Accent color', 255, 255, 255, 255)
        --},
    },
    misc = {
        anti_defensive = ui.new_checkbox('AA', 'Anti-aimbot angles', 'Anti defensive'),
        anti_defensive_key = ui.new_hotkey('AA', 'Anti-aimbot angles', 'Anti defensive', true, 0),
        animation_breakers = ui.new_multiselect('AA', 'Anti-aimbot angles', 'Anim. breakers', { 'Leg breaker', 'Air legs', 'Zero pitch on land', 'Move lean' }),
        leg_breaker = ui.new_combobox('AA', 'Anti-aimbot angles', 'Leg breaker', {'Static', 'Walking'}),
        leg_breaker_type = ui.new_combobox('AA', 'Anti-aimbot angles', 'Leg breaker type', {'Follow direction', 'Jitter'}),
        air_legs = ui.new_combobox('AA', 'Anti-aimbot angles', 'Air legs', {'Static', 'Walking'}),
        move_lean_multiplayer = ui.new_slider('AA', 'Anti-aimbot angles', 'Move lean multiplayer', 0, 100, 25, true, '°' , 1),
    },
    cfg = {
        export = ui.new_button('AA', 'Anti-aimbot angles', 'Export', function() end),
        load_default = ui.new_button('AA', 'Anti-aimbot angles', 'Load default', function() end),
        import = ui.new_button('AA', 'Anti-aimbot angles', 'Import', function() end),
    },
}

for i = 1, 6 do
    elements.anti_aim[i] = {
        pitch = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Pitch', {'Off', 'Default', 'Up', 'Down', 'Minimal', 'Random'}),
        yaw_base = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Yaw', {'Local view', 'At targets'}),
        yaw_type = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Yaw', {'Off', '180', 'Spin', 'Static', '180 Z', 'Crosshair', '180 Left/Right'}),
        yaw_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Yaw value', -180, 180, 0, true, '', 1),
        left_yaw_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Left yaw', -180, 180, 0, true, '', 1),
        right_yaw_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Right yaw', -180, 180, 0, true, '', 1),
        yaw_jitter = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Jitter yaw', {'Off', 'Offset', 'Center', 'Random', '180 Z', 'Skitter'}),
        jitter_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Jitter value', -180, 180, 0, true, '', 1),
        body_yaw = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Body yaw', {'Off', 'Opposite', 'Jitter', 'Static'}),
        body_yaw_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Body yaw value', -180, 180, 0, true, '', 1),
        fs_body_yaw = ui.new_checkbox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Freestanding body yaw'),
        
        defensive_anti_aim = ui.new_checkbox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Enable defensive anti-aim'),
        defensive_pitch = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Defensive pitch', {'Off', 'Default', 'Up', 'Down', 'Minimal', 'Random', 'Custom'}),
        defensive_pitch_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Pitch value', -89, 89, 0, true, '', 1),
        defensive_yaw = ui.new_combobox('AA', 'Anti-aimbot angles', conditions_num[i] ..' Defensive yaw', {'Off', '180', 'Spin', 'Static', '180 Z', 'Crosshair', '180 Left/Right'}),
        defensive_yaw_value = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' value', -180, 180, 0, true, '', 1),
        defensive_trigger = ui.new_multiselect('AA', 'Anti-aimbot angles', conditions_num[i] ..' Triggers', {'Doubletap', 'On-shot anti-aim'}),
        --defensive_timer = ui.new_slider('AA', 'Anti-aimbot angles', conditions_num[i] ..' Defensive deley timer', -2, 10, 0, true, '', 1),
    }
end

local reference = {
    RAGE = {
        aimbot = {
            min_damage = ui.reference('RAGE', 'Aimbot', 'Minimum damage'),
            min_damage_override = {ui.reference('RAGE', 'Aimbot', 'Minimum damage override')},
            force_safe_point = ui.reference('RAGE', 'Aimbot', 'Force safe point'),
            force_body_aim = ui.reference('RAGE', 'Aimbot', 'Force body aim'),
            double_tap = { ui.reference('RAGE', 'Aimbot', 'Double tap') },
        },

        other = {
            quick_peek_assist = {ui.reference('RAGE', 'Other', 'Quick peek assist')},
            quick_peek_assist_mode = {ui.reference('RAGE', 'Other', 'Quick peek assist mode')},
            duck_peek_assist = ui.reference('RAGE', 'Other', 'Duck peek assist'),
        },
    },

    AA = {
        angles = {
            enabled = ui.reference('AA', 'Anti-aimbot angles', 'Enabled'),
            pitch = {ui.reference('AA', 'Anti-aimbot angles', 'Pitch')},
            yaw_base = ui.reference('AA', 'Anti-aimbot angles', 'Yaw base'),
            yaw = { ui.reference('AA', 'Anti-aimbot angles', 'Yaw') },
            yaw_jitter = { ui.reference('AA', 'Anti-aimbot angles', 'Yaw jitter') },
            body_yaw = { ui.reference('AA', 'Anti-aimbot angles', 'Body yaw') },
            freestanding_body_yaw = ui.reference('AA', 'Anti-aimbot angles', 'Freestanding body yaw'),
            edge_yaw = ui.reference('AA', 'Anti-aimbot angles', 'Edge yaw'),
            freestanding = { ui.reference('AA', 'Anti-aimbot angles', 'Freestanding') },
            roll = ui.reference('AA', 'Anti-aimbot angles', 'Roll'),
        },

        fakelag = {
            enabled = ui.reference('AA', 'Fake lag', 'Enabled'),
            amount = ui.reference('AA', 'Fake lag', 'Amount'),
            variance = ui.reference('AA', 'Fake lag', 'Variance'),
            limit = ui.reference('AA', 'Fake lag', 'Limit'),
        },

        other = {
            slow_motion = { ui.reference('AA', 'Other', 'Slow motion') },
            leg_movement = ui.reference('AA', 'Other', 'Leg movement'),
            on_shot_antiaim = { ui.reference('AA', 'Other', 'On shot anti-aim') },
            fake_peek = ui.reference('AA', 'Other', 'Fake peek'),
        },
    },

    misc = {
        clantag = ui.reference('Misc', 'Miscellaneous', 'Clan tag spammer'),
        ping_spike = { ui.reference('Misc', 'Miscellaneous', 'Ping spike') },
        color = ui.reference('Misc', 'Settings', 'Menu color'),
    },
}

local cache = {
    RAGE = {
        other = {
            duck_peek_assist = ui.get(reference.RAGE.other.duck_peek_assist)
        },
    },

    AA = {
    	fakelag = {
    		limit = ui.get(reference.AA.fakelag.limit)
    	}, 
    },
    last_body_yaw = 0,
    m_iSide = 0,
    prev_side = 0,
    canbepressed = true,
    --defensive = 0,
    --checker = 0,
    --defensive_bool = false,
    defensive_sim = 0,
    prev_sim = 0,
    defensive_sim_bool = false,
    ground_ticks = 0,
    x_add = 0
}

handle_defensive = function()
    local lp = entity.get_local_player()
    if lp == nil or not entity.is_alive(lp) then
        return
    end
    local Entity = native_GetClientEntity(lp)
    cache.prev_sim = ffi.cast("float*", ffi.cast("uintptr_t", Entity) + 0x26C)[0]
    local m_flSimulationTime = entity.get_prop(lp, "m_flSimulationTime")
    local difference = cache.prev_sim - m_flSimulationTime
    if difference > 0 then
        cache.defensive_sim = globals.tickcount() + toticks(difference - client.latency())
        return;
    end
    cache.defensive_sim_bool = (globals.tickcount() - math.random(0, 100)/100) < cache.defensive_sim
end

get_exploit_charge = function()
    local target = entity.get_local_player()
    if not target then
        return
    end
    local weapon = entity.get_player_weapon(target)
    if target == nil or weapon == nil then
        return false
    end

    if ui.get(reference.RAGE.aimbot.double_tap[2]) then
        if get_curtime(16) < entity.get_prop(target, 'm_flNextAttack') then
            return false
        end
        if get_curtime(0) < entity.get_prop(weapon, 'm_flNextPrimaryAttack') then
            return false
        end
        return true
    end
end

function get_state()
    if get_localplayer() == nil then return end
    local speed = vector(entity.get_prop(get_localplayer(), 'm_vecVelocity')):length()
    if not speed then return end
    local flags = entity.get_prop(get_localplayer(), 'm_fFlags')
    if not flags then return end
    if bit.band(flags, 1) == 1 then
        if bit.band(flags, 4) == 4 or ui.get(reference.RAGE.other.duck_peek_assist) then
            return 4 -- [crouching]
        else
            if speed <= 3 then
                return 1 -- [standing]
            else
                if ui.get(reference.AA.other.slow_motion[2]) then
                    return 3 -- [moving]
                else
                    return 2 -- [slowwalk]
                end
            end
        end
    elseif
        bit.band(flags, 1) == 0 then
        if bit.band(flags, 4) == 4 then
            return 6 -- [air-C]
        else
            return 5 -- [air]
        end
    end
end

condition_get = function()
    if ui.get(elements.anti_aim.condition_selector) == conditions[1] then
        return 1
    end
    if ui.get(elements.anti_aim.condition_selector) == conditions[3] then
        return 3
    end
    if ui.get(elements.anti_aim.condition_selector) == conditions[5] then
        return 5
    end
    if ui.get(elements.anti_aim.condition_selector) == conditions[6] then
        return 6
    end
    if ui.get(elements.anti_aim.condition_selector) == conditions[4] then
        return 4
    end
    if ui.get(elements.anti_aim.condition_selector) == conditions[2] then
        return 2
    end
end

function menu_elements()
    rage, anti_aim, anti_aim_tweaks, visuals, misc, config = ui.get(elements.tab_list) == 'Ragebot', ui.get(elements.tab_list) == 'Anti-Aim', ui.get(elements.tab_list) == 'Anti-Aim tweaks', ui.get(elements.tab_list) == 'Visual', ui.get(elements.tab_list) == 'Misc', ui.get(elements.tab_list) == 'Config'
    state = condition_get()

    set_visible(elements.rage.ideal_tick, rage)
    set_visible(elements.rage.ideal_tick_settings, ui.get(elements.rage.ideal_tick) and rage)
    set_visible(elements.rage.exploit_manipulation, rage) 
    set_visible(elements.rage.aimbot_logging, rage)

    set_visible(elements.anti_aim.enable, anti_aim) 
    set_visible(elements.anti_aim.tweaks_selector, anti_aim and ui.get(elements.anti_aim.enable)) 
    set_visible(elements.anti_aim.condition_selector, anti_aim and ui.get(elements.anti_aim.enable)) 
    for i = 1, 6 do
        set_visible(elements.anti_aim[i].pitch, i == state and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].yaw_base, i == state and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].yaw_type, i == state and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].yaw_value, i == state and (ui.get(elements.anti_aim[i].yaw_type) ~= 'Off' and ui.get(elements.anti_aim[i].yaw_type) ~= '180 Left/Right') and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].left_yaw_value, i == state and (ui.get(elements.anti_aim[i].yaw_type) ~= 'Off' and ui.get(elements.anti_aim[i].yaw_type) == '180 Left/Right') and anti_aim and ui.get(elements.anti_aim.enable)) 
        set_visible(elements.anti_aim[i].right_yaw_value, i == state and (ui.get(elements.anti_aim[i].yaw_type) ~= 'Off' and ui.get(elements.anti_aim[i].yaw_type) == '180 Left/Right') and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].yaw_jitter, i == state and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].jitter_value, i == state and ui.get(elements.anti_aim[i].yaw_jitter) ~= 'Off' and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].body_yaw, i == state and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].body_yaw_value, i == state and ui.get(elements.anti_aim[i].body_yaw) ~= 'Off' and anti_aim and ui.get(elements.anti_aim.enable))
        set_visible(elements.anti_aim[i].fs_body_yaw, i == state and ui.get(elements.anti_aim[i].body_yaw) ~= 'Off' and anti_aim and ui.get(elements.anti_aim.enable))

        set_visible(elements.anti_aim[i].defensive_anti_aim, i == state and anti_aim and ui.get(elements.anti_aim.enable) and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim'))
        set_visible(elements.anti_aim[i].defensive_pitch, i == state and anti_aim and ui.get(elements.anti_aim.enable) and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
        set_visible(elements.anti_aim[i].defensive_pitch_value, i == state and anti_aim and ui.get(elements.anti_aim.enable) and ui.get(elements.anti_aim[i].defensive_pitch) == 'Custom' and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
        set_visible(elements.anti_aim[i].defensive_yaw, i == state and anti_aim and ui.get(elements.anti_aim.enable) and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
        set_visible(elements.anti_aim[i].defensive_yaw_value, i == state and anti_aim and ui.get(elements.anti_aim.enable) and ui.get(elements.anti_aim[i].defensive_yaw) ~= 'Off' and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
        set_visible(elements.anti_aim[i].defensive_trigger, i == state and anti_aim and ui.get(elements.anti_aim.enable) and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
        --set_visible(elements.anti_aim[i].defensive_timer, i == state and anti_aim and ui.get(elements.anti_aim.enable) and contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') and  ui.get(elements.anti_aim[i].defensive_anti_aim))
    end

    set_visible(elements.tweaks.left_manual, contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))
    set_visible(elements.tweaks.backward_manual, contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))
    set_visible(elements.tweaks.forward_manual, contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))
    set_visible(elements.tweaks.right_manual, contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))
    
    set_visible(elements.tweaks.freestanding, contains(ui.get(elements.anti_aim.tweaks_selector), 'Freestanding') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))
    set_visible(elements.tweaks.edge_yaw, contains(ui.get(elements.anti_aim.tweaks_selector), 'Edge yaw') and anti_aim_tweaks and ui.get(elements.anti_aim.enable))

    set_visible(elements.visuals.selector, visuals)
    set_visible(elements.visuals.fade_animation, visuals and contains(ui.get(elements.visuals.selector), 'Screen indication')) 
    --set_visible(elements.visuals.ui.select, visuals and contains(ui.get(elements.visuals.selector), 'UI')) 
    --set_visible(elements.visuals.ui.alpha, visuals and contains(ui.get(elements.visuals.selector), 'UI')) 
    --set_visible(elements.visuals.ui.color, visuals and contains(ui.get(elements.visuals.selector), 'UI')) 

    set_visible(elements.misc.anti_defensive, misc)
    set_visible(elements.misc.anti_defensive_key, misc) 
    set_visible(elements.misc.animation_breakers, misc) 

    set_visible(elements.misc.leg_breaker, misc and contains(ui.get(elements.misc.animation_breakers), 'Leg breaker')) 
    set_visible(elements.misc.leg_breaker_type, misc and contains(ui.get(elements.misc.animation_breakers), 'Leg breaker') and ui.get(elements.misc.leg_breaker) == 'Static') 
    set_visible(elements.misc.air_legs, misc and contains(ui.get(elements.misc.animation_breakers), 'Air legs'))
    set_visible(elements.misc.move_lean_multiplayer, misc and contains(ui.get(elements.misc.animation_breakers), 'Move lean'))

    set_visible(elements.cfg.export, config) 
    set_visible(elements.cfg.load_default, config) 
    set_visible(elements.cfg.import, config) 

    set_visible(reference.AA.angles, false)
end

function menu_elements_on_shutdown()
    set_visible(reference.AA.angles, true)
end

function ideal_tick_f()
    if ui.get(elements.rage.ideal_tick) then
        local should_tick = (ui.get(reference.RAGE.other.quick_peek_assist[2]) and true or false)
        override(reference.RAGE.aimbot.double_tap[2], (should_tick and contains(ui.get(elements.rage.ideal_tick_settings), 'Doubletap')) and 'Always on' or 'Toggle')
        override(reference.AA.angles.freestanding[1], should_tick and contains(ui.get(elements.rage.ideal_tick_settings), 'Freestanding'))
        override(reference.AA.angles.freestanding[2], (should_tick and contains(ui.get(elements.rage.ideal_tick_settings), 'Freestanding')) and 'Always on' or 'Toggle')
        override(reference.AA.angles.edge_yaw, should_tick and contains(ui.get(elements.rage.ideal_tick_settings), 'Edge Yaw'))
    end
end

function exploit_manipulation()
    if ui.get(elements.rage.exploit_manipulation) == 'Disable' and (ui.get(reference.RAGE.aimbot.double_tap[1]) and ui.get(reference.RAGE.aimbot.double_tap[2])) and not ui.get(reference.RAGE.other.duck_peek_assist) then
        ui.set(reference.AA.fakelag.limit, 1)
    elseif contains(ui.get(elements.anti_aim.tweaks_selector), 'Adjust on-shot fakelag') and (ui.get(reference.AA.other.on_shot_antiaim[1]) and ui.get(reference.AA.other.on_shot_antiaim[2])) and not ui.get(reference.RAGE.other.duck_peek_assist) then 
        ui.set(reference.AA.fakelag.limit, 1)
    else
        ui.set(reference.AA.fakelag.limit, cache.AA.fakelag.limit)
    end
end

function force_defensive_in_air(cmd)
    state = get_state()
    if contains(ui.get(elements.anti_aim.tweaks_selector), 'Force defensive in air') then
        cmd.force_defensive = (state == 5 or state == 6) and true or false
    end
end

anti_backstab = function(cmd)
    if not contains(ui.get(elements.anti_aim.tweaks_selector), 'Avoid Backstab') then
        return
    end

    local lp = entity.get_local_player()
    if not lp then
        return
    end

    local eye = vector(client.eye_position())

    local target = {
        idx = nil,
        distance = 169,
    }

    local enemies = entity.get_players(true)

    for _, entindex in pairs(enemies) do
        local weapon = entity.get_player_weapon(entindex)
        if not weapon then
            goto skip
        end

        local weapon_name = entity.get_classname(weapon)
        if not weapon_name then
            goto skip
        end
        if weapon_name ~= 'CKnife' then
            goto skip
        end

        local origin = vector(entity.get_origin(entindex))
        local distance = eye:dist(origin)

        if distance > target.distance then
            goto skip
        end

        target.idx = entindex
        target.distance = distance
        ::skip::
    end

    if not target.idx then
        return
    end

    local origin = vector(entity.get_origin(target.idx))
    local delta = eye - origin
    local angle = vector(delta:angles())
    local camera = vector(client.camera_angles())
    local yaw = normalize(angle.y - camera.y, -180, 180)

    override(reference.AA.angles.yaw_base, 'Local view')
    override(reference.AA.angles.yaw[2], yaw)

    return true
end

time = globals.realtime()
function manual_aa()
    cache.canbepressed = time + 0.1 < globals.realtime()
    if ui.get(elements.tweaks.left_manual) and cache.canbepressed then
        cache.m_iSide = 1   
        if cache.prev_side == cache.m_iSide then
            cache.m_iSide = 0
        end
        time = globals.realtime()
    end
    if ui.get(elements.tweaks.right_manual) and cache.canbepressed then
        cache.m_iSide = 2
        if cache.prev_side == cache.m_iSide then
            cache.m_iSide = 0
        end
        time = globals.realtime()
    end
    if ui.get(elements.tweaks.forward_manual) and cache.canbepressed then
        cache.m_iSide = 3
        if cache.prev_side == cache.m_iSide then
            cache.m_iSide = 0
        end
        time = globals.realtime()
    end
    if ui.get(elements.tweaks.backward_manual) and cache.canbepressed then
        cache.m_iSide = 4
        if cache.prev_side == cache.m_iSide then
            cache.m_iSide = 0
        end
        time = globals.realtime()
    end

    cache.prev_side = cache.m_iSide
    
    if cache.m_iSide == 1 then return 1 end 
    if cache.m_iSide == 2 then return 2 end 
    if cache.m_iSide == 3 then return 3 end
    if cache.m_iSide == 4 then return 4 end
    if cache.m_iSide == 0 then return 0 end
end

function anti_aim_settings(cmd)
    local state_id = get_state()
    local body_yaw = entity.get_prop(get_localplayer(), 'm_flPoseParameter', 11)
    local is_anti_backstabing = anti_backstab(cmd)
    --local is_defensive = cache.defensive_bool cache.defensive_sim_bool
    local is_defensive = cache.defensive_sim_bool
    --print(is_defensive)
    --print(is_anti_backstabing)

    if cmd.chokedcommands == 0 then
        cache.last_body_yaw = body_yaw * 120 - 60
    end

    if not is_anti_backstabing or (contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') and manual_aa() == 0) or is_defensive then
        override(reference.AA.angles.pitch[1] , ui.get(elements.anti_aim[state_id].pitch))
        if ui.get(elements.anti_aim[state_id].yaw_type) == '180 Left/Right' then
            override(reference.AA.angles.yaw[1] , '180')
            override(reference.AA.angles.yaw[2] , cache.last_body_yaw > 0 and ui.get(elements.anti_aim[state_id].right_yaw_value) or cache.last_body_yaw < 0 and ui.get(elements.anti_aim[state_id].left_yaw_value) or 0)
        else
            override(reference.AA.angles.yaw[1] , ui.get(elements.anti_aim[state_id].yaw_type))
            override(reference.AA.angles.yaw[2] , ui.get(elements.anti_aim[state_id].yaw_value))
        end
    end

    override(reference.AA.angles.yaw_base , ui.get(elements.anti_aim[state_id].yaw_base))
    override(reference.AA.angles.yaw_jitter[1] , ui.get(elements.anti_aim[state_id].yaw_jitter))
    override(reference.AA.angles.yaw_jitter[2] , ui.get(elements.anti_aim[state_id].jitter_value))
    override(reference.AA.angles.body_yaw[1] , ui.get(elements.anti_aim[state_id].body_yaw))
    override(reference.AA.angles.body_yaw[2] , ui.get(elements.anti_aim[state_id].body_yaw_value))
    override(reference.AA.angles.freestanding_body_yaw , ui.get(elements.anti_aim[state_id].fs_body_yaw))
end

ui.set(elements.tweaks.left_manual, 'On hotkey')
ui.set(elements.tweaks.backward_manual, 'On hotkey')
ui.set(elements.tweaks.forward_manual, 'On hotkey')
ui.set(elements.tweaks.right_manual, 'On hotkey')

function anti_aim_tweaks_settings(cmd)
    local is_anti_backstabing = anti_backstab(cmd)
    should_tick = (ui.get(elements.rage.ideal_tick) and ui.get(reference.RAGE.other.quick_peek_assist[2]) and true or false)
    if is_anti_backstabing then return end
    if contains(ui.get(elements.anti_aim.tweaks_selector), 'Manual anti-aim') then
        if manual_aa() == 1 then
            override(reference.AA.angles.yaw[1] , '180')
            ui.set(reference.AA.angles.yaw[2],-90)
        end
        if manual_aa() == 2 then
            override(reference.AA.angles.yaw[1] , '180')
            ui.set(reference.AA.angles.yaw[2],90)
        end
        if manual_aa() == 3 then
            override(reference.AA.angles.yaw[1] , '180')
            ui.set(reference.AA.angles.yaw[2],180)
        end
        if manual_aa() == 4 then
            override(reference.AA.angles.yaw[1] , '180')
            ui.set(reference.AA.angles.yaw[2], 0)
        end
    end
    if not (should_tick and (contains(ui.get(elements.rage.ideal_tick_settings), 'Freestanding') or contains(ui.get(elements.rage.ideal_tick_settings), 'Edge Yaw'))) then
        if contains(ui.get(elements.anti_aim.tweaks_selector), 'Freestanding') then
            override(reference.AA.angles.freestanding[1], ui.get(elements.tweaks.freestanding)) 
            override(reference.AA.angles.freestanding[2], ui.get(elements.tweaks.freestanding) and 'Always on' or 'Toggle')
        end
        if contains(ui.get(elements.anti_aim.tweaks_selector), 'Edge yaw') then
            override(reference.AA.angles.edge_yaw, ui.get(elements.tweaks.edge_yaw))
        end
    end
    --{'Avoid Backstab', 'Defensive anti-aim', 'Adjust on-shot fakelag', 'Manual anti-aim', 'Freestanding', 'Edge yaw'}
end

function defensive_anti_aim_f()
    if not contains(ui.get(elements.anti_aim.tweaks_selector), 'Defensive anti-aim') then return end
    local state_id = get_state()
    local body_yaw = entity.get_prop(get_localplayer(), 'm_flPoseParameter', 11)
    local is_anti_backstabing = anti_backstab(cmd)
    local is_defensive = cache.defensive_sim_bool
    --print(is_defensive)
    if not (is_anti_backstabing or manual_aa() ~= 0) then
        if ui.get(elements.anti_aim[state_id].defensive_anti_aim) and ( (contains(ui.get(elements.anti_aim[state_id].defensive_trigger), 'Doubletap') and (ui.get(reference.RAGE.aimbot.double_tap[1]) and ui.get(reference.RAGE.aimbot.double_tap[2]))) or (contains(ui.get(elements.anti_aim[state_id].defensive_trigger), 'On-shot anti-aim') and (ui.get(reference.AA.other.on_shot_antiaim[1]) and ui.get(reference.AA.other.on_shot_antiaim[2]))) )  then
            if is_defensive then           
                override(reference.AA.angles.pitch[1] , ui.get(elements.anti_aim[state_id].defensive_pitch))
                override(reference.AA.angles.pitch[2] , ui.get(elements.anti_aim[state_id].defensive_pitch_value))
                if ui.get(elements.anti_aim[state_id].defensive_yaw) == '180 Left/Right' then
                    override(reference.AA.angles.yaw[1] , '180')
                    override(reference.AA.angles.yaw[2] , cache.last_body_yaw > 0 and (ui.get(elements.anti_aim[state_id].defensive_yaw_value) * -1) or cache.last_body_yaw < 0 and ui.get(elements.anti_aim[state_id].defensive_yaw_value) or 0)
                else
                    override(reference.AA.angles.yaw[1] , ui.get(elements.anti_aim[state_id].defensive_yaw))
                    override(reference.AA.angles.yaw[2] , ui.get(elements.anti_aim[state_id].defensive_yaw_value))
                end
            end
        end
    end
end

function fast_ladder(cmd)
    if not contains(ui.get(elements.anti_aim.tweaks_selector), 'Fast ladder') then return end
    local me = entity.get_local_player();
    if me == nil or entity.get_prop(me, 'm_MoveType') ~= 9 then
        return;
    end
    local wpn = entity.get_player_weapon(me);
    if wpn == nil then
        return;
    end
    local throw_time = entity.get_prop(wpn, 'm_fThrowTime');
    if throw_time ~= nil and throw_time ~= 0 then
        return;
    end
    if cmd.in_forward == 1 or cmd.in_back == 1 then
        cmd.in_moveleft = cmd.in_back;
        cmd.in_moveright = cmd.in_back == 1 and 0 or 1;
        if cmd.sidemove == 0 then
            cmd.yaw = cmd.yaw + 45;
        end
        if cmd.sidemove > 0 then
            cmd.yaw = cmd.yaw - 1;
        end
        if cmd.sidemove < 0 then
            cmd.yaw = cmd.yaw + 90;
        end
    end
end

function peek_assist_clr()
    if not contains(ui.get(elements.visuals.selector), 'Peek assist color based on exploit') then return end
    local green_clr, red_clr = {160, 200, 45, 255}, {255, 0, 0, 255}
    if (ui.get(reference.RAGE.aimbot.double_tap[2]) and get_exploit_charge()) then
        override(reference.RAGE.other.quick_peek_assist_mode[2], 160, 200, 45, 255)
    else
        override(reference.RAGE.other.quick_peek_assist_mode[2], 255, 0, 0, 255)
    end
end

function watermark_f()
    if not (contains(ui.get(elements.visuals.selector), 'UI') and contains(ui.get(elements.visuals.ui.select), 'Watermark')) then return end
    alpha, color = ui.get(elements.visuals.ui.alpha), {ui.get(elements.visuals.ui.color)}
    local hours, minutes, seconds, milliseconds  = client.system_time()
    local time = hours .. ':' .. minutes .. ':' .. seconds
    local text
    if is_in_game(is_in_game) == true then
        local latency = math.floor(client.latency()*1000)
        if latency > 5 then
            text = 'gamesense | ' .. entity.get_player_name(get_localplayer()) .. " | deley:" .. latency .. "ms | " .. time
        else
            text = 'gamesense | ' .. entity.get_player_name(get_localplayer()) .. " | " .. time
        end
    else
        text = 'gamesense | ' .. entity.get_player_name(get_localplayer()) .. " | " .. time
    end
    text_x, text_y = renderer.measure_text(nil, text)
    x, y = screen()
    renderer.rectangle(x - text_x - 20, 10, text_x + 10, text_y + 7, 0, 0, 0, alpha)
    renderer.rectangle(x - text_x - 20, 10, text_x + 10, 2, color[1], color[2], color[3], 255)
    renderer.text(x - text_x - 15, 14, 255, 255, 255, 255, nil, 0, text)
end

local indication_tbl = {
    {ref = reference.misc.ping_spike[2], text = 'ping', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
    {ref = reference.RAGE.aimbot.double_tap[2], text = 'doubletap', color_r = 0, color_g = 0, color_b = 0, color_a = 0},
    {ref = reference.AA.other.on_shot_antiaim[2], text = 'onshot', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
    {ref = reference.RAGE.aimbot.min_damage_override[2], text = 'damage', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
    {ref = reference.RAGE.other.duck_peek_assist, text = 'duck', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
    {ref = reference.AA.angles.freestanding[2], text = 'freestand', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
    {ref = reference.RAGE.other.quick_peek_assist[2], text = 'peek', color_r = 255, color_g = 255, color_b = 255, color_a = 0},
}

function indication()
    if not contains(ui.get(elements.visuals.selector), 'Screen indication') then return end
    local fade = ui.get(elements.visuals.fade_animation)
    local y_add = 8
    x, y = screen()
    size_x, size_y = renderer.measure_text('-', 'ALCATRAZ.LUA')
    if not entity.is_alive(get_localplayer()) then return end
    cache.x_add = math.floor(lerp(cache.x_add, entity.get_prop(get_localplayer(), 'm_bIsScoped') == 1 and 50 or 0, globals.frametime() * 15))
    renderer.text(x/2 - size_x/2 + cache.x_add, y/1.92, 255, 255, 255, 255, '-', nil, fade and gradient_text_animated({255,255,255, 255}, {0,0,0, 255}, 'ALCATRAZ.LUA', 4) or 'ALCATRAZ.LUA')
    for i = 1, #indication_tbl do
        text_x, text_y = renderer.measure_text('-', indication_tbl[i].text:upper())
        local active = ui.get(indication_tbl[i].ref)
        if active then
            indication_tbl[i].color_a = lerp(indication_tbl[i].color_a, 255, globals.frametime() * 14)
            y_add = y_add + 1
        else
            indication_tbl[i].color_a = lerp(indication_tbl[i].color_a, 0, globals.frametime() * 16)
        end
        indication_tbl[1].color_r = 255 - lerp(indication_tbl[1].color_r, math.floor((ui.get(reference.misc.ping_spike[3]) / 200) * 255), globals.frametime() * 14)
        indication_tbl[1].color_b = 255 - lerp(indication_tbl[1].color_b, math.floor((ui.get(reference.misc.ping_spike[3]) / 200) * 255), globals.frametime() * 14)

        if get_exploit_charge() and not ui.get(reference.RAGE.other.duck_peek_assist) then
            indication_tbl[2].color_r = lerp(indication_tbl[2].color_r, 255, globals.frametime() * 14)
            indication_tbl[2].color_g = lerp(indication_tbl[2].color_g, 255, globals.frametime() * 14)
            indication_tbl[2].color_b = lerp(indication_tbl[2].color_b, 255, globals.frametime() * 14) 
        else
            indication_tbl[2].color_r = lerp(indication_tbl[2].color_r, 255, globals.frametime() * 14)
            indication_tbl[2].color_g = lerp(indication_tbl[2].color_g, 0, globals.frametime() * 14)
            indication_tbl[2].color_b = lerp(indication_tbl[2].color_b, 0, globals.frametime() * 14)
        end
        renderer.text(x/2 - text_x/2 + cache.x_add, y/1.92 + y_add , indication_tbl[i].color_r, indication_tbl[i].color_g, indication_tbl[i].color_b, indication_tbl[i].color_a, '-', nil, indication_tbl[i].text:upper())
        y_add = y_add + 8 * (indication_tbl[i].color_a / 255)
    end
end

function anti_defensive_f()
    local ax = cvar.cl_lagcompensation
    local sv_cheat = cvar.sv_cheats
    if ui.get(elements.misc.anti_defensive) then
        if ui.get(elements.misc.anti_defensive) then
            if ax:get_int() ~= 0 then
               ax:set_int(0)
               sv_cheat:set_int(1) 
            end
        else
            if ax:get_int() ~= 1 then
               ax:set_int(1)
               sv_cheat:set_int(1) 
            end
        end
    end 
end

prevent_mouse = function(cmd)
    if ui.is_menu_open() then
        cmd.in_attack = false
    end
end

local char_ptr = ffi.typeof('char*')
local nullptr = ffi.new('void*')
local class_ptr = ffi.typeof('void***')

do 
    local animation_layer_t = ffi.typeof([[
        struct {                                        char pad0[0x18];
            uint32_t    sequence;
            float       prev_cycle;
            float       weight;
            float       weight_delta_rate;
            float       playback_rate;
            float       cycle;
            void        *entity;                        char pad1[0x4];
        } **
    ]])

    function animations()
        local this = ui.get(elements.misc.animation_breakers)
        local legs_type = ui.get(elements.misc.leg_breaker) 
        local legs_type_2 = ui.get(elements.misc.leg_breaker_type) 
        local air_legs = ui.get(elements.misc.air_legs)
        local mv_l = ui.get(elements.misc.move_lean_multiplayer)
        local lp = entity.get_local_player()
        local in_air = get_state() == 5 or get_state() == 6

        if not lp then return end
        local pEnt = ffi.cast(class_ptr, native_GetClientEntity(lp))
        if pEnt == nullptr then return end

        local anim_layers_leg = ffi.cast(animation_layer_t, ffi.cast(char_ptr, pEnt) + 0x2990)[0][6]
        local anim_layers_lean = ffi.cast(animation_layer_t, ffi.cast(char_ptr, pEnt) + 0x2990)[0][12]

        if contains(this, 'Leg breaker') then
            if legs_type == 'Static' then
                if legs_type_2 == 'Follow direction' then
                    entity.set_prop(lp, 'm_flPoseParameter', 1, 0)
                else
                    if math.random(1,10) > 2 then
                        entity.set_prop(lp, "m_flPoseParameter", 1, 0)
                    end
                end
                override(reference.AA.other.leg_movement, 'Always slide')
            elseif legs_type == 'Walking' then
                entity.set_prop(lp, 'm_flPoseParameter', 0.5, 7)
                override(reference.AA.other.leg_movement, 'Never slide')
            end
        end

        if contains(this, 'Air legs') and in_air then
            if air_legs == 'Static' then
                entity.set_prop(lp, 'm_flPoseParameter', 1, 6)
            elseif air_legs == 'Walking' then
                anim_layers_leg.weight = 1
            end
        end
        if contains(this, 'Move lean') and in_air then
            anim_layers_lean.weight = mv_l/100
        end

        if entity.get_prop(lp, 'm_hGroundEntity') then
            cache.ground_ticks = cache.ground_ticks + 1
        else
            cache.ground_ticks = 0
        end
        if contains(this, 'Zero pitch on land') and cache.ground_ticks > 5 and cache.ground_ticks < 60 then
            entity.set_prop(lp, 'm_flPoseParameter', 0.5, 12)
        end
    end
end

local function sub_stringer(input, sep)
    local t = {} for str in string.gmatch(input, "([^"..sep.."]+)") do t[#t + 1] = string.gsub(str, "\n", "") end return t
end

local function toboolean(str)
    if str == "true" or str == "false" then return (str == "true") else return str end
end

config_system.export = function()
    configuration_data = tostring(ui.get(elements.anti_aim.enable)) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[2]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[3]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[4]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[5]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[6]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[7]) .. "|"
    .. tostring(ui.get(elements.anti_aim.tweaks_selector)[8]) .. "|"

    .. tostring(ui.get(elements.anti_aim.condition_selector)) .. "|"
    
    .. tostring(ui.get(elements.anti_aim[1].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].fs_body_yaw)) .. "|"

    .. tostring(ui.get(elements.anti_aim[2].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].fs_body_yaw)) .. "|"

    .. tostring(ui.get(elements.anti_aim[3].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].fs_body_yaw)) .. "|"

    .. tostring(ui.get(elements.anti_aim[4].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].fs_body_yaw)) .. "|"

    .. tostring(ui.get(elements.anti_aim[5].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].fs_body_yaw)) .. "|"

    .. tostring(ui.get(elements.anti_aim[6].pitch)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].yaw_base)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].yaw_type)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].left_yaw_value)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].right_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].yaw_jitter)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].jitter_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].body_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].body_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].fs_body_yaw)) .. "|"

end

config_system.export_2 = function()
    configuration_data_2 = configuration_data .. tostring(ui.get(elements.anti_aim[1].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[1].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[1].defensive_trigger)[2]) .. "|"

    .. tostring(ui.get(elements.anti_aim[2].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[2].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[2].defensive_trigger)[2]) .. "|"

    .. tostring(ui.get(elements.anti_aim[3].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[3].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[3].defensive_trigger)[2]) .. "|"

    .. tostring(ui.get(elements.anti_aim[4].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[4].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[4].defensive_trigger)[2]) .. "|"

    .. tostring(ui.get(elements.anti_aim[5].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[5].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[5].defensive_trigger)[2]) .. "|"

    .. tostring(ui.get(elements.anti_aim[6].defensive_anti_aim)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].defensive_pitch)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].defensive_pitch_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].defensive_yaw)) .. "|"
    .. tonumber(ui.get(elements.anti_aim[6].defensive_yaw_value)) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].defensive_trigger)[1]) .. "|"
    .. tostring(ui.get(elements.anti_aim[6].defensive_trigger)[2]) .. "|"

    --print(encrypt(json.stringify(configuration_data_2)))
    clipboard.set(encrypt(json.stringify(configuration_data_2)))
    
    client.exec("play ui\\beepclear")
    client.color_log(0, 255, 0, '[+] \0')
    client.color_log(255, 255, 255, 'Successfully copied config!')
end

config_system.import = function(input)
    local protected = function()
        local configuration_data = input == nil and json.parse(decrypt(clipboard.get())) or json.parse(decrypt(input))
        local tbl = sub_stringer(configuration_data, "|")
        ui.set(elements.anti_aim.enable, toboolean(tbl[1]))
        ui.set(elements.anti_aim.tweaks_selector, {tostring(tbl[2]), tostring(tbl[3]), tostring(tbl[4]), tostring(tbl[5]), tostring(tbl[6]), tostring(tbl[7]), tostring(tbl[8]), tostring(tbl[9])})
        ui.set(elements.anti_aim.condition_selector, tostring(tbl[10]))

        for i = 1, 6 do
            --print(tostring(tbl[0 + (11*i)]))
            ui.set(elements.anti_aim[i].pitch, tostring(tbl[0 + (11*i)]))
            ui.set(elements.anti_aim[i].yaw_base, tostring(tbl[1 + (11*i)]))
            ui.set(elements.anti_aim[i].yaw_type, tostring(tbl[2 + (11*i)]))
            ui.set(elements.anti_aim[i].yaw_value, tonumber(tbl[3 + (11*i)]))
            ui.set(elements.anti_aim[i].left_yaw_value, tonumber(tbl[4 + (11*i)]))
            ui.set(elements.anti_aim[i].right_yaw_value, tonumber(tbl[5 + (11*i)]))
            ui.set(elements.anti_aim[i].yaw_jitter, tostring(tbl[6 + (11*i)]))
            ui.set(elements.anti_aim[i].jitter_value, tonumber(tbl[7 + (11*i)]))
            ui.set(elements.anti_aim[i].body_yaw, tostring(tbl[8 + (11*i)]))
            ui.set(elements.anti_aim[i].body_yaw_value, tonumber(tbl[9 + (11*i)]))
            ui.set(elements.anti_aim[i].fs_body_yaw, toboolean(tbl[10 + (11*i)]))

            ui.set(elements.anti_aim[i].defensive_anti_aim, toboolean(tbl[70 + (7*i)]))
            ui.set(elements.anti_aim[i].defensive_pitch, tostring(tbl[71 + (7*i)]))
            ui.set(elements.anti_aim[i].defensive_pitch_value, tonumber(tbl[72 + (7*i)]))
            ui.set(elements.anti_aim[i].defensive_yaw, tostring(tbl[73 + (7*i)]))
            ui.set(elements.anti_aim[i].defensive_yaw_value, tonumber(tbl[74 + (7*i)]))
            ui.set(elements.anti_aim[i].defensive_trigger, {tostring(tbl[75 + (7*i)]), tostring(tbl[76 + (7*i)])})
        end

        client.exec("play ui\\beepclear")
        client.color_log(0, 255, 0, '[+] \0')
        client.color_log(255, 255, 255, 'Config succesfully loaded!')
    end
    local status, message = pcall(protected)
    if not status then
        client.exec("play ui\\error")
        client.color_log(255, 0, 0, '[-] \0')
        client.color_log(255, 255, 255, 'Failed to load config!')
        return
    end
end

ui.set_callback(elements.cfg.export, function()
    config_system.export()
    config_system.export_2()
end)

ui.set_callback(elements.cfg.load_default, function()
    default_cfg = 'XDcwMlw3OTZcODA2XDgyMVw4MTdcODUyXDgwNVw4NzBcODc1XDg4MVw4ODhcODMyXDg3OFw5MjFcOTM1XDk1NVw5NzVcOTg4XDk4MVw5OTRcMTAzMlw5ODVcMTAzMlwxMDUwXDEwNzNcMTA4M1wxMDk2XDEwMjRcMTExNVwxMTI2XDEwNzNcMTE1NVwxMTU2XDExNzVcMTE5MlwxMTIwXDEyMDJcMTIwOVwxMjMxXDEyMzdcMTI1NlwxMjU3XDEyNzVcMTMwOFwxMjY2XDEzMTlcMTMzNFwxMzMxXDEzNDVcMTI4OFwxMzY4XDEzODFcMTM5NFwxNDA1XDE0MjZcMTQ0M1wxNDQ1XDE0NzBcMTQ2NVwxNDA4XDE0OTNcMTUxMFwxNDQ0XDE1MjFcMTU0MVwxNTYyXDE1ODRcMTU0MlwxNTgxXDE2MTFcMTYyNFwxNTUyXDE2NDBcMTY0MVwxNjU2XDE2NjhcMTY4MVwxNzA2XDE3MjhcMTY4NVwxNzI4XDE3NDNcMTc1M1wxNjk2XDE3OTdcMTc4NVwxODE5XDE4MzZcMTgzNFwxODQxXDE4NTZcMTg4NFwxODgyXDE4ODlcMTkwNFwxOTMyXDE5MzBcMTkzN1wxOTUyXDE5ODBcMTkzM1wxOTg1XDIwMDZcMTkzNlwxOTU5XDE5NjBcMjAwN1wyMDY2XDIwNzVcMjA5M1wyMDg3XDIxMDRcMjEzNlwyMDkyXDIxMzdcMjE1MFwyMTU3XDIxODlcMjE5MlwyMjEyXDIyMzJcMjE4NVwyMjQ4XDIxNzZcMjI3MlwyMjY1XDIyOTRcMjI5NVwyMzA1XDIzMzJcMjM0M1wyMzY0XDIzMDFcMjMyMFwyMzI0XDI0MTJcMjM0OFwyNDM2XDIzNzJcMjQ2MFwyMzk2XDI0ODRcMjQ1MVwyNDg2XDI0OThcMjUzMlwyNDY4XDI1NTZcMjUyM1wyNTU4XDI1NzBcMjYwNFwyNTQwXDI2MjhcMjYxOFwyNjI1XDI2NDhcMjY2N1wyNjY1XDI3MDBcMjY1NlwyNzAxXDI3MTRcMjcyMVwyNzUzXDI3NTZcMjc3NlwyNzk2XDI3NDlcMjgxMlwyNzQwXDI4MzZcMjgyOVwyODU4XDI4NTlcMjg2OVwyODk2XDI5MDdcMjkyOFwyODY1XDI4ODRcMjg4OFwyOTc2XDI5MTJcMzAwMFwyOTMzXDI5NDlcMjk2NFwzMDQ4XDI5ODVcMzAwMFwzMDg0XDMwMzlcMzA4NVwzMTA2XDMxMjRcMzEyMVwzMTQ2XDMxNjhcMzEwOVwzMTE2XDMyMDRcMzE2NlwzMjA5XDMyMzJcMzI0NFwzMjQxXDMyNjZcMzI4OFwzMjI0XDMzMTJcMzMxNlwzMzI2XDMzNDFcMzMzN1wzMzcyXDMzMjhcMzM3M1wzMzg2XDMzOTNcMzQyNVwzNDI4XDM0NDhcMzQ2OFwzNDIxXDM0ODRcMzQxMlwzNTA4XDM1MDFcMzUzMFwzNTMxXDM1NDFcMzU2OFwzNTc5XDM2MDBcMzUzN1wzNTU2XDM1NjBcMzY0OFwzNTg0XDM2NzJcMzYwNVwzNjIxXDM2NDFcMzcyMFwzNjU3XDM2NzdcMzc1NlwzNzIzXDM3NThcMzc3MFwzODA0XDM3NDBcMzgyOFwzNzk5XDM4NDRcMzgzN1wzODY4XDM4NjlcMzg3NVwzOTEyXDM4NDVcMzg2OVwzODcyXDM5NjBcMzk2NFwzOTc0XDM5ODlcMzk4NVw0MDIwXDM5NzZcNDAyMVw0MDM0XDQwNDFcNDA3M1w0MDc2XDQwOTZcNDExNlw0MDY5XDQxMzJcNDA2MFw0MTU2XDQxNDlcNDE3OFw0MTc5XDQxODlcNDIxNlw0MjI3XDQyNDhcNDE4NVw0MjA0XDQyMDhcNDI5Nlw0MjMyXDQzMjBcNDI1Nlw0MzQ0XDQyODBcNDM2OFw0MzM1XDQzNzBcNDM4Mlw0NDE2XDQzNTJcNDQ0MFw0NDA3XDQ0NDJcNDQ1NFw0NDg4XDQ0MjRcNDUxMlw0NTAyXDQ1MDlcNDUzMlw0NTUxXDQ1NDlcNDU4NFw0NTQwXDQ1ODVcNDU5OFw0NjA1XDQ2MzdcNDY0MFw0NjYwXDQ2ODBcNDYzM1w0Njk2XDQ2MjRcNDcyMFw0NzEzXDQ3NDJcNDc0M1w0NzUzXDQ3ODBcNDc5MVw0ODEyXDQ3NDlcNDc2OFw0NzcyXDQ4NjBcNDc5Nlw0ODg0XDQ4MjBcNDkwOFw0ODQ0XDQ5MzJcNDkwMlw0OTI5XDQ5NTRcNDk1Nlw0OTc5XDQ5ODlcNTAxNlw0OTQ5XDQ5NjZcNDk4MFw1MDY0XDUwMzFcNTA2Nlw1MDc4XDUxMTJcNTA0OFw1MTM2XDUxMjZcNTEzM1w1MTU2XDUxNzVcNTE3M1w1MjA4XDUxNjRcNTIwOVw1MjIyXDUyMjlcNTI2MVw1MjY0XDUyODRcNTMwNFw1MjU3XDUzMjBcNTI0OFw1MzQ0XDUzMzdcNTM2Nlw1MzY3XDUzNzdcNTQwNFw1NDE1XDU0MzZcNTM3M1w1MzkyXDUzOTZcNTQ4NFw1NDIwXDU1MDhcNTQ0NFw1NTMyXDU0NjhcNTU1Nlw1NTIzXDU1NThcNTU3MFw1NjA0XDU1NDBcNTYyOFw1NTk1XDU2MzBcNTY0Mlw1Njc2XDU2MTJcNTcwMFw1NjkwXDU2OTdcNTcyMFw1NzM5XDU3MzdcNTc3Mlw1NzYyXDU3NjlcNTc5Mlw1ODExXDU4MDlcNTg0NFw1ODExXDU4NDZcNTg1OFw1ODkyXDU4MjhcNTkxNlw1ODgzXDU5MThcNTkzMFw1OTY0XDU5MDBcNTk4OFw1OTg2XDU5OTNcNjAwOFw2MDM2XDYwMzRcNjA0MVw2MDU2XDYwODRcNjA4OFw2MDk4XDYxMTNcNjEwOVw2MTQ0XDYwOTlcNjE2MVw2MTcxXDYxODRcNjE5MVw2MjAxXDYyMjhcNjE2NFw2MjUyXDYyMjNcNjI2NFw2MjY5XDYyODZcNjMxMlw2MjU0XDYyNjBcNjM0OFw2MzA0XDYzNTlcNjM3N1w2MzcwXDYzOTJcNjM5N1w2NDI0XDY0MTdcNjQ0NFw2NDY4XDY0NjZcNjQ3M1w2NDg4XDY1MTZcNjUwNlw2NTEzXDY1MzZcNjU1NVw2NTUzXDY1ODhcNjU1NVw2NTkwXDY2MDJcNjYzNlw2NTcyXDY2NjBcNjYyN1w2NjYyXDY2NzRcNjcwOFw2NjQ0XDY3MzJcNjczMFw2NzM3XDY3NTJcNjc4MFw2Nzc4XDY3ODVcNjgwMFw2ODI4XDY4MzJcNjg0Mlw2ODU3XDY4NTNcNjg4OFw2ODU4XDY4ODVcNjkxMFw2OTEyXDY5MzVcNjk0NVw2OTcyXDY5MDhcNjk5Nlw2OTMzXDY5NTJcNjk1Nlw3MDQ0XDY5ODFcNzAwMFw3MDA0XDcwOTJcNzA0OFw3MTAzXDcxMjFcNzExNFw3MTM2XDcxNDFcNzE2OFw3MTYxXDcxODhcNzIxMlw3MTc5XDcyMjJcNzE2OVw3MjUxXDcyNTJcNzI3MVw3Mjg4XDcyMTZcNzI5M1w3MzE4XDczMzZcNzMzN1w3Mjg5XDczNTNcNzM3M1w3Mzg5XDc0MTZcNzQyMFw3NDMwXDc0NDVcNzQ0MVw3NDc2XDc0NDlcNzQ4OFw3NTEyXDc0NDhcNzUzNlw3NTA3XDc1NDhcNzU1M1w3NTcwXDc1OTZcNzU0MVw3NTQ0XDc2MzJcNzU4OFw3NjQzXDc2NjFcNzY1NFw3Njc2XDc2ODFcNzcwOFw3NzAxXDc3MjhcNzc1Mlw3NzE5XDc3NjJcNzcwOVw3NzkxXDc3OTJcNzgxMVw3ODI4XDc3NTZcNzgzM1w3ODU4XDc4NzZcNzg3N1w3ODI5XDc4OTNcNzkxM1w3OTI5XDc5NTZcNzk2MFw3OTcwXDc5ODVcNzk4MVw4MDE2XDc5ODlcODAyOFw4MDUyXDc5ODhcODA3Nlw4MDQ3XDgwODhcODA5M1w4MTEwXDgxMzZcODA3M1w4MDg1XDgxMDBcODE4NFw4MTQwXDgxOTVcODIxM1w4MjA2XDgyMjhcODIzM1w4MjYwXDgyNTNcODI4MFw4MzA0XDgyNzFcODMxNFw4MjYxXDgzNDNcODM0NFw4MzYzXDgzODBcODMwOFw4Mzg1XDg0MTBcODQyOFw4NDI5XDgzODFcODQ0NVw4NDY1XDg0ODFcODUwOFw4NDMw'
    --             XDcwMlw3OTZcODA2XDgyMVw4MTdcODUyXDgwNVw4NzBcODc1XDg4MVw4ODhcODMyXDg3OFw5MjFcOTM1XDk1NVw5NzVcOTg4XDk4MVw5OTRcMTAzMlw5ODVcMTAzMlwxMDUwXDEwNzNcMTA4M1wxMDk2XDEwMjRcMTExNVwxMTI2XDEwNzNcMTE1NVwxMTU2XDExNzVcMTE5MlwxMTIwXDEyMDJcMTIwOVwxMjMxXDEyMzdcMTI1NlwxMjU3XDEyNzVcMTMwOFwxMjY2XDEzMTlcMTMzNFwxMzMxXDEzNDVcMTI4OFwxMzY4XDEzODFcMTM5NFwxNDA1XDE0MjZcMTQ0M1wxNDQ1XDE0NzBcMTQ2NVwxNDA4XDE0OTNcMTUxMFwxNDQ0XDE1MjFcMTU0MVwxNTYyXDE1ODRcMTU0MlwxNTgxXDE2MTFcMTYyNFwxNTUyXDE2NDBcMTY0MVwxNjU2XDE2NjhcMTY4MVwxNzA2XDE3MjhcMTY4NVwxNzI4XDE3NDNcMTc1M1wxNjk2XDE3OTdcMTc4NVwxODE5XDE4MzZcMTgzNFwxODQxXDE4NTZcMTg4NFwxODgyXDE4ODlcMTkwNFwxOTMyXDE5MzBcMTkzN1wxOTUyXDE5ODBcMTkzM1wxOTg1XDIwMDZcMTkzNlwxOTU5XDE5NjBcMjAwN1wyMDY2XDIwNzVcMjA5M1wyMDg3XDIxMDRcMjEzNlwyMDkyXDIxMzdcMjE1MFwyMTU3XDIxODlcMjE5MlwyMjEyXDIyMzJcMjE4NVwyMjQ4XDIxNzZcMjI3MlwyMjY1XDIyOTRcMjI5NVwyMzA1XDIzMzJcMjM0M1wyMzY0XDIzMDFcMjMyMFwyMzI0XDI0MTJcMjM0OFwyNDM2XDIzNzJcMjQ2MFwyMzk2XDI0ODRcMjQ1MVwyNDg2XDI0OThcMjUzMlwyNDY4XDI1NTZcMjUyM1wyNTU4XDI1NzBcMjYwNFwyNTQwXDI2MjhcMjYxOFwyNjI1XDI2NDhcMjY2N1wyNjY1XDI3MDBcMjY1NlwyNzAxXDI3MTRcMjcyMVwyNzUzXDI3NTZcMjc3NlwyNzk2XDI3NDlcMjgxMlwyNzQwXDI4MzZcMjgyOVwyODU4XDI4NTlcMjg2OVwyODk2XDI5MDdcMjkyOFwyODY1XDI4ODRcMjg4OFwyOTc2XDI5MTJcMzAwMFwyOTMzXDI5NDlcMjk2NFwzMDQ4XDI5ODVcMzAwMFwzMDg0XDMwMzlcMzA4NVwzMTA2XDMxMjRcMzEyMVwzMTQ2XDMxNjhcMzEwOVwzMTE2XDMyMDRcMzE2NlwzMjA5XDMyMzJcMzI0NFwzMjQxXDMyNjZcMzI4OFwzMjI0XDMzMTJcMzMxNlwzMzI2XDMzNDFcMzMzN1wzMzcyXDMzMjhcMzM3M1wzMzg2XDMzOTNcMzQyNVwzNDI4XDM0NDhcMzQ2OFwzNDIxXDM0ODRcMzQxMlwzNTA4XDM1MDFcMzUzMFwzNTMxXDM1NDFcMzU2OFwzNTc5XDM2MDBcMzUzN1wzNTU2XDM1NjBcMzY0OFwzNTg0XDM2NzJcMzYwNVwzNjIxXDM2NDFcMzcyMFwzNjU3XDM2NzdcMzc1NlwzNzIzXDM3NThcMzc3MFwzODA0XDM3NDBcMzgyOFwzNzk5XDM4NDRcMzgzN1wzODY4XDM4NjlcMzg3NVwzOTEyXDM4NDVcMzg2OVwzODcyXDM5NjBcMzk2NFwzOTc0XDM5ODlcMzk4NVw0MDIwXDM5NzZcNDAyMVw0MDM0XDQwNDFcNDA3M1w0MDc2XDQwOTZcNDExNlw0MDY5XDQxMzJcNDA2MFw0MTU2XDQxNDlcNDE3OFw0MTc5XDQxODlcNDIxNlw0MjI3XDQyNDhcNDE4NVw0MjA0XDQyMDhcNDI5Nlw0MjMyXDQzMjBcNDI1Nlw0MzQ0XDQyODBcNDM2OFw0MzM1XDQzNzBcNDM4Mlw0NDE2XDQzNTJcNDQ0MFw0NDA3XDQ0NDJcNDQ1NFw0NDg4XDQ0MjRcNDUxMlw0NTAyXDQ1MDlcNDUzMlw0NTUxXDQ1NDlcNDU4NFw0NTQwXDQ1ODVcNDU5OFw0NjA1XDQ2MzdcNDY0MFw0NjYwXDQ2ODBcNDYzM1w0Njk2XDQ2MjRcNDcyMFw0NzEzXDQ3NDJcNDc0M1w0NzUzXDQ3ODBcNDc5MVw0ODEyXDQ3NDlcNDc2OFw0NzcyXDQ4NjBcNDc5Nlw0ODg0XDQ4MjBcNDkwOFw0ODQ0XDQ5MzJcNDkwMlw0OTI5XDQ5NTRcNDk1Nlw0OTc5XDQ5ODlcNTAxNlw0OTQ5XDQ5NjZcNDk4MFw1MDY0XDUwMzFcNTA2Nlw1MDc4XDUxMTJcNTA0OFw1MTM2XDUxMjZcNTEzM1w1MTU2XDUxNzVcNTE3M1w1MjA4XDUxNjRcNTIwOVw1MjIyXDUyMjlcNTI2MVw1MjY0XDUyODRcNTMwNFw1MjU3XDUzMjBcNTI0OFw1MzQ0XDUzMzdcNTM2Nlw1MzY3XDUzNzdcNTQwNFw1NDE1XDU0MzZcNTM3M1w1MzkyXDUzOTZcNTQ4NFw1NDIwXDU1MDhcNTQ0NFw1NTMyXDU0NjhcNTU1Nlw1NTIzXDU1NThcNTU3MFw1NjA0XDU1NDBcNTYyOFw1NTk1XDU2MzBcNTY0Mlw1Njc2XDU2MTJcNTcwMFw1NjkwXDU2OTdcNTcyMFw1NzM5XDU3MzdcNTc3Mlw1NzYyXDU3NjlcNTc5Mlw1ODExXDU4MDlcNTg0NFw1ODExXDU4NDZcNTg1OFw1ODkyXDU4MjhcNTkxNlw1ODgzXDU5MThcNTkzMFw1OTY0XDU5MDBcNTk4OFw1OTg2XDU5OTNcNjAwOFw2MDM2XDYwMzRcNjA0MVw2MDU2XDYwODRcNjA4OFw2MDk4XDYxMTNcNjEwOVw2MTQ0XDYwOTlcNjE2MVw2MTcxXDYxODRcNjE5MVw2MjAxXDYyMjhcNjE2NFw2MjUyXDYyMjNcNjI2NFw2MjY5XDYyODZcNjMxMlw2MjU0XDYyNjBcNjM0OFw2MzA0XDYzNTlcNjM3N1w2MzcwXDYzOTJcNjM5N1w2NDI0XDY0MTdcNjQ0NFw2NDY4XDY0NjZcNjQ3M1w2NDg4XDY1MTZcNjUwNlw2NTEzXDY1MzZcNjU1NVw2NTUzXDY1ODhcNjU1NVw2NTkwXDY2MDJcNjYzNlw2NTcyXDY2NjBcNjYyN1w2NjYyXDY2NzRcNjcwOFw2NjQ0XDY3MzJcNjczMFw2NzM3XDY3NTJcNjc4MFw2Nzc4XDY3ODVcNjgwMFw2ODI4XDY4MzJcNjg0Mlw2ODU3XDY4NTNcNjg4OFw2ODU4XDY4ODVcNjkxMFw2OTEyXDY5MzVcNjk0NVw2OTcyXDY5MDhcNjk5Nlw2OTMzXDY5NTJcNjk1Nlw3MDQ0XDY5ODFcNzAwMFw3MDA0XDcwOTJcNzA0OFw3MTAzXDcxMjFcNzExNFw3MTM2XDcxNDFcNzE2OFw3MTYxXDcxODhcNzIxMlw3MTc5XDcyMjJcNzE2OVw3MjUxXDcyNTJcNzI3MVw3Mjg4XDcyMTZcNzI5M1w3MzE4XDczMzZcNzMzN1w3Mjg5XDczNTNcNzM3M1w3Mzg5XDc0MTZcNzQyMFw3NDMwXDc0NDVcNzQ0MVw3NDc2XDc0NDlcNzQ4OFw3NTEyXDc0NDhcNzUzNlw3NTA3XDc1NDhcNzU1M1w3NTcwXDc1OTZcNzU0MVw3NTQ0XDc2MzJcNzU4OFw3NjQzXDc2NjFcNzY1NFw3Njc2XDc2ODFcNzcwOFw3NzAxXDc3MjhcNzc1Mlw3NzE5XDc3NjJcNzcwOVw3NzkxXDc3OTJcNzgxMVw3ODI4XDc3NTZcNzgzM1w3ODU4XDc4NzZcNzg3N1w3ODI5XDc4OTNcNzkxM1w3OTI5XDc5NTZcNzk2MFw3OTcwXDc5ODVcNzk4MVw4MDE2XDc5ODlcODAyOFw4MDUyXDc5ODhcODA3Nlw4MDQ3XDgwODhcODA5M1w4MTEwXDgxMzZcODA3M1w4MDg1XDgxMDBcODE4NFw4MTQwXDgxOTVcODIxM1w4MjA2XDgyMjhcODIzM1w4MjYwXDgyNTNcODI4MFw4MzA0XDgyNzFcODMxNFw4MjYxXDgzNDNcODM0NFw4MzYzXDgzODBcODMwOFw4Mzg1XDg0MTBcODQyOFw4NDI5XDgzODFcODQ0NVw4NDY1XDg0ODFcODUwOFw4NDMw
    config_system.import(default_cfg)
end)

ui.set_callback(elements.cfg.import, function()
    config_system.import()
end)

local log = {}
local log_data = {
    wanted_damage = {},
    backtrack = {},
    hitgroup = {},
    id = 0
}

local function aim_hit(e)
    local group = hitgroup_names[e.hitgroup + 1] or '?'
    wanted_group = hitgroup_names[log_data.hitgroup[log_data.id] + 1] or '?' 
    difference_dmg = (log_data.wanted_damage[log_data.id] > e.damage)
    difference_group = (wanted_group ~= group)
    all_dif = (difference_dmg or difference_group)
    color = all_dif and {225, 200, 25} or {100, 200, 50}
    hitchance = math.floor(e.hit_chance) > 0 and (math.floor(e.hit_chance) .. '%, ') or ""

    client.color_log(color[1], color[2], color[3], (all_dif and '[~] ' or '[+] ') .. '\0')
    client.color_log(255, 255, 255, 'Hit \0')
    client.color_log(color[1], color[2], color[3], entity.get_player_name(e.target) .. '\0')
    client.color_log(255, 255, 255, ' in the ' .. '\0')
    client.color_log(color[1], color[2], color[3], group .. '\0')
    if difference_group then
        client.color_log(color[1], color[2], color[3],  ' (' .. wanted_group .. ')\0')
    end

    client.color_log(255, 255, 255, ' for ' .. '\0')
    client.color_log(color[1], color[2], color[3], e.damage .. '\0')
    if difference_dmg then
        client.color_log(color[1], color[2], color[3], ' (' .. log_data.wanted_damage[log_data.id] .. ')\0')
    end
    client.color_log(255, 255, 255, ' damage (' .. '\0')
    client.color_log(color[1], color[2], color[3], entity.get_prop(e.target, 'm_iHealth') .. '\0')
    client.color_log(255, 255, 255, ' health remaining)\0')
    client.color_log(color[1], color[2], color[3], ' (' .. hitchance .. log_data.backtrack[log_data.id] .. 't)')

    --print(('\a90EE90FF Hit %s in the %s for %d damage (%d health remaining)'):format( entity.get_player_name(e.target), group, e.damage, entity.get_prop(e.target, 'm_iHealth')))
end

function aim_miss(e)
    local group = hitgroup_names[e.hitgroup + 1] or '?'
    reason = e.reason
    hitchance = math.floor(e.hit_chance) > 0 and (math.floor(e.hit_chance) .. '%, ') or ''
    target = e.target
    color = {255, 15, 25}

    client.color_log(color[1], color[2], color[3], '[-] \0')
    client.color_log(255, 255, 255, 'Missed \0')
    client.color_log(color[1], color[2], color[3], entity.get_player_name(target) .. '\0')
    client.color_log(255, 255, 255, '`s ' .. '\0')
    client.color_log(color[1], color[2], color[3], group .. ' (' .. log_data.wanted_damage[log_data.id] .. ')\0')
    client.color_log(255, 255, 255, ' due to ' .. '\0')
    client.color_log(color[1], color[2], color[3], reason .. ' (' .. hitchance .. log_data.backtrack[log_data.id] .. 't)')
end

function aim_fire(e)
    table.insert(log_data.wanted_damage, e.damage)
    table.insert(log_data.backtrack, globals.tickcount() - e.tick)
    table.insert(log_data.hitgroup, e.hitgroup) 
    log_data.id = log_data.id + 1
end

client.set_event_callback('aim_fire', aim_fire)
client.set_event_callback('aim_miss', aim_miss)
client.set_event_callback('aim_hit', aim_hit)

client.set_event_callback("setup_command", function(cmd)
    --print(config.export())
    --print(ui.get(elements.anti_aim.condition_selector))
    ideal_tick_f()
	exploit_manipulation()
    force_defensive_in_air(cmd)
    anti_backstab(cmd)
    anti_aim_settings(cmd)
    anti_aim_tweaks_settings(cmd)
    fast_ladder(cmd)
    defensive_anti_aim_f(cmd)
    peek_assist_clr()
    anti_defensive_f()
    prevent_mouse(cmd)
end)

client.set_event_callback("paint", function(cmd)
    --watermark_f()
    indication()
end)

client.set_event_callback("paint_ui", function(cmd)
    menu_elements()
    --handle_tickbase()
end)

client.set_event_callback("net_update_end", function(cmd)
    handle_defensive()
end)

client.set_event_callback("shutdown", function(cmd)
    menu_elements_on_shutdown()
end)

client.set_event_callback("round_end", function(cmd)
    --cache.defensive = 0
    --cache.defensive_bool = false
end)

client.set_event_callback("pre_render", function(cmd)
    animations()
end) --FF00004D / A0C82DFF