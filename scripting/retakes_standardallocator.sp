#include <sourcemod>
#include <cstrike>
#include <clientprefs>
#include "include/retakes.inc"
#include "retakes/generic.sp"

#pragma semicolon 1
#pragma newdecls required

#define MENU_TIME_LENGTH 15

// Винтовки CS:S: { значение cookie, класс оружия, название в меню }.
// Первая строка - выбор по умолчанию. Им же заменяется неизвестное значение cookie
// (например, оставшееся от CS:GO-версии: "m4a1_silencer", "sg556").
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
    strcopy(g_CTRifleChoice[client], WEAPON_STRING_LENGTH, g_CTRifles[0][0]);
    strcopy(g_TRifleChoice[client], WEAPON_STRING_LENGTH, g_TRifles[0][0]);
    g_AwpChoice[client] = false;
}

public void Retakes_OnGunsCommand(int client) {
    GiveWeaponsMenu(client);
}

public void Retakes_OnWeaponsAllocated(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite) {
    WeaponAllocator(tPlayers, ctPlayers, bombsite);
}

/**
 * Returns the index of a rifle choice in a rifle table, or 0 (the default rifle)
 * if the choice is empty or unknown.
 */
static int FindCTRifle(const char[] choice) {
    for (int i = 0; i < sizeof(g_CTRifles); i++) {
        if (StrEqual(choice, g_CTRifles[i][0], true)) {
            return i;
        }
    }
    return 0;
}

static int FindTRifle(const char[] choice) {
    for (int i = 0; i < sizeof(g_TRifles); i++) {
        if (StrEqual(choice, g_TRifles[i][0], true)) {
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

    // Пустые и CS:GO-шные значения превращаются в выбор по умолчанию.
    strcopy(g_CTRifleChoice[client], WEAPON_STRING_LENGTH, g_CTRifles[FindCTRifle(ctrifle)][0]);
    strcopy(g_TRifleChoice[client], WEAPON_STRING_LENGTH, g_TRifles[FindTRifle(trifle)][0]);
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

public void WeaponAllocator(ArrayList tPlayers, ArrayList ctPlayers, Bombsite bombsite) {
    int tCount = tPlayers.Length;
    int ctCount = ctPlayers.Length;

    char primary[WEAPON_STRING_LENGTH];
    char secondary[WEAPON_STRING_LENGTH];
    char nades[NADE_STRING_LENGTH];
    int health = 100;
    int kevlar = 100;
    bool helmet = true;
    bool kit = true;

    bool giveTAwp = true;
    bool giveCTAwp = true;

    for (int i = 0; i < tCount; i++) {
        int client = tPlayers.Get(i);

        if (giveTAwp && g_AwpChoice[client]) {
            primary = "weapon_awp";
            giveTAwp = false;
        } else {
            strcopy(primary, sizeof(primary), g_TRifles[FindTRifle(g_TRifleChoice[client])][1]);
        }

        secondary = "weapon_glock";
        health = 100;
        kevlar = 100;
        helmet = true;
        kit = false;
        SetNades(nades);

        Retakes_SetPlayerInfo(client, primary, secondary, nades, health, kevlar, helmet, kit);
    }

    for (int i = 0; i < ctCount; i++) {
        int client = ctPlayers.Get(i);

        if (giveCTAwp && g_AwpChoice[client]) {
            primary = "weapon_awp";
            giveCTAwp = false;
        } else {
            strcopy(primary, sizeof(primary), g_CTRifles[FindCTRifle(g_CTRifleChoice[client])][1]);
        }

        secondary = "weapon_usp";
        kit = true;
        health = 100;
        kevlar = 100;
        helmet = true;
        SetNades(nades);

        Retakes_SetPlayerInfo(client, primary, secondary, nades, health, kevlar, helmet, kit);
    }
}

public void GiveWeaponsMenu(int client) {
    Menu menu = new Menu(MenuHandler_CTRifle);
    menu.SetTitle("Select a CT rifle:");
    for (int i = 0; i < sizeof(g_CTRifles); i++) {
        menu.AddItem(g_CTRifles[i][0], g_CTRifles[i][2]);
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
        TRifleMenu(client);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

public void TRifleMenu(int client) {
    Menu menu = new Menu(MenuHandler_TRifle);
    menu.SetTitle("Select a T rifle:");
    for (int i = 0; i < sizeof(g_TRifles); i++) {
        menu.AddItem(g_TRifles[i][0], g_TRifles[i][2]);
    }
    menu.Display(client, MENU_TIME_LENGTH);
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

public void GiveAwpMenu(int client) {
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
