#include <sourcemod>
#include <cstrike>
#include <clientprefs>
#include "include/retakes.inc"
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

#define MENU_TIME_LENGTH 15

// CS:S rifles: { cookie value, weapon class, menu name }.
// The first row is the default choice. It also replaces an unknown cookie value
// (e.g. one left by the CS:GO version: "m4a1_silencer", "sg556").
#define RIFLE_COOKIE 0
#define RIFLE_CLASS 1
#define RIFLE_NAME 2

char g_CTRifles[][][] = {
    { "m4a1", "weapon_m4a1", "M4A1" },
    { "aug", "weapon_aug", "AUG" },
    { "famas", "weapon_famas", "FAMAS" },
};

char g_TRifles[][][] = {
    { "ak47", "weapon_ak47", "AK-47" },
    { "sg552", "weapon_sg552", "SG 552" },
    { "galil", "weapon_galil", "Galil" },
};

char g_CTRifleChoice[MAXPLAYERS+1][WEAPON_STRING_LENGTH];
char g_TRifleChoice[MAXPLAYERS+1][WEAPON_STRING_LENGTH];
bool g_AwpChoice[MAXPLAYERS+1];
Handle g_hCTRifleChoiceCookie;
Handle g_hTRifleChoiceCookie;
Handle g_hAwpChoiceCookie;

public Plugin myinfo = {
    name = "CS:S Retakes: standard weapon allocator",
    author = "splewis",
    description = "Defines a simple weapon allocation policy and lets players set weapon preferences",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-retakes"
};

public void OnPluginStart() {
    g_hCTRifleChoiceCookie = RegClientCookie("retakes_ctriflechoice", "", CookieAccess_Private);
    g_hTRifleChoiceCookie = RegClientCookie("retakes_triflechoice", "", CookieAccess_Private);
    g_hAwpChoiceCookie = RegClientCookie("retakes_awpchoice", "", CookieAccess_Private);
}

public void OnClientConnected(int client) {
    strcopy(g_CTRifleChoice[client], WEAPON_STRING_LENGTH, g_CTRifles[0][RIFLE_COOKIE]);
    strcopy(g_TRifleChoice[client], WEAPON_STRING_LENGTH, g_TRifles[0][RIFLE_COOKIE]);
    g_AwpChoice[client] = false;
}

public void Retakes_OnGunsCommand(int client) {
    ShowRifleMenu(client, MenuHandler_CTRifle, "Select a CT rifle:", g_CTRifles, sizeof(g_CTRifles));
}

public void Retakes_OnWeaponsAllocated(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite) {
    AllocateTeam(tPlayers, false);
    AllocateTeam(ctPlayers, true);
}

/**
 * Returns the index of a rifle choice in a rifle table, or 0 (the default rifle)
 * if the choice is empty or unknown.
 */
static int FindRifle(const char[][][] rifles, int count, const char[] choice) {
    for (int i = 0; i < count; i++) {
        if (StrEqual(choice, rifles[i][RIFLE_COOKIE], true)) {
            return i;
        }
    }
    return 0;
}

/**
 * Updates client weapon settings according to their cookies.
 */
public void OnClientCookiesCached(int client) {
    if (IsFakeClient(client))
        return;
    char ctrifle[WEAPON_STRING_LENGTH];
    char trifle[WEAPON_STRING_LENGTH];
    GetClientCookie(client, g_hCTRifleChoiceCookie, ctrifle, sizeof(ctrifle));
    GetClientCookie(client, g_hTRifleChoiceCookie, trifle, sizeof(trifle));

    // Empty and CS:GO values turn into the default choice.
    int ctIndex = FindRifle(g_CTRifles, sizeof(g_CTRifles), ctrifle);
    int tIndex = FindRifle(g_TRifles, sizeof(g_TRifles), trifle);
    strcopy(g_CTRifleChoice[client], WEAPON_STRING_LENGTH, g_CTRifles[ctIndex][RIFLE_COOKIE]);
    strcopy(g_TRifleChoice[client], WEAPON_STRING_LENGTH, g_TRifles[tIndex][RIFLE_COOKIE]);
    g_AwpChoice[client] = GetCookieBool(client, g_hAwpChoiceCookie);
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
 * Sets the loadout of one team: the rifle each player chose (one AWP per team, for the
 * first player that asked for it), the team pistol, a random grenade, full armor and,
 * for the CTs, a defuse kit.
 */
static void AllocateTeam(ArrayList players, bool ct) {
    char primary[WEAPON_STRING_LENGTH];
    char secondary[WEAPON_STRING_LENGTH];
    char nades[NADE_STRING_LENGTH];
    bool giveAwp = true;

    for (int i = 0; i < players.Length; i++) {
        int client = players.Get(i);

        if (giveAwp && g_AwpChoice[client]) {
            primary = "weapon_awp";
            giveAwp = false;
        } else if (ct) {
            int rifle = FindRifle(g_CTRifles, sizeof(g_CTRifles), g_CTRifleChoice[client]);
            strcopy(primary, sizeof(primary), g_CTRifles[rifle][RIFLE_CLASS]);
        } else {
            int rifle = FindRifle(g_TRifles, sizeof(g_TRifles), g_TRifleChoice[client]);
            strcopy(primary, sizeof(primary), g_TRifles[rifle][RIFLE_CLASS]);
        }

        strcopy(secondary, sizeof(secondary), ct ? "weapon_usp" : "weapon_glock");
        SetNades(nades);

        Retakes_SetPlayerInfo(client, primary, secondary, nades, 100, 100, true, ct);
    }
}

static void ShowRifleMenu(int client, MenuHandler handler, const char[] title, const char[][][] rifles, int count) {
    Menu menu = new Menu(handler);
    menu.SetTitle(title);
    for (int i = 0; i < count; i++) {
        menu.AddItem(rifles[i][RIFLE_COOKIE], rifles[i][RIFLE_NAME]);
    }
    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_CTRifle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char choice[WEAPON_STRING_LENGTH];
        menu.GetItem(param2, choice, sizeof(choice));
        g_CTRifleChoice[client] = choice;
        SetClientCookie(client, g_hCTRifleChoiceCookie, choice);
        ShowRifleMenu(client, MenuHandler_TRifle, "Select a T rifle:", g_TRifles, sizeof(g_TRifles));
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

public int MenuHandler_TRifle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char choice[WEAPON_STRING_LENGTH];
        menu.GetItem(param2, choice, sizeof(choice));
        g_TRifleChoice[client] = choice;
        SetClientCookie(client, g_hTRifleChoiceCookie, choice);
        GiveAwpMenu(client);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

static void GiveAwpMenu(int client) {
    Menu menu = new Menu(MenuHandler_AWP);
    menu.SetTitle("Allow yourself to receive AWPs?");
    AddMenuBool(menu, true, "Yes");
    AddMenuBool(menu, false, "No");
    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_AWP(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        bool allowAwps = GetMenuBool(menu, param2);
        g_AwpChoice[client] = allowAwps;
        SetCookieBool(client, g_hAwpChoiceCookie, allowAwps);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
