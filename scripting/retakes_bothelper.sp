#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

// Retakes is an optional dependency: without it the plugin helps the CT bots of any server.
#undef REQUIRE_PLUGIN
#include "include/retakes.inc"
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

/**
 * Retakes bot helper for Counter-Strike: Source.
 *
 * A CT bot learns from the bomb_planted event that the bomb was planted, but not where: it
 * walks from bombsite to bombsite until it gets within 1500 units of the beeping bomb. This
 * plugin gives every living CT bot the position of the bomb the moment the bomb shows up,
 * and the bot's own AI does the rest: it plans the path and goes to defuse.
 *
 * What a bot knows about the bomb is kept in its CSGameState object (CCSBot::m_gameState).
 * The game fills it in with CSGameState::UpdatePlantedBomb(const Vector &). SourceMod 1.12
 * cannot call that function on a 64-bit server (its |this| is "the bot + an offset", and
 * neither an entity call nor a raw call can pass that, see PORT/PROGRESS.md), so the plugin
 * writes the same four fields itself, through the entity of the bot: the bombsite, the
 * position, the "position is known" flag and the bomb state. The offsets come from
 * gamedata/retakes_bothelper.games.txt; before anything is written the current contents of
 * the object are checked, and if they do not look like a CSGameState the plugin writes one
 * error to the log and stops working until it is reloaded.
 */

#define BOTHELPER_VERSION "0.1.0"

#define GAMEDATA_FILE "retakes_bothelper.games"

#define LATE_SPAWN_DELAY 0.1    // seconds between a bot's spawn and telling it about the bomb

#define MAX_ZONES 4             // CCSBotManager::MAX_ZONES
#define SITE_UNKNOWN -1         // CSGameState::UNKNOWN

// CSGameState::BombState
#define BOMB_MOVING 0
#define BOMB_PLANTED 2
#define BOMB_EXPLODED 4

// SetEntData() and GetEntData() refuse offsets above this.
#define MAX_ENT_OFFSET 32768

// Both platforms hand out memory in whole pages, so an object and the pseudo address
// SourceMod makes of it have the same low 12 bits.
#define PAGE_MASK 0xFFF

/** ConVars **/
ConVar g_hEnabled;
ConVar g_hDelay;
ConVar g_hDebug;

/** Environment **/
bool g_LateLoad;
bool g_RetakesLoaded;
bool g_GamedataReady;       // every offset was found, see LoadOffsets
bool g_Broken;              // a bot's game state did not pass the check: nothing is written any more

/** Offsets: g_OffGameState from the bot's entity, the others from the game state **/
int g_OffGameState = -1;
int g_OffRoundOver = -1;
int g_OffBombState = -1;
int g_OffSearchOrder = -1;
int g_OffSiteCount = -1;
int g_OffPlantedSite = -1;
int g_OffPosKnown = -1;
int g_OffPlantedPos = -1;

/** Round state **/
int g_RoundSerial;          // outdates the callbacks scheduled in an earlier round
bool g_BombAnnounced;       // the bomb of this round was already handled (or is about to be)
bool g_BombKnown;           // g_BombPos and g_BombSite are valid and the bots were told
int g_BombRef = INVALID_ENT_REFERENCE;
int g_BombSite = SITE_UNKNOWN;
float g_BombPos[3];

public Plugin myinfo = {
    name = "CS:S Retakes: bot helper",
    author = "retakes-css port",
    description = "Tells the CT bots where the bomb was planted",
    version = BOTHELPER_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "The retakes bot helper only supports Counter-Strike: Source");
        return APLRes_Failure;
    }

    g_LateLoad = late;
    return APLRes_Success;
}

public void OnPluginStart() {
    g_hEnabled = CreateConVar("sm_retakes_bothelper_enabled", "1", "Whether the CT bots are told where the bomb was planted", _, true, 0.0, true, 1.0);
    g_hDelay = CreateConVar("sm_retakes_bothelper_delay", "0.0", "Seconds between the bomb showing up and the CT bots being told where it is", _, true, 0.0);
    g_hDebug = CreateConVar("sm_retakes_bothelper_debug", "0", "1 = write which bots were told, the bomb position and the failed checks to addons/sourcemod/logs/retakes_bothelper_debug.log", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "retakes_bothelper", "sourcemod/retakes");

    CreateConVar("sm_retakes_bothelper_version", BOTHELPER_VERSION, "Current retakes bot helper version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    HookEvent("round_start", Event_RoundStart);
    HookEvent("bomb_planted", Event_BombPlanted);
    HookEvent("player_spawn", Event_PlayerSpawn);

    g_GamedataReady = LoadOffsets();
}

public void OnAllPluginsLoaded() {
    g_RetakesLoaded = LibraryExists("retakes");

    LogMessage("Retakes bot helper %s loaded: gamedata is %s, Retakes is %s",
               BOTHELPER_VERSION,
               g_GamedataReady ? "loaded" : "NOT loaded (the plugin does nothing)",
               g_RetakesLoaded ? "found" : "not found");

    // Late load in the middle of a round: the bomb may already be ticking.
    if (g_LateLoad && FindTickingBomb() != -1) {
        OnBombAppeared("the plugin was loaded late");
    }
}

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "retakes")) {
        g_RetakesLoaded = true;
    }
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "retakes")) {
        g_RetakesLoaded = false;
    }
}

public void OnMapStart() {
    ResetRound();
}

/**
 * Writes a line to logs/retakes_bothelper_debug.log if sm_retakes_bothelper_debug is set.
 */
static void DebugLog(const char[] format, any ...) {
    if (!g_hDebug.BoolValue) {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/retakes_bothelper_debug.log");
    LogToFileEx(path, "%s", buffer);
}

/*************************
 *                       *
 *       Gamedata        *
 *                       *
 *************************/

/**
 * Reads one offset of the gamedata file. Returns false and names the key in |missing| if
 * the file has no such key for this platform.
 */
static bool ReadOffset(GameData conf, const char[] key, int &offset, char[] missing, int maxlength) {
    offset = conf.GetOffset(key);
    if (offset < 0) {
        if (missing[0] == '\0') {
            strcopy(missing, maxlength, key);
        }
        return false;
    }
    return true;
}

/**
 * Loads the offsets. Returns false after one error in the log if the gamedata file is
 * missing, has no entries for this platform or holds offsets the plugin cannot use.
 */
static bool LoadOffsets() {
    // LoadGameConfigFile() raises an error for a missing file, so look first.
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA_FILE);
    if (!FileExists(path)) {
        LogError("The gamedata file addons/sourcemod/gamedata/%s.txt was not found: the bot helper does nothing", GAMEDATA_FILE);
        return false;
    }

    GameData conf = new GameData(GAMEDATA_FILE);
    if (conf == null) {
        LogError("The gamedata file %s.txt could not be read: the bot helper does nothing", GAMEDATA_FILE);
        return false;
    }

    char missing[64];
    bool found = true;
    found &= ReadOffset(conf, "CCSBot::m_gameState", g_OffGameState, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_isRoundOver", g_OffRoundOver, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_bombState", g_OffBombState, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_bombsiteSearchOrder", g_OffSearchOrder, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_bombsiteCount", g_OffSiteCount, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_plantedBombsite", g_OffPlantedSite, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_isPlantedBombPosKnown", g_OffPosKnown, missing, sizeof(missing));
    found &= ReadOffset(conf, "CSGameState::m_plantedBombPos", g_OffPlantedPos, missing, sizeof(missing));
    delete conf;

    if (!found) {
        LogError("The gamedata file %s.txt has no offset \"%s\" for this server (operating system, 32 or 64 bit): the bot helper does nothing", GAMEDATA_FILE, missing);
        return false;
    }

    // The game state follows the fields of the player, and everything the plugin touches
    // has to be within the reach of GetEntData() and SetEntData().
    int inner = g_OffRoundOver | g_OffBombState | g_OffSearchOrder | g_OffSiteCount
              | g_OffPlantedSite | g_OffPosKnown | g_OffPlantedPos;
    if (g_OffGameState < 1024 || inner >= 1024 || g_OffGameState + 1024 > MAX_ENT_OFFSET) {
        LogError("The offsets of the gamedata file %s.txt make no sense (m_gameState %d): the bot helper does nothing", GAMEDATA_FILE, g_OffGameState);
        return false;
    }

    return true;
}

/*************************
 *                       *
 *        Checks         *
 *                       *
 *************************/

/**
 * Returns if the plugin may touch the bots right now: it is switched on, its gamedata fits
 * and, when Retakes runs on this server, Retakes is enabled and neither in its warmup nor
 * in the spawn editor.
 */
static bool IsActive() {
    if (!g_GamedataReady || g_Broken || !g_hEnabled.BoolValue) {
        return false;
    }

    if (g_RetakesLoaded && !Retakes_Live()) {
        return false;
    }

    return true;
}

static bool IsLivingBot(int client, int team) {
    return client > 0 && client <= MaxClients
        && IsClientInGame(client)
        && IsFakeClient(client)
        && !IsClientSourceTV(client)
        && !IsClientReplay(client)
        && GetClientTeam(client) == team
        && IsPlayerAlive(client);
}

/**
 * Returns the planted bomb that is still ticking, or -1.
 */
static int FindTickingBomb() {
    int bomb = -1;
    while ((bomb = FindEntityByClassname(bomb, "planted_c4")) != -1) {
        if (!HasEntProp(bomb, Prop_Send, "m_bBombTicking") || GetEntProp(bomb, Prop_Send, "m_bBombTicking")) {
            return bomb;
        }
    }
    return -1;
}

static void ResetRound() {
    g_RoundSerial++;
    g_BombAnnounced = false;
    g_BombKnown = false;
    g_BombRef = INVALID_ENT_REFERENCE;
    g_BombSite = SITE_UNKNOWN;
}

/*************************
 *                       *
 *     Bomb zones        *
 *                       *
 *************************/

/**
 * Reads the middle of an entity's bounding box in world coordinates.
 */
static bool GetEntityCenter(int entity, float center[3]) {
    float mins[3];
    float maxs[3];
    if (HasEntProp(entity, Prop_Send, "m_vecMins") && HasEntProp(entity, Prop_Send, "m_vecMaxs")) {
        GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
    } else if (HasEntProp(entity, Prop_Data, "m_vecMins") && HasEntProp(entity, Prop_Data, "m_vecMaxs")) {
        GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
    } else {
        return false;
    }

    float origin[3];
    GetEntityOrigin(entity, origin);
    for (int i = 0; i < 3; i++) {
        center[i] = origin[i] + (mins[i] + maxs[i]) / 2.0;
    }
    return true;
}

static void GetEntityOrigin(int entity, float origin[3]) {
    if (HasEntProp(entity, Prop_Send, "m_vecOrigin")) {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    } else if (HasEntProp(entity, Prop_Data, "m_vecOrigin")) {
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
    }
}

/**
 * Returns the index of the bots' zone that is closest to a position, or SITE_UNKNOWN if the
 * map has no zones. |zoneCount| receives the number of zones.
 *
 * This repeats what the game does. CCSBotManager::ExtractScenarioData numbers the zones in
 * the order of the entity indexes (the bomb targets, and the hostage rescue and VIP zones,
 * which a bomb map does not have), at most MAX_ZONES of them; the centre of a brush zone
 * is the middle of its bounding box, that of a legacy point entity is its origin.
 * CCSBotManager::GetClosestZone picks the zone whose centre is the closest in a straight
 * line - that is the bombsite CSGameState::UpdatePlantedBomb stores.
 */
static int FindClosestZone(const float pos[3], int &zoneCount) {
    // CSS-VERIFY: the zones counted this way are the zones of the bots: the count equals
    // m_bombsiteCount of the bots, and a terrorist bot (which is told the bombsite by the
    // game itself) holds the same index - both are compared in the debug log.
    int closest = SITE_UNKNOWN;
    float closestDistance = 0.0;
    zoneCount = 0;

    char classname[64];
    int maxEntities = GetMaxEntities();
    for (int entity = MaxClients + 1; entity < maxEntities && zoneCount < MAX_ZONES; entity++) {
        if (!IsValidEdict(entity) || !GetEdictClassname(entity, classname, sizeof(classname))) {
            continue;
        }

        float center[3];
        if (StrEqual(classname, "func_bomb_target") || StrEqual(classname, "func_hostage_rescue")
            || StrEqual(classname, "func_vip_safetyzone")) {
            if (!GetEntityCenter(entity, center)) {
                GetEntityOrigin(entity, center);
            }
        } else if (StrEqual(classname, "info_bomb_target") || StrEqual(classname, "info_hostage_rescue")) {
            GetEntityOrigin(entity, center);
        } else {
            continue;
        }

        float distance = GetVectorDistance(center, pos, true);
        if (closest == SITE_UNKNOWN || distance < closestDistance) {
            closest = zoneCount;
            closestDistance = distance;
        }
        zoneCount++;
    }

    return closest;
}

/*************************
 *                       *
 *  The bot's game state *
 *                       *
 *************************/

/**
 * Checks that the memory at the game state offset of a bot looks like a CSGameState, so
 * that a gamedata file left over from an older game version is noticed before anything is
 * written. Returns false and describes the failed check in |why|.
 */
static bool CheckGameState(int client, char[] why, int maxlength) {
    int base = g_OffGameState;

    // The first field, m_owner, is a pointer to the bot the game state belongs to.
    int ownerLow = GetEntData(client, base, 4);
    int ownerHigh = GetEntData(client, base + 4, 4);
    if (ownerLow == 0 && ownerHigh == 0) {
        FormatEx(why, maxlength, "m_owner is null");
        return false;
    }

    // CSS-VERIFY: the low 12 bits of m_owner equal those of the address SourceMod reports
    // for the bot (a 64-bit SourceMod gives a "pseudo address": an offset from the start
    // of a memory region, and regions start at a page boundary). If SourceMod cannot make
    // an address of the bot (it returns 0 for some), this check is skipped.
    int address = view_as<int>(GetEntityAddress(client));
    if (address != 0 && (address & PAGE_MASK) != (ownerLow & PAGE_MASK)) {
        FormatEx(why, maxlength, "m_owner (%08X%08X) does not point to the bot (address %08X)", ownerHigh, ownerLow, address);
        return false;
    }

    int roundOver = GetEntData(client, base + g_OffRoundOver, 1);
    int state = GetEntData(client, base + g_OffBombState, 4);
    int siteCount = GetEntData(client, base + g_OffSiteCount, 4);
    int site = GetEntData(client, base + g_OffPlantedSite, 4);
    int posKnown = GetEntData(client, base + g_OffPosKnown, 1);

    if (roundOver != 0 && roundOver != 1) {
        FormatEx(why, maxlength, "m_isRoundOver is %d", roundOver);
        return false;
    }
    if (state < BOMB_MOVING || state > BOMB_EXPLODED) {
        FormatEx(why, maxlength, "m_bombState is %d", state);
        return false;
    }
    if (siteCount < 0 || siteCount > MAX_ZONES) {
        FormatEx(why, maxlength, "m_bombsiteCount is %d", siteCount);
        return false;
    }
    if (site < SITE_UNKNOWN || site >= MAX_ZONES) {
        FormatEx(why, maxlength, "m_plantedBombsite is %d", site);
        return false;
    }
    if (posKnown != 0 && posKnown != 1) {
        FormatEx(why, maxlength, "m_isPlantedBombPosKnown is %d", posKnown);
        return false;
    }

    // The order in which the bot searches the bombsites: every bombsite once.
    int seen = 0;
    for (int i = 0; i < siteCount; i++) {
        int index = GetEntData(client, base + g_OffSearchOrder + 4 * i, 4);
        if (index < 0 || index >= siteCount || (seen & (1 << index)) != 0) {
            FormatEx(why, maxlength, "m_bombsiteSearchOrder[%d] is %d with %d bombsite(s)", i, index, siteCount);
            return false;
        }
        seen |= 1 << index;
    }

    return true;
}

/**
 * A bot's game state failed the check: one error in the log, and the plugin writes nothing
 * until it is reloaded.
 */
static void GiveUp(int client, const char[] why) {
    g_Broken = true;
    LogError("The game state of %L does not look right (%s): the gamedata file %s.txt does not fit this game version, or the bot is not a bot of the game. The bot helper does nothing until it is reloaded.",
             client, why, GAMEDATA_FILE);
    DebugLog("check failed for %L: %s; the plugin has switched itself off", client, why);
}

/**
 * Gives a CT bot the position of the planted bomb: the same four writes as
 * CSGameState::UpdatePlantedBomb. Returns if the bot was told.
 */
static bool TellBot(int client) {
    if (g_Broken) {
        return false;
    }

    char why[128];
    if (!CheckGameState(client, why, sizeof(why))) {
        GiveUp(client, why);
        return false;
    }

    int base = g_OffGameState;
    int state = GetEntData(client, base + g_OffBombState, 4);
    int siteCount = GetEntData(client, base + g_OffSiteCount, 4);

    if (state > BOMB_PLANTED) {
        DebugLog("%L thinks the bomb was defused or has exploded (state %d): left alone", client, state);
        return false;
    }
    if (state == BOMB_PLANTED && GetEntData(client, base + g_OffPosKnown, 1) != 0) {
        DebugLog("%L already knows where the bomb is (bombsite %d)", client, GetEntData(client, base + g_OffPlantedSite, 4));
        return false;
    }

    // A bombsite the bot has never heard of would be worse than none.
    int site = g_BombSite;
    if (site >= siteCount) {
        DebugLog("%L knows %d bombsite(s), the bomb is at zone %d: the bombsite is left unknown", client, siteCount, site);
        site = SITE_UNKNOWN;
    }

    // CSS-VERIFY: with these fields set a CT bot stops checking the bombsites and goes to
    // the bomb: a bot on its way to a bombsite returns to its idle state on its next
    // update and picks the "defuse the bomb" task with a path to the bomb position.
    SetEntData(client, base + g_OffPlantedSite, site, 4);
    SetEntDataVector(client, base + g_OffPlantedPos, g_BombPos);
    SetEntData(client, base + g_OffPosKnown, 1, 1);
    if (state != BOMB_PLANTED) {
        SetEntData(client, base + g_OffBombState, BOMB_PLANTED, 4);
    }

    DebugLog("told %L: bombsite %d, position %.1f %.1f %.1f (the bot knew: state %d, %d bombsite(s))",
             client, site, g_BombPos[0], g_BombPos[1], g_BombPos[2], state, siteCount);
    return true;
}

/**
 * Debug only: a terrorist bot is told the bombsite by the game itself, so its game state
 * shows whether the offsets and the zone numbering of the plugin match the game.
 */
static void LogTerroristBots() {
    if (!g_hDebug.BoolValue) {
        return;
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsLivingBot(i, CS_TEAM_T)) {
            continue;
        }

        char why[128];
        if (!CheckGameState(i, why, sizeof(why))) {
            DebugLog("terrorist bot %L: the check failed (%s)", i, why);
            continue;
        }

        int base = g_OffGameState;
        float pos[3];
        GetEntDataVector(i, base + g_OffPlantedPos, pos);
        int site = GetEntData(i, base + g_OffPlantedSite, 4);
        DebugLog("terrorist bot %L knows from the game: state %d, bombsite %d (the plugin: %d)%s, position known %d, %.1f %.1f %.1f",
                 i, GetEntData(i, base + g_OffBombState, 4), site, g_BombSite,
                 site == g_BombSite ? "" : " - MISMATCH",
                 GetEntData(i, base + g_OffPosKnown, 1), pos[0], pos[1], pos[2]);
    }
}

/*************************
 *                       *
 *   When the bomb shows *
 *                       *
 *************************/

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    ResetRound();
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast) {
    OnBombAppeared("bomb_planted event");
}

public void OnEntityCreated(int entity, const char[] classname) {
    // A plugin may put a planted bomb on the map without the bomb_planted event. Whatever
    // comes first starts the work, once per round.
    if (StrEqual(classname, "planted_c4")) {
        SDKHook(entity, SDKHook_SpawnPost, Hook_BombSpawnPost);
    }
}

public void Hook_BombSpawnPost(int entity) {
    OnBombAppeared("planted_c4 entity spawned");
}

/**
 * Called by every sign of a planted bomb. Only the first one in a round counts; the bots
 * are told on the next frame or after sm_retakes_bothelper_delay.
 */
static void OnBombAppeared(const char[] source) {
    if (g_BombAnnounced) {
        return;
    }
    g_BombAnnounced = true;

    if (!IsActive()) {
        DebugLog("bomb: %s, but the plugin is not active (switched off, no gamedata, or Retakes is off / in warmup / in edit mode)", source);
        return;
    }

    float delay = g_hDelay.FloatValue;
    DebugLog("bomb: %s, telling the CT bots in %.1f s", source, delay);

    if (delay > 0.0) {
        CreateTimer(delay, Timer_TellBots, g_RoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    } else {
        // Not right away: the spawn hook of the entity may run before the game has moved
        // the bomb to its place.
        RequestFrame(Frame_TellBots, g_RoundSerial);
    }
}

public Action Timer_TellBots(Handle timer, int serial) {
    Frame_TellBots(serial);
    return Plugin_Stop;
}

public void Frame_TellBots(int serial) {
    if (serial != g_RoundSerial || !IsActive()) {
        return;
    }

    // CSS-VERIFY: a frame after the bomb_planted event (or after the planted_c4 spawn hook)
    // the entity exists and m_vecOrigin holds the place where the bomb lies.
    int bomb = FindTickingBomb();
    if (bomb == -1) {
        DebugLog("bomb: no ticking planted_c4 entity found, nothing to tell");
        return;
    }

    GetEntityOrigin(bomb, g_BombPos);
    g_BombRef = EntIndexToEntRef(bomb);

    int zoneCount;
    g_BombSite = FindClosestZone(g_BombPos, zoneCount);
    g_BombKnown = true;

    DebugLog("bomb: entity %d at %.1f %.1f %.1f, zone %d of %d",
             bomb, g_BombPos[0], g_BombPos[1], g_BombPos[2], g_BombSite, zoneCount);
    LogTerroristBots();

    int told = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsLivingBot(i, CS_TEAM_CT) && TellBot(i)) {
            told++;
        }
    }
    DebugLog("bomb: told %d CT bot(s)", told);
}

/**
 * A CT bot that spawns while the bomb is already planted (a late join) is told as well.
 */
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (!g_BombKnown) {
        return;
    }

    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsFakeClient(client)) {
        // The game resets what a bot knows when it spawns; wait until that is over.
        DataPack pack;
        CreateDataTimer(LATE_SPAWN_DELAY, Timer_TellLateBot, pack, TIMER_FLAG_NO_MAPCHANGE);
        pack.WriteCell(g_RoundSerial);
        pack.WriteCell(userid);
    }
}

public Action Timer_TellLateBot(Handle timer, DataPack pack) {
    pack.Reset();
    int serial = pack.ReadCell();
    int client = GetClientOfUserId(pack.ReadCell());

    if (serial != g_RoundSerial || !g_BombKnown || !IsActive() || !IsLivingBot(client, CS_TEAM_CT)) {
        return Plugin_Stop;
    }

    // The bomb of this round may be gone or defused by now.
    int bomb = EntRefToEntIndex(g_BombRef);
    if (bomb == INVALID_ENT_REFERENCE || bomb != FindTickingBomb()) {
        return Plugin_Stop;
    }

    DebugLog("late spawn: %L", client);
    TellBot(client);
    return Plugin_Stop;
}
