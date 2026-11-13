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
 * Round state. CS:S has no round_prestart event, so a round goes through these steps:
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
#include "retakes/teams.sp"
#include "retakes/roundtime.sp"
#include "retakes/warmup_link.sp"
#include "retakes/editor_freeplay.sp"
#include "retakes/bots.sp"
#include "retakes/editor.sp"
#include "retakes/editor_commands.sp"
#include "retakes/editor_menus.sp"
#include "retakes/natives.sp"
#include "retakes/spawns.sp"
#include "retakes/validate.sp"



/***********************
 *                     *
 * Sourcemod functions *
 *                     *
 ***********************/

public Plugin myinfo = {
    name = "CS:S Retakes",
    author = "splewis",
    description = "Retake practice for Counter-Strike: Source (port of splewis/csgo-retakes)",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
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

    // Set inital spawn types.
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
    if (!g_Enabled) {
        return;
    }

    if (g_DirtySpawns) {
        WriteSpawns();
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

public void ExecConfigs() {
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
    // ушёл человек - его место может занять бот; ушли все люди - боты тоже уходят
    UpdateBotQuota(false);
}

/**
 * Blocks every purchase while the game is live: retakes hands out the equipment itself.
 * Buying stays available in the warmup (and in the spawn editor).
 */
public Action CS_OnBuyCommand(int client, const char[] weapon) {
    if (!g_Enabled || InFreePlay()) {
        return Plugin_Continue;
    }

    // Проверено на сервере CS:S (11.11.2026): покупка отменяется и через меню, и через команду buy.
    // Поэтому награды за убийства и раунды не обнуляются: они копятся до начала следующего
    // раунда (там их сбрасывает GiveWeapons), но потратить их не на что.
    return Plugin_Handled;
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
 * Called once a second while the plugin is enabled.
 */
public void OnSecondTick() {
    UpdateBotQuota(false);

    if (InFreePlay() || InIntermission() || !g_TeamsValid || g_hAutoTeamsCvar.IntValue == 0) {
        return;
    }

    // В раунде меньше двух участников, а дополнить его есть кем (человек зашёл между раундами,
    // игра только что добавила ботов): не ждём конца раунда, начинаем следующий.
    bool humansWaiting = !Queue_IsEmpty(g_hWaitingQueue);
    bool botsWaiting = GetUnassignedBotCount() > 0 && g_ActivePlayers < GetBotsFillTarget();
    if (g_ActivePlayers < 2 && (humansWaiting || botsWaiting)) {
        DebugLog("round: only %d active player(s) while others are waiting, restarting the round", g_ActivePlayers);
        CS_TerminateRound(1.0, CSRoundEnd_Draw);
    }

    // Раунд из двух и более участников не трогаем, даже если часть ботов ждёт в наблюдателях:
    // игра добавляет ботов по одному, и после выхода из редактора или входа на пустой сервер
    // первый раунд может пройти 1 на 1. Это известное и принятое поведение (см. PORT/PROGRESS.md).
}

/**
 * Helper functions that resets client variables when they join or leave.
 */
public void ResetClientVariables(int client) {
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

public Action Command_ScrambleTeams(int client, int args) {
    if (g_Enabled) {
        g_ScrambleSignal = true;
        Retakes_MessageToAll("%t", "AdminScrambleTeams", client);
    }

    return Plugin_Continue;
}

/**
 * Tells a player about the !guns menu. Shown once per connection, when the player first
 * gets into the game (first spawn or the waiting queue), and only if a weapon allocator
 * is loaded: without one the command does nothing.
 * Этой подсказки нет в оригинальном плагине, добавлена по решению владельца.
 */
void ShowGunsHint(int client) {
    if (g_GunsHintShown[client] || !IsPlayer(client) || g_EditMode) {
        return;
    }
    g_GunsHintShown[client] = true;

    // Аллокатор загружен, если кто-то подписан на форвард Retakes_OnGunsCommand.
    if (GetForwardFunctionCount(g_hOnGunsCommand) == 0) {
        return;
    }

    if (TranslationPhraseExists("GunsHint")) {
        Retakes_Message(client, "%t", "GunsHint");
    } else {
        Retakes_Message(client, "Type {GREEN}!guns{NORMAL} in chat to choose your weapons.");
    }
}

public Action Command_Guns(int client, int args) {
    if (g_Enabled) {
        Call_StartForward(g_hOnGunsCommand);
        Call_PushCell(client);
        Call_Finish();
    }
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] args) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    static char gunsChatCommands[][] = { "gun", "guns", ".gun", ".guns", "!gun", "gnus" };
    for (int i = 0; i < sizeof(gunsChatCommands); i++) {
        if (strcmp(args[0], gunsChatCommands[i], false) == 0) {
            Call_StartForward(g_hOnGunsCommand);
            Call_PushCell(client);
            Call_Finish();
            break;
        }
    }

    return Plugin_Continue;
}


/***********************
 *                     *
 *    Command Hooks    *
 *                     *
 ***********************/

public Action Command_JoinTeam(int client, const char[] command, int argc) {
    if (!g_Enabled || g_hAutoTeamsCvar.IntValue == 0) {
        return Plugin_Continue;
    }

    if (!IsValidClient(client) || argc < 1)
        return Plugin_Handled;

    if (g_EditMode) {
        MovePlayerToEditMode(client);
        return Plugin_Handled;
    }

    // During the warmup the teams are not ours to manage: the game and the warmup plugin
    // handle joining and switching sides.
    if (Retakes_InWarmup()) {
        return Plugin_Continue;
    }

    char arg[4];
    GetCmdArg(1, arg, sizeof(arg));
    int team_to = StringToInt(arg);
    int team_from = GetClientTeam(client);

    if (g_PluginTeamSwitch[client] || IsFakeClient(client)) {
        return Plugin_Continue;
    }

    // note if a player hits autoselect their team_from=team_to=CS_TEAM_NONE
    if (team_from == team_to && team_from != CS_TEAM_NONE) {
        // Picking your own team again opens the model menu in CS:S, and changing the model
        // mid-round kills the player. Not allowed: T/CT can only be left for spectators.
        if (IsOnTeam(client)) {
            return Plugin_Handled;
        }
        return Plugin_Continue;
    } else {
        if (   (team_from == CS_TEAM_CT && team_to == CS_TEAM_T )
            || (team_from == CS_TEAM_T  && team_to == CS_TEAM_CT)) {
            // the plugin decides who plays on which side
            return Plugin_Handled;

        } else if (team_to == CS_TEAM_SPECTATOR) {
            // voluntarily joining spectator will not put you in the queue
            SwitchPlayerTeam(client, CS_TEAM_SPECTATOR);
            Queue_Drop(g_hWaitingQueue, client);

            // check if a team is now empty
            CheckRoundDone();

            return Plugin_Handled;
        } else {
            return PlacePlayer(client);
        }
    }
}

/**
 * Blocks changing the player model (class) while the game is live: in CS:S it kills the
 * player. The plugin sets the class itself when it puts a player on a team, so nobody
 * needs the class menu outside of the warmup and the editor.
 */
public Action Command_JoinClass(int client, const char[] command, int argc) {
    if (!g_Enabled || g_hAutoTeamsCvar.IntValue == 0 || InFreePlay()) {
        return Plugin_Continue;
    }

    if (!IsValidClient(client) || IsFakeClient(client)) {
        return Plugin_Continue;
    }

    // Игрок без модели (такого быть не должно) всё же должен иметь возможность её выбрать.
    if (IsOnTeam(client) && HasPickedClass(client)) {
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

/**
 * Generic logic for placing a player into the correct team when they join.
 */
public Action PlacePlayer(int client) {
    int tHumanCount=0, ctHumanCount=0, nPlayers=0;
    GetTeamsClientCounts(tHumanCount, ctHumanCount);
    nPlayers = tHumanCount + ctHumanCount;

    if (nPlayers < 2) {
        ChangeClientTeam(client, CS_TEAM_SPECTATOR);
        Queue_Enqueue(g_hWaitingQueue, client);
        DebugLog("join: %L placed in the waiting queue, fewer than 2 players on teams - restarting the round", client);
        // Между раундами следующий раунд уже подготовлен без этого игрока:
        // его подхватит проверка в OnSecondTick.
        UpdateBotQuota(false);
        if (!InIntermission()) {
            CS_TerminateRound(0.0, CSRoundEnd_CTWin);
        }
        return Plugin_Handled;
    }

    ChangeClientTeam(client, CS_TEAM_SPECTATOR);
    Queue_Enqueue(g_hWaitingQueue, client);
    DebugLog("join: %L placed in the waiting queue (%d on teams)", client, nPlayers);
    Retakes_Message(client, "%t", "JoinedQueueMessage");
    ShowGunsHint(client);
    return Plugin_Handled;
}



/***********************
 *                     *
 *     Event Hooks     *
 *                     *
 ***********************/

/**
 * Called when a player joins a team, silences team join events
 */
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)  {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    // The original plugin only set "silent" here. The CS:S client ignores that field and
    // prints "<player> is joining the ... force" for every switch (checked on a live server:
    // the chat filled up on every round), so the event is also kept from the clients.
    // Server-side listeners (other plugins) still receive it.
    // CSS-VERIFY: with player_team not broadcast, the scoreboard, the team counters and the
    // spectator UI still show the right teams (they are driven by networked properties).
    SetEventBool(event, "silent", true);
    event.BroadcastDisabled = true;
    return Plugin_Changed;
}

/**
 * Called when a player spawns. The players of a round are placed by PlacePlayers() at
 * round_start, not here: a spawn in the middle of a round never moves or re-equips anybody.
 */
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || !IsOnTeam(client))
        return Plugin_Continue;

    // In CS:S player_spawn also fires when a player joins the server and is still dead.
    if (!IsPlayerAlive(client))
        return Plugin_Continue;

    ShowGunsHint(client);

    // Nothing to do in the warmup (the warmup plugin owns it) or in the editor.
    if (InFreePlay()) {
        return Plugin_Continue;
    }

    // No slot in this round: a bot the game added in the middle of a round.
    if (g_TeamsValid && !IsAssigned(client) && g_hAutoTeamsCvar.IntValue != 0) {
        RequestFrame(Frame_MoveUnassignedToSpectator, GetClientUserId(client));
    }

    return Plugin_Continue;
}

/**
 * Returns if the plugin put the client on a team for the current round.
 */
bool IsAssigned(int client) {
    return g_Team[client] == CS_TEAM_T || g_Team[client] == CS_TEAM_CT;
}

/**
 * Puts everybody that plays the round on a retake spawn and gives the weapons.
 * Called once per round, from round_start, when the game has respawned the players.
 */
static void PlacePlayers() {
    // Somebody who left the team after the round was prepared (went to spectators)
    // does not play it.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsAssigned(i) && (!IsParticipant(i) || GetClientTeam(i) != g_Team[i])) {
            g_Team[i] = CS_TEAM_SPECTATOR;
        }
    }

    // The bomb carrier picks first: there are fewer spawns that suit it.
    if (IsParticipant(g_BombOwner) && IsAssigned(g_BombOwner)) {
        g_SpawnIndices[g_BombOwner] = SelectSpawn(CS_TEAM_T, true);
    }
    for (int i = 1; i <= MaxClients; i++) {
        if (i != g_BombOwner && IsAssigned(i)) {
            g_SpawnIndices[i] = SelectSpawn(g_Team[i], false);
        }
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsAssigned(i)) {
            continue;
        }

        // The game respawns everybody on a team at round restart, including the players
        // the plugin moved in from spectators (seen on a live server). This is a safety net.
        if (!IsPlayerAlive(i)) {
            DebugLog("round_start: %L was not spawned by the game, respawning", i);
            CS_RespawnPlayer(i);
        }
        if (IsPlayerAlive(i)) {
            SetupPlayer(i);
        }
    }
}

/**
 * Called when a player dies - gives points to killer, and does database stuff with the kill.
 */
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim > 0) {
        // для респауна в разминке/редакторе, см. warmup.sp
        g_LastDeathTime[victim] = GetGameTime();
    }

    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    bool validAttacker = IsValidClient(attacker);
    bool validVictim = IsValidClient(victim);

    if (DebugEnabled() && validVictim) {
        if (validAttacker) {
            DebugLog("kill: %N (team %d) killed %N (team %d)%s", attacker, GetClientTeam(attacker),
                     victim, GetClientTeam(victim), InIntermission() ? ", between rounds" : "");
        } else {
            DebugLog("kill: %N (team %d) died%s", victim, GetClientTeam(victim),
                     InIntermission() ? ", between rounds" : "");
        }
    }

    if (validAttacker && validVictim) {
        if (HelpfulAttack(attacker, victim)) {
            g_RoundPoints[attacker] += POINTS_KILL;
        } else {
            g_RoundPoints[attacker] -= POINTS_KILL;
        }
    }

    return Plugin_Continue;
}

/**
 * Called when a player deals damage to another player - ads round points if needed.
 */
public Action Event_DamageDealt(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));
    bool validAttacker = IsValidClient(attacker);
    bool validVictim = IsValidClient(victim);

    if (validAttacker && validVictim && HelpfulAttack(attacker, victim) ) {
        int damage = event.GetInt("dmg_health");
        g_RoundPoints[attacker] += (damage * POINTS_DMG);
    }
    return Plugin_Continue;
}

/**
 * Called when the bomb explodes or is defuser, gives ponts to the one that planted/defused it.
 */
public Action Event_BombPlant(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    g_bombPlanted = true;

    return Plugin_Continue;
}

/**
 * Called when the bomb explodes or is defused, gives ponts to the one that planted/defused it.
 */
public Action Event_Bomb(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        g_RoundPoints[client] += POINTS_BOMB;
    }

    return Plugin_Continue;
}

/**
 * Sets up everything for the next round: the ranking queue, the teams, the bombsite and
 * the bomb carrier. This is what round_prestart did in CS:GO; CS:S has no such event, so:
 *  - normally this runs one frame after round_end (see Event_RoundEnd), i.e. before the
 *    game restarts the round and respawns the players in their new teams;
 *  - if a round starts without it (first round, mp_restartgame), Event_RoundStart runs it.
 * It never runs twice for the same round, and it does not move or equip anybody:
 * that is PlacePlayers().
 */
public void PrepareNextRound() {
    g_PreparePending = false;
    g_RoundPrepared = true;
    g_TeamsValid = false;
    g_BombOwner = -1;
    g_BombHandedOut = false;

    for (int i = 1; i <= MaxClients; i++) {
        g_SpawnIndices[i] = -1;
        g_Team[i] = CS_TEAM_SPECTATOR;
    }

    // Сначала число ботов: если людей стало больше, лишние боты уходят до расстановки команд.
    UpdateBotQuota(true);
    RoundEndUpdates();
    UpdateTeams();
    g_BombOwner = PickBombOwner();
    DebugLogPreparedRound();
}

/**
 * Writes the outcome of PrepareNextRound to the debug log.
 */
static void DebugLogPreparedRound() {
    if (!DebugEnabled()) {
        return;
    }

    if (!g_TeamsValid) {
        DebugLog("prepare: teams were NOT set (spawns on the map: %d, sm_retakes_maxplayers: %d)",
                 g_NumSpawns, g_hMaxPlayers.IntValue);
        return;
    }

    DebugLog("prepare: site %s, %d T vs %d CT (active players: %d), waiting queue: %d",
             SITESTRING(g_Bombsite), g_NumT, g_NumCT, g_ActivePlayers, Queue_Length(g_hWaitingQueue));
    for (int i = 1; i <= MaxClients; i++) {
        if (IsParticipant(i) && IsAssigned(i)) {
            DebugLog("prepare:   %s %L, points %d%s", TEAMSTRING(g_Team[i]), i, g_RoundPoints[i],
                     (i == g_BombOwner) ? ", BOMB CARRIER" : "");
        }
    }
}

/**
 * Returns if a round has ended and the next one has not started yet.
 */
bool InIntermission() {
    return g_PreparePending || g_RoundPrepared;
}

public void Frame_PrepareNextRound(any serial) {
    // Если за этот кадр раунд уже успел начаться (или сменилась карта), подготовку сделал/сделает Event_RoundStart.
    if (!g_PreparePending || serial != g_RoundSerial || !Retakes_Live()) {
        g_PreparePending = false;
        return;
    }

    // CSS-VERIFY: CS_SwitchTeam живого игрока между round_end и рестартом раунда не убивает его,
    // а при рестарте все появляются уже в новых командах (и на спавнах ретейка).
    PrepareNextRound();
}

/**
 * Round start. In CS:S the players have already been respawned when this event fires.
 */
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_RoundSerial++;
    g_bombPlanted = false;

    if (!g_Enabled) {
        return Plugin_Continue;
    }

    if (InFreePlay()) {
        if (g_EditMode) {
            Editor_KeepRoundEndless();
        }
        return Plugin_Continue;
    }

    // A round_end handled in this very frame has not been prepared yet, and never will be.
    g_PreparePending = false;

    if (g_RoundPrepared) {
        DebugLog("round_start: using the teams prepared after round_end");
    } else {
        // First round after the warmup or the editor, mp_restartgame: there was no round_end.
        DebugLog("round_start: the round was not prepared after round_end, preparing now");
        PrepareNextRound();
    }
    g_RoundPrepared = false;

    for (int i = 1; i <= MaxClients; i++) {
        g_RoundPoints[i] = 0;
    }

    if (!g_TeamsValid) {
        // No retake this round (the map has no spawns): FixBomb() will not run, so the
        // game's own bomb must stay usable.
        g_BombHandedOut = true;
        return Plugin_Continue;
    }

    // CSS-VERIFY: teleporting and re-equipping the players inside the round_start handler
    // works like it did in player_spawn: everybody starts on the retake spawn with the
    // right weapons, and a player whose team was switched right here (unprepared round)
    // needs no respawn.
    PlacePlayers();

    // CSS-VERIFY: when m_iRoundTime runs out with no bomb planted the CTs win (Target Saved),
    // and once the bomb is planted this timer no longer ends the round.
    SetRoundTime(g_hRoundTime.IntValue);
    Retakes_MessageToAll("%t", "RetakeSiteMessage", SITESTRING(g_Bombsite), g_NumT, g_NumCT);

    CreateTimer(0.1, Timer_FixBomb, g_RoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

/**
 * Hands out the bomb shortly after the round start, when the game has given its own C4.
 */
public Action Timer_FixBomb(Handle timer, any serial) {
    if (serial == g_RoundSerial && Retakes_Live() && g_TeamsValid) {
        FixBomb();
    }
    return Plugin_Handled;
}

/**
 * Round freezetime end, resets the round points.
 */
public Action Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast) {
    for (int i = 1; i <= MaxClients; i++) {
        g_RoundPoints[i] = 0;
    }

    return Plugin_Continue;
}

/**
 * Round end event, calls the appropriate winner (T/CT) unction and sets the scores.
 */
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    // Повторный round_end до начала следующего раунда (например, CS_TerminateRound из-за
    // вышедшего игрока): раунд уже посчитан, следующий уже подготовлен.
    if (InIntermission()) {
        DebugLog("round_end: ignored, the next round is already being prepared");
        return Plugin_Continue;
    }

    int winner = event.GetInt("winner");
    DebugLog("round_end: winner team %d, reason %d, bomb planted: %d, active players: %d",
             winner, event.GetInt("reason"), g_bombPlanted, g_ActivePlayers);

    // winner не T/CT - это ничья или "Game Commencing": очки не трогаем.
    if (g_ActivePlayers >= 2 && g_TeamsValid && (winner == CS_TEAM_T || winner == CS_TEAM_CT)) {
        g_RoundCount++;

        ArrayList ts = new ArrayList();
        ArrayList cts = new ArrayList();

        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i)) {
                if (GetClientTeam(i) == CS_TEAM_CT)
                    cts.Push(i);
                else if (GetClientTeam(i) == CS_TEAM_T)
                    ts.Push(i);
            }
        }

        Call_StartForward(g_OnRoundWon);
        Call_PushCell(winner);
        Call_PushCell(ts);
        Call_PushCell(cts);
        Call_Finish();

        delete ts;
        delete cts;

        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i) && IsOnTeam(i) && GetClientTeam(i) != winner) {
                g_RoundPoints[i] -= POINTS_LOSS;
            }
        }

        if (winner == CS_TEAM_T) {
            TerroristsWon();
        } else if (winner == CS_TEAM_CT) {
            CounterTerroristsWon();
        }
    }

    // Команды следующего раунда выставляем на следующем кадре, до рестарта раунда.
    // Не таймер: при CS_TerminateRound с задержкой 0.0-0.1 таймер мог бы опоздать.
    // (Вариант "за 0.3 с до рестарта" пробовали: он давал заметный рывок перед началом
    // раунда - смена команд и респаун шли подряд, - и был отменён.)
    g_PreparePending = true;
    RequestFrame(Frame_PrepareNextRound, g_RoundSerial);

    return Plugin_Continue;
}

/***********************
 *                     *
 *    Retakes logic    *
 *                     *
 ***********************/

/**
 * Called at the end of the round - puts all the players into a priority queue by
 * their score for placing them next round.
 */
public void RoundEndUpdates() {
    PQ_Clear(g_hRankingQueue);

    Call_StartForward(g_hOnPreRoundEnqueue);
    Call_PushCell(g_hRankingQueue);
    Call_PushCell(g_hWaitingQueue);
    Call_Finish();

    int maxPlayers = g_hMaxPlayers.IntValue;

    // Люди всегда в приоритете: сначала те, кто уже играет, ...
    for (int client = 1; client <= MaxClients; client++) {
        if (IsPlayer(client) && IsOnTeam(client)) {
            PQ_Enqueue(g_hRankingQueue, client, g_RoundPoints[client]);
        }
    }

    // ... затем люди из очереди ожидания, ...
    while (!Queue_IsEmpty(g_hWaitingQueue) && PQ_GetSize(g_hRankingQueue) < maxPlayers) {
        int client = Queue_Dequeue(g_hWaitingQueue);
        if (IsPlayer(client)) {
            PQ_Enqueue(g_hRankingQueue, client, -POINTS_LOSS);
        }
    }

    // ... и только на оставшиеся до sm_retakes_bots_total места - боты. Бот никогда не занимает место человека,
    // а очки у ботов обычные: стороны между людьми и ботами меняются по тем же правилам.
    int fillTarget = GetBotsFillTarget();
    for (int client = 1; client <= MaxClients; client++) {
        if (PQ_GetSize(g_hRankingQueue) >= fillTarget) {
            break;
        }
        if (IsUsableBot(client)) {
            int points = IsOnTeam(client) ? g_RoundPoints[client] : -POINTS_LOSS;
            PQ_Enqueue(g_hRankingQueue, client, points);
        }
    }

    if (g_hAutoTeamsCvar.IntValue == 0) {
        PQ_Clear(g_hRankingQueue);
    }

    Call_StartForward(g_hOnPostRoundEnqueue);
    Call_PushCell(g_hRankingQueue);
    Call_PushCell(g_hWaitingQueue);
    Call_Finish();
}

/**
 * Places players onto the correct team.
 * This assumes the priority queue has already been built (e.g. by RoundEndUpdates).
 */
public void UpdateTeams() {
    for (int i = 0; i < MAX_SPAWNS; i++) {
        g_SpawnTaken[i] = false;
    }

    if (g_NumSpawns < g_hMaxPlayers.IntValue) {
        if (!g_NoSpawnsLogged) {
            g_NoSpawnsLogged = true;
            LogError("This map does not have enough spawns! (%d spawns, sm_retakes_maxplayers is %d)",
                     g_NumSpawns, g_hMaxPlayers.IntValue);
        }
        if (TranslationPhraseExists("NotEnoughSpawns")) {
            Retakes_MessageToAll("%t", "NotEnoughSpawns");
        } else {
            // на сервере старый файл переводов - не роняем из-за этого подготовку раунда
            Retakes_MessageToAll("{LIGHT_RED}This map does not have enough retake spawns. {NORMAL}An admin can create them with {GREEN}!edit");
        }
        return;
    }

    // Сайт выбираем только из тех, где хватает спавнов на этот состав: карта может быть
    // размечена не полностью (например, спавны расставлены только для A).
    int estPlayers = PQ_GetSize(g_hRankingQueue);
    if (estPlayers > g_hMaxPlayers.IntValue)
        estPlayers = g_hMaxPlayers.IntValue;
    int estT = RoundToNearest(g_hRatioConstant.FloatValue * float(estPlayers));
    if (estT < 1)
        estT = 1;
    int estCT = estPlayers - estT;
    if (estCT < 0)
        estCT = 0;

    bool siteAOk = SiteHasSpawns(BombsiteA, estT, estCT);
    bool siteBOk = SiteHasSpawns(BombsiteB, estT, estCT);
    if (siteAOk && !siteBOk) {
        g_Bombsite = BombsiteA;
    } else if (siteBOk && !siteAOk) {
        g_Bombsite = BombsiteB;
    } else {
        g_Bombsite = GetRandomBool() ? BombsiteA : BombsiteB;
    }

    if (siteAOk != siteBOk) {
        DebugLog("prepare: only site %s has enough spawns for %d T + %d CT, using it",
                 SITESTRING(g_Bombsite), estT, estCT);
    } else if (!siteAOk && !g_SiteSpawnsLogged) {
        g_SiteSpawnsLogged = true;
        LogError("Neither bombsite has enough spawns for %d T + %d CT (run sm_retakes_validatespawns), some players will stay at the map spawns",
                 estT, estCT);
    }

    Call_StartForward(g_OnSitePicked);
    Call_PushCellRef(g_Bombsite);
    Call_Finish();

    g_ActivePlayers = PQ_GetSize(g_hRankingQueue);
    if (g_ActivePlayers > g_hMaxPlayers.IntValue)
        g_ActivePlayers = g_hMaxPlayers.IntValue;

    g_NumT = RoundToNearest(g_hRatioConstant.FloatValue * float(g_ActivePlayers));
    if (g_NumT < 1)
        g_NumT = 1;

    g_NumCT = g_ActivePlayers - g_NumT;

    Call_StartForward(g_hOnTeamSizesSet);
    Call_PushCellRef(g_NumT);
    Call_PushCellRef(g_NumCT);
    Call_Finish();

    if (g_ScrambleSignal || g_hUseRandomTeams.IntValue != 0) {
        int n = g_hRankingQueue.Length;
        for (int i = 0; i < n; i++) {
            int value = GetRandomInt(1, 1000);
            g_hRankingQueue.Set(i, value, 1);
        }
        g_ScrambleSignal = false;
    }

    ArrayList ts = new ArrayList();
    ArrayList cts = new ArrayList();

    if (g_hAutoTeamsCvar.IntValue != 0) {
        // Ordinary team switching by retakes
        for (int i = 0; i < g_NumT; i++) {
            int client = PQ_Dequeue(g_hRankingQueue);
            if (IsValidClient(client)) {
                ts.Push(client);
            }
        }

        for (int i = 0; i < g_NumCT; i++) {
            int client = PQ_Dequeue(g_hRankingQueue);
            if (IsValidClient(client)) {
                cts.Push(client);
            }
        }
    } else {
        // Use the already set teams
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i)) {
                bool ct = GetClientTeam(i) == CS_TEAM_CT;
                bool t = GetClientTeam(i) == CS_TEAM_T;
                // В CS:S нет смены сторон (halftime), команды берём как есть.
                if (ct)
                    cts.Push(i);
                else if (t)
                    ts.Push(i);
            }
        }
        g_NumCT = cts.Length;
        g_NumT = ts.Length;
        g_ActivePlayers = g_NumCT + g_NumT;
    }

    Call_StartForward(g_hOnTeamsSet);
    Call_PushCell(ts);
    Call_PushCell(cts);
    Call_PushCell(g_Bombsite);
    Call_Finish();

    for (int i = 0; i < ts.Length; i++) {
        int client = ts.Get(i);
        if (IsValidClient(client)) {
            SwitchPlayerTeam(client, CS_TEAM_T);
            g_Team[client] = CS_TEAM_T;
            g_PlayerPrimary[client] = "weapon_ak47";
            g_PlayerSecondary[client] = "weapon_glock";
            g_PlayerNades[client] = "";
            g_PlayerKit[client] = false;
            g_PlayerHealth[client] = 100;
            g_PlayerArmor[client] = 100;
            g_PlayerHelmet[client] = true;
        }
    }

    for (int i = 0; i < cts.Length; i++) {
        int client = cts.Get(i);
        if (IsValidClient(client)) {
            SwitchPlayerTeam(client, CS_TEAM_CT);
            g_Team[client] = CS_TEAM_CT;
            g_PlayerPrimary[client] = "weapon_m4a1";
            g_PlayerSecondary[client] = "weapon_usp";
            g_PlayerNades[client] = "";
            g_PlayerKit[client] = true;
            g_PlayerHealth[client] = 100;
            g_PlayerArmor[client] = 100;
            g_PlayerHelmet[client] = true;
        }
    }

    // if somebody didn't get put in, put them back into the waiting queue
    while (!PQ_IsEmpty(g_hRankingQueue)) {
        int client = PQ_Dequeue(g_hRankingQueue);
        if (IsPlayer(client)) {
            Queue_EnqueueFront(g_hWaitingQueue, client);
        }
    }

    // Все, кто стоит в T/CT, но в раунд не попал (не хватило места, лишний бот), уходят в наблюдатели:
    // иначе игра заспаунила бы их на стандартном спавне со стандартным оружием.
    if (g_hAutoTeamsCvar.IntValue != 0) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i) && IsOnTeam(i) && !IsAssigned(i)) {
                SwitchPlayerTeam(i, CS_TEAM_SPECTATOR);
                if (!IsFakeClient(i)) {
                    Queue_Enqueue(g_hWaitingQueue, i);
                }
            }
        }
    }

    Call_StartForward(g_OnWeaponsAllocated);
    Call_PushCell(ts);
    Call_PushCell(cts);
    Call_PushCell(g_Bombsite);
    Call_Finish();

    int length = Queue_Length(g_hWaitingQueue);
    for (int i = 0; i < length; i++) {
        int client = g_hWaitingQueue.Get(i);
        if (IsValidClient(client)) {
            Retakes_Message(client, "%t", "WaitingQueueMessage", g_hMaxPlayers.IntValue);
        }
    }

    delete ts;
    delete cts;
    g_TeamsValid = true;
}

static bool ScramblesEnabled() {
    return g_hRoundsToScramble.IntValue >= 1;
}

public void TerroristsWon() {
    int toScramble = g_hRoundsToScramble.IntValue;
    g_WinStreak++;

    if (g_WinStreak >= toScramble) {
        if (ScramblesEnabled()) {
            g_ScrambleSignal = true;
            Retakes_MessageToAll("%t", "ScrambleMessage", g_WinStreak);
        }
        g_WinStreak = 0;
    } else if (g_WinStreak >= toScramble - 3 && ScramblesEnabled()) {
        Retakes_MessageToAll("%t", "WinStreakAlmostToScramble", g_WinStreak, toScramble - g_WinStreak);
    } else if (g_WinStreak >= 3) {
        Retakes_MessageToAll("%t", "WinStreak", g_WinStreak);
    }
}

public void CounterTerroristsWon() {
    if (!g_bombPlanted && IsValidClient(g_BombOwner) && g_RoundCount >= 3) {
        Retakes_MessageToAll("%t", "FailedToPlant", g_BombOwner);
        Call_StartForward(g_OnFailToPlant);
        Call_PushCell(g_BombOwner);
        Call_Finish();
    }

    if (g_WinStreak >= 3) {
        Retakes_MessageToAll("%t", "WinStreakOver", g_WinStreak);
    }

    g_WinStreak = 0;
}

/**
 * Ends the round if one of the teams has no players left.
 * ignoredClient is a client that is about to leave and must not be counted.
 */
void CheckRoundDone(int ignoredClient = 0) {
    if (!g_Enabled || InFreePlay()) {
        return;
    }

    // Между round_end и стартом следующего раунда ничего завершать не нужно.
    if (InIntermission()) {
        return;
    }

    int tCount = 0, ctCount = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == ignoredClient || !IsValidClient(i)) {
            continue;
        }
        if (GetClientTeam(i) == CS_TEAM_T) {
            tCount++;
        } else if (GetClientTeam(i) == CS_TEAM_CT) {
            ctCount++;
        }
    }

    if (tCount == 0 || ctCount == 0) {
        CS_TerminateRound(0.1, CSRoundEnd_TerroristWin);
    }
}

public int GetOtherTeam(int team) {
    return (team == CS_TEAM_CT) ? CS_TEAM_T : CS_TEAM_CT;
}

public Bombsite GetOtherSite(Bombsite site) {
    return (site == BombsiteA) ? BombsiteB : BombsiteA;
}

/**
 * Forgets everything the plugin has accumulated on this map: round points, the T win
 * streak, a pending scramble, the round counter and the prepared round. The waiting
 * queue, the spawns and the cvars are left alone.
 */
public void ResetRetakesProgress() {
    for (int i = 1; i <= MaxClients; i++) {
        g_RoundPoints[i] = 0;
        g_SpawnIndices[i] = -1;
        g_Team[i] = CS_TEAM_SPECTATOR;
    }

    g_WinStreak = 0;
    g_RoundCount = 0;
    g_ScrambleSignal = false;

    g_PreparePending = false;
    g_RoundPrepared = false;
    g_TeamsValid = false;

    g_BombOwner = -1;
    g_BombHandedOut = false;
    g_SelectBombClient = -1;
    g_bombPlanted = false;
}

/**
 * sm_retakes_warmup [seconds]: starts a warmup without changing the map and resets the
 * retakes progress. Without an argument sm_retakes_warmuptime is used; 0 ends the warmup.
 * The warmup itself is run by the warmup plugin.
 */
public Action Command_Warmup(int client, int args) {
    if (!g_Enabled) {
        ReplyToCommand(client, "[Retakes] The plugin is disabled.");
        return Plugin_Handled;
    }

    if (!WarmupAvailable()) {
        ReplyToCommand(client, "[Retakes] The warmup plugin (warmup.smx) is not loaded.");
        return Plugin_Handled;
    }

    if (g_EditMode) {
        ReplyToCommand(client, "[Retakes] Exit the spawn editor first (\"Exit edit mode\" in the !edit menu).");
        return Plugin_Handled;
    }

    int time = g_WarmupTimeCvar.IntValue;
    if (args >= 1) {
        char buffer[16];
        GetCmdArg(1, buffer, sizeof(buffer));
        time = StringToInt(buffer);
    }

    if (time <= 0) {
        if (Retakes_InWarmup()) {
            Retakes_MessageToAll("The warmup was ended by an admin.");
            // Warmup_OnEnd takes it from here and starts the first retake.
            Warmup_End();
        } else {
            ReplyToCommand(client, "[Retakes] There is no warmup to end. Usage: sm_retakes_warmup [seconds]");
        }
        return Plugin_Handled;
    }

    DebugLog("warmup: restarted by %L", client);
    ResetRetakesProgress();
    if (!Warmup_Start(time)) {
        ReplyToCommand(client, "[Retakes] The warmup plugin refused to start a warmup (sm_warmup_enabled 0?).");
        return Plugin_Handled;
    }
    UpdateBotQuota(false);
    Retakes_MessageToAll("Warmup for {GREEN}%d{NORMAL} seconds. Pick any team.", time);
    return Plugin_Handled;
}
