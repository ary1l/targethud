--[[
* targethud: AAEV module (Auto Attacks Easily Visualized).
* Original Windower addon by darkewaffle; Ashita v4 port (aaev 2.0.2).
* Settings now live in the settings lib (alias 'aaev', per character).
--]]

require('common');
local imgui = require('imgui');
local chat  = require('chat');
local slib  = require('settings');
local data  = require('hud_aaev_data');

local M = { };

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

local default_settings = T{
    enabled = false,      -- module toggle (off = no packet parsing, no draw)
    migrated = false,     -- old addons/targethud aaev files imported
    DisplayMode = 'full',
    DisplayContinuous = false,
    AdditionalEffectSingleBar = false,
    AdditionalEffectStackBars = true,
    AutoHide = true,
    HideDelay = 4.0,
    AlwaysShow = false,
    FixedSize = true,
    AutoDemo = false,
    ChartBars = 20, ChartStartX = 500, ChartStartY = 500, ChartWidth = 100, ChartHeight = 43,
    BarsAlpha = 255,
    -- NOTE(aryl): 'round' = one bar per attack round (packet), height = round damage,
    -- color = swing count so double/triple/quad attacks read at a glance.
    -- 'swing' = the original one-bar-per-swing chart.
    BarMode = 'round',
    ColorRound1 = { 0, 0, 237 }, ColorRound2 = { 0, 170, 255 },
    ColorRound3 = { 60, 220, 120 }, ColorRound4 = { 255, 200, 0 },
    ColorRound5 = { 255, 90, 0 },
    RoundCritCap = true, RoundCritCapPx = 2,
    LastShowHits = true,
    ColorHit = { 0, 0, 237 }, ColorCrit = { 119, 119, 237 }, ColorMiss = { 255, 255, 255 },
    ColorBlock = { 64, 64, 64 }, ColorHitZero = { 128, 128, 128 }, ColorCounter = { 237, 0, 0 },
    ColorHeal = { 102, 255, 7 }, ColorAdditionalEffect = { 192, 192, 192 },
    ColorAdditionalEffectHeal = { 102, 255, 7 },
    BGDisplay = true, BGColor = { 0, 0, 0 }, BGAlpha = 128, BGPaddingX = 5, BGPaddingY = 4,
    DisplayMax = false, MaxLabelPrefix = 'Max: ',
    DisplayHitRate = true, HitRateLabelPrefix = 'Acc: ',
    DisplayCritRate = true, CritRateLabelPrefix = 'Crit: ',
    DisplayTH = true, ColorTH = { 255, 200, 0 },
    DisplayAvg = true, AvgLabelPrefix = 'Avg: ',
    DisplayZoneAcc = true, ZoneAccLabelPrefix = 'Zone: ',
    DisplayLast = true, LastLabelPrefix = 'Last: ',
    DisplayRoundCount = false, RoundLabelPrefix = 'Rd: ',
    -- FIX: short single-char prefixes (narrow HUD). Set false for wordy Max:/Hit: etc.
    -- Defaults are ASCII (M L H C ~ Z + #). Override any per-key, e.g. GlyphMax='⌂',
    -- but non-ASCII glyphs tofu unless Ashita's font atlas has them.
    GlyphLabels = false,
    ResetOnTargetChange = true,
    SingleLineLabels = false,
    WidthFromLabels = false,
    AutoFitLabels = true,
    MinFontScale = 0.55,
    CompactLabels = true,
    HitRateColorize = true,
    LabelColor = { 255, 255, 255 }, LabelAlpha = 255, FontScale = 1.0,
    DisplayWeaponskills = true, ReverseWeaponskills = false, WeaponskillCount = 5,
    PetChart = true, PetChartBars = 20, PetChartStartX = 500, PetChartStartY = 650,
    PetChartWidth = 100, PetChartHeight = 43, PetWeaponskillCount = 5,
};
M.defaults = default_settings;

local settings = default_settings;   -- per-char table from the settings lib (M.set_cfg)

-- PERF: change counters. Label rows / colors / window size rebuild only when these move.
local ver = { cfg = 0 };
local saved_dirty_at = nil;   -- debounce: slider drags no longer write the file every frame

local function save_saved()
    return slib.save('aaev');
end

-- Normalize + invalidate caches (load, char switch, reset, reload).
local function load_settings()
    -- SingleBar wins if both AE modes set (original behavior).
    if (settings.AdditionalEffectSingleBar) then
        settings.AdditionalEffectStackBars = false;
    end
    -- AlwaysShow means the chart is a permanent HUD element; AutoHide is meaningless.
    if (settings.AlwaysShow) then
        settings.AutoHide = false;
    end
    ver.cfg = ver.cfg + 1;
end

-- Positions are ordinary keys in the per-char table now.
local function save_positions()
    return save_saved();
end

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local TYPE_PLAYER = 'player';
local TYPE_PET    = 'pet';

local logs = {
    [TYPE_PLAYER] = {},
    [TYPE_PET]    = {},
};

local state = {
    dead_ids = {},
    reset_at = nil,               -- os.clock time to purge dead target logs
    display_target = { [TYPE_PLAYER] = nil, [TYPE_PET] = nil },
    visible = { [TYPE_PLAYER] = false, [TYPE_PET] = false },
    pet_enemy = nil,
    hide_at = { [TYPE_PLAYER] = nil, [TYPE_PET] = nil },
    last_status = nil,
    last_job = nil,
    unlocked = false,
    applied_pos = { [TYPE_PLAYER] = false, [TYPE_PET] = false },
    forced_hidden = false,        -- /targethud aaev hide beats AlwaysShow until /targethud aaev show
    show_config = false,
    last_target = nil,
};

local config_open = { true };

-- Zone-lifetime melee accuracy for the player. Survives target death and log
-- purges; only a zone change (0x00B) or /targethud aaev zonereset clears it.
local zone_stats = { count = 0, miss = 0, crit = 0, v = 0 };

local function zone_reset()
    zone_stats.count, zone_stats.miss, zone_stats.crit = 0, 0, 0;
    zone_stats.v = zone_stats.v + 1;
end

-- Placeholder log so AlwaysShow can render an empty frame with no data.
local idle_log = { count = 0, max = 0, miss = 0, crit = 0, th = 0, rounds = 0, last_dmg = 0,
                   max_round = 0, max_round_sw = 0, last_hits = 0, last_swings = 0, rlist = {},
                   attacks = {}, ws = {}, v = 0 };

local function target_override()
    if (settings.DisplayContinuous) then
        return 'ALLTARGETS';
    end
    return nil;
end

-- FIX: charts linger HideDelay seconds after disengage/target death instead of
-- vanishing instantly. Any new data or re-engage cancels the pending hide.
local function set_visible(log_type)
    state.visible[log_type] = true;
    state.hide_at[log_type] = nil;
end

local function schedule_hide(log_type)
    if (settings.AlwaysShow and log_type == TYPE_PLAYER) then return; end
    if (not settings.AutoHide) then return; end
    if (settings.HideDelay == nil or settings.HideDelay <= 0) then
        state.visible[log_type] = false;
        state.hide_at[log_type] = nil;
    else
        state.hide_at[log_type] = os.clock() + settings.HideDelay;
    end
end

----------------------------------------------------------------------------------------------------
-- Game state helpers
----------------------------------------------------------------------------------------------------

local function player_id()
    local p = GetPlayerEntity();
    if (p ~= nil and p.ServerId ~= nil and p.ServerId > 0) then
        return p.ServerId;
    end
    return nil;
end

local function player_status()
    local p = GetPlayerEntity();
    if (p ~= nil) then
        return p.Status;
    end
    return nil;
end

local function main_job()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player ~= nil) then
        return player:GetMainJob();
    end
    return 0;
end

local function is_pet_job()
    return data.pet_jobs[main_job()] == true;
end

-- NOTE: resolved live every time; no stale pet ID after release/charm swap.
-- PERF: own + pet server ids, refreshed once per frame in M.render. Every
-- 0x028 in the zone used to pay GetPlayerEntity + GetEntity before the actor test.
local ids = { pid = nil, petid = nil };

local function pet_id(p)
    p = p or GetPlayerEntity();
    if (p == nil or p.PetTargetIndex == nil or p.PetTargetIndex == 0) then
        return nil;
    end
    local pet = GetEntity(p.PetTargetIndex);
    if (pet ~= nil and pet.ServerId ~= nil and pet.ServerId > 0) then
        return pet.ServerId;
    end
    return nil;
end

local function current_target_id()
    local tmgr = AshitaCore:GetMemoryManager():GetTarget();
    if (tmgr == nil) then return nil; end
    local idx = tmgr:GetTargetIndex(0);
    if (idx == nil or idx == 0) then return nil; end
    local ent = GetEntity(idx);
    if (ent ~= nil and ent.ServerId ~= nil and ent.ServerId > 0) then
        return ent.ServerId;
    end
    return nil;
end

-- Local mob server ids encode their index in the low 12 bits; players won't
-- match this check and are correctly excluded (original used spawn_type == 16).
local function is_monster(server_id)
    if (type(server_id) ~= 'number' or server_id == 0) then return false; end
    local idx = bit.band(server_id, 0xFFF);
    if (idx >= 0x900) then return false; end
    local ent = GetEntity(idx);
    if (ent ~= nil and ent.ServerId == server_id) then
        return bit.band(ent.SpawnFlags or 0, 0x10) ~= 0;
    end
    return false;
end

local function ws_name(ws_id, category)
    local rm = AshitaCore:GetResourceManager();
    if (category == 13) then
        -- Bloodpact / wyvern breath: param is a JA id; ability resource = id + 512.
        local res = rm:GetAbilityById(ws_id + 512);
        if (res ~= nil) then return res.Name[1]; end
    elseif (ws_id > 0 and ws_id <= 255) then
        local res = rm:GetAbilityById(ws_id);
        if (res ~= nil) then return res.Name[1]; end
    elseif (ws_id >= 257) then
        -- Mob skill (BST Ready / pet TP move). Names live in the
        -- 'monsters.abilities' string table at id - 256 (as LuAshitacast reads them).
        local auto = data.automaton_whitelist[ws_id];
        if (auto ~= nil) then return auto.en; end
        local s = rm:GetString('monsters.abilities', ws_id - 256);
        if (type(s) == 'string') then
            local nul = s:find('\0', 1, true);
            if (nul ~= nil) then s = s:sub(1, nul - 1); end
            -- Non-ASCII (JP client) would render as garbage in the default font.
            if (#s > 0 and not s:find('[\128-\255]')) then return s; end
        end
        return ('#%d'):format(ws_id);
    end
    return 'WS?';
end

----------------------------------------------------------------------------------------------------
-- Attack log
----------------------------------------------------------------------------------------------------

local function get_target_log(log_type, tid, create)
    local log = logs[log_type];
    if (log[tid] == nil) then
        if (not create) then return nil; end
        log[tid] = {
            count = 0, max = 0, miss = 0, crit = 0, th = 0, rounds = 0, last_dmg = 0,
            -- NOTE: round-mode state. rlist is the per-round ring buffer.
            max_round = 0, max_round_sw = 0, last_hits = 0, last_swings = 0, rlist = {},
            attacks = {}, ws = {}, v = 0,
        };
    end
    return log[tid];
end

local function chart_bars(log_type)
    if (log_type == TYPE_PET) then return settings.PetChartBars; end
    return settings.ChartBars;
end

local function chart_width(log_type)
    if (log_type == TYPE_PET) then return settings.PetChartWidth; end
    return settings.ChartWidth;
end

local function ws_count(log_type)
    if (log_type == TYPE_PET) then return settings.PetWeaponskillCount; end
    return settings.WeaponskillCount;
end

local function record_attacks(pkt, log_type)
    local tgt = pkt.targets[1];
    if (tgt == nil) then return nil; end
    local tid = target_override() or tgt.id;
    local tlog = get_target_log(log_type, tid, true);
    -- One 0x028 category-1 packet == one attack round (main + off + multi-attack).
    local round_dmg = 0;
    -- FIX: round-mode accumulators. swings == number of actions in the packet, which
    -- IS the multi-attack tier (1 single / 2 double / 3 triple / 4 quad / 5+ occ).
    local r_swings, r_hits, r_crit, r_counter, r_ae = 0, 0, 0, 0, 0;

    for _, act in ipairs(tgt.actions) do
        local a_msg    = act.message;
        local a_dmg    = act.param;
        local a_result = data.attack_messages[a_msg] or data.ATTACK_HIT;

        -- Countered attacks carry no attack message but do carry a spike message.
        if (a_msg == 0) then
            local spike_msg = 0;
            if (act.spike ~= nil) then spike_msg = act.spike.message; end
            a_result = data.attack_messages[spike_msg] or data.ATTACK_HIT;
            a_dmg = 0;
        end

        if (a_result == data.ATTACK_MISS) then
            tlog.miss = tlog.miss + 1;
        elseif (a_result == data.ATTACK_CRIT) then
            tlog.crit = tlog.crit + 1;
        end

        r_swings = r_swings + 1;
        if (a_result == data.ATTACK_CRIT) then
            r_crit = r_crit + 1;
        elseif (a_result == data.ATTACK_COUNTER) then
            r_counter = r_counter + 1;
        end
        if (a_result ~= data.ATTACK_MISS and a_result ~= data.ATTACK_COUNTER
            and a_result ~= data.ATTACK_SHADOW) then
            r_hits = r_hits + 1;
        end

        -- Zone accumulator: same hit/miss definition as the per-target rate.
        if (log_type == TYPE_PLAYER) then
            zone_stats.v = zone_stats.v + 1;
            zone_stats.count = zone_stats.count + 1;
            if (a_result == data.ATTACK_MISS) then
                zone_stats.miss = zone_stats.miss + 1;
            elseif (a_result == data.ATTACK_CRIT) then
                zone_stats.crit = zone_stats.crit + 1;
            end
        end

        if (a_result ~= data.ATTACK_MISS and a_result ~= data.ATTACK_COUNTER and a_dmg == 0) then
            a_result = data.ATTACK_HIT_ZERO;
        end

        local ae_result = data.AE_NONE;
        local ae_dmg = 0;
        if (act.ae ~= nil) then
            ae_result = data.ae_messages[act.ae.message] or data.AE_NONE;
            ae_dmg = act.ae.param or 0;
            -- TH proc: param is the new TH tier, not damage.
            if (ae_result == data.AE_TREASURE_HUNTER) then
                tlog.th = ae_dmg;
                ae_result = data.AE_NONE;
                ae_dmg = 0;
            end
        end

        local total = 0;
        if (a_result ~= data.ATTACK_HEAL) then
            total = total + a_dmg;
        end
        if ((settings.AdditionalEffectSingleBar or settings.AdditionalEffectStackBars)
            and ae_result ~= data.AE_HEAL) then
            total = total + ae_dmg;
        end

        tlog.max = math.max(tlog.max, total);
        tlog.count = tlog.count + 1;
        round_dmg = round_dmg + total;
        r_ae = r_ae + ae_dmg;

        table.insert(tlog.attacks, { result = a_result, dmg = a_dmg, ae_result = ae_result, ae_dmg = ae_dmg });
        while (#tlog.attacks > chart_bars(log_type)) do
            table.remove(tlog.attacks, 1);
        end
    end

    tlog.rounds = (tlog.rounds or 0) + 1;
    tlog.last_dmg = round_dmg;
    tlog.last_hits = r_hits;
    tlog.last_swings = r_swings;

    -- Round entry for BarMode == 'round'.
    if (r_swings > 0) then
        -- FIX: keep the swing count of the round that set max_round for the label.
        if (round_dmg > (tlog.max_round or 0)) then
            tlog.max_round = round_dmg;
            tlog.max_round_sw = r_swings;
        end
        table.insert(tlog.rlist, {
            dmg = round_dmg, swings = r_swings, hits = r_hits,
            crit = r_crit, counter = r_counter, ae_dmg = r_ae,
        });
        while (#tlog.rlist > chart_bars(log_type)) do
            table.remove(tlog.rlist, 1);
        end
    end

    tlog.v = tlog.v + 1;
    return tid;
end

local function record_ws(pkt, log_type, msg_map)
    local tgt = pkt.targets[1];
    if (tgt == nil or tgt.actions[1] == nil) then return nil; end
    local tid = target_override() or tgt.id;
    local act = tgt.actions[1];

    local result = msg_map[act.message];
    if (result == nil) then return nil; end

    local tlog = get_target_log(log_type, tid, true);
    local entry = {
        name   = ws_name(pkt.param, pkt.category),
        dmg    = act.param,
        result = result,
    };
    if (act.ae ~= nil) then
        local sc = data.skillchain_messages[act.ae.message];
        if (sc ~= nil) then
            entry.sc_name = sc.name;
            entry.sc_dmg = act.ae.param;
            entry.sc_result = sc.result;
        end
    end

    table.insert(tlog.ws, entry);
    while (#tlog.ws > ws_count(log_type)) do
        table.remove(tlog.ws, 1);
    end

    tlog.v = tlog.v + 1;
    return tid;
end

local function reset_dead_logs()
    for tid, _ in pairs(state.dead_ids) do
        logs[TYPE_PLAYER][tid] = nil;
        logs[TYPE_PET][tid] = nil;
        state.dead_ids[tid] = nil;
    end
    state.reset_at = nil;
end

local function reset_all_logs()
    logs[TYPE_PLAYER] = {};
    logs[TYPE_PET] = {};
    state.dead_ids = {};
    state.reset_at = nil;
    state.display_target[TYPE_PLAYER] = nil;
    state.display_target[TYPE_PET] = nil;
    state.pet_enemy = nil;
end

----------------------------------------------------------------------------------------------------
-- Packet parsing
----------------------------------------------------------------------------------------------------

-- Self-contained 0x028 action packet parser (bit layout per known field maps).
local function parse_action(e)
    local raw = e.data_raw;
    local pos = 40;
    local max_bits = e.size * 8;
    local overflow = false;

    local function take(n)
        if (pos + n > max_bits) then
            overflow = true;
            return 0;
        end
        local v = ashita.bits.unpack_be(raw, 0, pos, n);
        pos = pos + n;
        return v;
    end

    local pkt = {};
    pkt.actor = take(32);
    local tcount = take(6);
    take(4);
    pkt.category = take(4);
    pkt.param = take(16);
    take(16);
    pkt.recast = take(32);
    pkt.targets = {};

    for i = 1, tcount do
        local tgt = { id = take(32), actions = {} };
        local acount = take(4);
        for j = 1, acount do
            local act = {};
            act.reaction  = take(5);
            act.animation = take(12);
            act.effect    = take(7);
            act.knockback = take(3);
            act.param     = take(17);
            act.message   = take(10);
            act.flags     = take(31);
            if (take(1) == 1) then
                act.ae = { animation = take(10), param = take(17), message = take(10) };
            end
            if (take(1) == 1) then
                act.spike = { animation = take(10), param = take(14), message = take(10) };
            end
            tgt.actions[j] = act;
        end
        pkt.targets[i] = tgt;
    end

    if (overflow) then return nil; end
    return pkt;
end

local function handle_action(e)
    -- Cheap actor pre-check before full bit parse.
    local actor = struct.unpack('I4', e.data, 0x05 + 1);
    local pid, petid = ids.pid, ids.petid;
    if (pid == nil) then
        -- No frame yet (load / zone): live lookup, as before.
        local p = GetPlayerEntity();
        if (p == nil) then return; end
        pid, petid = p.ServerId, pet_id(p);
    end
    if (actor == pid) then
        petid = nil;
    elseif (petid == nil or actor ~= petid) then
        return;
    end

    local pkt = parse_action(e);
    if (pkt == nil or pkt.targets[1] == nil) then return; end
    -- FIX: raw server id. tid used to be 'ALLTARGETS' under DisplayContinuous, and
    -- is_monster('ALLTARGETS') -> bit.band error on every pet ability/Ready/BP.
    local tid = pkt.targets[1].id;

    if (actor == pid and pkt.category == 1) then
        -- Player melee round.
        local rec = record_attacks(pkt, TYPE_PLAYER);
        if (rec ~= nil) then
            state.display_target[TYPE_PLAYER] = rec;
            set_visible(TYPE_PLAYER);
        end

    elseif (actor == petid and pkt.category == 1) then
        -- Pet melee round.
        local rec = record_attacks(pkt, TYPE_PET);
        if (rec ~= nil and not state.dead_ids[rec]) then
            state.display_target[TYPE_PET] = rec;
            state.pet_enemy = rec;
            set_visible(TYPE_PET);
        end

    elseif (actor == pid and pkt.category == 3) then
        -- Player weaponskill.
        local rec = record_ws(pkt, TYPE_PLAYER, data.ws_messages);
        if (rec ~= nil) then
            state.display_target[TYPE_PLAYER] = rec;
            set_visible(TYPE_PLAYER);
        end

    elseif (actor == petid and is_monster(tid)) then
        -- Pet ability landing on a monster.
        local rec = nil;
        local job = main_job();
        if (pkt.category == 11 and job == 9) then
            -- BST Ready.
            rec = record_ws(pkt, TYPE_PET, data.ws_messages);
        elseif (pkt.category == 11 and job == 18) then
            -- Automaton TP move, whitelist gated.
            local auto = data.automaton_whitelist[pkt.param];
            if (auto ~= nil and auto.display) then
                rec = record_ws(pkt, TYPE_PET, data.ws_messages);
            end
        elseif (pkt.category == 13) then
            -- Avatar bloodpact / wyvern breath.
            rec = record_ws(pkt, TYPE_PET, data.bloodpact_messages);
        end
        if (rec ~= nil and not state.dead_ids[rec]) then
            state.display_target[TYPE_PET] = rec;
            state.pet_enemy = rec;
            set_visible(TYPE_PET);
        end

    elseif (actor == pid and pkt.category == 6) then
        -- Player JA that dismisses/parks the pet: hide the pet chart.
        if (data.hide_pet_triggers[pkt.param] ~= nil and settings.AutoHide) then
            state.visible[TYPE_PET] = false;
        end
    end
end

-- 0x00E: NPC update; detect deaths/despawns to retire logs.
local function handle_npc_update(e)
    if (settings.DisplayContinuous) then return; end
    if (e.size < 0x0B) then return; end

    local mask = struct.unpack('B', e.data, 0x0A + 1);
    if (bit.band(mask, 0x24) == 0) then return; end
    local npc_id = struct.unpack('I4', e.data, 0x04 + 1);
    -- PERF: only mobs we have data for matter; skip every other death in the zone.
    if (logs[TYPE_PLAYER][npc_id] == nil and logs[TYPE_PET][npc_id] == nil
        and npc_id ~= state.pet_enemy) then
        return;
    end
    local status_changed = bit.band(mask, 0x04) ~= 0;
    local terminated = bit.band(mask, 0x20) ~= 0;

    local died = false;
    if (status_changed and e.size >= 0x20) then
        local status = struct.unpack('B', e.data, 0x1F + 1);
        died = status >= 2 and status <= 3;
    end

    if ((died or terminated) and not state.dead_ids[npc_id]) then
        state.dead_ids[npc_id] = true;
        if (state.reset_at == nil) then
            state.reset_at = os.clock() + 20.0;
        end
        if (npc_id == state.pet_enemy) then
            schedule_hide(TYPE_PET);
            state.pet_enemy = nil;
        end
    end
end

function M.packet_in(e)
    if (not settings.enabled) then return; end
    if (e.id == 0x028) then
        handle_action(e);
    elseif (e.id == 0x00E) then
        handle_npc_update(e);
    elseif (e.id == 0x00B) then
        -- Zone exit. Zone accuracy is per-zone, so it clears here too.
        ids.pid, ids.petid = nil, nil;
        reset_all_logs();
        zone_reset();
        state.last_target = nil;
        state.visible[TYPE_PLAYER] = settings.AlwaysShow;
        state.visible[TYPE_PET] = false;
        state.hide_at[TYPE_PLAYER] = nil;
        state.hide_at[TYPE_PET] = nil;
    end
end

----------------------------------------------------------------------------------------------------
-- Frame polling (status / job change)
----------------------------------------------------------------------------------------------------

local function poll_state(p)
    -- FIX: hit%/crit%/avg are per-mob, but the chart used to keep showing the last
    -- mob you swung at until the first swing on the next one landed. Follow the
    -- target instead, so the numbers blank the moment you switch mobs.
    if (settings.ResetOnTargetChange and not settings.DisplayContinuous) then
        local ttid = current_target_id();
        if (ttid ~= nil and ttid ~= state.last_target) then
            state.last_target = ttid;
            if (is_monster(ttid)) then
                state.display_target[TYPE_PLAYER] = ttid;
            end
        end
    end

    local status = p.Status;
    if (status ~= state.last_status) then
        if (status == 1) then
            -- Engaged: show existing data for current target immediately.
            local tid = target_override() or current_target_id();
            if (tid ~= nil and logs[TYPE_PLAYER][tid] ~= nil) then
                state.display_target[TYPE_PLAYER] = tid;
                set_visible(TYPE_PLAYER);
            end
        elseif (state.last_status == 1) then
            schedule_hide(TYPE_PLAYER);
        end
        state.last_status = status;
    end

    local job = main_job();
    if (job ~= state.last_job) then
        if (not data.pet_jobs[job]) then
            state.visible[TYPE_PET] = false;
            state.display_target[TYPE_PET] = nil;
        end
        state.last_job = job;
    end

    local now = os.clock();
    if (state.reset_at ~= nil and now >= state.reset_at) then
        reset_dead_logs();
    end

    local h = state.hide_at;
    if (h[TYPE_PLAYER] ~= nil and now >= h[TYPE_PLAYER]) then
        state.visible[TYPE_PLAYER] = false;
        h[TYPE_PLAYER] = nil;
    end
    if (h[TYPE_PET] ~= nil and now >= h[TYPE_PET]) then
        state.visible[TYPE_PET] = false;
        h[TYPE_PET] = nil;
    end

    if (saved_dirty_at ~= nil and now - saved_dirty_at >= 0.5) then
        saved_dirty_at = nil;
        save_saved();
    end
end

----------------------------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------------------------

local function cursor_screen_pos()
    local a, b = imgui.GetCursorScreenPos();
    if (type(a) == 'table' or type(a) == 'userdata') then
        return a.x, a.y;
    end
    return a, b;
end

local function window_pos()
    local a, b = imgui.GetWindowPos();
    if (type(a) == 'table' or type(a) == 'userdata') then
        return a.x, a.y;
    end
    return a, b;
end

-- PERF: U32 colors cached per settings version (was a table + GetColorU32 per bar per frame).
local u32_cache, u32_ver = {}, -1;
local function col_u32(c, alpha)
    if (u32_ver ~= ver.cfg) then u32_cache, u32_ver = {}, ver.cfg; end
    alpha = alpha or 255;
    local byc = u32_cache[c];
    if (byc == nil) then byc = {}; u32_cache[c] = byc; end
    local v = byc[alpha];
    if (v == nil) then
        v = imgui.GetColorU32({ c[1] / 255, c[2] / 255, c[3] / 255, alpha / 255 });
        byc[alpha] = v;
    end
    return v;
end

-- PERF: reused ImVec2 tables; the binding copies values at call time.
local V1, V2, VD, VS = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 };
local function rect(dl, x1, y1, x2, y2, col)
    V1[1], V1[2], V2[1], V2[2] = x1, y1, x2, y2;
    dl:AddRectFilled(V1, V2, col);
end

local COLOR_SHADOW = { 192, 192, 192 };

local function result_color(result)
    if (result == data.ATTACK_HIT)      then return settings.ColorHit, settings.BarsAlpha; end
    if (result == data.ATTACK_CRIT)     then return settings.ColorCrit, settings.BarsAlpha; end
    if (result == data.ATTACK_MISS)     then return settings.ColorMiss, settings.BarsAlpha; end
    if (result == data.ATTACK_BLOCK)    then return settings.ColorBlock, settings.BarsAlpha; end
    if (result == data.ATTACK_HIT_ZERO) then return settings.ColorHitZero, settings.BarsAlpha; end
    if (result == data.ATTACK_COUNTER)  then return settings.ColorCounter, settings.BarsAlpha; end
    if (result == data.ATTACK_SHADOW)   then return COLOR_SHADOW, 1; end
    if (result == data.ATTACK_HEAL)     then return settings.ColorHeal, settings.BarsAlpha; end
    if (result == data.AE_HIT)          then return settings.ColorAdditionalEffect, settings.BarsAlpha; end
    if (result == data.AE_HEAL)         then return settings.ColorAdditionalEffectHeal, settings.BarsAlpha; end
    return nil, 0;
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v));
end

-- Round bar color == multi-attack tier. A round that landed nothing paints as a
-- miss (or counter) marker instead, so whiffs stay visible.
local ROUND_KEY = { 'ColorRound1', 'ColorRound2', 'ColorRound3', 'ColorRound4' };
local function round_color(r)
    if (r.hits <= 0) then
        if ((r.counter or 0) > 0) then return settings.ColorCounter, settings.BarsAlpha; end
        return settings.ColorMiss, settings.BarsAlpha;
    end
    local n = r.swings;
    if (n < 1) then n = 1; end
    if (n >= 5) then return settings.ColorRound5, settings.BarsAlpha; end
    return settings[ROUND_KEY[n]], settings.BarsAlpha;
end

local function draw_bars(tlog, log_type)
    local width, height, nbars;
    if (log_type == TYPE_PET) then
        width, height, nbars = settings.PetChartWidth, settings.PetChartHeight, settings.PetChartBars;
    else
        width, height, nbars = settings.ChartWidth, settings.ChartHeight, settings.ChartBars;
    end

    local cx, cy = cursor_screen_pos();
    VD[1], VD[2] = width, height;
    imgui.Dummy(VD);

    local dl = imgui.GetWindowDrawList();
    local bar_w = width / nbars;
    local gap = 0;
    if (bar_w >= 3) then gap = 1; end
    local bottom = cy + height;
    local marker_h = math.min(bar_w, height);

    -- FIX: round mode. One bar per attack round; height from round damage, color
    -- from swing count, thin cap when the round contained a crit.
    if (settings.BarMode == 'round') then
        local list = tlog.rlist or {};
        local scale = tlog.max_round or 0;
        for i = 1, nbars do
            local r = list[i];
            if (r ~= nil) then
                local x1 = cx + (bar_w * (i - 1));
                local x2 = x1 + bar_w - gap;
                local color, alpha = round_color(r);
                local h = marker_h;
                if (settings.DisplayMode ~= 'simple' and scale > 0 and r.dmg > 0) then
                    h = clamp(math.floor(r.dmg / scale * height), 1, height);
                end
                if (color ~= nil) then
                    rect(dl, x1, bottom - h, x2, bottom, col_u32(color, alpha));
                    if (settings.RoundCritCap and (r.crit or 0) > 0) then
                        local cap = math.min(settings.RoundCritCapPx or 2, h);
                        rect(dl, x1, bottom - h, x2, bottom - h + cap,
                             col_u32(settings.ColorCrit, settings.BarsAlpha));
                    end
                end
            end
        end
        return;
    end

    for i = 1, nbars do
        local entry = tlog.attacks[i];
        if (entry ~= nil) then
            local x1 = cx + (bar_w * (i - 1));
            local x2 = x1 + bar_w - gap;
            local result = entry.result;
            local dmg = entry.dmg;

            if (settings.DisplayMode == 'simple') then
                -- Uniform squares; crits fold into hits, AE hidden.
                local r = result;
                if (r == data.ATTACK_CRIT) then r = data.ATTACK_HIT; end
                local color, alpha = result_color(r);
                if (color ~= nil) then
                    rect(dl, x1, bottom - marker_h, x2, bottom, col_u32(color, alpha));
                end
            else
                if (settings.AdditionalEffectSingleBar) then
                    dmg = dmg + entry.ae_dmg;
                end

                local h = marker_h;
                local ae_h = 0;
                if (tlog.max > 0) then
                    h = clamp(math.floor(dmg / tlog.max * height), 1, height);
                    ae_h = clamp(math.floor(entry.ae_dmg / tlog.max * height), 0, height);
                    if (result == data.ATTACK_HEAL) then
                        h = clamp(h, 1, height);
                    end
                end

                -- Zero-ish outcomes render as fixed-size markers.
                if (result == data.ATTACK_MISS or result == data.ATTACK_HIT_ZERO
                    or result == data.ATTACK_COUNTER or result == data.ATTACK_SHADOW) then
                    h = marker_h;
                end

                local color, alpha = result_color(result);
                if (color ~= nil) then
                    rect(dl, x1, bottom - h, x2, bottom, col_u32(color, alpha));
                end

                -- Stacked additional effect bar on top of the physical hit.
                if (settings.AdditionalEffectStackBars and entry.ae_dmg > 0 and ae_h > 0
                    and entry.ae_result ~= data.AE_NONE) then
                    local ae_color, ae_alpha = result_color(entry.ae_result);
                    if (ae_color ~= nil) then
                        local top = clamp(bottom - h - ae_h, cy, bottom);
                        rect(dl, x1, top, x2, bottom - h, col_u32(ae_color, ae_alpha));
                    end
                end
            end
        end
    end
end

-- FIX: label prefix resolver. Glyph mode = tight single-glyph prefixes; word
-- mode falls back to the *LabelPrefix settings. TH has no word prefix of its
-- own (it rides on Last), so it is handled inline.
local GLYPH_DEFAULT = {
    -- FIX: ASCII only; Ashita font atlas lacks box/dingbat glyphs (they tofu).
    Max = 'M', Last = 'L', Acc = 'A', Crit = 'C',
    Avg = '~', Zone = 'Z', Round = '#', TH = '+',
};
local WORD_PREFIX = {
    Max = 'MaxLabelPrefix', Last = 'LastLabelPrefix', Acc = 'HitRateLabelPrefix',
    Crit = 'CritRateLabelPrefix', Avg = 'AvgLabelPrefix', Zone = 'ZoneAccLabelPrefix',
    Round = 'RoundLabelPrefix',
};
local function lp(key)
    if (settings.GlyphLabels) then
        return settings['Glyph' .. key] or GLYPH_DEFAULT[key] or '';
    end
    return settings[WORD_PREFIX[key]] or (key .. ': ');
end
-- FIX: TH is its own gold token now, always '+N', so it never inherits the
-- white label color and reads the same in word and glyph modes.
-- PERF: text/bg color tables built once per settings version, not per call.
local tc = { v = -1 };
local RATE_GOOD, RATE_BAD = { 0.4, 1.0, 0.03, 1.0 }, { 0.93, 0.0, 0.0, 1.0 };
local function refresh_cols()
    if (tc.v == ver.cfg) then return; end
    local a = settings.LabelAlpha / 255;
    local c = settings.LabelColor;
    tc.label = { c[1] / 255, c[2] / 255, c[3] / 255, a };
    c = settings.ColorTH or { 255, 200, 0 };
    tc.th = { c[1] / 255, c[2] / 255, c[3] / 255, a };
    c = settings.ColorHeal;
    tc.heal = { c[1] / 255, c[2] / 255, c[3] / 255, 1.0 };
    c = settings.BGColor;
    tc.bg = { c[1] / 255, c[2] / 255, c[3] / 255, settings.BGAlpha / 255 };
    tc.pad = { settings.BGPaddingX, settings.BGPaddingY };
    tc.spacing = { 4, 4 };
    tc.v = ver.cfg;
end
local function th_col()
    refresh_cols();
    return tc.th;
end

-- FIX: 12-char names instead of 5; no more 'Expia' mystery meat.
local function clean_ws_name(name)
    name = name:gsub('Blade: ', ''):gsub('Tachi: ', ''):gsub('\'', '');
    return name:sub(1, 12);
end

local function label_col()
    refresh_cols();
    return tc.label;
end

local function draw_ws_lines(tlog)
    local i0, i1, step = 1, #tlog.ws, 1;
    if (settings.ReverseWeaponskills) then
        i0, i1, step = #tlog.ws, 1, -1;
    end
    for i = i0, i1, step do
        local ws = tlog.ws[i];
        -- PERF: format once per entry, not per frame.
        if (ws.line == nil) then
            local dmg = tostring(ws.dmg);
            if (ws.result == data.ATTACK_MISS) then dmg = 'MISS'; end
            ws.line = ('%s %s'):format(clean_ws_name(ws.name), dmg);
            if (ws.sc_name ~= nil) then
                ws.sc_line = ('> %s %s'):format(ws.sc_name:sub(1, 4), tostring(ws.sc_dmg));
            end
        end
        local line_col = tc.label;
        if (ws.result == data.ATTACK_HEAL) then line_col = tc.heal; end

        imgui.TextColored(line_col, ws.line);
        if (ws.sc_line ~= nil) then
            imgui.SameLine();
            local sc_col = tc.label;
            if (ws.sc_result == data.ATTACK_HEAL) then sc_col = tc.heal; end
            imgui.TextColored(sc_col, ws.sc_line);
        end
    end
end

local function rate_color(rate, count)
    -- NOTE: quick visual read for daily use; >=95 green, <80 red.
    if (settings.HitRateColorize and count > 0) then
        if (rate >= 95) then return RATE_GOOD; end
        if (rate < 80) then return RATE_BAD; end
    end
    return label_col();
end

local function rate_fmt()
    if (settings.CompactLabels) then return '%s%d%%'; end
    return '%s%.1f%%';
end

-- Max / TH / Last round / round count group.
local function label_items_max(tlog)
    local t = {};
    local is_round = (settings.BarMode == 'round');
    if (settings.DisplayMax) then
        -- NOTE: in round mode Max is the biggest ROUND, matching what the bars show.
        local mx = tlog.max;
        if (is_round) then mx = tlog.max_round or 0; end
        -- FIX: show Max raw (was floored to nearest 100, made it read < Last).
        local mtxt = lp('Max') .. tostring(math.floor(mx));
        -- FIX: Max now shows the swing count of the round that set it, like Last.
        if (is_round and (tlog.max_round_sw or 0) > 0) then
            mtxt = mtxt .. (' (%d)'):format(tlog.max_round_sw);
        end
        t[#t + 1] = { text = mtxt, col = label_col() };
    end
    if (settings.DisplayLast) then
        -- FIX: show how many swings produced that number: (4) all landed,
        -- (2/4) two of a quad-attack round landed.
        local s = ('%s%d'):format(lp('Last'), tlog.last_dmg or 0);
        local sw = tlog.last_swings or 0;
        if (settings.LastShowHits and sw > 0) then
            local hs = tlog.last_hits or 0;
            if (hs == sw) then
                s = s .. (' (%d)'):format(sw);
            else
                s = s .. (' (%d/%d)'):format(hs, sw);
            end
        end
        t[#t + 1] = { text = s, col = label_col() };
        -- FIX: TH as its own gold '+N' token right after Last.
        if (settings.DisplayTH and (tlog.th or 0) > 0) then
            t[#t + 1] = { text = ('+%d'):format(tlog.th), col = th_col() };
        end
    end
    if (settings.DisplayRoundCount) then
        t[#t + 1] = { text = ('%s%d'):format(lp('Round'), tlog.rounds or 0),
                      col = label_col() };
    end
    return t;
end

-- Hit / Crit / Avg / Zone group.
local function label_items_rate(tlog, log_type)
    local t = {};
    if (not settings.DisplayHitRate) then return t; end
    local fmt = rate_fmt();

    local rate = 0;
    if (tlog.count > 0) then
        rate = (tlog.count - tlog.miss) / tlog.count * 100;
    end
    t[#t + 1] = { text = fmt:format(lp('Acc'), rate),
                  col = rate_color(rate, tlog.count) };

    -- FIX: zone accuracy parenthesized next to Hit, e.g. 'Hit: 98% (97%)'.
    -- Own color kept (separate item), so it still greens/reds independently.
    if (settings.DisplayZoneAcc and log_type == TYPE_PLAYER) then
        local zrate = 0;
        if (zone_stats.count > 0) then
            zrate = (zone_stats.count - zone_stats.miss) / zone_stats.count * 100;
        end
        local zfmt = settings.CompactLabels and '(%d%%)' or '(%.1f%%)';
        t[#t + 1] = { text = zfmt:format(zrate),
                      col = rate_color(zrate, zone_stats.count) };
    end

    if (settings.DisplayAvg) then
        local sum, n = 0, 0;
        if (settings.BarMode == 'round') then
            -- NOTE: round mode averages whole rounds, not individual swings.
            for _, r in ipairs(tlog.rlist or {}) do
                if (r.dmg > 0) then
                    sum = sum + r.dmg;
                    n = n + 1;
                end
            end
        else
        for _, a in ipairs(tlog.attacks) do
            if (a.result ~= data.ATTACK_HEAL and a.dmg > 0) then
                sum = sum + a.dmg;
                n = n + 1;
            end
        end
        end
        if (n > 0) then
            t[#t + 1] = { text = ('%s%d'):format(lp('Avg'), math.floor(sum / n)),
                          col = label_col() };
        end
    end

    if (settings.DisplayCritRate and tlog.count > 0) then
        t[#t + 1] = { text = fmt:format(lp('Crit'), tlog.crit / tlog.count * 100),
                      col = label_col() };
    end

    return t;
end

local function draw_label_row(items)
    for i, it in ipairs(items) do
        if (i > 1) then imgui.SameLine(); end
        imgui.TextColored(it.col, it.text);
    end
end

local win_flags_base = bit.bor(
    ImGuiWindowFlags_NoTitleBar or 1,
    ImGuiWindowFlags_NoResize or 2,
    ImGuiWindowFlags_NoScrollbar or 8,
    ImGuiWindowFlags_NoScrollWithMouse or 16,
    ImGuiWindowFlags_NoCollapse or 32,
    ImGuiWindowFlags_NoFocusOnAppearing or 4096,
    ImGuiWindowFlags_NoNav or 786432);

local function calc_text_size(text)
    local a, b = imgui.CalcTextSize(text);
    if (type(a) == 'table' or type(a) == 'userdata') then
        return a.x, a.y;
    end
    return a, b;
end

-- FIX: constant window size; stacked layout, width from widest real row.
local fws_cache = {};
local fixed_window_size_calc;
local function fixed_window_size(log_type)
    local c = fws_cache[log_type];
    if (c == nil or c.v ~= ver.cfg) then
        local w, h = fixed_window_size_calc(log_type);
        c = { v = ver.cfg, w = w, h = h };
        fws_cache[log_type] = c;
    end
    return c.w, c.h;
end

fixed_window_size_calc = function (log_type)
    local width, height;
    if (log_type == TYPE_PET) then
        width, height = settings.PetChartWidth, settings.PetChartHeight;
    else
        width, height = settings.ChartWidth, settings.ChartHeight;
    end

    -- Measured at scale 1 outside the window; the chart draws at FontScale
    -- (AutoFit only ever shrinks below it), so size for FontScale or rows clip.
    local fs = tonumber(settings.FontScale) or 1.0;
    local spacing = 4;
    local _, line_h = calc_text_size('Hg');
    line_h = (line_h or 13) * fs;

    local rows = 1; -- chart dummy
    local content_h = height;
    local content_w = width;

    local max_tmpl, rate_tmpl;
    if (settings.DisplayMax) then
        max_tmpl = lp('Max') .. '99999 (8)';
    end
    if (settings.DisplayLast) then
        max_tmpl = (max_tmpl or '') .. ' ' .. lp('Last') .. '99999';
        if (settings.LastShowHits) then max_tmpl = max_tmpl .. ' (8/8)'; end
        if (settings.DisplayTH) then
            max_tmpl = max_tmpl .. ' +9';
        end
    end
    if (settings.DisplayRoundCount) then
        max_tmpl = (max_tmpl or '') .. ' ' .. lp('Round') .. '999';
    end
    if (settings.DisplayHitRate) then
        rate_tmpl = lp('Acc') .. '100%';
        if (not settings.CompactLabels) then rate_tmpl = lp('Acc') .. '100.0%'; end
        if (settings.DisplayCritRate) then
            rate_tmpl = rate_tmpl .. ' ' .. lp('Crit') .. '100%';
        end
        if (settings.DisplayAvg) then
            rate_tmpl = rate_tmpl .. ' ' .. lp('Avg') .. '9999';
        end
        if (settings.DisplayZoneAcc and log_type ~= TYPE_PET) then
            rate_tmpl = rate_tmpl .. (settings.CompactLabels and ' (100%)' or ' (100.0%)');
        end
    end

    if (settings.SingleLineLabels) then
        if (max_tmpl ~= nil or rate_tmpl ~= nil) then
            local combined = ((max_tmpl or '') .. ' ' .. (rate_tmpl or '')):gsub('^%s+', '');
            content_h = content_h + line_h;
            rows = rows + 1;
            if (settings.WidthFromLabels) then
                local w = calc_text_size(combined);
                content_w = math.max(content_w, (w or 0) * fs);
            end
        end
    else
        if (max_tmpl ~= nil) then
            content_h = content_h + line_h;
            rows = rows + 1;
            if (settings.WidthFromLabels) then
                local w = calc_text_size(max_tmpl);
                content_w = math.max(content_w, (w or 0) * fs);
            end
        end
        if (rate_tmpl ~= nil) then
            content_h = content_h + line_h;
            rows = rows + 1;
            if (settings.WidthFromLabels) then
                local w = calc_text_size(rate_tmpl);
                content_w = math.max(content_w, (w or 0) * fs);
            end
        end
    end

    if (settings.DisplayWeaponskills) then
        local n = ws_count(log_type);
        content_h = content_h + (n * line_h);
        rows = rows + n;
        if (settings.WidthFromLabels) then
            local w = calc_text_size('Wwwwwwwwwwww 99999 > Wwww 99999');
            content_w = math.max(content_w, (w or 0) * fs);
        end
    end

    content_h = content_h + ((rows - 1) * spacing);

    return content_w + (2 * settings.BGPaddingX),
           content_h + (2 * settings.BGPaddingY);
end

local WIN_NAME = { [TYPE_PLAYER] = 'aaev_' .. TYPE_PLAYER, [TYPE_PET] = 'aaev_' .. TYPE_PET };
local row_cache = { [TYPE_PLAYER] = {}, [TYPE_PET] = {} };

local function draw_chart(log_type)
    local tid = state.display_target[log_type];
    local tlog = nil;
    if (tid ~= nil) then tlog = logs[log_type][tid]; end
    if (tlog ~= nil and #tlog.attacks == 0 and #tlog.ws == 0) then tlog = nil; end
    if (tlog == nil) then
        -- No live data: AlwaysShow keeps an empty player frame on screen.
        if (not (settings.AlwaysShow and log_type == TYPE_PLAYER)) then return; end
        tlog = idle_log;
    end

    local start_x, start_y;
    if (log_type == TYPE_PET) then
        start_x, start_y = settings.PetChartStartX, settings.PetChartStartY;
    else
        start_x, start_y = settings.ChartStartX, settings.ChartStartY;
    end

    local flags = win_flags_base;
    if (not state.unlocked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove or 4, ImGuiWindowFlags_NoMouseInputs or 512);
    end
    if (not settings.BGDisplay) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoBackground or 128);
    end

    if (not state.applied_pos[log_type]) then
        imgui.SetNextWindowPos({ start_x, start_y }, ImGuiCond_Always or 1);
        state.applied_pos[log_type] = true;
    end

    if (settings.FixedSize) then
        local fw, fh = fixed_window_size(log_type);
        VS[1], VS[2] = fw, fh;
        imgui.SetNextWindowSize(VS, ImGuiCond_Always or 1);
    else
        flags = bit.bor(flags, ImGuiWindowFlags_AlwaysAutoResize or 64);
    end

    refresh_cols();
    imgui.PushStyleColor(ImGuiCol_WindowBg or 2, tc.bg);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding or 2, tc.pad);
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing or 13, tc.spacing);

    if (imgui.Begin(WIN_NAME[log_type], nil, flags)) then
        -- PERF: label rows + fit scale rebuilt only when this log, zone stats or
        -- settings changed. Was: string.format + avg loop + CalcTextSize every frame.
        local lc = row_cache[log_type];
        local zv = (log_type == TYPE_PLAYER) and zone_stats.v or 0;
        if (lc.tlog ~= tlog or lc.v ~= tlog.v or lc.zv ~= zv or lc.cv ~= ver.cfg) then
            local top_row = label_items_max(tlog);
            local bot_row = label_items_rate(tlog, log_type);
            -- FIX: SingleLineLabels folds Max/TH onto the stat row so the window is
            -- one text line tall instead of two.
            if (settings.SingleLineLabels) then
                for i = #top_row, 1, -1 do
                    table.insert(bot_row, 1, top_row[i]);
                end
                top_row = {};
            end

            -- FIX: window width follows ChartWidth, not the label text. If the label
            -- row would overflow, shrink the font to fit instead of widening the window.
            local scale = settings.FontScale or 1.0;
            if (imgui.SetWindowFontScale ~= nil
                and settings.AutoFitLabels and not settings.WidthFromLabels) then
                -- Measure at 1.0.
                imgui.SetWindowFontScale(1.0);
                local widest = 0;
                for _, row in ipairs({ top_row, bot_row }) do
                    if (#row > 0) then
                        local parts = {};
                        for i, it in ipairs(row) do parts[i] = it.text; end
                        local w = calc_text_size(table.concat(parts, ' ')) or 0;
                        if (w > widest) then widest = w; end
                    end
                end
                local avail = chart_width(log_type);
                if (widest > 0 and avail > 0 and (widest * scale) > avail) then
                    scale = math.max(settings.MinFontScale or 0.55, avail / widest);
                end
            end
            lc.top, lc.bot, lc.scale = top_row, bot_row, scale;
            lc.tlog, lc.v, lc.zv, lc.cv = tlog, tlog.v, zv, ver.cfg;
        end
        local top_row, bot_row = lc.top, lc.bot;
        -- SetWindowFontScale is not exposed in every Ashita imgui build; guard it.
        if (imgui.SetWindowFontScale ~= nil) then
            imgui.SetWindowFontScale(lc.scale);
        end

        imgui.BeginGroup();

        if (#top_row > 0) then
            draw_label_row(top_row);
        end

        draw_bars(tlog, log_type);

        if (#bot_row > 0) then
            draw_label_row(bot_row);
        end

        -- Weaponskill results below the chart (narrower window than a side column).
        if (settings.DisplayWeaponskills and (#tlog.ws > 0 or settings.FixedSize)) then
            draw_ws_lines(tlog);
            if (settings.FixedSize) then
                for _ = #tlog.ws + 1, ws_count(log_type) do
                    imgui.Text(' ');
                end
            end
        end

        imgui.EndGroup();

        if (state.unlocked) then
            local wx, wy = window_pos();
            state['pos_' .. log_type] = { math.floor(wx), math.floor(wy) };
        end
    end
    imgui.End();
    imgui.PopStyleVar(2);
    imgui.PopStyleColor(1);
end

function M.render()
    if (not settings.enabled) then
        -- GUI edits made while disabled still need flushing.
        if (saved_dirty_at ~= nil) then saved_dirty_at = nil; save_saved(); end
        return;
    end

    local p = GetPlayerEntity();
    if (p == nil or p.ServerId == nil or p.ServerId == 0) then
        ids.pid, ids.petid = nil, nil;
        return;
    end
    ids.pid, ids.petid = p.ServerId, pet_id(p);
    poll_state(p);

    local show_player = state.visible[TYPE_PLAYER] or settings.AlwaysShow;
    if (state.forced_hidden) then show_player = false; end
    if (show_player) then
        draw_chart(TYPE_PLAYER);
    end
    if (state.visible[TYPE_PET] and settings.PetChart and data.pet_jobs[state.last_job]) then
        draw_chart(TYPE_PET);
    end
end

----------------------------------------------------------------------------------------------------
-- Demo dataset
----------------------------------------------------------------------------------------------------

local function make_demo(log_type)
    math.randomseed(os.time());
    local tlog = get_target_log(log_type, 'DEMO', true);
    tlog.count, tlog.max, tlog.miss, tlog.crit, tlog.th = 100, 0, 16, 21, 5;
    tlog.rounds, tlog.last_dmg = 37, 412;
    tlog.attacks = {};
    tlog.ws = {};

    -- Round-mode demo set: mixed multi-attack tiers so every color shows up.
    tlog.rlist = {};
    tlog.max_round = 0;
    tlog.max_round_sw = 0;
    for i = 1, chart_bars(log_type) do
        local sw = 1;
        local roll = math.random(100);
        if (roll > 92) then sw = 4;
        elseif (roll > 78) then sw = 3;
        elseif (roll > 50) then sw = 2; end
        local hits, dmg = 0, 0;
        for _ = 1, sw do
            if (math.random(100) > 12) then
                hits = hits + 1;
                dmg = dmg + math.random(180, 460);
            end
        end
        local crit = 0;
        if (hits > 0 and math.random(100) > 75) then
            crit = 1;
            dmg = dmg + math.random(120, 300);
        end
        if (dmg > tlog.max_round) then tlog.max_round = dmg; tlog.max_round_sw = sw; end
        table.insert(tlog.rlist, { dmg = dmg, swings = sw, hits = hits,
                                   crit = crit, counter = 0, ae_dmg = 0 });
    end
    local lastr = tlog.rlist[#tlog.rlist];
    if (lastr ~= nil) then
        tlog.last_dmg, tlog.last_hits, tlog.last_swings = lastr.dmg, lastr.hits, lastr.swings;
    end

    local results = {
        data.ATTACK_HIT, data.ATTACK_HIT, data.ATTACK_HIT, data.ATTACK_CRIT,
        data.ATTACK_BLOCK, data.ATTACK_MISS, data.ATTACK_HIT_ZERO, data.ATTACK_HIT,
        data.ATTACK_CRIT, data.ATTACK_HEAL,
    };
    for i = 1, chart_bars(log_type) do
        local r = results[math.random(#results)];
        local dmg = 0;
        if (r == data.ATTACK_HIT or r == data.ATTACK_CRIT or r == data.ATTACK_HEAL) then
            dmg = math.random(40, 125);
        elseif (r == data.ATTACK_BLOCK) then
            dmg = math.random(10, 35);
        end
        local ae = data.AE_NONE;
        local ae_dmg = 0;
        if (settings.AdditionalEffectStackBars and math.random() < 0.5 and dmg > 0) then
            ae = data.AE_HIT;
            ae_dmg = math.random(5, 25);
        end
        local total = dmg;
        if (r == data.ATTACK_HEAL) then total = 0; end
        if (settings.AdditionalEffectSingleBar or settings.AdditionalEffectStackBars) then
            total = total + ae_dmg;
        end
        tlog.max = math.max(tlog.max, total);
        table.insert(tlog.attacks, { result = r, dmg = dmg, ae_result = ae, ae_dmg = ae_dmg });
    end

    tlog.ws = {
        { name = 'Evisceration',  dmg = 1500,  result = data.ATTACK_HIT },
        { name = 'Rudra\'s Storm', dmg = 2000, result = data.ATTACK_HEAL, sc_name = 'Darkness', sc_dmg = 5000, sc_result = data.ATTACK_HIT },
        { name = 'Rudra\'s Storm', dmg = 3000, result = data.ATTACK_HIT, sc_name = 'Darkness', sc_dmg = 10000, sc_result = data.ATTACK_HEAL },
        { name = 'Viper Bite',    dmg = 666,   result = data.ATTACK_HIT },
        { name = 'Viper Bite',    dmg = 99999, result = data.ATTACK_HIT, sc_name = 'Scission', sc_dmg = 123, sc_result = data.ATTACK_HIT },
    };
    while (#tlog.ws > ws_count(log_type)) do
        table.remove(tlog.ws, 1);
    end
    tlog.v = (tlog.v or 0) + 1;
end

local function demo()
    make_demo(TYPE_PLAYER);
    state.display_target[TYPE_PLAYER] = 'DEMO';
    state.visible[TYPE_PLAYER] = true;
    if (settings.PetChart and is_pet_job()) then
        make_demo(TYPE_PET);
        state.display_target[TYPE_PET] = 'DEMO';
        state.visible[TYPE_PET] = true;
    end
end

----------------------------------------------------------------------------------------------------
-- Config window (mirrors the targetbar settings UI)
----------------------------------------------------------------------------------------------------

local cfg_flags = bit.bor(ImGuiWindowFlags_NoCollapse or 32,
                          ImGuiWindowFlags_AlwaysAutoResize or 64);

local function set_setting(key, value)
    settings[key] = value;
    ver.cfg = ver.cfg + 1;
    saved_dirty_at = os.clock();   -- flushed by poll_state after 0.5s idle
end

local function cfg_check(label, key)
    local v = { settings[key] == true };
    if (imgui.Checkbox(label, v)) then
        set_setting(key, v[1]);
        return true;
    end
    return false;
end

-- Same-line checkbox pair: label A + label B share one row. Callers pass a
-- shared min width so the two columns stay aligned when the labels differ in
-- length (imgui's default SameLine just butts them together).
local function cfg_check_pair(la, ka, lb, kb, col_w)
    cfg_check(la, ka);
    if (kb ~= nil) then
        imgui.SameLine(col_w or 220, 0);
        return cfg_check(lb, kb);
    end
end

-- InputInt used to write + clamp on every keystroke, so typing '250' went
-- 2 -> clamped to lo -> the field fought back. Buffer the raw value in an int_buf
-- table keyed by widget id; commit + clamp + save only when the field loses
-- focus (IsItemDeactivatedAfterEdit). Fall back to commit-on-change on bindings
-- that lack the query.
local int_buf = {};
local ig_dae  = imgui.IsItemDeactivatedAfterEdit;

local function cfg_int(label, key, lo, hi)
    local id = label .. '#' .. key;
    local cur = math.floor(tonumber(settings[key]) or 0);
    if (int_buf[id] == nil or not int_buf[id].editing) then
        int_buf[id] = { v = { cur }, editing = false };
    end
    local buf = int_buf[id];
    local changed = imgui.InputInt(label, buf.v);
    if (changed) then buf.editing = true; end

    local done = ig_dae and ig_dae() or (not ig_dae and changed);
    if (not done) then return false; end

    buf.editing = false;
    local n = math.floor(tonumber(buf.v[1]) or cur);
    if (n < lo) then n = lo; elseif (n > hi) then n = hi; end
    buf.v[1] = n;
    if (n ~= cur) then set_setting(key, n); return true; end
    return false;
end

local function cfg_slider(label, key, lo, hi)
    local v = { math.floor(tonumber(settings[key]) or 0) };
    if (imgui.SliderInt(label, v, lo, hi)) then
        set_setting(key, clamp(math.floor(v[1]), lo, hi));
        return true;
    end
    return false;
end

local function cfg_float(label, key, lo, hi)
    local v = { tonumber(settings[key]) or 0 };
    if (imgui.SliderFloat(label, v, lo, hi)) then
        set_setting(key, clamp(v[1], lo, hi));
        return true;
    end
    return false;
end

local function cfg_note(text)
    if (imgui.TextDisabled ~= nil) then
        imgui.TextDisabled(text);
    else
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, text);
    end
end

-- CollapsingHeader is not guaranteed in every Ashita imgui build; fall back to a plain heading.
local function cfg_section(label)
    if (imgui.CollapsingHeader ~= nil) then
        local ok, open = pcall(imgui.CollapsingHeader, label);
        if (ok) then return open; end
    end
    imgui.Separator();
    imgui.Text(label);
    return true;
end

-- Tab wrappers with feature detection. Older Ashita imgui bindings only ship
-- Checkbox/InputInt/Text; TabBar arrived later. When missing we fall back to
-- collapsing headers so the window still works, just as one long scroll.
local HAS_TABS = imgui.BeginTabBar ~= nil
             and imgui.BeginTabItem ~= nil
             and imgui.EndTabItem ~= nil
             and imgui.EndTabBar ~= nil;

local function tabs_begin(id)
    if (HAS_TABS) then
        local ok, opened = pcall(imgui.BeginTabBar, id);
        return ok and opened;
    end
    return false;
end
local function tabs_end()  if (HAS_TABS) then pcall(imgui.EndTabBar);  end end
local function tab_begin(label)
    if (HAS_TABS) then
        local ok, opened = pcall(imgui.BeginTabItem, label);
        return ok and opened;
    end
    return cfg_section(label);   -- fallback: headers, always drawn
end
local function tab_end() if (HAS_TABS) then pcall(imgui.EndTabItem); end end

local function help_marker(text)
    -- Small '(?)' with a hover tooltip. Not strictly needed but keeps the row
    -- from carrying a 60-char '(what this does)' phrase.
    if (imgui.TextDisabled == nil or imgui.IsItemHovered == nil
        or imgui.BeginTooltip == nil or imgui.EndTooltip == nil) then
        return;
    end
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if (imgui.IsItemHovered()) then
        imgui.BeginTooltip();
        imgui.Text(text);
        imgui.EndTooltip();
    end
end

local function apply_chart_pos()
    state.applied_pos[TYPE_PLAYER] = false;
    state.applied_pos[TYPE_PET] = false;
    save_positions();
end

-- Tab bodies. Split out so both the TabBar path and the CollapsingHeader
-- fallback (older imgui bindings) can call the same code.

local function tab_display()
    local full = { settings.DisplayMode ~= 'simple' };
    if (imgui.Checkbox('Damage-scaled bars', full)) then
        set_setting('DisplayMode', full[1] and 'full' or 'simple');
    end
    help_marker('Off: uniform result squares. On: bar height scales with damage.');

    local rmode = { settings.BarMode == 'round' };
    if (imgui.Checkbox('One bar per attack round', rmode)) then
        set_setting('BarMode', rmode[1] and 'round' or 'swing');
    end
    help_marker('Off: one bar per swing. On: one bar per round, color = swing count.');

    if (settings.BarMode == 'round') then
        cfg_note('  blue single / cyan double / green triple / yellow quad / orange 5+');
        cfg_note('  white or red bar = round landed nothing. Max and Avg are per round.');
        cfg_check('  Cap rounds that crit with a thin bar', 'RoundCritCap');
    end

    imgui.Separator();

    cfg_check('Always show (permanent chart, ignores disengage)', 'AlwaysShow');
    if (settings.AlwaysShow) then
        cfg_note('  Auto-hide ignored while Always show is on.');
    else
        cfg_check('Auto-hide on disengage', 'AutoHide');
        cfg_float('Hide delay (sec)', 'HideDelay', 0.0, 20.0);
    end
    cfg_check_pair('Continuous log', 'DisplayContinuous',
                   'Follow target', 'ResetOnTargetChange', 200);
    cfg_check('Fixed window size (no resize jumps)', 'FixedSize');
end

local function tab_layout()
    imgui.Text('Player chart');
    local unlocked = { state.unlocked };
    if (imgui.Checkbox('Unlock -- drag charts with the mouse', unlocked)) then
        state.unlocked = unlocked[1];
        if (not state.unlocked) then
            local p = state['pos_' .. TYPE_PLAYER];
            if (p ~= nil) then
                settings.ChartStartX, settings.ChartStartY = p[1], p[2];
            end
            local pp = state['pos_' .. TYPE_PET];
            if (pp ~= nil) then
                settings.PetChartStartX, settings.PetChartStartY = pp[1], pp[2];
            end
            save_positions();
        end
    end
    if (cfg_int('X##chartpos', 'ChartStartX', 0, 8000)) then apply_chart_pos(); end
    imgui.SameLine();
    if (cfg_int('Y##chartpos', 'ChartStartY', 0, 8000)) then apply_chart_pos(); end
    cfg_int('Width', 'ChartWidth', 20, 2000);
    imgui.SameLine();
    cfg_int('Height', 'ChartHeight', 4, 400);
    cfg_int((settings.BarMode == 'round') and 'Bars (rounds)' or 'Bars (swings)',
            'ChartBars', 1, 100);
    cfg_check('Let labels widen the window', 'WidthFromLabels');
    if (not settings.WidthFromLabels) then
        cfg_check('Shrink label text to fit the width', 'AutoFitLabels');
    end

    imgui.Separator();
    imgui.Text('Appearance');
    cfg_slider('Bar alpha',        'BarsAlpha', 0, 255);
    cfg_check('Draw background panel', 'BGDisplay');
    if (settings.BGDisplay) then
        cfg_slider('  Background alpha', 'BGAlpha', 0, 255);
    end
    cfg_float('Font scale', 'FontScale', 0.5, 3.0);
end

local function tab_stats()
    -- Row format: two-column checkbox grid. Each column is ~220px so the labels
    -- do not butt up against one another when the left is a short word.
    imgui.Text('Which numbers to show');
    cfg_check_pair('Max damage',              'DisplayMax',
                   'Average damage',          'DisplayAvg',      220);
    cfg_check_pair('Last round damage',       'DisplayLast',
                   'Round counter (this mob)','DisplayRoundCount', 220);
    cfg_check_pair('Hit rate (current mob)',  'DisplayHitRate',
                   'Crit rate',               'DisplayCritRate', 220);
    cfg_check_pair('Zone accuracy',           'DisplayZoneAcc',
                   'Treasure Hunter tier',    'DisplayTH',       220);
    if (settings.DisplayLast) then
        cfg_check('  Last: include swing count, e.g. "Last: 2547 (4)"', 'LastShowHits');
    end
    help_marker('TH rides on Last; disabling Last hides it.');

    imgui.Separator();
    imgui.Text('Format');
    -- 'GlyphLabels' internally, but 'glyph' is inaccurate -- ASCII M/L/A/C are
    -- not glyphs, they are single-letter prefixes. Label + tooltip make the
    -- meaning obvious without renaming the storage key (would break saves).
    cfg_check('Short prefixes  ("M 999" instead of "Max: 999")', 'GlyphLabels');
    help_marker(
        'Off: "Max: 999   Last: 2547   Acc: 92%   Crit: 8%"\n'
     .. 'On:  "M 999   L 2547   A 92%   C 8%"\n'
     .. 'Single-letter labels save room when the chart is narrow.');
    cfg_check_pair('One label row',           'SingleLineLabels',
                   'Whole-number rates',      'CompactLabels', 220);
    cfg_check('Colorize accuracy  (green >=95, red <80)', 'HitRateColorize');
end

local function tab_weaponskills()
    cfg_check('Show weaponskill list', 'DisplayWeaponskills');
    if (settings.DisplayWeaponskills) then
        cfg_check('Newest at top', 'ReverseWeaponskills');
        cfg_int('Lines kept', 'WeaponskillCount', 1, 20);
    end
end

local function tab_effects()
    local single = { settings.AdditionalEffectSingleBar == true };
    if (imgui.Checkbox('Fold AE damage into the hit bar', single)) then
        set_setting('AdditionalEffectSingleBar', single[1]);
        if (single[1]) then set_setting('AdditionalEffectStackBars', false); end
    end
    if (not settings.AdditionalEffectSingleBar) then
        cfg_check('Stack AE damage as a second bar', 'AdditionalEffectStackBars');
    end
    cfg_note('Additional effects: enspells, TH procs, aftermath damage, etc.');
end

local function tab_pet()
    cfg_check('Show pet chart (BST / DRG / SMN / PUP)', 'PetChart');
    if (not settings.PetChart) then return; end
    imgui.Separator();
    if (cfg_int('X##petpos', 'PetChartStartX', 0, 8000)) then apply_chart_pos(); end
    imgui.SameLine();
    if (cfg_int('Y##petpos', 'PetChartStartY', 0, 8000)) then apply_chart_pos(); end
    cfg_int('Width##pet',  'PetChartWidth',  20, 2000);
    imgui.SameLine();
    cfg_int('Height##pet', 'PetChartHeight', 4,  400);
    cfg_int('Bars##pet',   'PetChartBars', 1, 100);
    cfg_int('Weaponskill lines##pet', 'PetWeaponskillCount', 1, 20);
end

local function tab_footer()
    imgui.Separator();
    if (imgui.Button('Demo data')) then demo(); end
    imgui.SameLine();
    if (imgui.Button('Reset zone accuracy')) then
        zone_reset();
    end
    imgui.SameLine();
    if (imgui.Button('Reset all to defaults')) then
        M.reset_defaults();
    end
    cfg_note('Changes save per character as you make them.');
end

function M.draw_config_body()
    do
        if (tabs_begin('##aaev_tabs')) then
            if (tab_begin('Display'))       then tab_display();       tab_end(); end
            if (tab_begin('Layout'))        then tab_layout();        tab_end(); end
            if (tab_begin('Stats'))         then tab_stats();         tab_end(); end
            if (tab_begin('Weaponskills'))  then tab_weaponskills();  tab_end(); end
            if (tab_begin('Effects'))       then tab_effects();       tab_end(); end
            if (tab_begin('Pet'))           then tab_pet();           tab_end(); end
            tabs_end();
        else
            -- Fallback: no TabBar in this imgui build; drop back to headers.
            if (cfg_section('Display'))      then tab_display();      end
            if (cfg_section('Layout'))       then tab_layout();       end
            if (cfg_section('Stats'))        then tab_stats();        end
            if (cfg_section('Weaponskills')) then tab_weaponskills(); end
            if (cfg_section('Effects'))      then tab_effects();      end
            if (cfg_section('Pet'))          then tab_pet();          end
        end
        tab_footer();
    end
end

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

local function msg(s)
    print(chat.header(addon.name):append(chat.message(s)));
end

local function show_help()
    msg('/targethud aaev <cmd>  (settings: /targethud, AAEV tab). Commands:');
    msg('  (bare)  - toggle charts');
    msg('  on|off  - enable / disable AAEV');
    msg('  config  - open the settings window');
    msg('  show    - force charts visible');
    msg('  hide    - force charts hidden');
    msg('  simple  - simple display mode');
    msg('  full    - full display mode');
    msg('  demo    - draw charts with a sample dataset');
    msg('  unlock  - allow dragging chart windows');
    msg('  lock    - lock windows and auto-save positions');
    msg('  bars N  - set bar count on both charts (runtime)');
    msg('  autohide - toggle AutoHide (runtime)');
    msg('  always  - toggle permanent player chart (runtime)');
    msg('  zone    - print zone accuracy totals to chat');
    msg('  zonereset - clear zone accuracy counters');
    msg('  delay N - set HideDelay seconds 0-20 (runtime)');
    msg('  reload  - re-read this character\'s aaev.lua');
end

-- args[1] ignored; args[2..] = the old /targethud aaev sub-commands.
function M.command(args)

    local cmd = '';
    if (args[2] ~= nil) then cmd = args[2]:lower(); end

    -- NOTE: bare /targethud aaev toggles visibility for daily use.
    if (cmd == '') then
        if (state.forced_hidden) then
            cmd = 'show';
        elseif (state.visible[TYPE_PLAYER] or state.visible[TYPE_PET] or settings.AlwaysShow) then
            cmd = 'hide';
        else
            cmd = 'show';
        end
    end

    if (cmd == 'show') then
        state.forced_hidden = false;
        state.visible[TYPE_PLAYER] = settings.AlwaysShow or state.display_target[TYPE_PLAYER] ~= nil;
        state.visible[TYPE_PET] = state.display_target[TYPE_PET] ~= nil;
        if (not state.visible[TYPE_PLAYER] and not state.visible[TYPE_PET]) then
            msg('No attack data recorded yet; nothing to show. Try /targethud aaev demo.');
        end
    elseif (cmd == 'hide') then
        state.forced_hidden = true;
        state.visible[TYPE_PLAYER] = false;
        state.visible[TYPE_PET] = false;
        state.hide_at[TYPE_PLAYER] = nil;
        state.hide_at[TYPE_PET] = nil;
    elseif (cmd == 'simple') then
        settings.DisplayMode = 'simple';
        msg('Display mode: simple.');
    elseif (cmd == 'full') then
        settings.DisplayMode = 'full';
        msg('Display mode: full.');
    elseif (cmd == 'demo') then
        demo();
    elseif (cmd == 'unlock') then
        state.unlocked = true;
        msg('Charts unlocked; drag to position, then /targethud aaev lock.');
    elseif (cmd == 'lock') then
        state.unlocked = false;
        local p = state['pos_' .. TYPE_PLAYER];
        if (p ~= nil) then
            settings.ChartStartX, settings.ChartStartY = p[1], p[2];
        end
        local pp = state['pos_' .. TYPE_PET];
        if (pp ~= nil) then
            settings.PetChartStartX, settings.PetChartStartY = pp[1], pp[2];
        end
        -- FIX: positions auto-persist to aaev_positions.lua; no hand-editing.
        if (save_positions()) then
            msg('Charts locked; positions saved.');
        else
            msg('Charts locked; position save FAILED.');
        end
    elseif (cmd == 'delay') then
        local n = tonumber(args[3] or '');
        if (n ~= nil and n >= 0 and n <= 20) then
            settings.HideDelay = n;
            msg(('HideDelay: %.1fs.'):format(n));
        else
            msg('Usage: /targethud aaev delay <0-20> (seconds; 0 = instant hide)');
        end
    elseif (cmd == 'autohide') then
        settings.AutoHide = not settings.AutoHide;
        if (settings.AutoHide) then
            msg('AutoHide: on.');
        else
            msg('AutoHide: off (charts stay until zone or /targethud aaev hide).');
            state.hide_at[TYPE_PLAYER] = nil;
            state.hide_at[TYPE_PET] = nil;
        end
    elseif (cmd == 'config' or cmd == 'settings' or cmd == 'menu') then
        if (M.on_config ~= nil) then M.on_config(); end
    elseif (cmd == 'always') then
        settings.AlwaysShow = not settings.AlwaysShow;
        if (settings.AlwaysShow) then
            settings.AutoHide = false;
            state.forced_hidden = false;
            state.hide_at[TYPE_PLAYER] = nil;
            msg('AlwaysShow: on (player chart is permanent; AutoHide forced off).');
        else
            msg('AlwaysShow: off.');
        end
    elseif (cmd == 'zonereset') then
        zone_reset();
        msg('Zone accuracy reset.');
    elseif (cmd == 'zone') then
        if (zone_stats.count > 0) then
            msg(('Zone: %d swings, %d miss, %.2f%% acc, %.2f%% crit.'):format(
                zone_stats.count, zone_stats.miss,
                (zone_stats.count - zone_stats.miss) / zone_stats.count * 100,
                zone_stats.crit / zone_stats.count * 100));
        else
            msg('Zone: no swings recorded this zone.');
        end
    elseif (cmd == 'bars') then
        local n = tonumber(args[3] or '');
        if (n ~= nil and n >= 1 and n <= 100) then
            n = math.floor(n);
            settings.ChartBars = n;
            settings.PetChartBars = n;
            msg(('Chart bars: %d (both charts).'):format(n));
        else
            msg('Usage: /targethud aaev bars <1-100>');
        end
    elseif (cmd == 'reload') then
        slib.reload('aaev');      -- raises the switch event -> M.set_cfg
        msg('Settings reloaded.');
    else
        show_help();
    end
    ver.cfg = ver.cfg + 1;
    saved_dirty_at = os.clock();   -- command changes persist per character
end

----------------------------------------------------------------------------------------------------
-- Load
----------------------------------------------------------------------------------------------------

function M.init()
    state.last_status = player_status();
    state.last_job = main_job();
    if (settings.AutoDemo) then
        demo();
    end
end

function M.unload()
    if (saved_dirty_at ~= nil) then save_saved(); end
    -- Persist drag positions user forgot to lock in.
    if (state['pos_' .. TYPE_PLAYER] ~= nil or state['pos_' .. TYPE_PET] ~= nil) then
        local p = state['pos_' .. TYPE_PLAYER];
        if (p ~= nil) then
            settings.ChartStartX, settings.ChartStartY = p[1], p[2];
        end
        local pp = state['pos_' .. TYPE_PET];
        if (pp ~= nil) then
            settings.PetChartStartX, settings.PetChartStartY = pp[1], pp[2];
        end
        save_positions();
    end
end

----------------------------------------------------------------------------------------------------
-- Module API
----------------------------------------------------------------------------------------------------

-- Settings lib hands a NEW table on every character switch; adopt it as-is
-- (the lib saves it by reference).
function M.set_cfg(t)
    settings = t;
    saved_dirty_at = nil;
    for k in pairs(int_buf) do int_buf[k] = nil; end
    load_settings();
    state.applied_pos[TYPE_PLAYER] = false;
    state.applied_pos[TYPE_PET] = false;
end

function M.enabled() return settings.enabled == true; end

function M.set_enabled(on)
    settings.enabled = (on == true);
    if (settings.enabled) then
        state.last_status = player_status();
        state.last_job = main_job();
        state.visible[TYPE_PLAYER] = settings.AlwaysShow;
    else
        reset_all_logs();
        zone_reset();
        state.visible[TYPE_PLAYER] = false;
        state.visible[TYPE_PET] = false;
        state.hide_at[TYPE_PLAYER] = nil;
        state.hide_at[TYPE_PET] = nil;
        state.unlocked = false;
    end
    saved_dirty_at = nil;
    save_saved();
end

function M.reset_defaults()
    for k, v in pairs(default_settings) do
        if (k ~= 'enabled' and k ~= 'migrated') then
            settings[k] = (type(v) == 'table') and { unpack(v) } or v;
        end
    end
    saved_dirty_at = nil;
    for k in pairs(int_buf) do int_buf[k] = nil; end
    load_settings();
    save_saved();
    state.applied_pos[TYPE_PLAYER] = false;
    state.applied_pos[TYPE_PET] = false;
end

return M;
