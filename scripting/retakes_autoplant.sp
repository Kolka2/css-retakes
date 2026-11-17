#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
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
 * the C4 during the freezetime at all. Starting 0.75 s early for the "putting the bomb
 * down" animation alone did not work either: the view model just disappeared, and an
 * attempt in the first 0.3 s of a round was refused by the game and followed by a second
 * in which the C4 could not be armed.
 *
 * The planting animation of the player model (crouching and putting the bomb down) is a
 * different thing: the game sends it to the other players as a temp entity when the
 * arming starts (FX_PlantBomb), and the clients play it to the end even though the bomb
 * is planted a tick later. Left alone, it would play in the live round. So the plugin
 * holds back the game's temp entity of its own plant and sends the same temp entity
 * itself, PLANT_ANIM_TIME before the end of the freezetime, with the carrier holding the
 * C4 (the clients pick the animation by the weapon in the hands). If that cannot be done
 * before the plant, there is no animation at all.
 */

#define AUTOPLANT_VERSION "1.1.3"

#define START_DELAY 0.2     // seconds after round_start to stay away; Retakes hands the C4 out 0.1 s after it
#define GIVE_UP_TIME 5.0    // seconds after the planned plant before the carrier is left alone
#define MIN_BAR_TIME 0.5    // a progress bar shorter than this is not worth showing
#define MAX_BAR_TIME 15     // m_iProgressBarDuration is 4 bits wide
#define ARM_TIME 3.0        // seconds the game takes to arm the C4 (WEAPON_C4_ARM_TIME)
#define DRAW_LEAD_TIME 1.0  // seconds before the plant at which a human carrier is switched to the C4
#define CLICK_SOUND "c4.click"

// The temp entity is in sm_print_telist of a live CS:S server (CTEPlantBomb). Checked on
// a live CS:S server: the plugin's one plays the planting animation on the carrier, and
// sent 2.8 s ahead it ends as the round starts (3.0 s ahead it ended a little early).
#define PLANT_TE "Bomb Plant"   // temp entity the game sends when the arming starts (TE_PlantBomb)
#define PLANT_ANIM_TIME 2.8     // seconds before the plant at which the planting animation is sent
#define ANIM_DRAW_LEAD 0.5      // seconds before the animation at which the carrier is switched to the C4

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
float g_PlantTime;          // when the bomb is to be planted
float g_GiveUpTime;
float g_SearchTime;         // when the carrier may be looked for (the C4 is handed out by then)
int g_Carrier;              // the bomb carrier found during the freezetime, or 0
int g_BarClient;            // the human carrier that sees the progress bar, or 0
int g_BarSeconds;           // length of that bar
float g_BarStartTime;       // game time at which that bar is empty
bool g_LoggedBarRestore;
int g_NextClick = sizeof(g_ClickTimes); // index of the next keypad click in g_ClickTimes
float g_FirstClickTime;     // game time of the first keypad click
bool g_ClickFailed;         // the "no such sound" line is in the log
int g_LoggedCarrier;        // the carrier the "started" line was written for
bool g_LoggedArming;
bool g_LoggedNotInZone;
bool g_LoggedDraw;

/** Planting animation **/
bool g_PlantTEHooked;       // the planting temp entity is hooked, the plugin sends the animation itself
bool g_SendingPlantTE;      // the temp entity being sent is the plugin's own
bool g_AnimSent;            // the planting animation of this round is sent
bool g_LoggedAnimHeldBack;
bool g_LoggedSwitchRefused;
int g_LoggedAnimEvents;     // debug lines about the carrier's other animation temp entities this round

#define MAX_LOGGED_ANIM_EVENTS 10

public Plugin myinfo = {
    name = "CS:S Retakes: autoplant",
    author = "Kolka2",
    description = "Plants the bomb for the bomb carrier at the end of the freezetime",
    version = AUTOPLANT_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "The retakes autoplant only supports Counter-Strike: Source");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart() {
    g_hEnabled = CreateConVar("sm_retakes_autoplant_enabled", "0","Whether the bomb is planted for the bomb carrier at the end of the freezetime", _, true, 0.0, true, 1.0);

    g_hProgressBar = CreateConVar("sm_retakes_autoplant_progressbar", "1", "Whether a human bomb carrier sees a progress bar during the freezetime that fills up by the moment the bomb is planted", _, true, 0.0, true, 1.0);

    g_hSound = CreateConVar("sm_retakes_autoplant_sound", "1", "Whether the keypad clicks of a bomb being armed are played at the bomb carrier in the last seconds of the freezetime", _, true, 0.0, true, 1.0);

    AutoExecConfig(true, "retakes_autoplant", "sourcemod/retakes");

    g_hFreezeTime = FindConVar("mp_freezetime");

    CreateConVar("sm_retakes_autoplant_version", AUTOPLANT_VERSION, "Current retakes autoplant version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("bomb_planted", Event_BombPlanted);

    // AddTempEntHook throws on an unknown name. Called through Call_Finish, that error
    // only ends HookPlantTempEnt: the plugin still loads, without the animation of its own
    // and with the game's animation after the plant, as before.
    Call_StartFunction(null, HookPlantTempEnt);
    if (Call_Finish() != SP_ERROR_NONE || !g_PlantTEHooked) {
        g_PlantTEHooked = false;
        LogError("The temp entity \"%s\" was not found: the planting animation plays after the plant", PLANT_TE);
    }

    // Debug only: what else the clients are told to animate on the carrier while the
    // plugin plants (both names are in sm_print_telist of a live CS:S server).
    AddTempEntHook("PlayerAnimEvent", OnDebugTempEnt);
    AddTempEntHook("Shotgun Shot", OnDebugTempEnt);

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i)) {
            OnClientPutInServer(i);
        }
    }
}

public void OnClientPutInServer(int client) {
    SDKHook(client, SDKHook_WeaponSwitch, Hook_WeaponSwitch);
}

public void HookPlantTempEnt() {
    AddTempEntHook(PLANT_TE, OnPlantTempEnt);
    g_PlantTEHooked = true;
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
    g_PlantTime = plantTime;
    g_GiveUpTime = plantTime + GIVE_UP_TIME;
    g_SearchTime = GetGameTime() + START_DELAY;
    g_Carrier = 0;
    g_NextClick = sizeof(g_ClickTimes);
    g_LoggedCarrier = -1;
    g_LoggedArming = false;
    g_LoggedNotInZone = false;
    g_LoggedDraw = false;
    g_AnimSent = false;
    g_LoggedAnimHeldBack = false;
    g_LoggedSwitchRefused = false;
    g_LoggedAnimEvents = 0;
}

/**
 * Shows the game's own progress bar (the one of the defuse) to a client: it started
 * filling up at startTime and is full after `seconds`.
 */
static void ShowProgressBar(int client, int seconds, float startTime) {
    // The HUD of CS:S draws the bar from these two properties for a player that is not
    // defusing; the bar is full at startTime + seconds (checked on a live CS:S server).
    SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", startTime);
    SetEntProp(client, Prop_Send, "m_iProgressBarDuration", seconds);
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
    // The game drops the fraction of mp_freezetime: with 1.5 the freezetime lasts one
    // second (seen on a live CS:S server).
    float freezeTime = (g_hFreezeTime != null) ? float(g_hFreezeTime.IntValue) : 0.0;

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
 * bar (humans only) and the keypad clicks. Called for every user command until the bomb
 * is planted.
 */
static void CarrierEffects(int client, float now) {
    if (now < g_SearchTime) {
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
        g_BarSeconds = seconds;
        g_BarStartTime = g_PlantTime - float(seconds);
        g_LoggedBarRestore = false;
        ShowProgressBar(client, seconds, g_BarStartTime);
        AutoplantDebug("progress bar of %d s shown to %L, the plant is due in %.2f s", seconds, client, left);
    } else if (g_BarClient == client && left > 0.0
               && GetEntProp(client, Prop_Send, "m_iProgressBarDuration") == 0) {
        // The game clears the bar when the C4 is put away (CC4::Holster). It is put back
        // with the same start time, so it goes on from where it would have been (checked
        // on a live CS:S server).
        ShowProgressBar(client, g_BarSeconds, g_BarStartTime);
        if (!g_LoggedBarRestore) {
            g_LoggedBarRestore = true;
            AutoplantDebug("the game took the progress bar away from %L, it is put back", client);
        }
    }
}

/**
 * Holds back the game's planting animation while the plugin plants the bomb: the game
 * sends it when the arming starts, that is after the freezetime, and the clients would
 * play it in the live round. The plugin's own one (g_SendingPlantTE) goes through.
 */
public Action OnPlantTempEnt(const char[] te_name, const int[] players, int numClients, float delay) {
    if (g_SendingPlantTE || !g_Pending) {
        return Plugin_Continue;
    }
    if (!g_LoggedAnimHeldBack) {
        g_LoggedAnimHeldBack = true;
        int player = TE_IsValidProp("m_iPlayer") ? TE_ReadNum("m_iPlayer") + 1 : 0;
        if (player >= 1 && player <= MaxClients && IsClientInGame(player)) {
            AutoplantDebug("the game's planting animation of %L is held back (%s, the plugin's one was %s)",
                           player, player == g_Carrier ? "the carrier" : "NOT the carrier",
                           g_AnimSent ? "sent" : "not sent");
        } else {
            AutoplantDebug("the game's planting animation of client %d is held back (the plugin's one was %s)",
                           player, g_AnimSent ? "sent" : "not sent");
        }
    }
    return Plugin_Stop;
}

/**
 * Sends the planting animation of the carrier to everybody else, as the game does when
 * the arming starts (the carrier does not get it from the game either). The clients play
 * the animation of the weapon in the carrier's hands, so it must be the C4.
 */
static void SendPlantAnimation(int client) {
    g_AnimSent = true;

    int clients[MAXPLAYERS];
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i != client && IsClientInGame(i)) {
            clients[count++] = i;
        }
    }

    TE_Start(PLANT_TE);
    if (!TE_IsValidProp("m_iPlayer") || !TE_IsValidProp("m_vecOrigin")) {
        AutoplantDebug("the temp entity %s has no m_iPlayer or m_vecOrigin, no planting animation", PLANT_TE);
        return;
    }
    float origin[3];
    GetClientEyePosition(client, origin);
    // The game writes the client index minus one, as in "Shotgun Shot": its own planting
    // temp entity of the carrier with client index 1 had m_iPlayer 0 (seen on a live CS:S
    // server).
    TE_WriteNum("m_iPlayer", client - 1);
    TE_WriteVector("m_vecOrigin", origin);

    g_SendingPlantTE = true;
    TE_Send(clients, count);
    g_SendingPlantTE = false;

    AutoplantDebug("planting animation of %L sent to %d clients, the plant is due in %.2f s",
                   client, count, g_PlantTime - GetGameTime());
}

/**
 * Returns if the carrier is to be held with the C4 in the hands now, before the plant:
 * a second ahead for a human, and PLANT_ANIM_TIME + ANIM_DRAW_LEAD ahead for anybody
 * when the plugin sends the planting animation.
 */
static bool IsDrawTime(int client, float now) {
    float lead = DRAW_LEAD_TIME;
    if (g_PlantTEHooked) {
        lead = PLANT_ANIM_TIME + ANIM_DRAW_LEAD;
    } else if (IsFakeClient(client)) {
        return false;
    }
    return now >= g_PlantTime - lead && now < g_PlantTime;
}

/**
 * A bot switched to the C4 by the user command puts it away again at once (its own
 * weapon choice), and the two kept taking turns until the end of the freezetime (seen on
 * a live CS:S server). So while a bot carrier is to hold the C4, no other weapon may be
 * taken into its hands. Humans are not held this way: their client would predict the
 * switch and show weapons jumping.
 * CSS-VERIFY: the bot carrier keeps the C4 in the hands and does not flicker.
 */
public Action Hook_WeaponSwitch(int client, int weapon) {
    if (!g_Pending || client != g_Carrier || !IsFakeClient(client) || !IsDrawTime(client, GetGameTime())) {
        return Plugin_Continue;
    }
    int c4 = GetClientC4(client);
    if (c4 == -1 || weapon == c4) {
        return Plugin_Continue;
    }
    if (!g_LoggedSwitchRefused) {
        g_LoggedSwitchRefused = true;
        char classname[32];
        if (!IsValidEntity(weapon) || !GetEntityClassname(weapon, classname, sizeof(classname))) {
            strcopy(classname, sizeof(classname), "?");
        }
        AutoplantDebug("%L tried to take %s instead of the C4 %.2f s before the plant, refused",
                       client, classname, g_PlantTime - GetGameTime());
    }
    return Plugin_Handled;
}

/**
 * Debug only: logs the animation events (PlayerAnimEvent) and the shots (Shotgun Shot)
 * of the carrier while the plugin plants, to find out what the clients play on it.
 * Changes nothing.
 */
public Action OnDebugTempEnt(const char[] te_name, const int[] players, int numClients, float delay) {
    if (!g_Pending || g_Carrier == 0 || g_LoggedAnimEvents >= MAX_LOGGED_ANIM_EVENTS) {
        return Plugin_Continue;
    }

    int player = 0;
    int value = -1;
    if (StrEqual(te_name, "Shotgun Shot")) {
        if (TE_IsValidProp("m_iPlayer")) {
            player = TE_ReadNum("m_iPlayer") + 1;
        }
        if (TE_IsValidProp("m_iWeaponID")) {
            value = TE_ReadNum("m_iWeaponID");
        }
    } else {
        if (TE_IsValidProp("m_hPlayer")) {
            // A handle: the entity index is in the low bits.
            player = TE_ReadNum("m_hPlayer") & 0x7FF;
        }
        if (TE_IsValidProp("m_iEvent")) {
            value = TE_ReadNum("m_iEvent");
        }
    }
    if (player != g_Carrier) {
        return Plugin_Continue;
    }

    g_LoggedAnimEvents++;
    char classname[32] = "none";
    int active = GetEntPropEnt(g_Carrier, Prop_Send, "m_hActiveWeapon");
    if (active > MaxClients && IsValidEntity(active)) {
        GetEntityClassname(active, classname, sizeof(classname));
    }
    AutoplantDebug("%s of the carrier %L (event/weapon id %d), %s in the hands, %.2f s before the plant",
                   te_name, g_Carrier, value, classname, g_PlantTime - GetGameTime());
    return Plugin_Continue;
}

/**
 * Before the planned plant: switches the carrier to the C4 in time and sends the
 * planting animation PLANT_ANIM_TIME before the plant. Returns true if the user command
 * was changed.
 */
static bool BeforePlant(int client, float now, int &weapon) {
    if (client != g_Carrier || !IsPlayerAlive(client)) {
        return false;
    }
    int carried = GetClientC4(client);
    if (carried == -1) {
        return false;
    }
    bool holding = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == carried;

    // The animation is only sent when the bomb is going to be planted right there: with
    // the C4 in the hands and inside a bomb target. If the moment is missed (the C4 came
    // into the hands too late), it is sent as soon as possible before the plant.
    if (g_PlantTEHooked && !g_AnimSent && holding && now >= g_PlantTime - PLANT_ANIM_TIME
        && (!HasEntProp(client, Prop_Send, "m_bInBombZone") || GetEntProp(client, Prop_Send, "m_bInBombZone"))) {
        SendPlantAnimation(client);
    }

    // The game only plants from a C4 that is in the hands, and pulling it out takes
    // 0.5-0.8 s (seen on a live CS:S server: a human carrier with another weapon out
    // got the bomb planted that much late). So a human carrier is switched to the C4
    // a second ahead. Checked on a live CS:S server: with the C4 selected a second ahead
    // the bomb is planted on time. Bots plant on time as it is and were left alone; with
    // the planting animation both are switched before it starts.
    if (holding || !IsDrawTime(client, now)) {
        return false;
    }
    if (!g_LoggedDraw) {
        g_LoggedDraw = true;
        AutoplantDebug("%L holds another weapon, the C4 is pulled out %.2f s before the plant",
                       client, g_PlantTime - now);
    }
    weapon = carried;
    return true;
}

/**
 * Drives the bomb carrier's user commands until the bomb is planted: pulls out the C4,
 * holds the attack button, keeps the carrier in place and cuts the arming time short.
 * Arming starts at the planned moment and not earlier, see the top of the file.
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (!g_Pending) {
        return Plugin_Continue;
    }

    float now = GetGameTime();
    CarrierEffects(client, now);
    if (now < g_PlantTime) {
        return BeforePlant(client, now, weapon) ? Plugin_Changed : Plugin_Continue;
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
    // m_fArmedTime, for bots and humans alike (checked on a live CS:S server).
    buttons |= IN_ATTACK;

    if (GetEntProp(c4, Prop_Send, "m_bStartedArming")) {
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
