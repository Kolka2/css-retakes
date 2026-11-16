#include <sourcemod>
#include <cstrike>
#include <clientprefs>
#include "include/retakes.inc"
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

#define MENU_TIME_LENGTH 15

// CS:S pistols. The index in this array is what the player's cookie stores.
// The first NUM_DEFAULT_PISTOLS rows are the "starting" pistols: with them the player gets armor.
#define NUM_DEFAULT_PISTOLS 2
#define DEFAULT_PISTOL_CHOICE 1

char g_PistolChoices[][][] = {
    // Default pistols:
    { "weapon_glock", "Glock" },
    { "weapon_usp", "USP" },

    // Upgraded pistols:
    { "weapon_p228", "P228" },
    { "weapon_fiveseven", "Five-SeveN" },
    { "weapon_deagle", "Desert Eagle" },
    { "weapon_elite", "Dual Elites" },
    // Random pistol, must be last entry in the array
    { "", "Random" },
};

int g_PistolChoice[MAXPLAYERS+1];
Handle g_PistolChoiceCookie;

public Plugin myinfo = {
    name = "CS:S Retakes: Pistols and nades",
    author = "splewis, BatMen, Ejz, Kolka2",
    description = "Defines a simple weapon allocation policy that gives Pistols and nades",
    version = PLUGIN_VERSION,
    url = "https://github.com/Kolka2/css-retakes"
};

public void OnPluginStart() {
    g_PistolChoiceCookie = RegClientCookie("retakes_pistolchoice", "", CookieAccess_Private);
}

public void OnClientConnected(int client) {
    g_PistolChoice[client] = DEFAULT_PISTOL_CHOICE;
}

public void Retakes_OnGunsCommand(int client) {
    GiveGunsMenu(client);
}

public void Retakes_OnWeaponsAllocated(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite) {
    AllocateTeam(tPlayers, false);
    AllocateTeam(ctPlayers, true);
}

/**
 * Returns a usable index into g_PistolChoices.
 * Cookies written by the CS:GO version may hold an index that no longer exists.
 */
static int ValidatePistolChoice(int choice) {
    if (choice < 0 || choice >= sizeof(g_PistolChoices)) {
        return DEFAULT_PISTOL_CHOICE;
    }
    return choice;
}

static bool IsDefaultPistol(int weaponIndex) {
    return weaponIndex < NUM_DEFAULT_PISTOLS;
}

static bool IsRandomPistol(int weaponIndex) {
    return weaponIndex == sizeof(g_PistolChoices) - 1;
}

public void OnClientCookiesCached(int client) {
    if (IsFakeClient(client))
        return;

    char buffer[INTEGER_STRING_LENGTH];
    GetClientCookie(client, g_PistolChoiceCookie, buffer, sizeof(buffer));
    if (buffer[0] == '\0') {
        // no cookie yet: the default choice from OnClientConnected stays
        return;
    }
    g_PistolChoice[client] = ValidatePistolChoice(StringToInt(buffer));
}

static void SetNades(char nades[NADE_STRING_LENGTH]) {
    int rand = GetRandomInt(0, 3);
    switch(rand) {
        case 0: nades = "";
        case 1: nades = "s";
        case 2: nades = "f";
        case 3: nades = "h";
    }
}

/**
 * Sets the loadout of one team: no primary weapon, the pistol each player chose, a
 * random grenade, armor only with a default pistol, no helmet and, for the CTs, a
 * defuse kit.
 */
static void AllocateTeam(ArrayList players, bool ct) {
    char primary[WEAPON_STRING_LENGTH];
    char secondary[WEAPON_STRING_LENGTH];
    char nades[NADE_STRING_LENGTH];

    for (int i = 0; i < players.Length; i++) {
        int client = players.Get(i);
        int choice = ValidatePistolChoice(g_PistolChoice[client]);
        if (IsRandomPistol(choice)) {
            choice = GetRandomInt(0, sizeof(g_PistolChoices) - 2);
        }
        strcopy(secondary, sizeof(secondary), g_PistolChoices[choice][0]);
        int kevlar = IsDefaultPistol(choice) ? 100 : 0;
        SetNades(nades);
        Retakes_SetPlayerInfo(client, primary, secondary, nades, 100, kevlar, false, ct);
    }
}

static void GiveGunsMenu(int client) {
    Menu menu = new Menu(GunsMenuHandler);
    menu.SetTitle("Select a pistol:");
    for (int i = 0; i < sizeof(g_PistolChoices); i++) {
        AddMenuInt(menu, i, g_PistolChoices[i][1]);
    }
    menu.Display(client, MENU_TIME_LENGTH);
}

public int GunsMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        int choice = ValidatePistolChoice(GetMenuInt(menu, param2));
        g_PistolChoice[client] = choice;
        SetCookieInt(client, g_PistolChoiceCookie, choice);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
