#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#include "include/warmup.inc"

#pragma semicolon 1
#pragma newdecls required

/**
 * Warmup for Counter-Strike: Source.
 *
 * CS:S has no built-in warmup (no mp_warmup_* cvars, no m_bWarmupPeriod), so this plugin
 * runs one: an endless round where the dead respawn, everybody can buy, and there is no
 * bomb. Game modes drive it through the natives and forwards in include/warmup.inc;
 * it also works on its own with sm_warmup_autostart 1.
 */

#define WARMUP_VERSION "1.0.0"

#define WARMUP_MONEY 16000           // the CS:S money cap
#define WARMUP_BUYTIME "1440"        // mp_buytime while the warmup runs, in minutes
#define ENDLESS_ROUND_TIME 3600      // seconds kept on the round clock
#define MAX_ROUND_TIME 30000         // m_iRoundTime is networked with 16 bits
#define CVAR_VALUE_LENGTH 64
#define HINT_SOUND "UI/hint.wav"      // played by the game with every hint message

// CS:S player classes (models): 1-4 belong to the terrorists, 5-8 to the CTs.
#define CSS_FIRST_T_CLASS 1
#define CSS_LAST_T_CLASS 4
#define CSS_FIRST_CT_CLASS 5
#define CSS_LAST_CT_CLASS 8

/** ConVars **/
ConVar g_hEnabled;
ConVar g_hAutoStart;
ConVar g_hTime;
ConVar g_hMinPlayers;
ConVar g_hRespawnTime;
ConVar g_hInfiniteMoney;
ConVar g_hBuyAnywhere;
ConVar g_hRestartDelay;
ConVar g_hDebug;

/** Warmup state **/
bool g_Active;
int g_TimeLimit;      // length of the running warmup in seconds, 0 = no time limit
int g_TimeLeft;
float g_LastDeathTime[MAXPLAYERS+1];

/** Only for the debug log (sm_warmup_debug) **/
int g_DebugTeamT = -1;                  // team sizes at the last check, -1 = not known yet
int g_DebugTeamCT = -1;
float g_DebugLastBlockTime;             // when a blocked round end was last logged
CSRoundEndReason g_DebugLastBlockReason;
bool g_DebugVetoLogged;                 // the "another plugin keeps the warmup going" line is out

/** Cvars changed for the duration of the warmup, see OverrideCvar **/
ArrayList g_OverriddenCvars;    // ConVar handles
ArrayList g_OriginalValues;     // what to put back
ArrayList g_OverrideValues;     // what the warmup wants
bool g_SettingCvar;

/** Forwards **/
Handle g_hOnStart;
Handle g_hOnEnding;
Handle g_hOnEnd;

public Plugin myinfo = {
    name = "CS:S Warmup",
    author = "Kolka2",
    description = "A plugin-managed warmup for Counter-Strike: Source that any game mode can use",
    version = WARMUP_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "This warmup plugin only supports Counter-Strike: Source");
        return APLRes_Failure;
    }

    CreateNative("Warmup_IsActive", Native_IsActive);
    CreateNative("Warmup_Start", Native_Start);
    CreateNative("Warmup_End", Native_End);
    RegPluginLibrary("warmup");
    return APLRes_Success;
}

public void OnPluginStart() {
    LoadTranslations("warmup.phrases");

    g_hEnabled = CreateConVar("sm_warmup_enabled", "1", "Whether warmups can be started at all", _, true, 0.0, true, 1.0);
    g_hAutoStart = CreateConVar("sm_warmup_autostart", "0", "1 = start a warmup on every map start. Leave at 0 when a game mode (e.g. retakes) starts the warmup itself", _, true, 0.0, true, 1.0);
    g_hTime = CreateConVar("sm_warmup_time", "25", "Default warmup length in seconds. 0 = no time limit (the warmup ends by sm_warmup_min_players or by command)", _, true, 0.0);
    g_hMinPlayers = CreateConVar("sm_warmup_min_players", "1", "Humans needed on the server. With a time limit the countdown only runs while this many are present; without one the warmup ends as soon as this many are present. 0 = do not wait for players", _, true, 0.0);
    g_hRespawnTime = CreateConVar("sm_warmup_respawn_time", "1.5", "Seconds between a death and the respawn during the warmup", _, true, 0.0);
    g_hInfiniteMoney = CreateConVar("sm_warmup_infinite_money", "1", "1 = everybody has $16000 on spawn and again after every purchase during the warmup", _, true, 0.0, true, 1.0);
    g_hBuyAnywhere = CreateConVar("sm_warmup_buy_anywhere", "0", "1 = players can buy anywhere on the map during the warmup, not only in the buy zones", _, true, 0.0, true, 1.0);
    g_hRestartDelay = CreateConVar("sm_warmup_restart_delay", "1", "Seconds until the game restarts after the warmup (mp_restartgame). 0 = do not restart the game", _, true, 0.0);

    g_hDebug = CreateConVar("sm_warmup_debug", "0", "1 = write what the warmup does (start, end, removed bombs) to addons/sourcemod/logs/warmup_debug.log", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "warmup");

    CreateConVar("sm_warmup_version", WARMUP_VERSION, "Current warmup plugin version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_hEnabled.AddChangeHook(OnEnabledChanged);

    RegAdminCmd("sm_warmup", Command_Warmup, ADMFLAG_CHANGEMAP, "sm_warmup [seconds] - starts or restarts the warmup (0 = no time limit, no argument = sm_warmup_time)");
    RegAdminCmd("sm_warmup_end", Command_WarmupEnd, ADMFLAG_CHANGEMAP, "Ends the running warmup");

    AddCommandListener(Command_JoinTeam, "jointeam");

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);

    g_hOnStart = CreateGlobalForward("Warmup_OnStart", ET_Ignore, Param_Cell);
    g_hOnEnding = CreateGlobalForward("Warmup_OnEnding", ET_Event);
    g_hOnEnd = CreateGlobalForward("Warmup_OnEnd", ET_Ignore, Param_Cell);

    g_OverriddenCvars = new ArrayList();
    g_OriginalValues = new ArrayList(ByteCountToCells(CVAR_VALUE_LENGTH));
    g_OverrideValues = new ArrayList(ByteCountToCells(CVAR_VALUE_LENGTH));

    // Late load: the clients that are already in game were never passed to OnClientPutInServer.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }
}

public void OnPluginEnd() {
    EndWarmup(WarmupEnd_PluginUnload, false);
}

public void OnMapStart() {
    CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted() {
    if (g_hAutoStart.BoolValue && !g_Active) {
        StartWarmup(-1);
    }
}

public void OnMapEnd() {
    EndWarmup(WarmupEnd_MapChange, false);
}

public void OnEnabledChanged(ConVar cvar, const char[] oldValue, const char[] newValue) {
    if (!cvar.BoolValue) {
        EndWarmup(WarmupEnd_Forced, false);
    }
}

public void OnClientPutInServer(int client) {
    g_LastDeathTime[client] = 0.0;
    SDKHook(client, SDKHook_PostThinkPost, Hook_PostThinkPost);
    SDKHook(client, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
}

/**
 * Writes a line to logs/warmup_debug.log if sm_warmup_debug is set.
 */
static void DebugLog(const char[] format, any ...) {
    if (!g_hDebug.BoolValue) {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 2);

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/warmup_debug.log");
    LogToFile(path, "%s", buffer);
}

/**
 * Counts the players of a team for the debug log: members and the living among them.
 */
static void CountTeam(int team, int &members, int &alive) {
    members = 0;
    alive = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && GetClientTeam(i) == team) {
            members++;
            if (IsPlayerAlive(i)) {
                alive++;
            }
        }
    }
}

/**
 * Formats "T 2/3 alive, CT 0/3 alive" for the debug log.
 */
static void DescribeTeams(char[] buffer, int maxlength) {
    int t, tAlive, ct, ctAlive;
    CountTeam(CS_TEAM_T, t, tAlive);
    CountTeam(CS_TEAM_CT, ct, ctAlive);
    Format(buffer, maxlength, "T %d/%d alive, CT %d/%d alive", tAlive, t, ctAlive, ct);
}

/**
 * Names the round end reasons that can show up in a warmup.
 */
static void RoundEndReasonName(CSRoundEndReason reason, char[] buffer, int maxlength) {
    switch (reason) {
        case CSRoundEnd_TargetBombed: strcopy(buffer, maxlength, "target bombed");
        case CSRoundEnd_BombDefused: strcopy(buffer, maxlength, "bomb defused");
        case CSRoundEnd_CTWin: strcopy(buffer, maxlength, "all terrorists dead");
        case CSRoundEnd_TerroristWin: strcopy(buffer, maxlength, "all CTs dead");
        case CSRoundEnd_Draw: strcopy(buffer, maxlength, "draw");
        case CSRoundEnd_TargetSaved: strcopy(buffer, maxlength, "time ran out");
        case CSRoundEnd_GameStart: strcopy(buffer, maxlength, "game commencing");
        default: strcopy(buffer, maxlength, "other");
    }
}

/**
 * Debug log only: tells when a team becomes empty or gets its first member. The game
 * restarts the round ("Game Commencing") when a team that was empty gets a player.
 */
static void DebugTrackTeams() {
    if (!g_hDebug.BoolValue) {
        g_DebugTeamT = -1;
        g_DebugTeamCT = -1;
        return;
    }

    int t, ct, alive;
    CountTeam(CS_TEAM_T, t, alive);
    CountTeam(CS_TEAM_CT, ct, alive);
    if (g_DebugTeamT != -1 && ((t == 0) != (g_DebugTeamT == 0) || (ct == 0) != (g_DebugTeamCT == 0))) {
        DebugLog("teams: T %d -> %d, CT %d -> %d players (%s)", g_DebugTeamT, t, g_DebugTeamCT, ct,
                 (t > 0 && ct > 0) ? "both teams have players again, the game may restart the round"
                                   : "a team is empty");
    }
    g_DebugTeamT = t;
    g_DebugTeamCT = ct;
}


/***********************
 *                     *
 *      Lifecycle      *
 *                     *
 ***********************/

/**
 * Starts (or restarts) the warmup. A negative length means sm_warmup_time.
 */
static bool StartWarmup(int seconds) {
    if (!g_hEnabled.BoolValue) {
        return false;
    }

    if (seconds < 0) {
        seconds = g_hTime.IntValue;
    }

    bool wasActive = g_Active;
    g_Active = true;
    g_DebugTeamT = -1;
    g_DebugTeamCT = -1;
    g_DebugVetoLogged = false;
    g_TimeLimit = seconds;
    g_TimeLeft = seconds;

    if (!wasActive) {
        // The warmup is one endless round: with the normal mp_buytime buying would stop
        // a few seconds after it began.
        OverrideCvar("mp_buytime", WARMUP_BUYTIME);
    }

    if (seconds > 0) {
        DebugLog("warmup %s: %d seconds", wasActive ? "restarted" : "started", seconds);
    } else {
        DebugLog("warmup %s: no time limit, it ends once %d human(s) are on the server (sm_warmup_min_players)",
                 wasActive ? "restarted" : "started", g_hMinPlayers.IntValue);
    }

    ExtendRound();
    RemoveBombs("warmup start");

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsOnTeam(i)) {
            GiveWarmupMoney(i);
        }
    }

    Call_StartForward(g_hOnStart);
    Call_PushCell(seconds);
    Call_Finish();
    return true;
}

/**
 * Ends the warmup: restores the cvars, tells the other plugins and, for a regular
 * end, restarts the game.
 */
static bool EndWarmup(WarmupEndReason reason, bool restartGame) {
    if (!g_Active) {
        return false;
    }

    g_Active = false;
    RestoreCvars();
    DebugLog("warmup ended, reason %d (0 finished, 1 forced, 2 map change, 3 plugin unload), game restart: %s",
             reason, (restartGame && g_hRestartDelay.IntValue > 0
                      && (reason == WarmupEnd_Finished || reason == WarmupEnd_Forced)) ? "yes" : "no");

    Call_StartForward(g_hOnEnd);
    Call_PushCell(reason);
    Call_Finish();

    int delay = g_hRestartDelay.IntValue;
    if (restartGame && delay > 0 && (reason == WarmupEnd_Finished || reason == WarmupEnd_Forced)) {
        ServerCommand("mp_restartgame %d", delay);
    }
    return true;
}

/**
 * The warmup has met its end conditions. Asks the other plugins first:
 * any of them can keep the warmup going by returning Plugin_Handled.
 */
static void TryFinishWarmup() {
    Action result = Plugin_Continue;
    Call_StartForward(g_hOnEnding);
    Call_Finish(result);

    if (result >= Plugin_Handled) {
        if (!g_DebugVetoLogged) {
            g_DebugVetoLogged = true;
            DebugLog("warmup: the end conditions are met, but another plugin keeps the warmup going (Warmup_OnEnding)");
        }
        return;
    }
    g_DebugVetoLogged = false;

    EndWarmup(WarmupEnd_Finished, true);
}

static int GetHumanCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            count++;
        }
    }
    return count;
}

/**
 * Shows a translated hint to every human. The phrase gets up to two integer arguments.
 */
static void HintToAll(const char[] phrase, int arg1, int arg2 = 0) {
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            PrintHintText(i, "%t", phrase, arg1, arg2);
            // CS:S plays a sound with every hint message; with a countdown that is a beep
            // every second. Cut it right away.
            // Checked on a live CS:S server: the hint sound is UI/hint.wav on the static channel, and stopping it
            // here silences the countdown without hiding the text.
            StopSound(i, SNDCHAN_STATIC, HINT_SOUND);
        }
    }
}

/**
 * Runs every second: keeps the round endless, respawns the players the game left dead,
 * and checks the end conditions (time and/or minimum number of players).
 */
public Action Timer_Second(Handle timer) {
    if (!g_Active) {
        return Plugin_Continue;
    }

    ExtendRound();
    RespawnDeadPlayers();
    // A safety net: whatever way a C4 got into the warmup, it does not live long enough
    // to be planted. Needed: on a live server it found a C4 on the ground that had not
    // gone through Hook_WeaponCanUse. The cost is a walk over the players' weapons once
    // a second, only while the warmup runs.
    RemoveBombs("every-second check");
    DebugTrackTeams();

    int humans = GetHumanCount();
    int minPlayers = g_hMinPlayers.IntValue;
    bool enoughPlayers = humans >= minPlayers;

    if (g_TimeLimit > 0) {
        // The countdown only runs while somebody is there to warm up (and the minimum is met);
        // whoever joins an empty server gets the whole warmup.
        if (humans == 0 || !enoughPlayers) {
            g_TimeLeft = g_TimeLimit;
            if (humans > 0) {
                HintToAll("WarmupWaitingForPlayers", humans, minPlayers);
            }
            return Plugin_Continue;
        }

        if (g_TimeLeft <= 0) {
            TryFinishWarmup();
            return Plugin_Continue;
        }

        HintToAll("WarmupTimeLeft", g_TimeLeft);
        g_TimeLeft--;
        return Plugin_Continue;
    }

    // No time limit: the warmup ends when enough players have joined.
    // With sm_warmup_min_players 0 as well it only ends by Warmup_End() / sm_warmup_end.
    if (minPlayers > 0) {
        if (enoughPlayers) {
            TryFinishWarmup();
        } else if (humans > 0) {
            HintToAll("WarmupWaitingForPlayers", humans, minPlayers);
        }
    }

    return Plugin_Continue;
}


/***********************
 *                     *
 *   Cvar overrides    *
 *                     *
 ***********************/

/**
 * Sets a cvar for the duration of the warmup and remembers what to put back.
 * If something else changes the cvar meanwhile (a config executed on map start, an
 * admin), that new value becomes the one to restore and the warmup value is re-applied.
 */
static void OverrideCvar(const char[] name, const char[] value) {
    ConVar cvar = FindConVar(name);
    if (cvar == null) {
        LogError("The %s cvar was not found, the warmup cannot change it", name);
        return;
    }

    char original[CVAR_VALUE_LENGTH];
    cvar.GetString(original, sizeof(original));

    g_OverriddenCvars.Push(cvar);
    g_OriginalValues.PushString(original);
    g_OverrideValues.PushString(value);
    cvar.AddChangeHook(OnOverriddenCvarChanged);

    g_SettingCvar = true;
    cvar.SetString(value);
    g_SettingCvar = false;
}

public void OnOverriddenCvarChanged(ConVar cvar, const char[] oldValue, const char[] newValue) {
    if (g_SettingCvar || !g_Active) {
        return;
    }

    int index = g_OverriddenCvars.FindValue(cvar);
    if (index == -1) {
        return;
    }

    g_OriginalValues.SetString(index, newValue);

    char value[CVAR_VALUE_LENGTH];
    g_OverrideValues.GetString(index, value, sizeof(value));

    char cvarName[64];
    cvar.GetName(cvarName, sizeof(cvarName));
    DebugLog("cvar: %s was set to %s during the warmup; kept at %s, %s will be restored afterwards",
             cvarName, newValue, value, newValue);
    g_SettingCvar = true;
    cvar.SetString(value);
    g_SettingCvar = false;
}

/**
 * Puts back every cvar changed by OverrideCvar. Called whenever the warmup ends:
 * normally, on a map change and when the plugin is unloaded.
 */
static void RestoreCvars() {
    char original[CVAR_VALUE_LENGTH];
    g_SettingCvar = true;
    for (int i = 0; i < g_OverriddenCvars.Length; i++) {
        ConVar cvar = g_OverriddenCvars.Get(i);
        g_OriginalValues.GetString(i, original, sizeof(original));
        cvar.RemoveChangeHook(OnOverriddenCvarChanged);
        cvar.SetString(original);
    }
    g_SettingCvar = false;

    g_OverriddenCvars.Clear();
    g_OriginalValues.Clear();
    g_OverrideValues.Clear();
}


/***********************
 *                     *
 *    Endless round    *
 *                     *
 ***********************/

/**
 * The round never ends during the warmup, so the map is never reset under the players.
 */
public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason) {
    if (!g_Active) {
        return Plugin_Continue;
    }

    char teams[64];
    char reasonName[32];

    // "Game Commencing" is the game's own first restart (it resets the scores), let it through.
    if (reason == CSRoundEnd_GameStart) {
        if (g_hDebug.BoolValue) {
            DescribeTeams(teams, sizeof(teams));
            DebugLog("round: game commencing let through, the round restarts in %.1f s (%s)", delay, teams);
        }
        return Plugin_Continue;
    }

    // The game may ask again and again while the condition holds: one line per second
    // and reason is enough.
    if (g_hDebug.BoolValue
        && (reason != g_DebugLastBlockReason || GetGameTime() - g_DebugLastBlockTime >= 1.0)) {
        g_DebugLastBlockReason = reason;
        g_DebugLastBlockTime = GetGameTime();
        DescribeTeams(teams, sizeof(teams));
        RoundEndReasonName(reason, reasonName, sizeof(reasonName));
        DebugLog("round: end blocked, reason %d (%s), %s", reason, reasonName, teams);
    }

    // Plugin_Handled cancels the end of the round (a team wiped out, the time ran out);
    // checked on a live server.
    return Plugin_Handled;
}

/**
 * Debug log only. A round_end inside a warmup means the round ended although
 * CS_OnTerminateRound blocks it: either "game commencing" or a path around the forward.
 */
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (g_Active && g_hDebug.BoolValue) {
        char teams[64];
        char reasonName[32];
        CSRoundEndReason reason = view_as<CSRoundEndReason>(event.GetInt("reason"));
        DescribeTeams(teams, sizeof(teams));
        RoundEndReasonName(reason, reasonName, sizeof(reasonName));
        DebugLog("round: round_end INSIDE the warmup, winner team %d, reason %d (%s), %s",
                 event.GetInt("winner"), reason, reasonName, teams);
    }
    return Plugin_Continue;
}

/**
 * Keeps an hour on the round clock, so the round timer never runs out.
 */
static void ExtendRound() {
    // The game rules entity does not exist yet very early in a map start.
    if (FindEntityByClassname(-1, "cs_gamerules") == -1) {
        return;
    }

    // Changing m_iRoundTime mid-round moves both the HUD timer and the moment the round
    // ends (checked on a live server). m_fRoundStartTime is the end of the freeze time.
    int elapsed = RoundToFloor(GetGameTime() - GameRules_GetPropFloat("m_fRoundStartTime"));
    if (elapsed < 0) {
        elapsed = 0;
    }

    int seconds = elapsed + ENDLESS_ROUND_TIME;
    if (seconds > MAX_ROUND_TIME) {
        seconds = MAX_ROUND_TIME;
    }
    GameRules_SetProp("m_iRoundTime", seconds, 4, 0, true);
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    if (g_Active) {
        if (g_hDebug.BoolValue) {
            char teams[64];
            DescribeTeams(teams, sizeof(teams));
            DebugLog("round: round_start inside the warmup - the round was restarted (%s)", teams);
        }
        ExtendRound();
        // The game hands out a C4 on every round restart, after the players have spawned.
        CreateTimer(0.1, Timer_RemoveBombs, _, TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}


/***********************
 *                     *
 *       Respawn       *
 *                     *
 ***********************/

static bool IsOnTeam(int client) {
    int team = GetClientTeam(client);
    return team == CS_TEAM_T || team == CS_TEAM_CT;
}

/**
 * Returns if a player has picked a player class (model). In CS:S a player that joined
 * a team cannot spawn until the class menu is answered.
 */
static bool HasPickedClass(int client) {
    // Checked on a live CS:S server: m_iClass is 0 until the player has picked a class (model).
    return GetEntProp(client, Prop_Send, "m_iClass") != 0;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0) {
        return Plugin_Continue;
    }

    g_LastDeathTime[client] = GetGameTime();
    if (g_Active) {
        float delay = g_hRespawnTime.FloatValue;
        if (delay < 0.1) {
            delay = 0.1;
        }
        CreateTimer(delay, Timer_Respawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

public Action Timer_Respawn(Handle timer, int userid) {
    int client = GetClientOfUserId(userid);
    if (g_Active && client > 0 && IsClientInGame(client) && IsOnTeam(client)
        && !IsPlayerAlive(client) && HasPickedClass(client)) {
        CS_RespawnPlayer(client);
    }
    return Plugin_Handled;
}

/**
 * Respawns everybody who is dead on a team. Timer_Respawn handles the players that were
 * killed; this also covers the ones that joined a team too late to be spawned by the game.
 */
static void RespawnDeadPlayers() {
    float now = GetGameTime();
    float delay = g_hRespawnTime.FloatValue;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || !IsOnTeam(i) || IsPlayerAlive(i)) {
            continue;
        }
        if (!HasPickedClass(i) || now - g_LastDeathTime[i] < delay) {
            continue;
        }
        CS_RespawnPlayer(i);
    }
}


/***********************
 *                     *
 *       Natives       *
 *                     *
 ***********************/

public int Native_IsActive(Handle plugin, int numParams) {
    return g_Active;
}

public int Native_Start(Handle plugin, int numParams) {
    return StartWarmup(GetNativeCell(1));
}

public int Native_End(Handle plugin, int numParams) {
    return EndWarmup(WarmupEnd_Forced, GetNativeCell(1));
}


/***********************
 *                     *
 *      Commands       *
 *                     *
 ***********************/

public Action Command_Warmup(int client, int args) {
    int seconds = -1;
    if (args >= 1) {
        char buffer[16];
        GetCmdArg(1, buffer, sizeof(buffer));
        seconds = StringToInt(buffer);
        if (seconds < 0) {
            seconds = 0;
        }
    }

    if (StartWarmup(seconds)) {
        if (g_TimeLimit > 0) {
            ReplyToCommand(client, "[Warmup] Warmup started for %d seconds.", g_TimeLimit);
        } else {
            ReplyToCommand(client, "[Warmup] Warmup started with no time limit.");
        }
    } else {
        ReplyToCommand(client, "[Warmup] The warmup is disabled (sm_warmup_enabled 0).");
    }
    return Plugin_Handled;
}

public Action Command_WarmupEnd(int client, int args) {
    if (EndWarmup(WarmupEnd_Forced, true)) {
        ReplyToCommand(client, "[Warmup] Warmup ended.");
    } else {
        ReplyToCommand(client, "[Warmup] There is no warmup running.");
    }
    return Plugin_Handled;
}


/***********************
 *                     *
 *   Money and buying  *
 *                     *
 ***********************/

/**
 * Tops the client's money up to the cap, if sm_warmup_infinite_money is set.
 */
static void GiveWarmupMoney(int client) {
    if (g_hInfiniteMoney.BoolValue) {
        SetEntProp(client, Prop_Send, "m_iAccount", WARMUP_MONEY);
    }
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Active) {
        return Plugin_Continue;
    }

    // CS:S also fires player_spawn when a client enters the server, still dead and without a team.
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client) && IsOnTeam(client) && IsPlayerAlive(client)) {
        GiveWarmupMoney(client);
    }
    return Plugin_Continue;
}

/**
 * Refills the money after every purchase. The forward fires before the game takes the
 * price, so the refill is done on the next frame.
 */
public Action CS_OnBuyCommand(int client, const char[] weapon) {
    if (g_Active && g_hInfiniteMoney.BoolValue) {
        RequestFrame(Frame_RefillMoney, GetClientUserId(client));
    }
    return Plugin_Continue;
}

public void Frame_RefillMoney(int userid) {
    int client = GetClientOfUserId(userid);
    if (g_Active && client > 0 && IsClientInGame(client)) {
        GiveWarmupMoney(client);
    }
}

/**
 * sm_warmup_buy_anywhere: makes the game believe the player stands in a buy zone.
 */
public void Hook_PostThinkPost(int client) {
    if (!g_Active || !g_hBuyAnywhere.BoolValue || !IsPlayerAlive(client)) {
        return;
    }

    // Checked on a live CS:S server: CCSPlayer has m_bInBuyZone, and forcing it to 1 every think lets the player
    // open the buy menu and buy anywhere on the map (the game resets the flag on its own
    // while the player is outside of a real buy zone). Off by default.
    if (HasEntProp(client, Prop_Send, "m_bInBuyZone")) {
        SetEntProp(client, Prop_Send, "m_bInBuyZone", 1);
    }
}


/***********************
 *                     *
 *        Bomb         *
 *                     *
 ***********************/

/**
 * Removes every C4 from the game: carried, dropped and planted. There is no bomb
 * during the warmup; the game hands a new one out when it restarts after the warmup.
 */
static void RemoveBombs(const char[] when) {
    int carried = 0, loose = 0, planted = 0;
    char classname[32];
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client)) {
            continue;
        }

        int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
        for (int i = 0; i < size; i++) {
            int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
            if (weapon > MaxClients && IsValidEntity(weapon)
                && GetEntityClassname(weapon, classname, sizeof(classname))
                && StrEqual(classname, "weapon_c4")) {
                DebugLog("bomb: taking the C4 from %L (%s)", client, when);
                RemovePlayerItem(client, weapon);
                AcceptEntityInput(weapon, "Kill");
                carried++;
            }
        }
    }

    // A carried C4 was detached above and is found here once more: only the ones that
    // still have no owner count as lying on the ground.
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "weapon_c4")) != -1) {
        AcceptEntityInput(entity, "Kill");
        loose++;
    }
    loose = (loose > carried) ? loose - carried : 0;

    // Checked on a live CS:S server: removing a planted bomb (planted_c4) mid-round does not confuse the game
    // or the bots; the next game restart clears the "bomb planted" state anyway.
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "planted_c4")) != -1) {
        AcceptEntityInput(entity, "Kill");
        planted++;
    }

    if (carried > 0 || loose > 0 || planted > 0) {
        DebugLog("bomb: removed at %s - carried: %d, on the ground: %d, planted: %d",
                 when, carried, loose, planted);
    }
}

public Action Timer_RemoveBombs(Handle timer) {
    if (g_Active) {
        RemoveBombs("round start");
    }
    return Plugin_Handled;
}

/**
 * Nobody can take a C4 during the warmup. Removing the bombs at the warmup start and at
 * every round start was not enough: on a live server the game kept handing a C4 to the
 * terrorist bots while they joined the server one by one, and they planted it.
 */
public Action Hook_WeaponCanUse(int client, int weapon) {
    if (!g_Active || !IsValidEntity(weapon)) {
        return Plugin_Continue;
    }

    char classname[32];
    if (!GetEntityClassname(weapon, classname, sizeof(classname))
        || !StrEqual(classname, "weapon_c4")) {
        return Plugin_Continue;
    }

    // Checked on a live CS:S server: refusing the C4 here and removing the refused entity keeps the bomb out
    // of the warmup whichever way the game hands it out (round restart, late spawn).
    DebugLog("bomb: refused the C4 for %L and removed it", client);
    AcceptEntityInput(weapon, "Kill");
    return Plugin_Handled;
}


/***********************
 *                     *
 *    Team switching   *
 *                     *
 ***********************/

/**
 * Lets players change sides freely during the warmup. The game allows one team change
 * per round and the warmup is a single endless round, so a T <-> CT switch is done here
 * instead: the player is moved, given a model of the new team and respawned.
 * Joining from spectators and leaving to spectators is left to the game.
 */
public Action Command_JoinTeam(int client, const char[] command, int argc) {
    if (!g_Active || argc < 1 || client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) {
        return Plugin_Continue;
    }

    char arg[4];
    GetCmdArg(1, arg, sizeof(arg));
    int teamTo = StringToInt(arg);
    int teamFrom = GetClientTeam(client);

    bool switchingSides = (teamFrom == CS_TEAM_T && teamTo == CS_TEAM_CT)
        || (teamFrom == CS_TEAM_CT && teamTo == CS_TEAM_T);
    if (!switchingSides) {
        return Plugin_Continue;
    }

    CS_SwitchTeam(client, teamTo);

    // Checked on a live CS:S server: a player switching sides in the warmup gets a model of the new team
    // and is respawned without being shown the model menu.
    int class = GetEntProp(client, Prop_Send, "m_iClass");
    if (teamTo == CS_TEAM_T && (class < CSS_FIRST_T_CLASS || class > CSS_LAST_T_CLASS)) {
        SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_T_CLASS, CSS_LAST_T_CLASS));
    } else if (teamTo == CS_TEAM_CT && (class < CSS_FIRST_CT_CLASS || class > CSS_LAST_CT_CLASS)) {
        SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_CT_CLASS, CSS_LAST_CT_CLASS));
    }

    CS_UpdateClientModel(client);
    CS_RespawnPlayer(client);
    return Plugin_Handled;
}
