addon.name    = 'targethud';
addon.author  = 'aryl (targetbar); Broguypal / Ashita v4 port (targetring); darkewaffle / Ashita v4 port (aaev)';
addon.version = '1.1';
addon.desc    = 'Target/cast/JA/menu bars + ground rings + GEO bubbles + optional AAEV. Per-character settings.';
addon.link    = 'https://github.com/ary1l/targethud';

require('common');
local chat     = require('chat');
local settings = require('settings');
local bar      = require('hud_bar');
local ring     = require('hud_ring');
local aaev     = require('hud_aaev');
local gui      = require('hud_gui');

--[[
* Settings: Ashita's settings lib is per-character by design.
*   config/addons/targethud/<Name>_<id>/bar.lua, ring.lua, aaev.lua   (logged in)
*   config/addons/targethud/defaults/...                            (logged out)
* On a character switch the lib saves, then loads a NEW table per alias and raises
* settings.register callbacks. Modules must adopt that table (the lib saves by
* reference), which is what set_cfg does.
--]]
local cfg = { bar = nil, ring = nil, aaev = nil };

local function char_folder()
    return settings.settings_path():match('([^\\]+)\\+$') or 'defaults';
end

-- One-time import of the old addon's file for the same character folder.
local function migrate(alias, s, defaults, old_addon)
    if (s.migrated) then return; end
    s.migrated = true;

    local folder = char_folder();
    local file = ('%s\\config\\addons\\%s\\%s\\settings.lua'):fmt(AshitaCore:GetInstallPath(), old_addon, folder);
    if (ashita.fs.exists(file)) then
        local ok, old = pcall(function () return loadfile(file)(); end);
        if (ok and type(old) == 'table') then
            local n = 0;
            for k, v in pairs(defaults) do
                if (k ~= 'migrated' and old[k] ~= nil and type(old[k]) == type(v)) then
                    s[k] = old[k];
                    n = n + 1;
                end
            end
            print(chat.header(addon.name):append(chat.message(('Imported %d %s settings (%s).'):fmt(n, old_addon, folder))));
        end
    end

    settings.save(alias);
end

local function load_file(file)
    if (not ashita.fs.exists(file)) then return nil; end
    local ok, t = pcall(dofile, file);
    return (ok and type(t) == 'table') and t or nil;
end

-- AAEV kept one shared (not per-char) set in its addon folder:
-- aaev_settings.lua (hand-edited) < aaev_saved.lua (GUI) < aaev_positions.lua.
-- Imported into each character's aaev.lua once. Found files => module enabled.
local function migrate_aaev(s)
    if (s.migrated) then return; end
    s.migrated = true;

    local dir = ('%s\\addons\\aaev\\'):fmt(AshitaCore:GetInstallPath());
    local keys, found = { }, false;

    local function take(t)
        if (t == nil) then return; end
        found = true;
        for k, v in pairs(aaev.defaults) do
            if (k ~= 'enabled' and k ~= 'migrated' and t[k] ~= nil and type(t[k]) == type(v)) then
                s[k] = t[k];
                keys[k] = true;
            end
        end
    end

    take(load_file(dir .. 'aaev_settings.lua'));
    take(load_file(dir .. 'aaev_saved.lua'));

    local pos = load_file(dir .. 'aaev_positions.lua');
    if (pos ~= nil) then
        found = true;
        local map = { px = 'ChartStartX', py = 'ChartStartY', ex = 'PetChartStartX', ey = 'PetChartStartY' };
        for pk, sk in pairs(map) do
            if (type(pos[pk]) == 'number') then s[sk] = pos[pk]; keys[sk] = true; end
        end
    end

    if (found) then
        s.enabled = true;
        local n = 0;
        for _ in pairs(keys) do n = n + 1; end
        print(chat.header(addon.name):append(chat.message(('Imported %d aaev settings (%s); AAEV enabled.'):fmt(n, char_folder()))));
    end

    settings.save('aaev');
end

local function adopt_bar(s)
    migrate('bar', s, bar.defaults, 'targetbar');
    cfg.bar = s;
    bar.set_cfg(s);
end

local function adopt_ring(s)
    migrate('ring', s, ring.defaults, 'targetring');
    cfg.ring = s;
    ring.set_cfg(s);
end

local function adopt_aaev(s)
    migrate_aaev(s);
    cfg.aaev = s;
    aaev.set_cfg(s);
end

ashita.events.register('load', 'thud_load', function ()
    bar.init();
    adopt_bar(settings.load(bar.defaults, 'bar'));
    adopt_ring(settings.load(ring.defaults, 'ring'));
    adopt_aaev(settings.load(aaev.defaults, 'aaev'));
    aaev.init();
    aaev.on_config = gui.open_window;

    settings.register('bar',  'thud_bar_switch',  adopt_bar);
    settings.register('ring', 'thud_ring_switch', adopt_ring);
    settings.register('aaev', 'thud_aaev_switch', adopt_aaev);
end);

ashita.events.register('unload', 'thud_unload', function ()
    bar.unload();
    aaev.unload();
    settings.save('bar');
    settings.save('ring');
    settings.save('aaev');
end);

-- Separate registrations: an error in one module cannot stop the other.
ashita.events.register('packet_in',  'thud_bar_in',   function (e) bar.packet_in(e);  end);
ashita.events.register('packet_in',  'thud_ring_in',  function (e) ring.packet_in(e); end);
ashita.events.register('packet_in',  'thud_aaev_in',  function (e) aaev.packet_in(e); end);
ashita.events.register('packet_out', 'thud_bar_out',  function (e) bar.packet_out(e);  end);
ashita.events.register('packet_out', 'thud_ring_out', function (e) ring.packet_out(e); end);
ashita.events.register('d3d_present', 'thud_ring_draw', function () ring.render(); end);
ashita.events.register('d3d_present', 'thud_bar_draw',  function () bar.render();  end);
ashita.events.register('d3d_present', 'thud_aaev_draw', function () aaev.render(); end);
ashita.events.register('d3d_present', 'thud_gui_draw',  function () gui.render(cfg, bar, ring, aaev); end);

local HELP = {
    '/targethud                      toggle settings window',
    '/targethud ring                 ring status',
    '/targethud ring on|off|depth|arrow|runes|fade|flip',
    '/targethud ring scale <n> | slices <n>',
    '/targethud ring range on|off|geo|hitbox | base <n> | fill <n>',
    '/targethud geo [on|off|buffs|cure|bubble|clear | radius|cap|scan|slices <n>]',
    '/targethud aaev on|off          enable / disable auto-attack chart',
    '/targethud aaev [show|hide|demo|lock|unlock|zone|help ...]',
};

ashita.events.register('command', 'thud_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/targethud') then return; end
    e.blocked = true;

    local sub = args[2] and args[2]:lower() or nil;

    if (sub == nil) then
        gui.toggle();
    elseif (sub == 'ring') then
        -- Old /tring layout: args[2] = sub-command. Drop the 'ring' word.
        local a = { args[1] };
        for i = 3, #args do a[#a + 1] = args[i]; end
        ring.command(a);
    elseif (sub == 'geo') then
        ring.command(args);     -- already /tring geo <opt> <val> layout
    elseif (sub == 'aaev') then
        local opt = args[3] and args[3]:lower() or nil;
        if (opt == 'on' or opt == 'off') then
            aaev.set_enabled(opt == 'on');
            print(chat.header(addon.name):append(chat.message('AAEV ' .. opt .. '.')));
        elseif (not aaev.enabled() and opt ~= 'config') then
            print(chat.header(addon.name):append(chat.message('AAEV is off: /targethud aaev on')));
        else
            local a = { args[1] };
            for i = 3, #args do a[#a + 1] = args[i]; end
            aaev.command(a);
        end
    else
        for _, line in ipairs(HELP) do
            print(chat.header(addon.name):append(chat.message(line)));
        end
    end
end);
