#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include "include/retakes.inc"

#pragma semicolon 1
#pragma newdecls required

/**
 * Retakes autoplant for Counter-Strike: Source.
 *
 * Plants the bomb for the bomb carrier at the end of the freezetime, right where the
 * carrier stands.
 *
 * The bomb is planted by the game's own code, not by the plugin: a planted_c4 entity
 * created by name would be dead in CS:S (its timer and think function are only set by
 * CPlantedC4::Init, which cannot be reached without gamedata). Instead the plugin holds
 * the attack button for the carrier with the C4 in the hands and, once the game has
 * started arming the bomb, moves the weapon's arming deadline to "now". The game then
 * finishes the plant itself: the real planted bomb, the bomb_planted event, the sounds,
 * the bots' knowledge of the bomb - all as after a plant by hand.
 */

#define AUTOPLANT_VERSION "0.1.0"

#define START_DELAY 0.2     // seconds after round_freeze_end; Retakes hands the C4 out 0.1 s after round_start
#define GIVE_UP_TIME 5.0    // seconds to keep trying before the carrier is left alone

/** ConVars **/
ConVar g_hEnabled;

/** Round state **/
bool g_Pending;             // the bomb of this round still has to be planted by the plugin
float g_FreezeEndTime;
float g_StartTime;
float g_GiveUpTime;
int g_LoggedCarrier;        // the carrier the "started" line was written for
bool g_LoggedArming;
bool g_LoggedNotInZone;

public Plugin myinfo = {
    name = "CS:S Retakes: autoplant",
    author = "retakes-css port",
    description = "Plants the bomb for the bomb carrier at the end of the freezetime",
    version = AUTOPLANT_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "The retakes autoplant only supports Counter-Strike: Source");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart() {
    g_hEnabled = CreateConVar("sm_retakes_autoplant_enabled", "1", "Whether the bomb is planted for the bomb carrier at the end of the freezetime", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "retakes_autoplant", "sourcemod/retakes");

    CreateConVar("sm_retakes_autoplant_version", AUTOPLANT_VERSION, "Current retakes autoplant version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("bomb_planted", Event_BombPlanted);
}

public void OnMapStart() {
    g_Pending = false;
    g_FreezeEndTime = 0.0;
}

/**
 * Writes a line to logs/retakes_autoplant_debug.log when sm_retakes_debug (the cvar of
 * the Retakes core) is set.
 */
static void AutoplantDebug(const char[] format, any ...) {
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
    BuildPath(Path_SM, path, sizeof(path), "logs/retakes_autoplant_debug.log");
    LogToFileEx(path, "%s", text);
}

/**
 * Returns the weapon_c4 entity carried by a client, or -1.
 */
static int GetClientC4(int client) {
    char classname[32];
    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon > MaxClients && IsValidEntity(weapon)
            && GetEntityClassname(weapon, classname, sizeof(classname))
            && StrEqual(classname, "weapon_c4")) {
            return weapon;
        }
    }
    return -1;
}

/*************************
 *                       *
 *     Round events      *
 *                       *
 *************************/

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    // A game restart in the middle of an attempt: the bomb must not be planted during
    // the freezetime of the new round. With mp_freezetime 0 round_freeze_end comes at
    // the same moment as round_start (in either order), and that attempt is kept.
    if (g_Pending && GetGameTime() - g_FreezeEndTime > 0.5) {
        AutoplantDebug("round_start in the middle of an attempt, the attempt is dropped");
        g_Pending = false;
    }
}

public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast) {
    g_Pending = false;

    if (!g_hEnabled.BoolValue || !Retakes_Enabled() || Retakes_InWarmup() || Retakes_InEditMode()) {
        return;
    }

    g_Pending = true;
    g_FreezeEndTime = GetGameTime();
    g_StartTime = g_FreezeEndTime + START_DELAY;
    g_GiveUpTime = g_StartTime + GIVE_UP_TIME;
    g_LoggedCarrier = -1;
    g_LoggedArming = false;
    g_LoggedNotInZone = false;
    AutoplantDebug("round_freeze_end: looking for the bomb carrier");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (g_Pending) {
        AutoplantDebug("round_end before the bomb was planted");
    }
    g_Pending = false;
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast) {
    if (g_Pending) {
        AutoplantDebug("bomb_planted by %L, %.2f s after round_freeze_end",
                       GetClientOfUserId(event.GetInt("userid")), GetGameTime() - g_FreezeEndTime);
    }
    g_Pending = false;
}

/*************************
 *                       *
 *      The plant        *
 *                       *
 *************************/

/**
 * Drives the bomb carrier's user commands until the bomb is planted: pulls out the C4,
 * holds the attack button, keeps the carrier in place and cuts the arming time short.
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (!g_Pending) {
        return Plugin_Continue;
    }

    float now = GetGameTime();
    if (now < g_StartTime) {
        return Plugin_Continue;
    }
    if (now > g_GiveUpTime) {
        AutoplantDebug("giving up: the bomb was not planted in %.1f s", GIVE_UP_TIME);
        g_Pending = false;
        return Plugin_Continue;
    }

    if (!IsPlayerAlive(client) || GetClientTeam(client) != CS_TEAM_T) {
        return Plugin_Continue;
    }
    int c4 = GetClientC4(client);
    if (c4 == -1) {
        return Plugin_Continue;
    }

    if (g_LoggedCarrier != client) {
        g_LoggedCarrier = client;
        AutoplantDebug("the bomb carrier is %L", client);
    }

    // Outside of a bomb target the game would only print "C4 must be planted at a bomb
    // site" every second. The carrier is left alone: Retakes spawns it inside the bomb
    // target, so this is a spawn that was set up wrong or a carrier that has moved.
    if (HasEntProp(client, Prop_Send, "m_bInBombZone") && !GetEntProp(client, Prop_Send, "m_bInBombZone")) {
        if (!g_LoggedNotInZone) {
            g_LoggedNotInZone = true;
            AutoplantDebug("%L is not inside a bomb target, waiting", client);
        }
        return Plugin_Continue;
    }

    // From here on the carrier stays where it is: the game aborts the plant when the
    // player leaves the ground or the bomb target.
    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    buttons &= ~IN_JUMP;

    if (!(GetEntityFlags(client) & FL_ONGROUND)) {
        return Plugin_Changed;
    }

    // The weapon-select field of the user command switches a bot to the C4 as it does
    // for a human (checked on a live CS:S server).
    if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != c4) {
        weapon = c4;
        return Plugin_Changed;
    }

    // The weapon code does not run until the draw animation of the C4 is over
    // (m_flNextAttack of the player); moving that time to "now" skips the wait.
    // Checked on a live CS:S server: a bot plants 0.28 s after the freezetime.
    if (HasEntProp(client, Prop_Send, "m_flNextAttack")
        && GetEntPropFloat(client, Prop_Send, "m_flNextAttack") > now) {
        SetEntPropFloat(client, Prop_Send, "m_flNextAttack", now);
    }

    // With the attack button held in the user command the game starts arming the C4
    // (m_bStartedArming) and plants the bomb once the game time has reached
    // m_fArmedTime, for bots and humans alike (checked on a live CS:S server). Should
    // the two properties be missing, the button alone still plants the bomb, in the
    // usual 3 seconds.
    buttons |= IN_ATTACK;

    if (HasEntProp(c4, Prop_Send, "m_bStartedArming") && HasEntProp(c4, Prop_Send, "m_fArmedTime")
        && GetEntProp(c4, Prop_Send, "m_bStartedArming")) {
        if (!g_LoggedArming) {
            g_LoggedArming = true;
            AutoplantDebug("the game is arming the C4 of %L, cutting the arming time", client);
        }
        if (GetEntPropFloat(c4, Prop_Send, "m_fArmedTime") > now) {
            SetEntPropFloat(c4, Prop_Send, "m_fArmedTime", now);
        }
    }

    return Plugin_Changed;
}
