// The !guns menu of the allocator.
// Included only from retakes_allocator.sp.

#define MENU_INFO_AWP "awp"
#define MENU_INFO_NADES "nades"

/**
 * Sends a phrase of the allocator to a client through the retakes chat prefix.
 * The text is translated here: the phrases belong to this plugin, not to retakes.
 */
void TellPhrase(int client, const char[] phrase) {
    char text[192];
    Format(text, sizeof(text), "%T", phrase, client);
    Retakes_Message(client, "%s", text);
}

/**
 * Writes the name of a slot value for a menu: the weapon name or "random every round".
 */
static void GetChoiceName(int client, int choice, char[] buffer, int size) {
    if (choice == CHOICE_RANDOM) {
        Format(buffer, size, "%T", "RandomEveryRound", client);
    } else {
        strcopy(buffer, size, g_Weapons[choice][WEAPON_NAME]);
    }
}

/**
 * The main menu: one line per setting, with its current value. Only the settings that
 * matter for the round types of sm_retakes_alloc_rounds are listed. The item info is the
 * slot number, MENU_INFO_AWP or MENU_INFO_NADES.
 */
void ShowGunsMenu(int client) {
    Menu menu = new Menu(MenuHandler_Guns);
    menu.SetTitle("%T", "GunsMenuTitle", client);

    char phrase[32];
    char name[64];
    char text[96];
    char info[INTEGER_STRING_LENGTH];
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        if (!CycleHasPrimary(g_SlotPolicy[slot])) {
            continue;
        }
        Format(phrase, sizeof(phrase), "Menu%s", g_SlotPhrases[slot]);
        GetChoiceName(client, g_Choice[client][slot], name, sizeof(name));
        Format(text, sizeof(text), "%T", phrase, client, name);
        IntToString(slot, info, sizeof(info));
        menu.AddItem(info, text);
    }

    if (CycleHasPrimary(Primary_Rifle)) {
        Format(name, sizeof(name), "%T", g_AwpChoice[client] ? "Yes" : "No", client);
        Format(text, sizeof(text), "%T", "MenuAwp", client, name);
        menu.AddItem(MENU_INFO_AWP, text);
    }

    AddNadesMenuItem(menu, client, MENU_INFO_NADES);

    if (menu.ItemCount == 0) {
        delete menu;
        TellPhrase(client, "NothingToChoose");
        return;
    }
    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_Guns(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[INTEGER_STRING_LENGTH];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, MENU_INFO_AWP)) {
            SetAwpChoice(client, !g_AwpChoice[client]);
            ShowGunsMenu(client);
        } else if (StrEqual(info, MENU_INFO_NADES)) {
            ShowNadesMenu(client);
        } else {
            ShowSlotMenu(client, StringToInt(info));
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

/**
 * The weapons of one slot. The item info is "<slot>:<weapon id>", with
 * RANDOM_COOKIE_VALUE as the id of "random every round".
 */
static void ShowSlotMenu(int client, int slot) {
    if (slot < 0 || slot >= NUM_SLOTS) {
        return;
    }

    Menu menu = new Menu(MenuHandler_Slot);
    char phrase[32];
    Format(phrase, sizeof(phrase), "Select%s", g_SlotPhrases[slot]);
    menu.SetTitle("%T", phrase, client);

    char info[WEAPON_STRING_LENGTH];
    if (g_SlotAllowsRandom[slot]) {
        char name[64];
        GetChoiceName(client, CHOICE_RANDOM, name, sizeof(name));
        Format(info, sizeof(info), "%d:%s", slot, RANDOM_COOKIE_VALUE);
        menu.AddItem(info, name);
    }
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        if (IsValidChoice(slot, i)) {
            Format(info, sizeof(info), "%d:%s", slot, g_Weapons[i][WEAPON_ID]);
            menu.AddItem(info, g_Weapons[i][WEAPON_NAME]);
        }
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_LENGTH);
}

public int MenuHandler_Slot(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[WEAPON_STRING_LENGTH];
        menu.GetItem(param2, info, sizeof(info));

        int slot = StringToInt(info);
        int choice = ParseChoice(info[FindCharInString(info, ':') + 1]);
        if (slot >= 0 && slot < NUM_SLOTS && IsValidChoice(slot, choice)) {
            SetChoice(client, slot, choice);
        }
        ShowGunsMenu(client);
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowGunsMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
