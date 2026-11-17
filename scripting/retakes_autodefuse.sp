#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include "include/retakes.inc"

#pragma semicolon 1
#pragma newdecls required

/**
 * Retakes autodefuse for Counter-Strike: Source.
 *
 * When a CT starts defusing the bomb while no terrorist is alive and the bomb would not
 * explode before the end of that defuse, the defuse is finished at once: nobody is left
 * to stop it, so the wait decides nothing. The defuse kit counts: the time a defuse needs
 * is the game's own (5 s with a kit, 10 s without), so a CT without a kit that would be
 * late is not helped, while one with a kit in the same second is.
 *
 * The bomb is defused by the game's own code, not by the plugin: the plugin only moves
 * the moment at which the running defuse is complete (m_flDefuseCountDown of the planted
 * bomb) to "now". The game then ends the defuse on the bomb's next think: the
 * bomb_defused event, the sound, the round end and the points of Retakes - all as after
 * a defuse that was waited out.
 */

#define AUTODEFUSE_VERSION "0.1.0"

#define DEFUSE_TIME 10.0     // seconds a defuse takes without a kit
#define DEFUSE_TIME_KIT 5.0  // and with one

/** ConVars **/
ConVar g_hEnabled;

public Plugin myinfo = {
    name = "CS:S Retakes: autodefuse",
    author = "Kolka2",
    description = "Finishes a defuse at once when no terrorist is alive and the bomb timer allows the defuse",
    version = AUTODEFUSE_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "The retakes autodefuse only supports Counter-Strike: Source");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart() {
    g_hEnabled = CreateConVar("sm_retakes_autodefuse_enabled", "0", "Whether a defuse is finished at once when no terrorist is alive and the bomb would not explode before the end of that defuse", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "retakes_autodefuse", "sourcemod/retakes");

    CreateConVar("sm_retakes_autodefuse_version", AUTODEFUSE_VERSION, "Current retakes autodefuse version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    HookEvent("bomb_begindefuse", Event_BombBeginDefuse);
}

/**
 * Writes a line to logs/retakes_autodefuse_debug.log when sm_retakes_debug (the cvar of
 * the Retakes core) is set.
 */
static void AutodefuseDebug(const char[] format, any ...) {
    static ConVar debugCvar;
    if (debugCvar == null) {
        debugCvar = FindConVar("sm_retakes_debug");
    }
    if (debugCvar == null || !debugCvar.BoolValue) {
        return;
    }

    char text[256];
    VFormat(text, sizeof(text), format, 2);
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "logs/retakes_autodefuse_debug.log");
    LogToFileEx(path, "%s", text);
}

static bool IsActive() {
    return g_hEnabled.BoolValue && Retakes_Enabled() && !Retakes_InWarmup() && !Retakes_InEditMode();
}

/**
 * Returns the number of terrorists that are alive.
 */
static int CountAliveTerrorists() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == CS_TEAM_T) {
            count++;
        }
    }
    return count;
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

/**
 * A CT has started defusing. The game may fire the event before it has set up the defuse
 * (its length and the moment it is complete), so the check is made on the next frame.
 */
public void Event_BombBeginDefuse(Event event, const char[] name, bool dontBroadcast) {
    if (!IsActive()) {
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(event.GetInt("userid"));
    pack.WriteCell(event.GetBool("haskit"));
    RequestFrame(Frame_CheckDefuse, pack);
}

public void Frame_CheckDefuse(DataPack pack) {
    pack.Reset();
    int client = GetClientOfUserId(pack.ReadCell());
    bool hasKit = pack.ReadCell();
    delete pack;

    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client) || !IsActive()) {
        return;
    }

    int terrorists = CountAliveTerrorists();
    if (terrorists > 0) {
        AutodefuseDebug("%L started defusing, %d terrorist(s) alive: left to the game", client, terrorists);
        return;
    }

    int bomb = FindTickingBomb();
    if (bomb == -1) {
        AutodefuseDebug("%L started defusing, but no ticking planted_c4 was found", client);
        return;
    }

    // The planted bomb has m_flC4Blow (the game time of the explosion), m_flDefuseLength
    // (the length of the running defuse, 5 s with a kit and 10 s without) and
    // m_flDefuseCountDown (the game time at which the running defuse is complete), and the
    // game ends the defuse on the bomb's next think once m_flDefuseCountDown is in the past
    // (checked on a live CS:S server with bots). Without the first and the last of them
    // the plugin does nothing.
    if (!HasEntProp(bomb, Prop_Send, "m_flC4Blow") || !HasEntProp(bomb, Prop_Send, "m_flDefuseCountDown")) {
        AutodefuseDebug("the planted_c4 has no m_flC4Blow or m_flDefuseCountDown, nothing can be done");
        return;
    }

    float now = GetGameTime();
    float countDown = GetEntPropFloat(bomb, Prop_Send, "m_flDefuseCountDown");
    if (countDown <= now) {
        // No defuse is running any more: the CT has let go of the bomb within this frame.
        AutodefuseDebug("%L started defusing, but the defuse is not running any more", client);
        return;
    }

    // The time this defuse needs is taken from the game. The kit flag of the event and of
    // the player is the fallback if the game does not tell.
    float defuseTime = 0.0;
    if (HasEntProp(bomb, Prop_Send, "m_flDefuseLength")) {
        defuseTime = GetEntPropFloat(bomb, Prop_Send, "m_flDefuseLength");
    }
    if (defuseTime <= 0.0) {
        if (!hasKit) {
            hasKit = GetEntProp(client, Prop_Send, "m_bHasDefuser") != 0;
        }
        defuseTime = hasKit ? DEFUSE_TIME_KIT : DEFUSE_TIME;
    }

    float timeLeft = GetEntPropFloat(bomb, Prop_Send, "m_flC4Blow") - now;
    if (timeLeft <= defuseTime) {
        AutodefuseDebug("%L started defusing (%.0f s%s), no terrorists alive, but the bomb explodes in %.2f s: left to the game",
                        client, defuseTime, hasKit ? ", kit" : "", timeLeft);
        return;
    }

    SetEntPropFloat(bomb, Prop_Send, "m_flDefuseCountDown", now);
    AutodefuseDebug("%L started defusing (%.0f s%s), no terrorists alive, the bomb explodes in %.2f s: the defuse is finished at once",
                    client, defuseTime, hasKit ? ", kit" : "", timeLeft);
}
