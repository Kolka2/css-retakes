// The !guns menu of the allocator.
// Included only from retakes_allocator.sp.
//
// The settings are grouped by round type: the main menu has a line per type and the
// grenades, a type menu has the weapon settings of the type. When only one type has
// anything to set up, its settings are listed in the main menu itself.

#define MENU_INFO_AWP "awp"
#define MENU_INFO_NADES "nades"
// Followed by the index of a round type: the line that opens the menu of the type.
#define MENU_INFO_TYPE 't'

// The type menu a client came from to a weapon list, or -1 for the main menu.
int g_MenuType[MAXPLAYERS+1] = {-1, ...};

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

static void GetTypeName(int client, int type, char[] buffer, int size) {
    char phrase[48];
    Format(phrase, sizeof(phrase), "RoundType_%s", g_RoundTypes[type][TYPE_TOKEN]);
    Format(buffer, size, "%T", phrase, client);
}

/**
 * Returns if the players can choose the weapons of a round type: the type has choice
 * slots and is not listed in sm_retakes_alloc_random_types.
 */
static bool TypeHasWeaponChoice(int type) {
    if (g_TypeForcedRandom[type]) {
        return false;
    }
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        if (g_SlotType[slot] == type) {
            return true;
        }
    }
    return false;
}

/**
 * Returns if a round type has the "receive the AWP" setting. It stays when the weapons
 * of the type are forced to be random: the AWP still goes only to those who agreed.
 */
static bool TypeHasAwpChoice(int type) {
    return g_TypePrimary[type] == Primary_Rifle;
}

/**
 * Returns if a round type has anything to set up: it is played (is in
 * sm_retakes_alloc_rounds) and has a weapon or an AWP setting.
 */
static bool TypeHasSettings(int type) {
    return CycleHasType(type) && (TypeHasWeaponChoice(type) || TypeHasAwpChoice(type));
}

/**
 * Adds the settings of a round type to a menu, with their current values. The item info
 * is the slot number or MENU_INFO_AWP.
 */
static void AddTypeSettings(Menu menu, int client, int type) {
    char phrase[32];
    char name[64];
    char text[96];
    char info[INTEGER_STRING_LENGTH];

    if (TypeHasWeaponChoice(type)) {
        for (int slot = 0; slot < NUM_SLOTS; slot++) {
            if (g_SlotType[slot] != type) {
                continue;
            }
            Format(phrase, sizeof(phrase), "Menu%s", g_SlotPhrases[slot]);
            GetChoiceName(client, g_Choice[client][slot], name, sizeof(name));
            Format(text, sizeof(text), "%T", phrase, client, name);
            IntToString(slot, info, sizeof(info));
            menu.AddItem(info, text);
        }
    }

    if (TypeHasAwpChoice(type)) {
        Format(name, sizeof(name), "%T", g_AwpChoice[client] ? "Yes" : "No", client);
        Format(text, sizeof(text), "%T", "MenuAwp", client, name);
        menu.AddItem(MENU_INFO_AWP, text);
    }
}

/**
 * The main menu: a line per round type that has settings (or the settings themselves if
 * there is only one such type) and the grenades.
 */
void ShowGunsMenu(int client) {
    g_MenuType[client] = -1;

    int types = 0;
    int onlyType = -1;
    for (int type = 0; type < sizeof(g_RoundTypes); type++) {
        if (TypeHasSettings(type)) {
            types++;
            onlyType = type;
        }
    }

    Menu menu = new Menu(MenuHandler_Guns);
    menu.SetTitle("%T", "GunsMenuTitle", client);

    if (types == 1) {
        AddTypeSettings(menu, client, onlyType);
    } else {
        char name[64];
        char info[INTEGER_STRING_LENGTH + 1];
        for (int type = 0; type < sizeof(g_RoundTypes); type++) {
            if (TypeHasSettings(type)) {
                GetTypeName(client, type, name, sizeof(name));
                Format(info, sizeof(info), "%c%d", MENU_INFO_TYPE, type);
                menu.AddItem(info, name);
            }
        }
    }

    AddNadesMenuItem(menu, client, MENU_INFO_NADES);

    if (menu.ItemCount == 0) {
        delete menu;
        TellPhrase(client, "NothingToChoose");
        return;
    }
    menu.Display(client, MENU_TIME_LENGTH);
}

/**
 * The settings of one round type.
 */
static void ShowTypeMenu(int client, int type) {
    if (type < 0 || type >= sizeof(g_RoundTypes) || !TypeHasSettings(type)) {
        ShowGunsMenu(client);
        return;
    }
    g_MenuType[client] = type;

    Menu menu = new Menu(MenuHandler_Guns);
    char name[64];
    GetTypeName(client, type, name, sizeof(name));
    menu.SetTitle("%s", name);
    AddTypeSettings(menu, client, type);
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_LENGTH);
}

/**
 * Goes back to the menu a setting was opened from.
 */
static void ShowSettingsMenu(int client) {
    if (g_MenuType[client] >= 0) {
        ShowTypeMenu(client, g_MenuType[client]);
    } else {
        ShowGunsMenu(client);
    }
}

/**
 * The handler of the main menu and of the type menus.
 */
public int MenuHandler_Guns(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char info[INTEGER_STRING_LENGTH + 1];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, MENU_INFO_AWP)) {
            SetAwpChoice(client, !g_AwpChoice[client]);
            ShowSettingsMenu(client);
        } else if (StrEqual(info, MENU_INFO_NADES)) {
            ShowNadesMenu(client);
        } else if (info[0] == MENU_INFO_TYPE) {
            ShowTypeMenu(client, StringToInt(info[1]));
        } else {
            ShowSlotMenu(client, StringToInt(info));
        }
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowGunsMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

/**
 * Writes the menu line of a weapon in a slot: its name, and what armor the choice
 * leaves where the budget is tight ("AK-47 (no armor)").
 */
static void GetWeaponLine(int client, int slot, int weapon, char[] buffer, int size) {
    if (!SlotDecidesArmor(slot)) {
        strcopy(buffer, size, g_Weapons[weapon][WEAPON_NAME]);
        return;
    }

    bool armor, helmet;
    GetChoiceArmor(slot, weapon, armor, helmet);
    Format(buffer, size, "%s (%T)", g_Weapons[weapon][WEAPON_NAME],
           helmet ? "ArmorFull" : (armor ? "ArmorKevlar" : "ArmorNone"), client);
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
    char text[96];
    if (g_SlotAllowsRandom[slot]) {
        GetChoiceName(client, CHOICE_RANDOM, text, sizeof(text));
        Format(info, sizeof(info), "%d:%s", slot, RANDOM_COOKIE_VALUE);
        menu.AddItem(info, text);
    }
    for (int i = 0; i < sizeof(g_Weapons); i++) {
        if (IsValidChoice(slot, i)) {
            Format(info, sizeof(info), "%d:%s", slot, g_Weapons[i][WEAPON_ID]);
            GetWeaponLine(client, slot, i, text, sizeof(text));
            menu.AddItem(info, text);
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
        ShowSettingsMenu(client);
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        ShowSettingsMenu(param1);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}
