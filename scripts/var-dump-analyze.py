#!/usr/bin/env python3
"""Turn a var-dump snapshot (and its change log) into files a human can navigate.

Usage: python3 -I scripts/var-dump-analyze.py [snapshot.jsonl] [options]

  snapshot.jsonl     a snapshot from the var-dump plugin (default: the newest
                     dumps/var-dump/snapshot-*.jsonl; .partial files are skipped)
  --changes PATH     the VarTransmit log (default: changes.jsonl next to the
                     snapshot, if it exists); only read, never written
  --compare PATH     an older snapshot to diff against (default: the snapshot
                     before this one, if there is one; "none" to skip)
  --out DIR          where to write (default: dumps/var-dump/analysis)
  --catalog [DIR]    also write the account-independent var catalog (names,
                     types, families, VarBit layout; no values) to DIR
                     (default: docs/vars). That folder is gitignored; the
                     plugin tests need it.

Writes to the output dir:
  REPORT.md            readable summary with interpretations (guesses marked)
  summary.json         headline counts
  vars.csv             every var, one row each, with family/group/state/hint
  families.csv/.json   the name-prefix family tree, with counts per node
  families-tree.txt    the same tree, indented
  nondefault.csv/.txt  only the vars that hold state for this character
  basevars.json/.txt   each packed base VarPlayer with its VarBits and bit ranges
  changes-summary.csv  per-var behaviour in the change log
  snapshot-diff.csv    vars that differ from the --compare snapshot

"Default" means the value a var holds when nothing has set it: 0, -1, "", the
null coordinate, or a config reference with id -1. Everything else is "set".
BOOLEAN vars are "ambiguous" (see BOOLEAN_NOTE). Values that could identify
other players (PLAYER_UID vars, and name-like STRING vars) are never written
out, as Jagex's guidelines forbid exporting other players' info. They're only
counted, as "redacted".
"""

import argparse
import calendar
import csv
import json
import re
import statistics
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DUMP_DIR = ROOT / "dumps/var-dump"

# --- Family tree tuning -------------------------------------------------------
LEAF_MAX = 60   # a group with more members than this is split by its next name token
MIN_GROUP = 3   # sub-groups smaller than this are folded back into their parent
MAX_DEPTH = 4   # never split deeper than this many name tokens

# --- What counts as "default" -------------------------------------------------
NULL_COORD = "-1,0,0,0,0"
# The plugin writes an unset SPOTANIM as this odd tostring text.
DEFAULT_VALUES = {0, -1, "", NULL_COORD, "config..(-1)"}

# --- Other players' info: count, never print ----------------------------------
REDACTED_TYPES = {"PLAYER_UID"}
# STRING vars whose name suggests they hold a player name (party members, hosts...).
NAME_LIKE = re.compile(r"(^|_)(NAME|PLAYER|FRIEND|INVITE|MEM\d*|MEMBER|USER|OWNER|HOST|PARTNER"
                       r"|TARGET|P\d)(_|$|\d)")

BOOLEAN_NOTE = (
    "BOOLEAN vars read mostly `true`, including some that are implausible for an idle "
    "character (e.g. HOUSE_CURRENTLY_PEEKING, COMSCENARIO_PVP_ACTIVE). The API probably "
    "converts an unset (-1) value to true, so `true` can't be told apart from unset. "
    "`false` may be the explicitly-set value. They're kept separate as 'ambiguous'."
)

# --- Game time encodings (see the "Time values" section of the report) --------
RS_EPOCH = calendar.timegm((2002, 2, 27, 0, 0, 0))  # RuneDate day 0, in Unix seconds
UNIX_ZERO_IN_RS_MINUTES = -RS_EPOCH // 60            # -16912800: "unset" timestamps
FIVE_YEARS_MIN = 5 * 365 * 24 * 60
# A number only reads as a timestamp if the var's name says it's a time (colours and
# packed layouts often happen to be timestamp-sized).
TIME_LIKE = re.compile(r"MINUTE|TIME|CLOCK|DATE|EXPIR|LAST|LOGIN|LOGOUT|RESET|CHECK|STAMP|DAY")
DAY_LIKE = re.compile(r"DAY|RESET|LAST|LOGIN|TRACKER|CHECKED|EXPIR")

# --- Interpretation (hand-written; "GUESS" = inferred from names only) --------
# Themes roll family stems up into topics. A pattern must match the whole family
# label (without its "*"), either as is or with trailing digits removed (GWD2 -> GWD).
THEMES = {
    "Combat & abilities": r"COMBATV2|COMBAT|CBTV2CA|ACTIONBAR|PRAYER|TOPSTAT|CURSE|NECRO|NECROMANCY|LORE|"
                          r"KEYBIND|BUFF|AUTOCAST|LIFEPOINTS|MAXLIFEPOINTS|AGGRO|INCENSE",
    "Interface & settings": r"TOPLEVEL|IF|UITUTORIAL|TUTSYS|TUT|TUTORIAL|OPTION|MOBILE|QUICKCHAT|"
                            r"OPTEXT|MACRO|CHAT|MESSAGE|SETTINGS|ACCESSIBILITY|TLI|EMOTE|"
                            r"LOGINSCREEN|LOGIN|NEWS|XPDISPLAY|BANK|SIDEBOOK|POPUP|"
                            r"NOTES|MACHINIMA|ADVISOR|SHARE|TRADE|LOOT|MINIMAP|CAMERA|INTERFACE|"
                            r"TUTISLAND|LOBBY",
    "Travel & map": r"FAIRYRINGS|FAIRY|WORLDMAP|THAS|TELEPORT|LODESTONE|SPIRIT|EAGLEPEAK|"
                    r"LUNARFM",
    "Quests & story": r"QUEST|MINIQUEST|Q|QP|QPS|QL|MOURNING|FREMSAGA|MAH|MYQ|ELFCITY|MENAPHOS|"
                      r"OWEN|ELR|FORT|TSD|SLISKE|ARIANE|OZAN|VKQ|SUM|RA|PENG|LUNAR|PIRATEFINALE|"
                      r"TPR|PNR|FOTG|GOWER|WENDLE|SEREN|ENAKH|DORGESH|LUC|CSI|HOG|ATMO|TNS|NOM|VIKING|"
                      r"FORGET|WANTED|DESERT|WATCHTOWER|KELDAGRIM|HEARTSTEALER|GRIM|FEUD|"
                      r"TOMB|FEVER|RDEN|EGQ|EVQ|LQ|ME|GOEBIE|MOM",
    "Achievements & logs": r"CHEEVO|ITEMLOG|COLLECTION|TASK|LVL|SKILLCAPE|DISTINCTION|NJCAPES|"
                           r"AT[A-Z]{2,6}|DNDTRACKER|UAUI|CHALLENGE|VARIETY_TASK_EVENTS",
    "Archaeology": r"ARCH|ARCHAEOLOGY",
    "House & Construction": r"POH|CONSTRUCTION|CON|HOUSE",
    "Skilling": r"INVENT|FARMING|POF|POP|DINO|MINING|HUNTING|DIV|ARTISAN|SLAYER|SLAYC|BSLAY|"
                r"FISHCOMP|ECOSYSTEM|SKILLPETS|TOOLBELT|THIEVING|HERBLORE|RCSIPHONXP|BIRDHOUSE|"
                r"FIREDUP|CRCS|XP|BONUSXP|DOUBLEXP|DXP|GIVEXP|MAKEX|STATS|HEIST|SAFES|SKILL|FISH|"
                r"RCGUILD|BLAST",
    "Leagues & game modes": r"LEAGUE|GROUP|SWORLDS|GAMEMODE_SEASONAL",
    "Bosses & raids": r"BOSS|RAID|GWD|EGWD|RAND|DUNGEON|DEATH|BPETS|QBD|VORAGO|TZHAAR|BARROWS",
    "Minigames": r"DOM|DUEL|BARBASSAULT|SC|CRUC|BOARDGAMES|MEGAGAMES|SFA|DOV|TRAIL|MOB|"
                 r"CASTLEWARS|CLANWARS|CONQ|FMC|SLIDE_PUZZLE|DEADLY|SPOTLIGHT|PVPW|WILDY|BREW|"
                 r"GARDEN|MAGICTRAINING|WARGUILD|CHAMPIONS",
    "Shop, MTX & promotions": r"MTX[A-Z]*|TRH|BONDS|CURRENCY|PREMCLUB|UPASS|RUNEPASS|BP|LOY|WOF|RSRAFFLE|RAFFLE|"
                              r"MTXFAIR|MTXFEST|MTXBEACH|MTX15Y|PREM|OMGE|CALENDAR|MONTHLY_DROPS|"
                              r"TG|MM|TWITCH|EVALID|POLLS|POSTBAG|MARKETPLACE",
    "Seasonal & world events": r"EASTER|HALLOWEEN|HW|XMAS|CHRISTMAS|OCT|6AWE|EVENT|HOLIDAY|"
                               r"ANNIVERSARY|SPRING_CLEANER|LOVE|TIMED|BIRTHDAY|CHARITY|APRIL",
    "Music": r"MUSICTRACK|MUSIC|PLAYLIST|CURRENTSONG",
    "Social & clan": r"CLAN|FRIEND|EXCHANGE|GODSS",
    "Account, time & telemetry": r"TELEMETRY|PLAYER|MEMBERSHIP|CLOCK|INTERN|ISLANDS|12_MONTH|"
                                 r"DSF|ATLUM_DAY|BANKPIN",
}
THEME_PATTERNS = {theme: re.compile(f"(?:{pattern})") for theme, pattern in THEMES.items()}

# Fallback for families no THEMES pattern names: tokens in the member names vote.
# A theme that wins at least a quarter of the members is used, marked "(auto)".
THEME_KEYWORDS = {
    "QUEST": "Quests & story", "CUTSCENE": "Quests & story", "MINIQUEST": "Quests & story",
    "BOSS": "Bosses & raids", "KILLS": "Bosses & raids", "KC": "Bosses & raids",
    "MINIGAME": "Minigames", "COSTUME": "Shop, MTX & promotions",
    "OUTFIT": "Shop, MTX & promotions", "OVERRIDE": "Shop, MTX & promotions",
    "PROMO": "Shop, MTX & promotions", "INTERFACE": "Interface & settings",
    "TUTORIAL": "Interface & settings", "XP": "Skilling",
}

# One-line meaning for the biggest families. Plain = clear from the names;
# "GUESS:" = an inference worth checking.
FAMILY_NOTES = {
    "TRH": "Treasure Hunter: one sub-family per promotion (TRH189, TRH132...) holding prize "
           "and progress bits; TRH_* is the core (keys, activity timers).",
    "COMBATV2": "Combat (Evolution of Combat): ability cooldowns, current target, buffs/debuffs, "
                "equipment ratings, action-bar state. Mostly VarClient, so client-side.",
    "TOPLEVEL": "TOPLEVEL_V2: the interface layout (window positions/sizes, locks, edit mode). "
                "Almost all VarClient.",
    "LEAGUE": "Leagues game mode: per-task completion bits (LEAGUE_TASK) and relics.",
    "MUSICTRACK": "One bit per music track: 1 = unlocked.",
    "QUEST": "Per-quest progress for newer quests (QUEST_<NAME>_*). Older quests have their own "
             "families (MAH*, MYQ*, MOURNING, PENG...).",
    "ITEMLOG": "GUESS: the Collection Log / item log: per-item 'obtained' bits, grouped by "
               "source (bosses, slayer).",
    "MTX": "Cosmetic unlocks bought or won (pets, outfits, batch-numbered releases).",
    "ARCH": "Archaeology: artefact restoration, excavation hotspots, research, relic powers, "
            "dig sites (Kharid-et, Infernal Source, Everlight, Warforge...).",
    "CHEEVO": "The Achievements system: per-achievement bits by category, RuneScore, "
              "recommended paths.",
    "ACTIONBAR": "Ability (action) bars: slot contents per bar (ACTIONBAR1, 2, ...).",
    "POH": "Player-owned house: costume room storage (POH_COSTUME), aquarium, ownership.",
    "RAND": "Dungeoneering (Daemonheim): floors completed, hard mode, Bilrach books, party "
            "invites, rewards. GUESS: 'RAND' from 'randomly generated dungeon'.",
    "CONSTRUCTION": "Construction: CONSTRUCTION_HOUSE_* room/hotspot layout, neighbourhoods.",
    "INVENT": "Invention: auto-disassemble lists, perks, materials, machines, tech tree.",
    "CLAN": "Clans: clan camp, citadel, events, admin, permissions.",
    "RUNEPASS": "Rune Pass seasons: free/premium track reward bits.",
    "XMAS": "Christmas events, one sub-family per year.",
    "POF": "Player-owned farm (Manor Farm): animals, beehives, collection, rewards.",
    "CALENDAR": "GUESS: client-side hotfix/event calendar data (CALENDAR_HOTFIX, all VarClient).",
    "WOF": "GUESS: Squeal of Fortune (Treasure Hunter's predecessor) promotions by number.",
    "POP": "Player-owned ports: voyages, crew, ships, regions.",
    "COLLECTION": "Archaeology collections (per collector: Velucia, Sharrigan, Wise Old Man...).",
    "EASTER": "Easter events, one sub-family per year.",
    "QUICKCHAT": "Quick-chat interface state (VarClient).",
    "6AWE": "GUESS: Sixth Age world events (6AWE1-3), votes, rewards.",
    "NECRO": "Necromancy: the hub (City of Um) and rituals.",
    "ELFCITY": "Prifddinas (the elf city): titles, voice of Seren, recipes, clan districts.",
    "EVENT": "Numbered (seasonal) events and per-login event bookkeeping.",
    "BSLAY": "GUESS: boss kill counts and boss-slayer/prestige tracking.",
    "MTXMGT": "Cosmetic management: wardrobe presets, store, unlock bitsets.",
    "PLAYER": "Your own character: inspect panel, kit, title icon, position (PLAYER_COORD).",
    "BP3": "GUESS: a seasonal battle pass (missions per quarter).",
    "GROUP": "Group Ironman: group stats, cooldowns, storage.",
    "DINO": "Anachronia: Big Game Hunter, totems, dinosaur base.",
    "TASK": "Task systems: onboarding tasks (TASK_OMGE, TASK_F4H), tutorial tasks.",
    "LOY": "Loyalty programme: auras, costumes, emotes, recolours.",
    "DUNGEON": "Dungeon (area) progress: Aminishi, Dragonkin fortress, Ulthven, EGWD...",
    "EGWD": "Elder God Wars Dungeon: time warp, per-boss and achievement state.",
    "TRAIL": "Treasure Trails (clue scrolls): loot-beam settings, clue state.",
    "TNS": "GUESS: a three-room puzzle area or quest (TNS_ROOM1-3).",
    "FARMING": "Farming: per-patch state packed into FARMING_VARP_n, compost, tool leprechaun.",
    "HALLOWEEN": "Halloween events by year.",
    "HW": "GUESS: older Halloween events by year (HW06, HW09...).",
    "MOURNING": "Mourning's End quests (light puzzle, temple).",
    "MYQ": "Myreque quest series (MYQ3-7).",
    "MAH": "Mahjarrat quest series.",
    "PENG": "Penguin agent quests (Hunt for Red Raktuber, Back to the Freezer...).",
    "DUEL": "Duel Arena / duelling.",
    "HOUSE": "GUESS: a house-based puzzle or minigame (doors, keys, mastermind), not the POH.",
    "CON": "Construction contracts.",
    "LORE": "Familiar and pet (lore) state: owned pets, special-ability options.",
    "DOM": "Dominion Tower: bosses beaten, achievements, handicaps.",
    "MOB": "GUESS: Mobilising Armies minigame (exchange, spoils, investment).",
    "ISLANDS": "GUESS: a customisable-island feature (custom locs, claimed islands).",
    "OMGE": "GUESS: an onboarding/recommended-task system (intro dialogues, challenges).",
    "DNDTRACKER": "The Distractions & Diversions tracker: minutes to daily reset, days to month "
                  "end, per-D&D timers. Packed into UAUI_DND_TIMER_1-4.",
    "TOOLBELT": "Tools added to the toolbelt (1 bit each).",
    "THIEVING": "Thieving chest/door states.",
    "TELEMETRY": "Client telemetry: current RS-epoch minute, ping, inactivity timeout.",
    "PLAYLIST": "Music playlist slots; 32767 = empty slot.",
    "KEYBIND": "Keybinds for action-bar slots (packed key codes).",
}

# A few vars that say a lot about the character, shown first in the report.
PROFILE_VARS = {
    "QP": "quest points", "QP_TOTAL": "quest points available",
    "QL4_QUESTCOUNT": "quests in the quest list", "CHEEVO_RUNESCORE": "RuneScore",
    "CHEEVO_COMBAT_LEVEL": "combat level", "LIFEPOINTS": "life points",
    "MAXLIFEPOINTS": "max life points", "TUTORIAL": "tutorial progress",
    "TUT_SKIPPED": "tutorial skipped", "MEMBERSHIP_EXPIRY_MINUTES": "membership expiry",
    "PLAYER_COORD": "position", "OPTION_RUN": "run toggle",
}


# --- Loading ------------------------------------------------------------------
def read_jsonl(path):
    """Yield one object per line. A torn last line (the receiver may still be
    appending) is skipped with a warning rather than aborting."""
    with open(path) as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                print(f"{path}:{number}: skipping unparsable line", file=sys.stderr)


def list_snapshots(directory):
    """Complete snapshots in a directory, oldest first. The pattern ends in .jsonl, so the
    receiver's snapshot-*.jsonl.partial files (an upload still running, or abandoned) never match."""
    return sorted(directory.glob("snapshot-*.jsonl"))  # names sort by time


def snapshot_time(path):
    """Unix time a snapshot was taken, from its snapshot-YYYYmmdd-HHMMSS name
    (local time, as the receiver writes it), else the file's mtime."""
    match = re.search(r"(\d{8}-\d{6})", path.name)
    if match:
        return time.mktime(time.strptime(match.group(1), "%Y%m%d-%H%M%S"))
    return path.stat().st_mtime


# --- Per-var helpers ----------------------------------------------------------
def bit_range(mask):
    """(low bit, high bit) of a contiguous VarBit mask, e.g. 56 -> (3, 5)."""
    mask &= 0xFFFFFFFF
    if mask == 0:
        return None
    low = (mask & -mask).bit_length() - 1
    return low, mask.bit_length() - 1


def is_redacted_type(var):
    """True if this var's value could identify another player."""
    if var.get("valueTypeName") in REDACTED_TYPES:
        return True
    return var.get("valueTypeName") == "STRING" and bool(NAME_LIKE.search(var["name"]))


def state_of(var):
    """Classify a var's value: set / default / ambiguous / unreadable / redacted."""
    if "value" not in var:
        return "unreadable"  # an error, or a COMPONENT the API returns nothing for
    value = var["value"]
    if var.get("valueTypeName") == "BOOLEAN":
        return "ambiguous"
    if isinstance(value, dict):
        value = value.get("id")
    if value in DEFAULT_VALUES:
        return "default"
    return "redacted" if is_redacted_type(var) else "set"


def show_value(var):
    """The value as short display text. Redacted vars never show their value."""
    if "value" not in var:
        return f"<{var.get('error', 'no value')}>"
    if var["_state"] == "redacted":
        return "<redacted>"
    value = var["value"]
    if isinstance(value, dict):
        return f"{value.get('config')}#{value.get('id')}"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, str):
        return json.dumps(value)
    return str(value)


def utc_text(unix_seconds):
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(unix_seconds))


def value_hint(var, now):
    """A best-effort reading of a set integer: a game timestamp, or a sentinel.
    `now` is the snapshot's Unix time. Returns "" if nothing fits."""
    value = var.get("value")
    if var["_state"] != "set" or not isinstance(value, int) or isinstance(value, bool):
        return ""
    if value == UNIX_ZERO_IN_RS_MINUTES:
        return "RS-epoch minutes for Unix 0, i.e. never/unset"
    timed = bool(TIME_LIKE.search(var["name"]))
    if timed and abs(value - (now - RS_EPOCH) / 60) < FIVE_YEARS_MIN:
        return f"RS-epoch minutes: {utc_text(RS_EPOCH + value * 60)}"
    if timed and abs(value - now / 60) < FIVE_YEARS_MIN:
        return f"Unix minutes: {utc_text(value * 60)}"
    if timed and abs(value - now) < FIVE_YEARS_MIN * 60:
        return f"Unix seconds: {utc_text(value)}"
    today = (now - RS_EPOCH) // 86400
    if DAY_LIKE.search(var["name"]) and abs(value - today) <= 3650:
        return f"RuneDay {value}: {time.strftime('%Y-%m-%d', time.gmtime(RS_EPOCH + value * 86400))}"
    span = bit_range(var["mask"]) if var.get("isVarBit") else None
    if span and span[1] - span[0] >= 3 and value == (1 << (span[1] - span[0] + 1)) - 1:
        return "all bits set: probably an 'empty' sentinel"
    if value in (32767, 65535, 2147483647):
        return "max value: probably an 'empty' sentinel"
    return ""


def type_label(var):
    """The var's value type name; -1 is the API's UNSUPPORTED type."""
    if var.get("valueTypeName"):
        return var["valueTypeName"]
    return "UNSUPPORTED" if var.get("valueType") == -1 else f"type{var.get('valueType')}"


def name_tokens(name):
    """Split a name into tokens, ignoring a leading underscore (_6AWE1_...)."""
    return name.lstrip("_").split("_")


# --- Family tree --------------------------------------------------------------
def group_path(name):
    """Keys from the top of the tree down. The first is the first token without
    trailing digits, so TRH189, EASTER24 and RAID1 group with TRH, EASTER and RAID;
    then the first token itself, then one more token per level.
    E.g. TRH189_PRIZE_SLOT_1 -> TRH, TRH189, TRH189_PRIZE, TRH189_PRIZE_SLOT."""
    tokens = name_tokens(name)
    stem = re.sub(r"\d+$", "", tokens[0]) or tokens[0]
    return [stem] + ["_".join(tokens[:k]) for k in range(1, len(tokens))]


def build_tree(vars_):
    """Group vars into a prefix tree. A node with more than LEAF_MAX members is split
    by the next key in group_path; sub-groups smaller than MIN_GROUP are folded back
    into the parent ("loose" members), and a level with a single sub-group is skipped."""

    def make(label, members, depth):
        node = {"label": label, "members": members, "children": [], "loose": members}
        if len(members) <= LEAF_MAX or depth > MAX_DEPTH:
            return node
        buckets = defaultdict(list)
        loose = []  # names that end here, or whose sub-group is too small
        for var in members:
            path = var["_path"]
            if depth < len(path):
                buckets[path[depth]].append(var)
            else:
                loose.append(var)
        children = []
        for key, group in buckets.items():
            if len(group) < MIN_GROUP:
                loose.extend(group)
            else:
                children.append((key, group))
        if len(children) == 1 and not loose:
            key, group = children[0]
            return make(key, group, depth + 1)
        node["children"] = sorted((make(k, g, depth + 1) for k, g in children),
                                  key=lambda n: -len(n["members"]))
        node["loose"] = loose
        return node

    stems = defaultdict(list)
    for var in vars_:
        stems[var["_path"][0]].append(var)
    roots = []
    for stem, members in stems.items():
        first_tokens = {name_tokens(v["name"])[0] for v in members}
        if len(first_tokens) == 1:
            # Only one spelling (e.g. COMBATV2): name the family after it, digits and all.
            node = make(first_tokens.pop(), members, 1)
        else:
            # Several spellings (TRH, TRH189...): the star marks the merged stem.
            node = make(stem + "*", members, 1)
        roots.append(node)
    return sorted(roots, key=lambda n: -len(n["members"]))


def walk(nodes, depth=0, parents=()):
    """Yield (depth, node, ancestor labels) for every node, parents before children."""
    for node in nodes:
        yield depth, node, parents
        yield from walk(node["children"], depth + 1, parents + (node["label"],))


def node_stats(members):
    """Counts for a group, using leaf vars only for states (packed base vars are
    summed through their VarBits, so they would double count)."""
    leaves = [v for v in members if not v["_packed"]]
    states = Counter(v["_state"] for v in leaves)
    return {
        "vars": len(members),
        "varbits": sum(1 for v in members if v.get("isVarBit")),
        "varplayer": sum(1 for v in members if v["domain"] == "VarPlayer" and not v.get("isVarBit")),
        "varclient": sum(1 for v in members if v["domain"] == "VarClient"),
        "packed_bases": len(members) - len(leaves),
        "set": states["set"],
        "ambiguous": states["ambiguous"],
        "unreadable": states["unreadable"],
        "redacted": states["redacted"],
        "types": dict(Counter(v.get("valueTypeName") or "?" for v in members).most_common()),
    }


def assign_themes(tree):
    """Give each top-level family a theme: from THEMES, else by keyword vote."""
    for node in tree:
        label = node["label"].rstrip("*")
        stems = (label, re.sub(r"\d+$", "", label))
        node["theme"] = next((t for t, p in THEME_PATTERNS.items()
                              if any(p.fullmatch(s) for s in stems)), None)
        if node["theme"]:
            continue
        votes = Counter()
        for var in node["members"]:
            themes = {THEME_KEYWORDS[t] for t in name_tokens(var["name"])[1:] if t in THEME_KEYWORDS}
            votes.update(themes)
        best = votes.most_common(1)
        if best and best[0][1] * 4 >= len(node["members"]):
            node["theme"] = best[0][0] + " (auto)"
        else:
            node["theme"] = "Other"


# --- Base var -> VarBit tree --------------------------------------------------
def build_basevars(vars_):
    """For each base VarPlayer that has VarBits: its raw value, the VarBits sorted by
    bit, which set bits no VarBit covers, and any overlapping VarBits (aliases)."""
    plain = {v["name"]: v for v in vars_ if v["domain"] == "VarPlayer" and not v.get("isVarBit")}
    bits_of = defaultdict(list)
    for v in vars_:
        if v.get("isVarBit"):
            bits_of[v["baseVar"]].append(v)
    bases = []
    for base_name, bits in bits_of.items():
        base = plain.get(base_name, {})
        raw = base.get("value") if isinstance(base.get("value"), int) else None
        covered, overlaps, fields = 0, [], []
        for bit in sorted(bits, key=lambda b: bit_range(b["mask"]) or (99, 99)):
            mask = bit["mask"] & 0xFFFFFFFF
            if covered & mask:
                overlaps.append(bit["name"])
            covered |= mask
            span = bit_range(mask)
            fields.append({
                "name": bit["name"], "id": bit["id"],
                "low": span[0] if span else None, "high": span[1] if span else None,
                "bits": f"{span[0]}-{span[1]}" if span else "none",
                "width": span[1] - span[0] + 1 if span else 0,
                "value": bit.get("value"), "state": bit["_state"],
            })
        unmapped = (raw & 0xFFFFFFFF) & ~covered if raw is not None else 0
        bases.append({
            "name": base_name, "id": base.get("id"), "family": base.get("_family", ""),
            "value": raw, "hex": f"0x{raw & 0xFFFFFFFF:08x}" if raw is not None else None,
            "bits_used": bin(covered).count("1"), "unmapped_set_bits": f"0x{unmapped:08x}",
            "overlapping": overlaps, "set_fields": sum(f["state"] == "set" for f in fields),
            "varbits": fields,
        })
    return sorted(bases, key=lambda b: b["name"])


def decode_fields(base, old, new):
    """Which VarBits of a packed base var differ between two raw values."""
    moved = []
    for field in base["varbits"]:
        if field["low"] is None:
            continue
        width_mask = (1 << field["width"]) - 1
        before = ((old or 0) & 0xFFFFFFFF) >> field["low"] & width_mask
        after = ((new or 0) & 0xFFFFFFFF) >> field["low"] & width_mask
        if before != after:
            moved.append(field["name"])
    return moved


# --- Change log -----------------------------------------------------------------
def split_sessions(changes):
    """The log spans several plugin enables; seq restarts at each one, and ticks count
    from that enable. Return a list of sessions, each a list of events."""
    sessions, previous = [], None
    for event in changes:
        if previous is None or event["seq"] <= previous:
            sessions.append([])
        sessions[-1].append(event)
        previous = event["seq"]
    return sessions


def classify(values, steps):
    """Name the pattern a var's updates follow. `steps` are the numeric deltas of
    the real changes (empty for non-numbers)."""
    real = sum(1 for a, b in zip(values, values[1:]) if a != b)
    if real == 0:
        return "re-sent, never changed"
    if real == 1:
        return "one-off change"
    if steps and len(steps) == real:
        step, count = Counter(steps).most_common(1)[0]
        if count == real:
            return "countdown" if step < 0 else "count-up / clock"
        # Mostly one steady step with the odd jump back: a timer that resets or wraps.
        if count * 4 >= real * 3:
            return "countdown that resets" if step < 0 else "count-up that wraps/resets"
        # One jump (a timer being started), then a steady step.
        if len(set(steps[1:])) == 1:
            return "set, then counts down" if steps[1] < 0 else "set, then counts up"
    if len({json.dumps(v) for v in values}) == 2:
        return "toggle"
    return "varies"


def summarise_changes(sessions, var_by_key, bases_by_name):
    """Per var: how often it's sent, how often it really changes, how fast, and what
    pattern it follows. Base-var events also list which VarBits moved."""
    per_var = defaultdict(lambda: {"events": [], "sessions": set()})
    for number, session in enumerate(sessions, 1):
        for event in session:
            entry = per_var[(event.get("domain"), event.get("name"))]
            entry["events"].append((number, event))
            entry["sessions"].add(number)

    rows = []
    for (domain, name), entry in per_var.items():
        events = [e for _, e in entry["events"]]
        values = [events[0].get("old")] + [e.get("new") for e in events]
        known = var_by_key.get((domain, name), {})
        redact = known.get("_state") == "redacted" or is_redacted_type(known or {"name": name or ""})
        # Ticks between real changes and the size of each step (ticks restart per session).
        gaps, steps, last_tick = [], [], {}
        for number, e in entry["events"]:
            if e.get("old") == e.get("new"):
                continue
            if number in last_tick:
                gaps.append(e["tick"] - last_tick[number])
            last_tick[number] = e["tick"]
            if isinstance(e.get("new"), int) and isinstance(e.get("old"), int):
                steps.append(e["new"] - e["old"])
        moved = Counter()
        if name in bases_by_name:
            for e in events:
                moved.update(decode_fields(bases_by_name[name], e.get("old"), e.get("new")))
        base = known.get("baseVar", "")
        siblings = len(bases_by_name[base]["varbits"]) - 1 if base in bases_by_name else ""
        rows.append({
            "domain": domain, "name": name, "family": known.get("_family", "?"),
            "type": known.get("valueTypeName", "?"), "varbit_of": base,
            "siblings_in_base": siblings,
            "events": len(events),
            "real_changes": sum(1 for e in events if e.get("old") != e.get("new")),
            "sessions": len(entry["sessions"]),
            "pattern": classify(values, steps),
            "median_ticks_between_changes": round(statistics.median(gaps)) if gaps else "",
            "typical_step": "" if redact or not steps else Counter(steps).most_common(1)[0][0],
            "first": "<redacted>" if redact else json.dumps(values[0]),
            "last": "<redacted>" if redact else json.dumps(values[-1]),
            "varbits_moved": "; ".join(f"{n} x{c}" for n, c in moved.most_common()),
        })
    rows.sort(key=lambda r: (-r["real_changes"], -r["events"], r["name"] or ""))
    return rows


def diff_snapshots(old_vars, new_vars):
    """Vars whose value differs between two snapshots (packed bases flagged)."""
    before = {(v["domain"], v["id"]): v for v in old_vars}
    rows = []
    for var in new_vars:
        old = before.get((var["domain"], var["id"]))
        if old is None or old.get("value") != var.get("value"):
            if old is not None:
                old["_state"] = state_of(old)
            rows.append({
                "domain": var["domain"], "name": var["name"], "family": var["_family"],
                "packed_base": var["_packed"], "varbit_of": var.get("baseVar", ""),
                "old": show_value(old) if old else "<absent>", "new": show_value(var),
            })
    return rows


def silent_changes(diff_rows, sessions, bases_by_name, since, until):
    """Leaf vars that changed between two snapshots without a VarTransmit event naming
    them, while the change log was recording. Returns (rows, events in the window)."""
    window = [e for s in sessions for e in s if since <= e["received"] <= until]
    named = {e.get("name") for e in window}
    reported = {(e.get("domain"), e.get("name")) for e in window}
    rows = [r for r in diff_rows
            if not r["packed_base"] and (r["domain"], r["name"]) not in reported]
    for r in rows:
        # Was the base var, or another VarBit in it, reported in the window?
        base = bases_by_name.get(r["varbit_of"])
        family = {r["varbit_of"]} | ({f["name"] for f in base["varbits"]} if base else set())
        r["base_reported"] = bool(base) and bool(named & family)
    return rows, window


# --- Output -------------------------------------------------------------------
def write_csv(path, rows, fields):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


# Columns of vars.csv and nondefault.csv.
VAR_FIELDS = ["domain", "id", "name", "family", "group", "theme", "type", "varbit",
              "base_var", "bits", "packed_base", "state", "value", "hint"]


def write_families(out, tree):
    """families.csv (one row per tree node), families.json (nested), families-tree.txt."""
    rows, lines = [], []
    for depth, node, parents in walk(tree):
        stats = node_stats(node["members"])
        rows.append({"path": "/".join(parents + (node["label"],)), "depth": depth,
                     "label": node["label"], "theme": node.get("theme", ""), **stats,
                     "types": " ".join(f"{k}:{n}" for k, n in stats["types"].items())})
        types = ", ".join(f"{k} {n}" for k, n in list(stats["types"].items())[:3])
        lines.append(f"{'  ' * depth}{node['label']}  {stats['vars']} vars, {stats['set']} set"
                     f"  [{types}]")
    write_csv(out / "families.csv", rows,
              ["path", "depth", "label", "theme", "vars", "varbits", "varplayer", "varclient",
               "packed_bases", "set", "ambiguous", "unreadable", "redacted", "types"])
    (out / "families-tree.txt").write_text("\n".join(lines) + "\n")

    def as_json(node):
        return {"label": node["label"], **node_stats(node["members"]),
                "children": [as_json(c) for c in node["children"]],
                "loose_members": sorted(v["name"] for v in node["loose"])}
    (out / "families.json").write_text(json.dumps([as_json(n) for n in tree], indent=1))


def write_nondefault_text(path, held):
    """nondefault.txt: the set vars, grouped by family, with VarBit position and hint."""
    text, current = [], None
    for r in held:
        if r["family"] != current:
            current = r["family"]
            note = FAMILY_NOTES.get(current.rstrip("*"), "")
            text.append(f"\n== {current}  ({r['theme']}){': ' + note if note else ''}")
        where = f"  [{r['base_var']} bits {r['bits']}]" if r["varbit"] else ""
        hint = f"  ({r['hint']})" if r["hint"] else ""
        text.append(f"  {r['name']} = {r['value']}{where}{hint}")
    path.write_text("\n".join(text).lstrip() + "\n")


def write_basevars(out, bases):
    """basevars.json, and basevars.txt: each base var with its VarBits by bit position."""
    (out / "basevars.json").write_text(json.dumps(bases, indent=1))
    text = []
    for b in bases:
        flags = []
        if b["unmapped_set_bits"] != "0x00000000":
            flags.append(f"bits set outside any VarBit: {b['unmapped_set_bits']}")
        if b["overlapping"]:
            flags.append(f"overlapping: {', '.join(b['overlapping'])}")
        text.append(f"{b['name']} (id {b['id']}) = {b['value']} {b['hex']}  "
                    f"{len(b['varbits'])} varbits, {b['bits_used']}/32 bits used"
                    + (f"  !! {'; '.join(flags)}" if flags else ""))
        for f in b["varbits"]:
            mark = "*" if f["state"] == "set" else " "
            text.append(f"  {mark} bits {f['bits']:>5}  {f['name']} = {f['value']}")
    (out / "basevars.txt").write_text("\n".join(text) + "\n")


# --- Catalog: what exists, for docs/vars/ (no values) ---------------------------
# Columns of the catalog's vars.csv: everything about a var except its value.
CATALOG_FIELDS = ["domain", "id", "name", "family", "group", "type", "base_var", "bits"]


def structure_stats(members):
    """Counts for a group that don't depend on whose account was dumped."""
    return {
        "vars": len(members),
        "varbits": sum(1 for v in members if v.get("isVarBit")),
        "varclient": sum(1 for v in members if v["domain"] == "VarClient"),
        "types": Counter(type_label(v) for v in members),
    }


def write_catalog(out, snapshot_day, vars_, var_rows, tree, bases):
    """The account-independent reference in docs/vars/: every var's name, id, type,
    family and VarBit layout, but no values (those belong to whoever was logged in;
    dump again to see them). Writes vars.csv, families.txt and README.md."""
    out.mkdir(parents=True, exist_ok=True)
    write_csv(out / "vars.csv", var_rows, CATALOG_FIELDS)

    lines = []
    for depth, node, _ in walk(tree):
        stats = structure_stats(node["members"])
        types = ", ".join(f"{k} {n}" for k, n in stats["types"].most_common(3))
        lines.append(f"{'  ' * depth}{node['label']}  {stats['vars']} vars"
                     f" ({stats['varbits']} VarBits, {stats['varclient']} VarClient)  [{types}]")
    (out / "families.txt").write_text("\n".join(lines) + "\n")

    md = []
    add = md.append
    kind = lambda v: "VarBit" if v.get("isVarBit") else v["domain"]
    by_kind = Counter(kind(v) for v in vars_)
    packed = sum(1 for v in vars_ if v["_packed"])
    types = Counter(type_label(v) for v in vars_)
    add("# Var catalog\n")
    add(f"Every var the plugin API exposes, from a var-dump snapshot taken {snapshot_day}. "
        "This is **what exists**, not anyone's values: names, IDs, types, families and how "
        "VarBits are packed. To see an account's actual state, dump it again with "
        "`plugins/var-dump` and run `scripts/var-dump-analyze.py` (its full output, values "
        "included, goes to the gitignored `dumps/var-dump/analysis/`).\n")
    add("Regenerate this folder: `python3 -I scripts/var-dump-analyze.py --catalog`. "
        "Family meanings come from var names only; **GUESS** marks an inference.\n")
    add("## Looking things up\n")
    add("- `vars.csv`, one row per var: `domain,id,name,family,group,type,base_var,bits`. "
        "`grep -i farming docs/vars/vars.csv` finds a topic. "
        "`grep ',UAUI_DND_TIMER_1,' docs/vars/vars.csv` lists the VarBits packed into a base var.")
    add("- `families.txt`: the family tree (vars grouped by name prefix), with sizes.")
    add("- In Lua: `var.VarPlayer.<NAME>.value` / `var.VarClient.<NAME>.value`, or "
        "`var.<Domain>.FromID(id)`. VarBits are under `var.VarPlayer` and have negative IDs.\n")

    add("## Overview\n")
    add(f"- {len(vars_):,} vars: {by_kind['VarPlayer']:,} plain VarPlayers, "
        f"{by_kind['VarBit']:,} VarBits, {by_kind['VarClient']:,} VarClients.")
    add("- **VarPlayer** is server-side save state (quests, unlocks, settings). **VarClient** is "
        "client-side state (interface layout, cooldowns). A **VarBit** is a bit range inside a "
        f"base VarPlayer; {packed:,} of the plain VarPlayers exist only to hold VarBits.")
    add("- Value types: " + ", ".join(f"{k} {n:,}" for k, n in types.most_common()) + ".")
    add(f"- {len(tree):,} name families; {sum(1 for n in tree if len(n['members']) == 1)} of them "
        "are a single var (mostly quest and area codenames).\n")

    add("## Themes\n")
    add("Families rolled up by topic (THEMES in the script; \"(auto)\" = placed by keywords "
        "in the var names).\n")
    add("| Theme | Families | Vars |")
    add("|---|---:|---:|")
    themes = defaultdict(lambda: [0, 0])
    for node in tree:
        themes[node["theme"]][0] += 1
        themes[node["theme"]][1] += len(node["members"])
    for theme, (fams, count) in sorted(themes.items(), key=lambda kv: -kv[1][1]):
        add(f"| {theme} | {fams} | {count:,} |")
    add("")

    add("## Biggest families\n")
    add("`*` marks a family merging several spellings (TRH, TRH189, ...). Full tree: "
        "`families.txt`.\n")
    add("| Family | Vars | VarBits | VarClient | Main sub-groups | Meaning |")
    add("|---|---:|---:|---:|---|---|")
    for node in tree[:60]:
        stats = structure_stats(node["members"])
        subs = ", ".join(f"{c['label']} {len(c['members'])}" for c in node["children"][:4])
        note = FAMILY_NOTES.get(node["label"].rstrip("*"), "")
        add(f"| `{node['label']}` | {stats['vars']:,} | {stats['varbits']:,} "
            f"| {stats['varclient']:,} | {subs} | {md_cell(note)} |")
    add("")

    add("## Base vars and VarBits\n")
    sizes = [len(b["varbits"]) for b in bases]
    widths = Counter(f["width"] for b in bases for f in b["varbits"])
    overlapping = [b for b in bases if b["overlapping"]]
    add(f"- {len(bases):,} base VarPlayers carry VarBits; median {statistics.median(sizes)} "
        f"VarBits each, max {max(sizes)}. All masks are contiguous, and a VarBit's value is "
        "`(base & mask) >> low bit`.")
    add("- VarBit widths (bits: count): "
        + ", ".join(f"{w}: {n:,}" for w, n in sorted(widths.items())) + ".")
    add(f"- {len(overlapping)} base vars have overlapping VarBits (one field read two ways).\n")

    add("## Reading values: what we've seen\n")
    add("From dumps of one account (2026-10-20); check before relying on them.\n")
    add(f"- {BOOLEAN_NOTE}")
    add(f"- COMPONENT vars ({types.get('COMPONENT', 0)}) return no value through the API. Types "
        "the API can't convert (UNSUPPORTED above) can't be read at all: "
        "reading one logs an [ERROR].")
    add("- Unset is usually 0, -1, empty, the null coordinate `-1,0,0,0,0`, or a config with "
        "id -1. Some vars use an all-bits-set 'empty' marker instead (PLAYLIST_* = 32767).")
    add("- The client only knows vars the server sends it, so 0 can mean \"never sent\".")
    add("- Time encodings: **RS-epoch minutes** (minutes since 2002-02-27 00:00 UTC, e.g. "
        "`*_CURRENT_MINUTE`; -16912800 = unset), **Unix minutes** (`CLOCK_TIME_DATE_MINUTES`), "
        "**RuneDay** (days since 2002-02-27, e.g. `*_RUNEDAY`). `DNDTRACKER_MINS_TO_DAY_END` "
        "counts down to the 00:00 UTC reset.")
    add("- VarTransmit events seem to arrive once per base-var update, named after just one "
        "of its VarBits. See \"Runtime limits we've hit\" in `docs/api-concepts.md`.\n")
    path = out / "README.md"
    path.write_text("\n".join(md) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("snapshot", nargs="?", type=Path)
    parser.add_argument("--changes", type=Path)
    parser.add_argument("--compare", help='older snapshot, or "none"')
    parser.add_argument("--out", type=Path, default=DUMP_DIR / "analysis")
    parser.add_argument("--catalog", type=Path, nargs="?", const=ROOT / "docs/vars",
                        help="also write the value-free catalog (default dir: <repo>/docs/vars)")
    args = parser.parse_args()

    snapshot = args.snapshot
    if snapshot is None:
        found = list_snapshots(DUMP_DIR)
        if not found:
            sys.exit(f"no snapshot-*.jsonl in {DUMP_DIR}; pass a path")
        snapshot = found[-1]
    changes_path = args.changes or snapshot.parent / "changes.jsonl"
    if args.compare == "none":
        compare = None
    elif args.compare:
        compare = Path(args.compare)
    else:
        older = [p for p in list_snapshots(snapshot.parent) if p.name < snapshot.name]
        compare = older[-1] if older else None
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    now = snapshot_time(snapshot)

    # Load and annotate every var with its family path, state and packing.
    vars_ = list(read_jsonl(snapshot))
    base_names = {v["baseVar"] for v in vars_ if v.get("isVarBit")}
    for var in vars_:
        var["_path"] = group_path(var["name"])
        var["_state"] = state_of(var)
        var["_packed"] = (var["domain"] == "VarPlayer" and not var.get("isVarBit")
                          and var["name"] in base_names)
        var["_hint"] = value_hint(var, now)
    print(f"{len(vars_)} vars from {snapshot}")

    # Family tree. Each var's family is its top-level node; its group the deepest one.
    tree = build_tree(vars_)
    assign_themes(tree)
    group_of = {}
    for depth, node, parents in walk(tree):
        for var in node["members"]:
            group_of[id(var)] = node["label"]  # deeper nodes overwrite their parents
            if depth == 0:
                var["_family"], var["_theme"] = node["label"], node["theme"]

    bases = build_basevars(vars_)
    bases_by_name = {b["name"]: b for b in bases}

    # vars.csv: the master table.
    var_rows = []
    for v in vars_:
        span = bit_range(v["mask"]) if v.get("isVarBit") else None
        var_rows.append({
            "domain": v["domain"], "id": v["id"], "name": v["name"], "family": v["_family"],
            "group": group_of[id(v)], "theme": v["_theme"],
            "type": type_label(v),
            "varbit": bool(v.get("isVarBit")), "base_var": v.get("baseVar", ""),
            "bits": f"{span[0]}-{span[1]}" if span else "", "packed_base": v["_packed"],
            "state": v["_state"], "value": show_value(v), "hint": v["_hint"],
        })
    var_rows.sort(key=lambda r: (r["family"], r["group"], r["name"]))
    write_csv(out / "vars.csv", var_rows, VAR_FIELDS)

    write_families(out, tree)
    held = [r for r in var_rows if r["state"] in ("set", "redacted") and not r["packed_base"]]
    write_csv(out / "nondefault.csv", held, VAR_FIELDS)
    write_nondefault_text(out / "nondefault.txt", held)
    write_basevars(out, bases)

    # Change log.
    sessions, change_rows = [], []
    if changes_path.exists():
        var_by_key = {(v["domain"], v["name"]): v for v in vars_}
        sessions = split_sessions(list(read_jsonl(changes_path)))
        change_rows = summarise_changes(sessions, var_by_key, bases_by_name)
        if change_rows:
            write_csv(out / "changes-summary.csv", change_rows, list(change_rows[0]))
        print(f"{sum(map(len, sessions))} change events in {len(sessions)} sessions")

    # Snapshot diff, and changes the change log never reported.
    diff_rows, silent, window = [], [], []
    if compare:
        old_vars = list(read_jsonl(compare))
        diff_rows = diff_snapshots(old_vars, vars_)
        write_csv(out / "snapshot-diff.csv", diff_rows,
                  ["domain", "name", "family", "packed_base", "varbit_of", "old", "new"])
        if sessions:
            silent, window = silent_changes(diff_rows, sessions, bases_by_name,
                                            snapshot_time(compare), now)
        print(f"{len(diff_rows)} vars differ from {compare}")

    # Summary and report.
    leaves = [v for v in vars_ if not v["_packed"]]
    kind = lambda v: "VarBit" if v.get("isVarBit") else v["domain"]
    summary = {
        "snapshot": str(snapshot), "snapshot_time": utc_text(now), "vars": len(vars_),
        "by_domain": dict(Counter(kind(v) for v in vars_)),
        "packed_bases": len(vars_) - len(leaves), "leaf_vars": len(leaves),
        "leaf_states": dict(Counter(v["_state"] for v in leaves)),
        "set_but_sentinel": sum("sentinel" in v["_hint"] for v in leaves),
        "leaf_states_by_domain": {d: dict(Counter(v["_state"] for v in leaves if kind(v) == d))
                                  for d in ("VarPlayer", "VarBit", "VarClient")},
        "types": dict(Counter(v.get("valueTypeName") or "?" for v in vars_).most_common()),
        "families": len(tree),
        "redactable_vars": sum(is_redacted_type(v) for v in vars_),
        "change_sessions": len(sessions), "change_events": sum(map(len, sessions)),
        "compare": str(compare) if compare else None, "snapshot_diff": len(diff_rows),
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    profile = [(n, PROFILE_VARS[n], v) for n in PROFILE_VARS
               for v in vars_ if v["name"] == n and not v["_packed"]]
    write_report(out / "REPORT.md", summary, tree, bases, held, change_rows, sessions,
                 diff_rows, silent, window, profile)
    print(f"wrote {out}/")

    if args.catalog:
        write_catalog(args.catalog, time.strftime("%Y-%m-%d", time.localtime(now)),
                      vars_, var_rows, tree, bases)
        print(f"wrote catalog to {args.catalog}/")


def md_cell(text):
    return str(text).replace("|", "\\|")


def write_report(path, summary, tree, bases, held, change_rows, sessions, diff_rows,
                 silent, window, profile):
    """REPORT.md: the readable overview. Long lists stay in the csv/txt files."""
    md = []
    add = md.append
    leaf = summary["leaf_states"]
    add("# Var dump analysis\n")
    add(f"Snapshot `{summary['snapshot']}` ({summary['snapshot_time']}), generated by "
        "`scripts/var-dump-analyze.py`. Interpretations come from var names only; "
        "**GUESS** marks an inference.\n")

    add("## Overview\n")
    d = summary["by_domain"]
    add(f"- {summary['vars']:,} vars: {d.get('VarPlayer', 0):,} plain VarPlayers, "
        f"{d.get('VarBit', 0):,} VarBits (packed into VarPlayers), {d.get('VarClient', 0):,} VarClients.")
    add(f"- {summary['packed_bases']:,} of the plain VarPlayers only hold VarBits. Their bits are "
        f"counted through the VarBits, leaving {summary['leaf_vars']:,} leaf vars.")
    add(f"- **{leaf.get('set', 0):,} leaf vars ({100 * leaf.get('set', 0) / summary['leaf_vars']:.1f}%) "
        f"hold a non-default value.** {leaf.get('default', 0):,} are default, "
        f"{leaf.get('ambiguous', 0)} are BOOLEAN (ambiguous), {leaf.get('unreadable', 0)} unreadable, "
        f"{leaf.get('redacted', 0)} redacted. {summary['set_but_sentinel']} of the set values look "
        "like 'empty' sentinels (all bits set), so the real count is a little lower.")
    for domain, states in summary["leaf_states_by_domain"].items():
        total = sum(states.values()) or 1
        add(f"  - {domain}: {states.get('set', 0):,} of {total:,} set "
            f"({100 * states.get('set', 0) / total:.1f}%)")
    add(f"- {summary['families']:,} top-level name families. {summary['redactable_vars']} vars "
        "could name other players (PLAYER_UID, name-like STRINGs); their values are never written.")
    add("- Value types: " + ", ".join(f"{k} {n:,}" for k, n in summary["types"].items()) + ".\n")

    if profile:
        add("### Character profile\n")
        add("A few telling vars. This looks like a young character, which is why most families "
            "are all default.\n")
        add("| Var | Meaning | Value | Hint |")
        add("|---|---|---|---|")
        for name, meaning, v in profile:
            add(f"| `{name}` | {meaning} | {md_cell(show_value(v))} | {md_cell(v['_hint'])} |")
        add("")

    add("### Caveats\n")
    add(f"- {BOOLEAN_NOTE}")
    add("- COMPONENT vars return no value through the API, and 9 vars have value types the "
        "plugin can't convert (`unsupported ValueType`).")
    add("- \"Default\" means 0 / -1 / empty / null coordinate / config id -1. A var whose real "
        "default is something else (e.g. PLAYLIST_* at 32767) shows as set; the `hint` column "
        "flags likely sentinels.")
    add("- Default can also mean the server never sent the var. The client only knows the "
        "vars it is sent, so a 0 isn't proof of 'not done'.")
    add("- The snapshot is read over a few seconds, so timer vars may be one step apart.\n")

    # Themes.
    add("## Themes\n")
    add("Families rolled up by topic. The patterns are in THEMES in the script; "
        "\"(auto)\" families were placed by keywords in their var names.\n")
    add("| Theme | Families | Vars | Set |")
    add("|---|---:|---:|---:|")
    themes = defaultdict(lambda: [0, 0, 0])
    for node in tree:
        stats = node_stats(node["members"])
        t = themes[node["theme"]]
        t[0] += 1
        t[1] += stats["vars"]
        t[2] += stats["set"]
    for theme, (fams, count, held_count) in sorted(themes.items(), key=lambda kv: -kv[1][1]):
        add(f"| {theme} | {fams} | {count:,} | {held_count:,} |")
    add("")

    # Biggest families with notes and sub-groups.
    add("## Biggest families\n")
    add("Top families by size. \"Set\" counts leaf vars with a non-default value; `*` marks "
        "a family merging several spellings (TRH, TRH189, ...). Full tree: "
        "`families-tree.txt` / `families.csv`.\n")
    add("| Family | Vars | VarBits | VarClient | Set | Main sub-groups | Meaning |")
    add("|---|---:|---:|---:|---:|---|---|")
    for node in tree[:60]:
        stats = node_stats(node["members"])
        subs = ", ".join(f"{c['label']} {len(c['members'])}" for c in node["children"][:4])
        note = FAMILY_NOTES.get(node["label"].rstrip("*"), "")
        add(f"| `{node['label']}` | {stats['vars']:,} | {stats['varbits']:,} | {stats['varclient']:,} "
            f"| {stats['set']:,} | {subs} | {md_cell(note)} |")
    add("")

    # Where this character's state actually is.
    add("## Where the state is\n")
    add("Families ranked by how many vars hold a non-default value, with examples. "
        "Full list with VarBit positions and hints: `nondefault.txt` / `nondefault.csv`.\n")
    by_family = defaultdict(list)
    for r in held:
        by_family[r["family"]].append(r)
    add("| Family | Set | Examples |")
    add("|---|---:|---|")
    for family, rows in sorted(by_family.items(), key=lambda kv: -len(kv[1]))[:40]:
        examples = "; ".join(f"{r['name']}={r['value']}" for r in rows[:4])
        add(f"| `{family}` | {len(rows)} | {md_cell(examples)} |")
    add("")

    # Time values.
    timed = [r for r in held if r["hint"] and "sentinel" not in r["hint"]]
    if timed:
        add("## Time values\n")
        add("Set integers that read as game timestamps. Encodings seen: **RS-epoch minutes** "
            "(minutes since RuneDate 0, 2002-02-27 00:00 UTC; -16912800 is Unix 0, i.e. unset), "
            "**Unix minutes**, and **RuneDay** (days since 2002-02-27). Matched by magnitude "
            "(and name, for RuneDays), so treat each as a GUESS.\n")
        for r in timed[:30]:
            add(f"- `{r['name']}` = {r['value']}: {r['hint']}")
        add("")

    # Packing.
    add("## Base vars and VarBits\n")
    add(f"{len(bases):,} base VarPlayers carry VarBits. Every VarBit value in the snapshot "
        "equals `(base & mask) >> low bit`, and all masks are contiguous. Full tree: "
        "`basevars.txt` (`*` marks a set VarBit) / `basevars.json`.\n")
    sizes = [len(b["varbits"]) for b in bases]
    add(f"- VarBits per base var: median {statistics.median(sizes)}, max {max(sizes)}; "
        f"{sizes.count(1)} base vars have a single VarBit.")
    widths = Counter(f["width"] for b in bases for f in b["varbits"])
    add("- VarBit widths (bits: count): " + ", ".join(f"{w}: {n:,}" for w, n in sorted(widths.items())) + ".")
    unmapped = [b for b in bases if b["unmapped_set_bits"] != "0x00000000"]
    add(f"- {len(unmapped)} base vars have set bits no VarBit covers (state only readable from "
        "the raw value)" + (": " + ", ".join(f"`{b['name']}` {b['unmapped_set_bits']}"
                                              for b in unmapped[:10]) if unmapped else "") + ".")
    overlapping = [b for b in bases if b["overlapping"]]
    add(f"- {len(overlapping)} base vars have overlapping VarBits (one field read two ways)"
        + (": " + ", ".join(f"`{b['name']}`" for b in overlapping[:10]) if overlapping else "") + ".")
    fullest = sorted(bases, key=lambda b: -b["set_fields"])[:8]
    add("- Most set VarBits: " + ", ".join(f"`{b['name']}` {b['set_fields']}/{len(b['varbits'])}"
                                          for b in fullest) + "\n")

    # Change log.
    if change_rows:
        add("## Change log\n")
        add(f"{summary['change_events']} VarTransmit events over {len(sessions)} plugin sessions "
            "(seq restarts at each enable; ticks count from that enable, ~0.6 s each). "
            "Per-var detail: `changes-summary.csv`.\n")
        for number, session in enumerate(sessions, 1):
            span = session[-1]["received"] - session[0]["received"]
            add(f"- Session {number}: {len(session)} events, ticks {session[0]['tick']}-"
                f"{session[-1]['tick']}, {span / 60:.1f} min of wall time, "
                f"{len({e.get('name') for e in session})} distinct vars.")
        add("")
        add("| Var | Pattern | Events | Changes | Ticks/change | Step | First -> last | VarBit of | VarBits moved |")
        add("|---|---|---:|---:|---:|---:|---|---|---|")
        for r in change_rows[:40]:
            base = f"{r['varbit_of']} (+{r['siblings_in_base']} more)" if r["varbit_of"] else ""
            add(f"| `{r['name']}` | {r['pattern']} | {r['events']} | {r['real_changes']} "
                f"| {r['median_ticks_between_changes']} | {r['typical_step']} "
                f"| {md_cell(r['first'])} -> {md_cell(r['last'])} | {base} | {r['varbits_moved']} |")
        add("")

    if summary["compare"]:
        add("## Difference from the previous snapshot\n")
        add(f"Against `{summary['compare']}`: {len(diff_rows)} vars differ "
            "(`snapshot-diff.csv`).\n")
        for r in diff_rows[:40]:
            tag = " (base var)" if r["packed_base"] else ""
            add(f"- `{r['name']}`{tag}: {md_cell(r['old'])} -> {md_cell(r['new'])}")
        add("")
        if window:
            add("### Changed without a VarTransmit event\n")
            add(f"The change log recorded {len(window)} events between the two snapshots. These "
                "leaf vars changed in that time but no event named them. Where another VarBit "
                "of the same base var was reported, the event most likely covered the whole "
                "base var and named just one VarBit. So when a VarBit's event fires, re-read "
                "its siblings too. (Or the log wasn't running for part of the gap: compare "
                "the session times above.)\n")
            for r in silent:
                if r["domain"] == "VarClient":
                    how = "VarClient, set by the client itself, so no server event is expected"
                elif r["base_reported"]:
                    how = "its base var or a sibling VarBit was reported"
                else:
                    how = "nothing in its base var was reported"
                add(f"- `{r['name']}` ({r['varbit_of'] or 'plain'}): {md_cell(r['old'])} -> "
                    f"{md_cell(r['new'])}; {how}")
            add("")

    add("## Files\n")
    add("- `vars.csv`: every var with family, group, theme, type, VarBit bits, state, value, hint.")
    add("- `families.csv` / `families.json` / `families-tree.txt`: the family tree with counts.")
    add("- `nondefault.csv` / `nondefault.txt`: only vars holding state, grouped by family.")
    add("- `basevars.json` / `basevars.txt`: base var -> VarBit layout with bit ranges.")
    add("- `changes-summary.csv`, `snapshot-diff.csv`, `summary.json`.")
    path.write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
