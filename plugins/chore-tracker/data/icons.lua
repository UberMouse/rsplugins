-- The icon each chore's list row shows, hand-written. Each entry
-- names one built-in client graphic by its constant name: `obj`, an item (id.Obj.<name>, from
-- docs/api/consts/Obj.lua), or `sprite`, an interface sprite (id.Sprite.<name>, from
-- docs/api/consts/Sprite.lua). Names, not ids, so this stays plain data (the specs read it
-- outside the plugin, where `id` doesn't exist) and the shell looks each one up as it builds a
-- row. An item pictures the chore's reward or the thing it handles; the round gold sprites
-- (XP_TOKEN_0 and the SKILL_* ones) mark chores whose reward is XP, and MAPFUNCTION_SEP_0, the
-- General Store map icon, marks the general shops. All are graphics the client already has: the
-- plugin ships no images of its own.

---@class ChoreIcon
---@field obj string? an id.Obj constant name
---@field sprite string? an id.Sprite constant name

---@type table<string, ChoreIcon>
return {
    ["daily-challenge"] = { sprite = "XP_TOKEN_0" },
    ["player-owned-ports"] = { obj = "POP_LOG" },
    ["player-owned-farm"] = { sprite = "SKILL_FARMING" },
    ["crystal-tree-blossom"] = { obj = "CRYSTAL_TREE_BLOSSOM" },
    ["invention-machine"] = { obj = "INVENT_DIVINE_CHARGE" },
    ["divine-locations"] = { sprite = "SKILL_DIVINATION" },
    ["archaeology-research"] = { obj = "ARCH_CURRENCY_CHRONOTES" },
    ["nemi-forest"] = { sprite = "XP_TOKEN_0" },
    ["sinkholes"] = { obj = "TRH_DUNGEONEERING_TOKEN" },
    ["goebie-bands"] = { obj = "RAID1_GOEBIE_COURIER_SUPPLY" },
    ["menaphos-obelisk"] = { obj = "MENAPHOS_JEWELLED_SCARAB" },
    ["big-chinchompa"] = { obj = "CHINCHOMPA_BIG_CAPTURED" },
    ["fixate"] = { sprite = "SKILL_ARCHAEOLOGY" },
    ["arc-contracts"] = { obj = "ELR1_CURRENCY" },
    ["rapid-growth"] = { sprite = "SKILL_FARMING" },
    ["runesphere"] = { obj = "RUNE_DUST" },
    ["book-of-char"] = { obj = "FMC_FIREMAKERS_HANDBOOK" },
    ["bloodwood-tree"] = { obj = "SNIPER_BOLTS" },
    ["miscellania"] = { obj = "MAPLE_LOGS" },
    ["herb-run"] = { obj = "RANARR_WEED" },
    ["soul-reaper"] = { sprite = "SKILL_SLAYER" },
    ["thalmunds-wares"] = { sprite = "MAPFUNCTION_SEP_0" },
    ["capping-clan-citadel"] = { obj = "CLAN_FLAG" },
    ["charge-anachronia-totems"] = { obj = "DINO_TOTEM_CLUES" },
    ["meg"] = { obj = "MACRO_GENILAMP" },
    ["tears-of-guthix"] = { obj = "TOG_BOWL" },
    ["herby-werby"] = { obj = "DINO_REWARD_HERB_BAG" },
    ["big-top-bonanza"] = { sprite = "XP_TOKEN_0" },
    ["penguin-hide-and-seek"] = { obj = "PENG_SPY_DEVICE" },
    ["wisps-of-the-grove"] = { obj = "NATURE_BEINGS_JAR_EMPTY" },
    ["shattered-worlds"] = { obj = "SWORLDS_REWARD_CURRENCY" },
    ["familiarisation"] = { obj = "LORE_SPIRIT_SHARD" },
    ["skeletal-horror"] = { obj = "TRAIL_CLUE_ELITE_COMPASS" },
    ["aquarium-treasure-chest"] = { obj = "TRAIL_CLUE_ELITE_COMPASS" },
    ["agoroth"] = { obj = "ASH1_REPLAY_CONSUMABLE" },
    ["broken-home"] = { obj = "MACRO_GENILAMP" },
    ["rush-of-blood"] = { sprite = "SKILL_SLAYER" },
    ["water-filtration"] = { obj = "UNCUT_ONYX" },
    ["miscellania-weekly"] = { obj = "MAPLE_LOGS" },
    ["invention-machine-weekly"] = { obj = "INVENT_DIVINE_CHARGE" },
    ["arc-supplies"] = { obj = "ELR1_BAMBOO_LOW" },
    ["dream-of-iaia-resource"] = { sprite = "XP_TOKEN_0" },
    ["gwd2-bounties"] = { obj = "GWD2_REP_TROPHY_ZAMORAK" },
    ["fort-forinthry-bonus-xp"] = { obj = "WOF_SMALL_FALLING_STAR_PRISMATIC" },
    ["advance-time"] = { sprite = "SPELL_ICON_STANDARD_SKILLING_ADVANCE_TIME_MOBILE" },
    ["feather-shop-run"] = { obj = "FEATHER" },
    ["meat-packs"] = { obj = "RAW_BEEF" },
    ["vial-of-water-packs"] = { obj = "VIAL_WATER" },
    ["yak-hide"] = { obj = "YAK_HIDE" },
    ["bandit-duty-free"] = { sprite = "MAPFUNCTION_SEP_0" },
    ["seaweed-and-pineapples"] = { obj = "SEAWEED" },
    ["bert-sand"] = { obj = "BUCKET_SAND" },
    ["dellmonti-pineapples"] = { obj = "PINEAPPLE" },
    ["coeden-logs"] = { obj = "LOGS" },
    ["lupe"] = { obj = "DRAGON_BONES" },
    ["feathers-of-ma-at"] = { obj = "MENAPHOS_SLAYER_MAAT_FEATHER" },
    ["broad-arrowheads"] = { obj = "SLAYER_BROAD_ARROW_HEAD" },
    ["oldman-potato-cactus"] = { obj = "CACTUS_POTATO" },
    ["razmire-planks"] = { obj = "WOODPLANK" },
    ["geoffrey-flax"] = { obj = "FLAX" },
    ["cromperty-pure-essence"] = { obj = "BLANKRUNE_HIGH" },
    ["rune-shop-run"] = { obj = "AIRRUNE" },
    ["giant-oyster"] = { sprite = "SKILL_FISHING" },
    ["god-statues"] = { sprite = "SKILL_CONSTRUCTION" },
    ["effigy-incubator"] = { obj = "EFFI_ANCIENT_EFFIGY_LEVEL_0" },
    ["troll-invasion"] = { sprite = "XP_TOKEN_0" },
    ["dream-of-iaia-xp"] = { sprite = "XP_TOKEN_0" },
}
