-- targethud: AAEV static data (was aaev data.lua)
-- NOTE(aryl): ported verbatim from Windower AAEV 1.2.0beta by darkewaffle.

local data = {};

-- Attack result tokens
data.ATTACK_HIT      = 'hit';
data.ATTACK_CRIT     = 'crit';
data.ATTACK_MISS     = 'miss';
data.ATTACK_BLOCK    = 'block';
data.ATTACK_HIT_ZERO = 'zero';
data.ATTACK_HEAL     = 'heal';
data.ATTACK_SHADOW   = 'shadow';
data.ATTACK_COUNTER  = 'counter';

data.AE_HIT             = 'ae_hit';
data.AE_HEAL            = 'ae_heal';
data.AE_TREASURE_HUNTER = 'ae_th';
data.AE_NONE            = 'ae_none';

-- Melee attack message id -> result
data.attack_messages = {
    [1]   = data.ATTACK_HIT,
    [14]  = data.ATTACK_COUNTER,
    [15]  = data.ATTACK_MISS,
    [31]  = data.ATTACK_SHADOW,
    [33]  = data.ATTACK_COUNTER,
    [63]  = data.ATTACK_MISS,
    [67]  = data.ATTACK_CRIT,
    [69]  = data.ATTACK_BLOCK,
    [70]  = data.ATTACK_BLOCK,  -- parry
    [373] = data.ATTACK_HEAL,
    [606] = data.ATTACK_COUNTER,
};

-- Additional effect message id -> result
data.ae_messages = {
    [163] = data.AE_HIT,   -- generic damage
    [229] = data.AE_HIT,   -- enspell
    [384] = data.AE_HEAL,  -- enspell heal
    [603] = data.AE_TREASURE_HUNTER,
};

-- Weaponskill message id -> result
data.ws_messages = {
    [101]  = data.ATTACK_HIT,
    [103]  = data.ATTACK_HEAL,
    [109]  = data.ATTACK_HIT,
    [135]  = data.ATTACK_HIT,
    [142]  = data.ATTACK_HIT,
    [159]  = data.ATTACK_HIT,
    [185]  = data.ATTACK_HIT,
    [186]  = data.ATTACK_HIT,
    [187]  = data.ATTACK_HIT,
    [188]  = data.ATTACK_MISS,
    [189]  = data.ATTACK_HIT,
    [194]  = data.ATTACK_HIT,
    [197]  = data.ATTACK_HIT,
    [221]  = data.ATTACK_HIT,
    [224]  = data.ATTACK_HEAL,
    [225]  = data.ATTACK_HIT,
    [226]  = data.ATTACK_HIT,
    [231]  = data.ATTACK_HIT,
    [238]  = data.ATTACK_HEAL,
    [242]  = data.ATTACK_HIT,
    [243]  = data.ATTACK_HIT,
    [360]  = data.ATTACK_HIT,
    [362]  = data.ATTACK_HIT,
    [369]  = data.ATTACK_HIT,
    [370]  = data.ATTACK_HIT,
    [402]  = data.ATTACK_HIT,
    [405]  = data.ATTACK_HIT,
    [406]  = data.ATTACK_HIT,
    [409]  = data.ATTACK_HIT,
    [416]  = data.ATTACK_HIT,
    [418]  = data.ATTACK_HIT,
    [539]  = data.ATTACK_HIT,
    [607]  = data.ATTACK_HIT,
    [747]  = data.ATTACK_HIT,
    [748]  = data.ATTACK_HIT,
    [750]  = data.ATTACK_HIT,
    [752]  = data.ATTACK_HIT,
    [754]  = data.ATTACK_HIT,
    [755]  = data.ATTACK_HIT,
    [762]  = data.ATTACK_HIT,
    [763]  = data.ATTACK_HIT,
    [764]  = data.ATTACK_HIT,
    [778]  = data.ATTACK_HIT,
    [779]  = data.ATTACK_HIT,
    [780]  = data.ATTACK_HIT,
    [805]  = data.ATTACK_HIT,
    [1023] = data.ATTACK_HIT,
};

-- Bloodpact / wyvern breath message id -> result
data.bloodpact_messages = {
    [102] = data.ATTACK_HEAL,
    [110] = data.ATTACK_HIT,
    [158] = data.ATTACK_MISS,
    [306] = data.ATTACK_HEAL,
    [317] = data.ATTACK_HIT,
    [318] = data.ATTACK_HEAL,
    [323] = data.ATTACK_MISS,
    [324] = data.ATTACK_MISS,
    [379] = data.ATTACK_HIT,
    [522] = data.ATTACK_HIT,
    [736] = data.ATTACK_HIT,
    [802] = data.ATTACK_HIT,
    [803] = data.ATTACK_HIT,
};

-- Skillchain message id -> { name, result }
data.skillchain_messages = {
    [288] = { name = 'Light',         result = data.ATTACK_HIT },
    [289] = { name = 'Darkness',      result = data.ATTACK_HIT },
    [290] = { name = 'Gravitation',   result = data.ATTACK_HIT },
    [291] = { name = 'Fragmentation', result = data.ATTACK_HIT },
    [292] = { name = 'Distortion',    result = data.ATTACK_HIT },
    [293] = { name = 'Fusion',        result = data.ATTACK_HIT },
    [294] = { name = 'Compression',   result = data.ATTACK_HIT },
    [295] = { name = 'Liquefaction',  result = data.ATTACK_HIT },
    [296] = { name = 'Induration',    result = data.ATTACK_HIT },
    [297] = { name = 'Reverberation', result = data.ATTACK_HIT },
    [298] = { name = 'Transfixion',   result = data.ATTACK_HIT },
    [299] = { name = 'Scission',      result = data.ATTACK_HIT },
    [300] = { name = 'Detonation',    result = data.ATTACK_HIT },
    [301] = { name = 'Impaction',     result = data.ATTACK_HIT },
    [385] = { name = 'Light',         result = data.ATTACK_HEAL },
    [386] = { name = 'Darkness',      result = data.ATTACK_HEAL },
    [387] = { name = 'Gravitation',   result = data.ATTACK_HEAL },
    [388] = { name = 'Fragmentation', result = data.ATTACK_HEAL },
    [389] = { name = 'Distortion',    result = data.ATTACK_HEAL },
    [390] = { name = 'Fusion',        result = data.ATTACK_HEAL },
    [391] = { name = 'Compression',   result = data.ATTACK_HEAL },
    [392] = { name = 'Liquefaction',  result = data.ATTACK_HEAL },
    [393] = { name = 'Induration',    result = data.ATTACK_HEAL },
    [394] = { name = 'Reverberation', result = data.ATTACK_HEAL },
    [395] = { name = 'Transfixion',   result = data.ATTACK_HEAL },
    [396] = { name = 'Scission',      result = data.ATTACK_HEAL },
    [397] = { name = 'Detonation',    result = data.ATTACK_HEAL },
    [398] = { name = 'Impaction',     result = data.ATTACK_HEAL },
    [767] = { name = 'Radiance',      result = data.ATTACK_HIT },
    [768] = { name = 'Umbra',         result = data.ATTACK_HIT },
    [769] = { name = 'Radiance',      result = data.ATTACK_HEAL },
    [770] = { name = 'Umbra',         result = data.ATTACK_HEAL },
};

-- Automaton TP moves: id -> { en, display }
data.automaton_whitelist = {
    [1940] = { en = 'Chimera Ripper',  display = true },
    [1941] = { en = 'String Clipper',  display = true },
    [1942] = { en = 'Arcuballista',    display = true },
    [1943] = { en = 'Slapstick',       display = true },
    [1944] = { en = 'Shield Bash',     display = false },
    [1945] = { en = 'Provoke',         display = false },
    [1946] = { en = 'Shock Absorber',  display = false },
    [1947] = { en = 'Flashbulb',       display = false },
    [1948] = { en = 'Mana Converter',  display = false },
    [1949] = { en = 'Ranged Attack',   display = true },
    [2021] = { en = 'Eraser',          display = false },
    [2031] = { en = 'Reactive Shield', display = false },
    [2065] = { en = 'Cannibal Blade',  display = true },
    [2066] = { en = 'Daze',            display = true },
    [2067] = { en = 'Knockout',        display = true },
    [2068] = { en = 'Economizer',      display = false },
    [2299] = { en = 'Bone Crusher',    display = true },
    [2300] = { en = 'Armor Piercer',   display = true },
    [2301] = { en = 'Magic Mortar',    display = true },
    [2743] = { en = 'String Shredder', display = true },
    [2744] = { en = 'Armor Shatterer', display = true },
    [2745] = { en = 'Heat Capacitor',  display = false },
    [2746] = { en = 'Barrage Turbine', display = false },
    [2747] = { en = 'Disruptor',       display = false },
    [2778] = { en = 'Reactive Shield', display = false },
    [2779] = { en = 'Shock Absorber',  display = false },
    [2780] = { en = 'Replicator',      display = false },
    [3485] = { en = 'Regulator',       display = false },
};

-- Player JA ids that hide the pet chart (dismiss/retrieve/etc)
data.hide_pet_triggers = {
    [29]  = 'Spirit Surge',
    [70]  = 'Heel',
    [71]  = 'Leave',
    [87]  = 'Dismiss',
    [89]  = 'Retreat',
    [90]  = 'Release',
    [139] = 'Deactivate',
    [140] = 'Retrieve',
};

-- Pet-capable main jobs: BST DRG SMN PUP
data.pet_jobs = { [9] = true, [14] = true, [15] = true, [18] = true };

return data;
