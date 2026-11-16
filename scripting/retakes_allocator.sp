#include <sourcemod>
#include <cstrike>
#include <clientprefs>
#include <sdkhooks>
#include "include/retakes.inc"
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

// A weapon allocator built around round types (pistol, bonus, force, buy, free): the cvar
// sm_retakes_alloc_rounds says which types are played and for how many rounds.
//
//   retakes_allocator/weapons.sp - the weapon table
//   retakes_allocator/choices.sp - what the players chose, and the cookies
//   retakes_allocator/rounds.sp  - the round types, the cycle and the loadout of a player
//   retakes_allocator/nades.sp   - the grenades and their menus
//   retakes_allocator/menus.sp   - the !guns menu

#define MENU_TIME_LENGTH 15

ConVar g_hRoundsCvar;
ConVar g_hOrderCvar;
ConVar g_hRandomTypesCvar;
ConVar g_hNadesCvar;
ConVar g_hNadesCountCvar;

// Set when the loadouts of a round are built, cleared when the round type is announced.
bool g_AnnouncePending;

/**
 * Writes a line to logs/retakes_allocator_debug.log when sm_retakes_debug (the cvar of
 * retakes) is on.
 */
void AllocDebug(const char[] format, any ...) {
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
    BuildPath(Path_SM, path, sizeof(path), "logs/retakes_allocator_debug.log");
    LogToFileEx(path, "%s", text);
}

#include "retakes_allocator/weapons.sp"
#include "retakes_allocator/choices.sp"
#include "retakes_allocator/rounds.sp"
#include "retakes_allocator/nades.sp"
#include "retakes_allocator/menus.sp"

public Plugin myinfo = {
    name = "CS:S Retakes: round type weapon allocator",
    author = "Kolka2",
    description = "Pistol, bonus, force, buy and free choice rounds in a configurable cycle",
    version = PLUGIN_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("retakes_allocator.phrases");

    ParseWeapons();
    ParseRoundTypes();

    g_hRoundsCvar = CreateConVar("sm_retakes_alloc_rounds", "pistol:2,bonus:2,force:3,buy:12",
        "Round types and how many rounds each lasts: \"type:rounds,type:rounds,...\". Types: pistol, bonus, force, buy, free (any weapon the player chose). A single type (\"buy\") makes every round the same.");
    g_hOrderCvar = CreateConVar("sm_retakes_alloc_order", "cycle",
        "cycle = the round types of sm_retakes_alloc_rounds are played in a circle, random = every round gets a random type, the round counts work as weights");
    g_hRoundsCvar.AddChangeHook(RoundsChanged);
    g_hRandomTypesCvar = CreateConVar("sm_retakes_alloc_random_types", "",
        "Round types, separated by commas, in which the weapons are always random and what the players chose in !guns is ignored (\"force\", \"pistol,bonus,force,buy,free\"). Empty = the players choose wherever there is a choice. The AWP in buy rounds still goes only to those who agreed to it.");
    g_hRandomTypesCvar.AddChangeHook(RandomTypesChanged);
    g_hNadesCvar = CreateConVar("sm_retakes_alloc_nades", "choice",
        "choice = the players set up their grenades in the !guns menu (random until they do), random = random grenades for everybody");
    g_hNadesCountCvar = CreateConVar("sm_retakes_alloc_nades_count", "",
        "Grenades per player: empty = by the round type (pistol 0-1, bonus 1, force 0-1, buy 1-2, free 0-4), or a number (\"1\"), or a range (\"0-4\")");
    g_hNadesCountCvar.AddChangeHook(NadeCountChanged);
    AutoExecConfig(true, "retakes_allocator", "sourcemod/retakes");

    char value[256];
    g_hRoundsCvar.GetString(value, sizeof(value));
    ParseRounds(value);
    g_hRandomTypesCvar.GetString(value, sizeof(value));
    ParseRandomTypes(value);
    g_hNadesCountCvar.GetString(value, sizeof(value));
    ParseNadeCount(value);

    RegisterChoiceCookies();
    RegisterNadeCookies();

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_RoundFreezeEnd);
    HookEvent("round_end", Event_RoundEnd);

    // Late load: the players that are already on the server.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i)) {
            OnClientConnected(i);
            if (IsClientInGame(i)) {
                OnClientPutInServer(i);
                if (AreClientCookiesCached(i)) {
                    OnClientCookiesCached(i);
                }
            }
        }
    }
}

public void RoundsChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    ParseRounds(newValue);
}

public void RandomTypesChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    ParseRandomTypes(newValue);
}

public void NadeCountChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    ParseNadeCount(newValue);
}

public void OnClientConnected(int client) {
    ResetChoices(client);
    ResetNades(client);
}

public void OnMapStart() {
    Nades_OnMapStart();
}

public void OnClientPutInServer(int client) {
    Nades_HookClient(client);
}

public void OnClientCookiesCached(int client) {
    if (!IsFakeClient(client)) {
        LoadChoices(client);
        LoadNades(client);
    }
}

public void Retakes_OnGunsCommand(int client) {
    ShowGunsMenu(client);
}

public void Retakes_OnWeaponsAllocated(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite) {
    AllocateRound(tPlayers, ctPlayers);
    g_AnnouncePending = true;
}

/**
 * The round type is announced when the round starts. Not right here: a round that was not
 * prepared after round_end gets its loadouts inside the round_start handler of retakes,
 * which may run after this one. One frame later they are built either way.
 */
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    Nades_OnRoundStart();
    RequestFrame(Frame_AnnounceRound);
}

public void Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast) {
    Nades_OnFreezeEnd();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    Nades_OnRoundEnd();
}

public void Frame_AnnounceRound(any data) {
    if (!g_AnnouncePending) {
        return;
    }
    g_AnnouncePending = false;

    // Nothing to announce when every round is of the same type.
    if (g_CycleEntries < 2 || !Retakes_Live()) {
        return;
    }

    char phrase[48];
    Format(phrase, sizeof(phrase), "RoundType_%s", g_RoundTypes[g_RoundType][TYPE_TOKEN]);

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsPlayer(client)) {
            continue;
        }
        char typeName[64];
        char text[192];
        Format(typeName, sizeof(typeName), "%T", phrase, client);
        if (g_RoundNumber > 0) {
            Format(text, sizeof(text), "%T", "RoundAnnounce", client, typeName, g_RoundNumber, g_RoundsOfType);
        } else {
            Format(text, sizeof(text), "%T", "RoundAnnounceRandom", client, typeName);
        }
        Retakes_Message(client, "%s", text);
    }
}
