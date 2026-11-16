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
 * carrier stands. During the freezetime a human carrier sees a progress bar that fills
 * up by the moment of the plant, and in its last seconds the keypad clicks of a bomb
 * being armed are played at the carrier.
 *
 * The bomb is planted by the game's own code, not by the plugin: a planted_c4 entity
 * created by name would be dead in CS:S (its timer and think function are only set by
 * CPlantedC4::Init, which cannot be reached without gamedata). Instead the plugin holds
 * the attack button for the carrier with the C4 in the hands and, once the game has
 * started arming the bomb, moves the weapon's arming deadline to "now". The game then
 * finishes the plant itself: the real planted bomb, the bomb_planted event, the sounds,
 * the bots' knowledge of the bomb - all as after a plant by hand.
 *
 * The plant is not stretched over the freezetime to show the arming animation. That was
 * tried on a live server: the client predicts the C4 without the attack button, so the
 * carrier only saw the last second of the animation, and the game does not let bots arm
 * the C4 during the freezetime at all.
 */

#define AUTOPLANT_VERSION "0.5.0"

#define START_DELAY 0.2     // seconds after round_start to stay away; Retakes hands the C4 out 0.1 s after it
#define GIVE_UP_TIME 5.0    // seconds after the planned plant before the carrier is left alone
#define MIN_BAR_TIME 0.5    // a progress bar shorter than this is not worth showing
#define MAX_BAR_TIME 15     // m_iProgressBarDuration is 4 bits wide
#define ARM_TIME 3.0        // seconds the game takes to arm the C4 (WEAPON_C4_ARM_TIME)
#define PLACE_ANIM_TIME 0.75 // seconds before the plant at which the game plays the "putting the bomb down" animation
#define CLICK_SOUND "c4.click"

// When the game plays the keypad clicks, in seconds from the start of the arming: frames
// 27, 37, 45, 51, 57, 63 and 67 of the 83 frames the arming animation plays in 2.25 s
// (CC4::PlayArmingBeeps).
static const float g_ClickTimes[] = { 0.73, 1.00, 1.22, 1.38, 1.55, 1.71, 1.82 };

/** ConVars **/
ConVar g_hEnabled;
ConVar g_hProgressBar;
ConVar g_hSound;
ConVar g_hFreezeTime;

/** Round state **/
bool g_Pending;             // the bomb of this round still has to be planted by the plugin
float g_StartTime;          // when the carrier starts arming the C4
float g_PlantTime;          // when the bomb is to be planted
float g_GiveUpTime;
float g_BarTime;            // when the carrier may be looked for (the C4 is handed out by then)
int g_Carrier;              // the bomb carrier found during the freezetime, or 0
int g_BarClient;            // the human carrier that sees the progress bar, or 0
int g_NextClick = sizeof(g_ClickTimes); // index of the next keypad click in g_ClickTimes
float g_FirstClickTime;     // game time of the first keypad click
bool g_ClickFailed;         // the "no such sound" line is in the log
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

    g_hProgressBar = CreateConVar("sm_retakes_autoplant_progressbar", "1", "Whether a human bomb carrier sees a progress bar during the freezetime that fills up by the moment the bomb is planted", _, true, 0.0, true, 1.0);

    g_hSound = CreateConVar("sm_retakes_autoplant_sound", "1", "Whether the keypad clicks of a bomb being armed are played at the bomb carrier in the last seconds of the freezetime", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "retakes_autoplant", "sourcemod/retakes");

    g_hFreezeTime = FindConVar("mp_freezetime");

    CreateConVar("sm_retakes_autoplant_version", AUTOPLANT_VERSION, "Current retakes autoplant version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("bomb_planted", Event_BombPlanted);
}

public void OnMapStart() {
    g_Pending = false;
    g_Carrier = 0;
    g_BarClient = 0;
    g_NextClick = sizeof(g_ClickTimes);
    g_ClickFailed = false;
    PrecacheScriptSound(CLICK_SOUND);
}

public void OnClientDisconnect(int client) {
    if (client == g_BarClient) {
        g_BarClient = 0;
    }
    if (client == g_Carrier) {
        g_Carrier = 0;
    }
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

static bool IsActive() {
    return g_hEnabled.BoolValue && Retakes_Enabled() && !Retakes_InWarmup() && !Retakes_InEditMode();
}

/**
 * Starts the attempt of the round: the bomb is to be planted at plantTime.
 */
static void StartAttempt(float plantTime) {
    g_Pending = true;
    g_StartTime = plantTime;
    g_PlantTime = plantTime;
    g_GiveUpTime = plantTime + GIVE_UP_TIME;
    g_BarTime = GetGameTime() + START_DELAY;
    g_Carrier = 0;
    g_NextClick = sizeof(g_ClickTimes);
    g_LoggedCarrier = -1;
    g_LoggedArming = false;
    g_LoggedNotInZone = false;
}

/**
 * Shows the game's own progress bar (the one of the defuse) to a client: it started
 * filling up at startTime and is full after `seconds`.
 */
static void ShowProgressBar(int client, int seconds, float startTime) {
    // CS:S has the m_iProgressBarDuration / m_flProgressBarStartTime properties and its
    // HUD draws the bar from them for a player that is not defusing; the bar is full at
    // startTime + seconds (checked on a live CS:S server). Without the properties the
    // older BarTime user message is tried.
    if (HasEntProp(client, Prop_Send, "m_iProgressBarDuration")) {
        if (HasEntProp(client, Prop_Send, "m_flProgressBarStartTime")) {
            SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", startTime);
        }
        SetEntProp(client, Prop_Send, "m_iProgressBarDuration", seconds);
        return;
    }

    if (GetUserMessageId("BarTime") != INVALID_MESSAGE_ID) {
        Handle message = StartMessageOne("BarTime", client);
        if (message != null) {
            BfWriteShort(message, seconds);
            EndMessage();
        }
    }
}

/**
 * Takes the progress bar away from the carrier that was shown one.
 */
static void HideProgressBar() {
    int client = g_BarClient;
    g_BarClient = 0;
    if (client > 0 && IsClientInGame(client)) {
        ShowProgressBar(client, 0, 0.0);
    }
}

/**
 * Plans the plant of the round for the end of the freezetime. A round_start in the
 * middle of an attempt (a game restart) replaces that attempt, so the bomb is never
 * planted early in the new round.
 */
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_Pending = false;
    HideProgressBar();
    if (!IsActive()) {
        return;
    }

    float now = GetGameTime();
    float freezeTime = (g_hFreezeTime != null) ? g_hFreezeTime.FloatValue : 0.0;

    float plantTime = now + freezeTime;
    if (plantTime < now + START_DELAY) {
        plantTime = now + START_DELAY;
    }

    StartAttempt(plantTime);
    AutoplantDebug("round_start: freezetime %.1f s, the plant is due in %.2f s", freezeTime, plantTime - now);
}

/**
 * The freezetime is over: whatever was planned, the bomb is due now.
 */
public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast) {
    float now = GetGameTime();

    if (!g_Pending) {
        // Either the bomb is planted already, or no round_start was seen for this round
        // (e.g. the plugin was loaded during the freezetime).
        if (IsActive() && FindEntityByClassname(-1, "planted_c4") == -1) {
            StartAttempt(now + START_DELAY);
            AutoplantDebug("round_freeze_end without a planned plant, planting now");
        }
        return;
    }

    AutoplantDebug("round_freeze_end (the plant was due in %.2f s)", g_PlantTime - now);
    if (g_PlantTime > now) {
        g_PlantTime = now;
    }
    if (g_StartTime > now) {
        g_StartTime = now;
    }
    g_GiveUpTime = now + GIVE_UP_TIME;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (g_Pending) {
        AutoplantDebug("round_end before the bomb was planted");
    }
    g_Pending = false;
    g_NextClick = sizeof(g_ClickTimes);
    HideProgressBar();
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast) {
    if (g_Pending) {
        AutoplantDebug("bomb_planted by %L, %.2f s after the planned moment",
                       GetClientOfUserId(event.GetInt("userid")), GetGameTime() - g_PlantTime);
    }
    g_Pending = false;
    HideProgressBar();
}

/*************************
 *                       *
 *      The plant        *
 *                       *
 *************************/

/**
 * Plays the keypad clicks at the carrier. All of them are always played, with the game's
 * own gaps between them: with a short freezetime the last ones fall into the live round,
 * after the bomb is planted. Like the game's clicks they are heard around the carrier.
 */
public void OnGameFrame() {
    if (g_NextClick >= sizeof(g_ClickTimes)
        || GetGameTime() < g_FirstClickTime + g_ClickTimes[g_NextClick] - g_ClickTimes[0]) {
        return;
    }

    if (g_Carrier == 0 || !IsClientInGame(g_Carrier) || !g_hSound.BoolValue) {
        g_NextClick = sizeof(g_ClickTimes);
        return;
    }

    g_NextClick++;
    // The c4.click game sound is heard by the carrier and around (checked on a live CS:S
    // server).
    if (!EmitGameSoundToAll(CLICK_SOUND, g_Carrier) && !g_ClickFailed) {
        g_ClickFailed = true;
        AutoplantDebug("the game sound %s was not found, no keypad clicks", CLICK_SOUND);
    }
}

/**
 * What the carrier gets during the freezetime instead of the arming animation: a progress
 * bar (humans only) and the keypad clicks. Called for every user command before the plant.
 */
static void FreezeTimeEffects(int client, float now) {
    if (now < g_BarTime) {
        return;
    }

    if (g_Carrier == 0) {
        if (!IsPlayerAlive(client) || GetClientTeam(client) != CS_TEAM_T || GetClientC4(client) == -1) {
            return;
        }
        g_Carrier = client;
        g_LoggedCarrier = client;
        AutoplantDebug("the bomb carrier is %L", client);

        // The clicks are laid out as if the carrier had started arming the C4 three
        // seconds before the planned plant. If that moment is already in the past (a
        // short freezetime), they start right away. No clicks if not even the first
        // one would be heard before the plant.
        g_FirstClickTime = g_PlantTime - ARM_TIME + g_ClickTimes[0];
        if (g_FirstClickTime < now) {
            g_FirstClickTime = now;
        }
        if (g_hSound.BoolValue && g_FirstClickTime < g_PlantTime) {
            g_NextClick = 0;
            AutoplantDebug("keypad clicks start in %.2f s, the plant is due in %.2f s",
                           g_FirstClickTime - now, g_PlantTime - now);
        }
    }

    if (client != g_Carrier || !IsPlayerAlive(client)) {
        return;
    }

    // The bar is full at the planned moment of the plant. It counts whole seconds, so
    // its start is moved back to make the end fall on that moment.
    float left = g_PlantTime - now;
    if (g_BarClient == 0 && g_hProgressBar.BoolValue && !IsFakeClient(client)
        && left >= MIN_BAR_TIME && RoundToCeil(left) <= MAX_BAR_TIME) {
        int seconds = RoundToCeil(left);
        g_BarClient = client;
        ShowProgressBar(client, seconds, g_PlantTime - float(seconds));
        AutoplantDebug("progress bar of %d s shown to %L, the plant is due in %.2f s", seconds, client, left);
    }
}

/**
 * Drives the bomb carrier's user commands until the bomb is planted: pulls out the C4,
 * holds the attack button, keeps the carrier in place and cuts the arming time short.
 *
 * A human carrier starts PLACE_ANIM_TIME before the planned moment: the game then plays
 * the "putting the bomb down" animation of the view model, the one part of the arming
 * animation the client does not throw away (seen on a live CS:S server). Bots start at
 * the planned moment: the game does not let them arm the C4 during the freezetime.
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (!g_Pending) {
        return Plugin_Continue;
    }

    float now = GetGameTime();
    FreezeTimeEffects(client, now);

    float startTime = g_StartTime;
    if (!IsFakeClient(client)) {
        startTime -= PLACE_ANIM_TIME;
        if (startTime < g_BarTime) {
            startTime = g_BarTime;
        }
    }
    if (now < startTime) {
        return Plugin_Continue;
    }
    if (now > g_GiveUpTime) {
        AutoplantDebug("giving up: the bomb was not planted %.1f s after the planned moment", GIVE_UP_TIME);
        g_Pending = false;
        HideProgressBar();
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
    //
    // CSS-VERIFY: with the deadline less than 0.75 s away the game plays the "putting
    // the bomb down" animation for a human carrier, and from the outside the short
    // arming does not look like rapid fire (the 3 s one did).
    buttons |= IN_ATTACK;

    if (HasEntProp(c4, Prop_Send, "m_bStartedArming") && HasEntProp(c4, Prop_Send, "m_fArmedTime")
        && GetEntProp(c4, Prop_Send, "m_bStartedArming")) {
        // The game has set the deadline to 3 seconds from the start of the arming. It
        // is only ever moved closer: to the planned moment, or to "now" once that
        // moment has passed.
        float deadline = (g_PlantTime > now) ? g_PlantTime : now;
        if (!g_LoggedArming) {
            g_LoggedArming = true;
            AutoplantDebug("the game is arming the C4 of %L, the bomb will be planted in %.2f s", client, deadline - now);
        }
        if (GetEntPropFloat(c4, Prop_Send, "m_fArmedTime") > deadline) {
            SetEntPropFloat(c4, Prop_Send, "m_fArmedTime", deadline);
        }
    }

    return Plugin_Changed;
}
