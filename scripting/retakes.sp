#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#include "include/priorityqueue.inc"
#include "include/queue.inc"
#include "include/restorecvars.inc"
#include "include/retakes.inc"

// The warmup plugin is an optional dependency, see retakes/warmup_link.sp.
#undef REQUIRE_PLUGIN
#include "include/warmup.inc"
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required


/***********************
 *                     *
 *   Global variables  *
 *                     *
 ***********************/

/**
 * The general way players are put on teams is using a system of
 * "round points". Actions during a round earn points, and at the end of the round,
 * players are put into a priority queue using their rounds as the value.
 */
#define POINTS_KILL 50
#define POINTS_DMG 1
#define POINTS_BOMB 50
#define POINTS_LOSS 5000

bool g_Enabled = true;
ArrayList g_SavedCvars;

/** Client variable arrays **/
int g_SpawnIndices[MAXPLAYERS+1];
int g_RoundPoints[MAXPLAYERS+1];
bool g_PluginTeamSwitch[MAXPLAYERS+1];
bool g_GunsHintShown[MAXPLAYERS+1]; // the !guns hint is shown once per connection
int g_Team[MAXPLAYERS+1];

/** Queue Handles **/
ArrayList g_hWaitingQueue;
ArrayList g_hRankingQueue;

/** ConVar handles **/
ConVar g_EnabledCvar;
ConVar g_hAutoTeamsCvar;
ConVar g_hCvarVersion;
ConVar g_hEditorEnabled;
ConVar g_hMaxPlayers;
ConVar g_hRatioConstant;
ConVar g_hRoundsToScramble;
ConVar g_hRoundTime;
ConVar g_hUseRandomTeams;
ConVar g_WarmupTimeCvar;
ConVar g_MessagePrefix;
ConVar g_hBots;
ConVar g_hBotsTotal;
ConVar g_hBotsCarryBomb;
ConVar g_hDebug;

/** Editing global variables **/
bool g_EditMode;
bool g_DirtySpawns; // whether the spawns have been edited since loading from the file

/** Win-streak data **/
bool g_ScrambleSignal;
int g_WinStreak;
int g_RoundCount;

/** Stored info from the spawns config file **/
#define MAX_SPAWNS 256
int g_NumSpawns;
bool g_SpawnDeleted[MAX_SPAWNS];
float g_SpawnPoints[MAX_SPAWNS][3];
float g_SpawnAngles[MAX_SPAWNS][3];
Bombsite g_SpawnSites[MAX_SPAWNS];
int g_SpawnTeams[MAX_SPAWNS];
SpawnType g_SpawnTypes[MAX_SPAWNS];

/** Spawns being edited per-client **/
int g_EditingSpawnTeams[MAXPLAYERS+1];
SpawnType g_EditingSpawnTypes[MAXPLAYERS+1];

/** Bomb-site stuff read from the map **/
ArrayList g_SiteMins;
ArrayList g_SiteMaxs;

/** Data created for the current retake scenario **/
Bombsite g_Bombsite;
bool g_SpawnTaken[MAX_SPAWNS];
char g_PlayerPrimary[MAXPLAYERS+1][WEAPON_STRING_LENGTH];
char g_PlayerSecondary[MAXPLAYERS+1][WEAPON_STRING_LENGTH];
char g_PlayerNades[MAXPLAYERS+1][NADE_STRING_LENGTH];
int g_PlayerHealth[MAXPLAYERS+1];
int g_PlayerArmor[MAXPLAYERS+1];
bool g_PlayerHelmet[MAXPLAYERS+1];
bool g_PlayerKit[MAXPLAYERS+1];

/** Per-round information about the player setup **/
bool g_bombPlanted;
int g_BombOwner = -1;
int g_NumCT;
int g_NumT;
int g_ActivePlayers;

/**
 * Round state. CS:S has no round_prestart event, so a round goes through these steps
 * (all of them live in retakes/round.sp):
 *  1. round_end: the points are counted, g_PreparePending is set;
 *  2. one frame later PrepareNextRound() builds the teams and switches the players, so
 *     that the game respawns them on the right side; g_RoundPrepared is set;
 *  3. round_start (the game has respawned everybody): PlacePlayers() puts the players on
 *     the retake spawns and gives the weapons; g_RoundPrepared is cleared;
 *  4. 0.1 s later FixBomb() hands out the C4.
 * If a round starts without steps 1-2 (first round, mp_restartgame), step 3 runs
 * PrepareNextRound() itself. Players are placed in step 3 only.
 */
bool g_PreparePending; // round_end was seen, PrepareNextRound runs on the next frame
bool g_RoundPrepared;  // the next round is prepared and waits for its round_start
bool g_TeamsValid;     // the plugin assigned the teams of the current/prepared round (false if the map has no spawns)
int g_RoundSerial;     // incremented on every round_start, lets the delayed callbacks detect a new round
bool g_NoSpawnsLogged;
bool g_SiteSpawnsLogged;

/** Forwards **/
Handle g_hOnGunsCommand;
Handle g_hOnPostRoundEnqueue;
Handle g_hOnPreRoundEnqueue;
Handle g_hOnTeamSizesSet;
Handle g_hOnTeamsSet;
Handle g_OnFailToPlant;
Handle g_OnRoundWon;
Handle g_OnSitePicked;
Handle g_OnWeaponsAllocated;

#include "retakes/generic.sp"
#include "retakes/debug.sp"
#include "retakes/roundtime.sp"
#include "retakes/warmup_link.sp"
#include "retakes/teams.sp"
#include "retakes/bots.sp"
#include "retakes/spawns.sp"
#include "retakes/equipment.sp"
#include "retakes/bomb.sp"
#include "retakes/editor_freeplay.sp"
#include "retakes/points.sp"
#include "retakes/round.sp"
#include "retakes/commands.sp"
#include "retakes/editor.sp"
#include "retakes/editor_commands.sp"
#include "retakes/editor_menus.sp"
#include "retakes/validate.sp"
#include "retakes/natives.sp"



/***********************
 *                     *
 * Sourcemod functions *
 *                     *
 ***********************/

public Plugin myinfo = {
    name = "CS:S Retakes",
    author = "splewis, Kolka2",
    description = "Retake practice for Counter-Strike: Source (port of splewis/csgo-retakes)",
    version = PLUGIN_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("retakes.phrases");

    /** ConVars **/
    g_EnabledCvar = CreateConVar("sm_retakes_enabled", "1", "Whether the plugin is enabled");
    g_hAutoTeamsCvar = CreateConVar("sm_retakes_auto_set_teams", "1", "Whether retakes is allowed to automanage team balance");
    g_hEditorEnabled = CreateConVar("sm_retakes_editor_enabled", "1", "Whether the editor can be launched by admins");
    g_hMaxPlayers = CreateConVar("sm_retakes_maxplayers", "9", "Maximum number of players allowed in the game at once.", _, true, 2.0);
    g_hRatioConstant = CreateConVar("sm_retakes_ratio_constant", "0.425", "Ratio constant for team sizes.");
    g_hRoundsToScramble = CreateConVar("sm_retakes_scramble_rounds", "10", "Consecutive terrorist wins to cause a team scramble.");
    g_hRoundTime = CreateConVar("sm_retakes_round_time", "12", "Round time left in seconds.");
    g_hUseRandomTeams = CreateConVar("sm_retakes_random_teams", "0", "If set to 1, this will randomize the teams every round.");
    g_WarmupTimeCvar = CreateConVar("sm_retakes_warmuptime", "25", "Warmup time on map starts, in seconds. Needs the warmup plugin (warmup.smx); 0 or no plugin = no warmup");
    g_MessagePrefix = CreateConVar("sm_retake_message_prefix", "[{GREEN}Retakes{NORMAL}]", "Message prefix used on chat messages.");
    g_hBots = CreateConVar("sm_retakes_bots", "1", "0 = no bots (retakes keeps bot_quota at 0), 1 = fill the game with bots when there are not enough humans", _, true, 0.0, true, 1.0);
    g_hBotsTotal = CreateConVar("sm_retakes_bots_total", "6", "How many participants (humans + bots) to keep when there are fewer humans than this. Capped by sm_retakes_maxplayers.", _, true, 0.0);
    g_hBotsCarryBomb = CreateConVar("sm_retakes_bots_carry_bomb", "1", "Whether a bot can be the bomb carrier. With 0 a bot only gets the bomb if there are no humans on the T team.", _, true, 0.0, true, 1.0);
    g_hDebug = CreateConVar("sm_retakes_debug", "0", "1 = write the plugin's decisions (teams, bomb carrier, bot quota) to logs/retakes_debug.log", _, true, 0.0, true, 1.0);

    g_EnabledCvar.AddChangeHook(EnabledChanged);

    /** Create/Execute retakes cvars **/
    AutoExecConfig(true, "retakes", "sourcemod/retakes");

    g_hCvarVersion = CreateConVar("sm_retakes_version", PLUGIN_VERSION, "Current retakes version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_hCvarVersion.SetString(PLUGIN_VERSION);

    /** Command hooks **/
    AddCommandListener(Command_JoinTeam, "jointeam");
    AddCommandListener(Command_JoinClass, "joinclass");

    /** Admin/editor commands **/
    RegAdminCmd("sm_scramble", Command_ScrambleTeams, ADMFLAG_CHANGEMAP, "Sets teams to scramble on the next round");
    RegAdminCmd("sm_scrambleteams", Command_ScrambleTeams, ADMFLAG_CHANGEMAP, "Sets teams to scramble on the next round");

    RegAdminCmd("sm_edit", Command_EditSpawns, ADMFLAG_CHANGEMAP, "Launches the retakes spawn editor mode");
    RegAdminCmd("sm_spawns", Command_EditSpawns, ADMFLAG_CHANGEMAP, "Launches the retakes spawn editor mode");
    RegAdminCmd("sm_endedit", Command_EndEdit, ADMFLAG_CHANGEMAP, "Leaves the retakes spawn editor mode");

    RegAdminCmd("sm_new", Command_AddSpawn, ADMFLAG_CHANGEMAP, "Creates a new retakes spawn");
    RegAdminCmd("sm_newspawn", Command_AddSpawn, ADMFLAG_CHANGEMAP, "Creates a new retakes spawn");
    RegAdminCmd("sm_delete", Command_DeleteSpawn, ADMFLAG_CHANGEMAP, "Deletes the nearest retakes spawn");
    RegAdminCmd("sm_deletespawn", Command_DeleteSpawn, ADMFLAG_CHANGEMAP, "Deletes the nearest retakes spawn");
    RegAdminCmd("sm_deletemapspawns", Command_DeleteMapSpawns, ADMFLAG_CHANGEMAP, "Deletes all retakes spawns for the current map");

    RegAdminCmd("sm_show", Command_Show, ADMFLAG_CHANGEMAP, "Shows all retakes spawns in a bombsite");
    RegAdminCmd("sm_goto", Command_GotoSpawn, ADMFLAG_CHANGEMAP, "Goes to a retakes spawn");
    RegAdminCmd("sm_nearest", Command_GotoNearestSpawn, ADMFLAG_CHANGEMAP, "Goes to nearest retakes spawn");
    RegAdminCmd("sm_next", Command_NextSpawn, ADMFLAG_CHANGEMAP, "Goes to the next retakes spawn (by number)");
    RegAdminCmd("sm_nextspawn", Command_NextSpawn, ADMFLAG_CHANGEMAP, "Goes to the next retakes spawn (by number)");
    RegAdminCmd("sm_prev", Command_PrevSpawn, ADMFLAG_CHANGEMAP, "Goes to the previous retakes spawn (by number)");
    RegAdminCmd("sm_prevspawn", Command_PrevSpawn, ADMFLAG_CHANGEMAP, "Goes to the previous retakes spawn (by number)");

    RegAdminCmd("sm_iteratespawns", Command_IterateSpawns, ADMFLAG_CHANGEMAP);
    RegAdminCmd("sm_reloadspawns", Command_ReloadSpawns, ADMFLAG_CHANGEMAP, "Reloads retakes spawns for the current map, discarding changes");
    RegAdminCmd("sm_savespawns", Command_SaveSpawns, ADMFLAG_CHANGEMAP, "Saves retakes spawns for the current map");
    RegAdminCmd("sm_retakes_warmup", Command_Warmup, ADMFLAG_CHANGEMAP, "Starts the retakes warmup (sm_retakes_warmup [seconds], 0 ends it) and resets the retakes progress");
    RegAdminCmd("sm_retakes_validatespawns", Command_ValidateSpawns, ADMFLAG_CHANGEMAP, "Checks the retakes spawns of the current map and prints a report");

    /** Player commands **/
    RegConsoleCmd("sm_guns", Command_Guns);

    /** Event hooks **/
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_hurt", Event_DamageDealt);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("bomb_planted", Event_BombPlant);
    HookEvent("bomb_exploded", Event_Bomb);
    HookEvent("bomb_defused", Event_Bomb);
    HookEvent("round_end", Event_RoundEnd);
    HookBombHintMessages();

    g_hOnGunsCommand = CreateGlobalForward("Retakes_OnGunsCommand", ET_Ignore, Param_Cell);
    g_hOnPostRoundEnqueue = CreateGlobalForward("Retakes_OnPostRoundEnqueue", ET_Ignore, Param_Cell, Param_Cell);
    g_hOnPreRoundEnqueue = CreateGlobalForward("Retakes_OnPreRoundEnqueue", ET_Ignore, Param_Cell, Param_Cell);
    g_hOnTeamSizesSet = CreateGlobalForward("Retakes_OnTeamSizesSet", ET_Ignore, Param_CellByRef, Param_CellByRef);
    g_hOnTeamsSet = CreateGlobalForward("Retakes_OnTeamsSet", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
    g_OnFailToPlant = CreateGlobalForward("Retakes_OnFailToPlant", ET_Ignore, Param_Cell);
    g_OnRoundWon = CreateGlobalForward("Retakes_OnRoundWon", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
    g_OnSitePicked = CreateGlobalForward("Retakes_OnSitePicked", ET_Ignore, Param_CellByRef);
    g_OnWeaponsAllocated = CreateGlobalForward("Retakes_OnWeaponsAllocated", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

    g_SiteMins = new ArrayList(3);
    g_SiteMaxs = new ArrayList(3);
    g_hWaitingQueue = Queue_Init();
    g_hRankingQueue = PQ_Init();

    // Set initial spawn types.
    for (int i = 0; i < MAX_SPAWNS; i++) {
        g_SpawnTypes[i] = SpawnType_Normal;
    }

    // Late load: hook the players that are already on the server.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }
}

public void OnPluginEnd() {
    if (g_SavedCvars != null) {
        RestoreCvars(g_SavedCvars, true);
    }
}

public void OnMapStart() {
    PQ_Clear(g_hRankingQueue);
    Queue_Clear(g_hWaitingQueue);
    g_ScrambleSignal = false;
    g_WinStreak = 0;
    g_RoundCount = 0;
    g_PreparePending = false;
    g_RoundPrepared = false;
    g_TeamsValid = false;
    g_NoSpawnsLogged = false;
    g_SiteSpawnsLogged = false;

    g_bombPlanted = false;
    g_BombHandedOut = false;

    FindSites();
    g_NumSpawns = ParseSpawns();
    PrecacheEditorSprites();

    g_EditMode = false;
    CreateTimer(1.0, Timer_ShowSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    if (!g_Enabled)
        return;

    ExecConfigs();

    // Restart warmup for players to connect.
    StartMapWarmup();
}

public void OnMapEnd() {
    // The spawns reach the file only through an explicit save (!savespawns or the editor
    // menu); the original plugin wrote unsaved edits here. They are dropped with the map.
    if (g_DirtySpawns) {
        LogMessage("Unsaved spawn changes were discarded on map change (sm_savespawns saves them)");
    }
}

public void EnabledChanged(Handle cvar, const char[] oldValue, const char[] newValue) {
    bool wasEnabled = !StrEqual(oldValue, "0");
    g_Enabled = !StrEqual(newValue, "0");

    if (wasEnabled && !g_Enabled) {
        if (g_SavedCvars != null)
            RestoreCvars(g_SavedCvars, true);

    } else if (!wasEnabled && g_Enabled) {
        Queue_Clear(g_hWaitingQueue);
        ExecConfigs();
        for (int i = 1; i <= MaxClients; i++)  {
            if (IsClientConnected(i) && !IsFakeClient(i)) {
                OnClientConnected(i);
                if (IsClientInGame(i) && IsOnTeam(i)) {
                    SwitchPlayerTeam(i, CS_TEAM_SPECTATOR);
                    Queue_Enqueue(g_hWaitingQueue, i);
                    FakeClientCommand(i, "jointeam 2");
                }
            }
        }
    }
}

void ExecConfigs() {
    if (g_SavedCvars != null) {
        CloseCvarStorage(g_SavedCvars);
    }
    g_SavedCvars = ExecuteAndSaveCvars("sourcemod/retakes/retakes_game.cfg");
}

public void OnClientConnected(int client) {
    ResetClientVariables(client);
}

public void OnClientPutInServer(int client) {
    SDKHook(client, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
}

public void OnClientDisconnect(int client) {
    ResetClientVariables(client);
    CheckRoundDone(client);
}

public void OnClientDisconnect_Post(int client) {
    // A human left: a bot may take the slot. Every human left: the bots leave as well.
    UpdateBotQuota(false);
}

/**
 * Runs every second for the whole map.
 */
public Action Timer_Second(Handle timer) {
    if (g_Enabled) {
        OnSecondTick();
        Editor_OnSecondTick();
    }
    return Plugin_Continue;
}

/**
 * Helper functions that resets client variables when they join or leave.
 */
void ResetClientVariables(int client) {
    if (client == g_BombOwner)
        g_BombOwner = -1;
    Queue_Drop(g_hWaitingQueue, client);
    g_Team[client] = CS_TEAM_SPECTATOR;
    g_SpawnIndices[client] = -1;
    g_BotLeaving[client] = false;
    g_PluginTeamSwitch[client] = false;
    g_RoundPoints[client] = -POINTS_LOSS;
    g_LastDeathTime[client] = 0.0;
    g_GunsHintShown[client] = false;
    g_EditorCursor[client] = -1;
}
