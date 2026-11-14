#include <sourcemod>
#include <cstrike>
#include <clientprefs>
#include "include/retakes.inc"
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

// A weapon allocator built around round types (pistol, bonus, force, buy): the cvar
// sm_retakes_alloc_rounds says which types are played and for how many rounds.
//
//   retakes_allocator/weapons.sp - the weapon table
//   retakes_allocator/rounds.sp  - the round types, the cycle and the loadout of a player
//   retakes_allocator/nades.sp   - the grenades
//   retakes_allocator/menus.sp   - the !guns menu

// What the players chose in the !guns menu. The rifles are indices into g_Weapons.
int g_Rifle[MAXPLAYERS+1][2];
bool g_AwpChoice[MAXPLAYERS+1];

// The cookies have the names retakes_standardallocator uses: the players keep their choice.
Handle g_hRifleCookie[2];
Handle g_hAwpCookie;

ConVar g_hRoundsCvar;

// Set when the loadouts of a round are built, cleared when the round type is announced.
bool g_AnnouncePending;

#include "retakes_allocator/weapons.sp"
#include "retakes_allocator/rounds.sp"
#include "retakes_allocator/nades.sp"
#include "retakes_allocator/menus.sp"

public Plugin myinfo = {
    name = "CS:S Retakes: round type weapon allocator",
    author = "Kolka2",
    description = "Pistol, bonus, force and buy rounds in a configurable cycle",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
};

public void OnPluginStart() {
    LoadTranslations("common.phrases");
    LoadTranslations("retakes_allocator.phrases");

    ParseWeapons();
    ParseRoundTypes();

    g_hRoundsCvar = CreateConVar("sm_retakes_alloc_rounds", "pistol:2,bonus:2,force:3,buy:12",
        "Round types and how many rounds each lasts, played in a circle: \"type:rounds,type:rounds,...\". Types: pistol, bonus, force, buy. A single type (\"buy\") makes every round the same.");
    g_hRoundsCvar.AddChangeHook(RoundsChanged);
    AutoExecConfig(true, "retakes_allocator", "sourcemod/retakes");

    char rounds[256];
    g_hRoundsCvar.GetString(rounds, sizeof(rounds));
    ParseRounds(rounds);

    g_hRifleCookie[CT_INDEX] = RegClientCookie("retakes_ctriflechoice", "", CookieAccess_Private);
    g_hRifleCookie[T_INDEX] = RegClientCookie("retakes_triflechoice", "", CookieAccess_Private);
    g_hAwpCookie = RegClientCookie("retakes_awpchoice", "", CookieAccess_Private);

    HookEvent("round_start", Event_RoundStart);

    // Late load: the players that are already on the server.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i)) {
            OnClientConnected(i);
            if (IsClientInGame(i) && AreClientCookiesCached(i)) {
                OnClientCookiesCached(i);
            }
        }
    }
}

public void RoundsChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
    ParseRounds(newValue);
}

public void OnClientConnected(int client) {
    g_Rifle[client][T_INDEX] = g_DefaultRifle[T_INDEX];
    g_Rifle[client][CT_INDEX] = g_DefaultRifle[CT_INDEX];
    g_AwpChoice[client] = false;
}

/**
 * Reads the rifle a client chose for one side. An empty or unknown cookie value (e.g. one
 * left by the CS:GO version: "m4a1_silencer", "sg556") leaves the default rifle.
 */
static void LoadRifleChoice(int client, bool ct) {
    int side = SideIndex(ct);
    char id[WEAPON_STRING_LENGTH];
    GetClientCookie(client, g_hRifleCookie[side], id, sizeof(id));

    int weapon = FindWeapon(id);
    if (weapon != -1 && WeaponFits(weapon, CAT_RIFLE, ct)) {
        g_Rifle[client][side] = weapon;
    }
}

public void OnClientCookiesCached(int client) {
    if (IsFakeClient(client)) {
        return;
    }
    LoadRifleChoice(client, false);
    LoadRifleChoice(client, true);
    g_AwpChoice[client] = GetCookieBool(client, g_hAwpCookie);
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
    RequestFrame(Frame_AnnounceRound);
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
        Format(text, sizeof(text), "%T", "RoundAnnounce", client, typeName, g_RoundNumber, g_RoundsOfType);
        Retakes_Message(client, "%s", text);
    }
}
