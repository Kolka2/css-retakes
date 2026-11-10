#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#include "include/priorityqueue.inc"
#include "include/queue.inc"
#include "include/restorecvars.inc"
#include "include/retakes.inc"

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

/** Plugin-managed warmup (CS:S has no mp_warmup_*) **/
bool g_InWarmup;

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
bool g_bombPlantSignal;
bool g_bombPlanted;
int g_BombOwner = -1;
int g_NumCT;
int g_NumT;
int g_ActivePlayers;
bool g_RoundSpawnsDecided; // spawns are lazily decided on the first player spawn event

/**
 * Round preparation state. CS:S has no round_prestart event, so the teams for the next
 * round are set right after round_end (see PrepareNextRound), before the game respawns the players.
 */
bool g_PreparePending; // round_end was seen, PrepareNextRound runs on the next frame
bool g_RoundPrepared;  // PrepareNextRound has run and its data (teams, spawns) is usable
bool g_PrepConsumed;   // a round_start has already used the prepared data
bool g_TeamsValid;     // UpdateTeams actually assigned the teams (false if the map has no spawns)
int g_RoundSerial;     // incremented on every round_start, lets the delayed callbacks detect a new round
bool g_NoSpawnsLogged;

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
#include "retakes/teams.sp"
#include "retakes/warmup.sp"
#include "retakes/editor.sp"
#include "retakes/editor_commands.sp"
#include "retakes/editor_menus.sp"
#include "retakes/natives.sp"
#include "retakes/spawns.sp"



/***********************
 *                     *
 * Sourcemod functions *
 *                     *
 ***********************/

public Plugin myinfo = {
    name = "CS:GO Retakes",
    author = "splewis",
    description = "CS:GO Retake practice",
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
    g_WarmupTimeCvar = CreateConVar("sm_retakes_warmuptime", "25", "Warmup time on map starts");
    g_MessagePrefix = CreateConVar("sm_retake_message_prefix", "[{GREEN}Retakes{NORMAL}]", "Message prefix used on chat messages.");

    g_EnabledCvar.AddChangeHook(EnabledChanged);

    /** Create/Execute retakes cvars **/
    AutoExecConfig(true, "retakes", "sourcemod/retakes");

    g_hCvarVersion = CreateConVar("sm_retakes_version", PLUGIN_VERSION, "Current retakes version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_hCvarVersion.SetString(PLUGIN_VERSION);

    /** Command hooks **/
    AddCommandListener(Command_JoinTeam, "jointeam");

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

    RegAdminCmd("sm_iteratespawns", Command_IterateSpawns, ADMFLAG_CHANGEMAP);
    RegAdminCmd("sm_reloadspawns", Command_ReloadSpawns, ADMFLAG_CHANGEMAP, "Reloads retakes spawns for the current map, discarding changes");
    RegAdminCmd("sm_savespawns", Command_SaveSpawns, ADMFLAG_CHANGEMAP, "Saves retakes spawns for the current map");

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
    g_RoundSpawnsDecided = false;
    g_PreparePending = false;
    g_RoundPrepared = false;
    g_PrepConsumed = false;
    g_TeamsValid = false;
    g_NoSpawnsLogged = false;

    g_bombPlanted = false;
    g_bombPlantSignal = false;

    FindSites();
    g_NumSpawns = ParseSpawns();

    g_EditMode = false;
    g_InWarmup = false;
    CreateTimer(1.0, Timer_ShowSpawns, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_FreePlay, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    if (!g_Enabled)
        return;

    ExecConfigs();

    // Restart warmup for players to connect.
    StartWarmup(g_WarmupTimeCvar.IntValue);
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

public void OnClientDisconnect(int client) {
    ResetClientVariables(client);
    CheckRoundDone(client);
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
    g_PluginTeamSwitch[client] = false;
    g_RoundPoints[client] = -POINTS_LOSS;
    g_LastDeathTime[client] = 0.0;
}

public Action Command_ScrambleTeams(int client, int args) {
    if (g_Enabled) {
        g_ScrambleSignal = true;
        Retakes_MessageToAll("%t", "AdminScrambleTeams", client);
    }

    return Plugin_Continue;
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

    char arg[4];
    GetCmdArg(1, arg, sizeof(arg));
    int team_to = StringToInt(arg);
    int team_from = GetClientTeam(client);

    // if same team, teamswitch controlled by the plugin
    // note if a player hits autoselect their team_from=team_to=CS_TEAM_NONE
    if ((team_from == team_to && team_from != CS_TEAM_NONE) || g_PluginTeamSwitch[client] || IsFakeClient(client)) {
        return Plugin_Continue;
    } else {
        // ignore switches between T/CT team
        if (   (team_from == CS_TEAM_CT && team_to == CS_TEAM_T )
            || (team_from == CS_TEAM_T  && team_to == CS_TEAM_CT)) {
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
 * Generic logic for placing a player into the correct team when they join.
 */
public Action PlacePlayer(int client) {
    int tHumanCount=0, ctHumanCount=0, nPlayers=0;
    GetTeamsClientCounts(tHumanCount, ctHumanCount);
    nPlayers = tHumanCount + ctHumanCount;

    if (g_InWarmup && nPlayers < g_hMaxPlayers.IntValue) {
        return Plugin_Continue;
    }

    if (nPlayers < 2) {
        ChangeClientTeam(client, CS_TEAM_SPECTATOR);
        Queue_Enqueue(g_hWaitingQueue, client);
        // Между раундами следующий раунд уже подготовлен без этого игрока:
        // его подхватит проверка в Timer_PostRoundStart.
        if (!InIntermission()) {
            CS_TerminateRound(0.0, CSRoundEnd_CTWin);
        }
        return Plugin_Handled;
    }

    ChangeClientTeam(client, CS_TEAM_SPECTATOR);
    Queue_Enqueue(g_hWaitingQueue, client);
    Retakes_Message(client, "%t", "JoinedQueueMessage");
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

    SetEventBool(event, "silent", true);
    return Plugin_Continue;
}

/**
 * Called when a player spawns.
 * Moves the player to the retake spawn and gives the weapons.
 */
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || !IsOnTeam(client) || InFreePlay())
        return Plugin_Continue;

    // В CS:S player_spawn приходит и при входе на сервер, когда игрок ещё мёртв.
    if (!IsPlayerAlive(client))
        return Plugin_Continue;

    // Раунд не подготовлен (первый раунд, mp_restartgame) или на карте нет спавнов:
    // в первом случае Event_RoundStart сам подготовит раунд и переспаунит игроков.
    if (!g_RoundPrepared || !g_TeamsValid)
        return Plugin_Continue;

    if (!g_RoundSpawnsDecided) {
        DecideRoundSpawns();
    }

    SetupPlayer(client);
    return Plugin_Continue;
}

/**
 * Picks the spawn points for everybody that plays the round.
 */
static void DecideRoundSpawns() {
    if (IsPlayer(g_BombOwner)) {
        g_SpawnIndices[g_BombOwner] = SelectSpawn(CS_TEAM_T, true);
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && IsOnTeam(i) && i != g_BombOwner) {
            g_SpawnIndices[i] = SelectSpawn(g_Team[i], false);
        }
    }
    g_RoundSpawnsDecided = true;
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

    if (validAttacker) {
        // награду за убийство не оставляем: закупаться в ретейке нельзя
        SetClientMoney(attacker, 0);
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
    g_bombPlantSignal = false;

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
 *  - if a round starts without it (first round, mp_restartgame), Event_RoundStart runs it
 *    and respawns the players.
 * It never runs twice for the same round.
 */
public void PrepareNextRound() {
    g_PreparePending = false;
    g_RoundPrepared = true;
    g_PrepConsumed = false;
    g_RoundSpawnsDecided = false;
    g_TeamsValid = false;
    g_BombOwner = -1;

    for (int i = 1; i <= MaxClients; i++) {
        g_SpawnIndices[i] = -1;
        g_Team[i] = CS_TEAM_SPECTATOR;
    }

    RoundEndUpdates();
    UpdateTeams();

    ArrayList ts = new ArrayList();
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && g_Team[i] == CS_TEAM_T) {
            ts.Push(i);
        }
    }

    if (ts.Length >= 1) {
        g_BombOwner = RandomElement(ts);
    }
    delete ts;
}

/**
 * Returns if a round has ended and the next one has not started yet.
 */
bool InIntermission() {
    return g_PreparePending || (g_RoundPrepared && !g_PrepConsumed);
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
        ExtendFreePlayRound();
        return Plugin_Continue;
    }

    // Страховка: раунд начался без подготовки (первый раунд после разминки, mp_restartgame).
    bool fallback = !g_RoundPrepared || g_PrepConsumed;
    if (fallback) {
        PrepareNextRound();
    }
    g_PrepConsumed = true;

    for (int i = 1; i <= MaxClients; i++) {
        g_RoundPoints[i] = 0;
    }

    if (!g_TeamsValid) {
        return Plugin_Continue;
    }

    if (fallback) {
        // Игроки уже заспаунены игрой в старых командах и на стандартных спавнах.
        // CSS-VERIFY: CS_RespawnPlayer внутри обработчика round_start переспаунивает игроков без побочных эффектов.
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && IsOnTeam(i) && g_Team[i] == GetClientTeam(i)) {
                CS_RespawnPlayer(i);
            }
        }
    }

    // CSS-VERIFY: по истечении m_iRoundTime без установленной бомбы побеждают CT (Target Saved),
    // а после установки бомбы раунд по этому таймеру уже не заканчивается.
    SetRoundTime(g_hRoundTime.IntValue);
    Retakes_MessageToAll("%t", "RetakeSiteMessage", SITESTRING(g_Bombsite), g_NumT, g_NumCT);

    CreateTimer(0.1, Timer_PostRoundStart, g_RoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

/**
 * Runs shortly after the round start, when every player has been spawned by the game.
 */
public Action Timer_PostRoundStart(Handle timer, any serial) {
    if (serial != g_RoundSerial || !Retakes_Live() || !g_TeamsValid) {
        return Plugin_Handled;
    }

    // CSS-VERIFY: игрок, переведённый плагином из наблюдателей в команду, спаунится игрой при рестарте раунда.
    // Если нет - доспауниваем его здесь.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && IsOnTeam(i) && g_Team[i] == GetClientTeam(i) && !IsPlayerAlive(i)) {
            CS_RespawnPlayer(i);
        }
    }

    // Раунд начался меньше чем с двумя игроками, а в очереди кто-то ждёт (зашёл между раундами):
    // не ждём конца раунда, а сразу начинаем следующий, уже с ним.
    if (g_hAutoTeamsCvar.IntValue != 0 && g_ActivePlayers < 2 && !Queue_IsEmpty(g_hWaitingQueue)) {
        CS_TerminateRound(1.0, CSRoundEnd_Draw);
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
        return Plugin_Continue;
    }

    int winner = event.GetInt("winner");

    // winner не T/CT - это ничья или "Game Commencing": очки не трогаем.
    if (g_ActivePlayers >= 2 && g_TeamsValid && (winner == CS_TEAM_T || winner == CS_TEAM_CT)) {
        g_RoundCount++;

        ArrayList ts = new ArrayList();
        ArrayList cts = new ArrayList();

        for (int i = 1; i <= MaxClients; i++) {
            if (IsPlayer(i)) {
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
            if (IsPlayer(i) && GetClientTeam(i) != winner) {
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

    for (int client = 1; client <= MaxClients; client++) {
        if (IsPlayer(client) && IsOnTeam(client)) {
            PQ_Enqueue(g_hRankingQueue, client, g_RoundPoints[client]);
        }
    }

    while (!Queue_IsEmpty(g_hWaitingQueue) && PQ_GetSize(g_hRankingQueue) < g_hMaxPlayers.IntValue) {
        int client = Queue_Dequeue(g_hWaitingQueue);
        if (IsPlayer(client)) {
            PQ_Enqueue(g_hRankingQueue, client, -POINTS_LOSS);
        } else {
            break;
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
        Retakes_MessageToAll("%t", "NotEnoughSpawns");
        return;
    }

    g_Bombsite = GetRandomBool() ? BombsiteA : BombsiteB;
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
