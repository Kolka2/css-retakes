// The !guns menu of the allocator.
// Included only from retakes_allocator.sp.

#define MENU_TIME_LENGTH 15

/**
 * Sends a phrase of the allocator to a client through the retakes chat prefix.
 * The text is translated here: the phrases belong to this plugin, not to retakes.
 */
static void TellPhrase(int client, const char[] phrase) {
    char text[192];
    Format(text, sizeof(text), "%T", phrase, client);
    Retakes_Message(client, "%s", text);
}

/**
 * The main menu: one line per setting, with its current value. Only the settings that
 * matter for the round types of sm_retakes_alloc_rounds are listed.
 */
void ShowGunsMenu(int client) {
    if (!CycleHasPrimary(Primary_Rifle)) {
        TellPhrase(client, "NothingToChoose");
        return;
    }

    Menu menu = new Menu(MenuHandler_Guns);
    menu.SetTitle("%T", "GunsMenuTitle", client);

    char text[64];
    Format(text, sizeof(text), "%T", "MenuCTRifle", client, g_Weapons[g_Rifle[client][CT_INDEX]][WEAPON_NAME]);
    menu.AddItem("ctrifle", text);
    Format(text, sizeof(text), "%T", "MenuTRifle", client, g_Weapons[g_Rifle[client][T_INDEX]][WEAPON_NAME]);
    menu.AddItem("trifle", text);

    char yesNo[16];
    Format(yesNo, sizeof(yesNo), "%T", g_AwpChoice[client] ? "Yes" : "No", client);
    Format(text, sizeof(text), "%T", "MenuAwp", client, yesNo);
    menu.AddItem("awp", text);

    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_Guns(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[16];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "ctrifle")) {
            ShowRifleMenu(client, true);
        } else if (StrEqual(info, "trifle")) {
            ShowRifleMenu(client, false);
        } else if (StrEqual(info, "awp")) {
            g_AwpChoice[client] = !g_AwpChoice[client];
            SetCookieBool(client, g_hAwpCookie, g_AwpChoice[client]);
            ShowGunsMenu(client);
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

/**
 * The rifles of one side. The item info is "<side>:<weapon id>".
 */
static void ShowRifleMenu(int client, bool ct) {
    Menu menu = new Menu(MenuHandler_Rifle);
    menu.SetTitle("%T", ct ? "SelectCTRifle" : "SelectTRifle", client);

    char info[WEAPON_STRING_LENGTH];
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        if (WeaponFits(i, CAT_RIFLE, ct)) {
            Format(info, sizeof(info), "%s:%s", ct ? "ct" : "t", g_Weapons[i][WEAPON_ID]);
            menu.AddItem(info, g_Weapons[i][WEAPON_NAME]);
        }
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_Rifle(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[WEAPON_STRING_LENGTH];
        menu.GetItem(param2, info, sizeof(info));

        bool ct = (info[0] == 'c');
        int weapon = FindWeapon(info[FindCharInString(info, ':') + 1]);
        if (weapon != -1 && WeaponFits(weapon, CAT_RIFLE, ct)) {
            int side = SideIndex(ct);
            g_Rifle[client][side] = weapon;
            SetClientCookie(client, g_hRifleCookie[side], g_Weapons[weapon][WEAPON_ID]);
        }
        ShowGunsMenu(client);
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowGunsMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
