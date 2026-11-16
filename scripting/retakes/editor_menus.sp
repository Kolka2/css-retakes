// Menus of the spawn editor. Included only from retakes.sp.

enum EditorMenuKind {
    EditorMenu_Main,
    EditorMenu_NewSpawn,
};

// The editor menu a client is looking at right now (null if none), to draw it again
// when the shown bombsite changes behind it (a chat command, another admin).
static Menu g_OpenEditorMenu[MAXPLAYERS+1];
static EditorMenuKind g_OpenEditorMenuKind[MAXPLAYERS+1];
static int g_OpenEditorMenuPosition[MAXPLAYERS+1];

static void RememberEditorMenu(int client, Menu menu, EditorMenuKind kind, int menuPosition) {
    g_OpenEditorMenu[client] = menu;
    g_OpenEditorMenuKind[client] = kind;
    g_OpenEditorMenuPosition[client] = menuPosition;
}

/**
 * Called when a menu is closed for a client. The handle is compared because a menu
 * replaced by a new one reports its cancellation too, and must not clear the new one.
 */
static void ForgetEditorMenu(int client, Menu menu) {
    if (client >= 1 && client <= MaxClients && g_OpenEditorMenu[client] == menu) {
        g_OpenEditorMenu[client] = null;
    }
}

/**
 * Draws the open editor menus again, for everybody who has one on the screen.
 */
void RefreshEditorMenus() {
    for (int i = 1; i <= MaxClients; i++) {
        if (g_OpenEditorMenu[i] == null) {
            continue;
        }

        if (!IsPlayer(i)) {
            g_OpenEditorMenu[i] = null;
        } else if (g_OpenEditorMenuKind[i] == EditorMenu_Main) {
            GiveEditorMenu(i, g_OpenEditorMenuPosition[i]);
        } else {
            GiveNewSpawnMenu(i);
        }
    }
}

void GiveEditorMenu(int client, int menuPosition=-1) {
    Menu menu = new Menu(EditorMenuHandler);
    menu.ExitButton = true;
    menu.SetTitle("Retakes spawn editor");
    AddMenuOption(menu, "end_edit", "Exit edit mode");
    AddMenuOption(menu, "change_site", "Showing bombsite: %s", SITESTRING(g_EditingSite));
    AddMenuOption(menu, "add_spawn", "Add a spawn");
    AddMenuOption(menu, "goto_nearest_spawn", "Go to nearest spawn");
    AddMenuOption(menu, "goto_next_spawn", "Go to next spawn");
    AddMenuOption(menu, "goto_prev_spawn", "Go to previous spawn");
    AddMenuOption(menu, "delete_nearest_spawn", "Delete nearest spawn");
    AddMenuOption(menu, "save_spawns", "Save spawns");
    AddMenuOption(menu, "delete_map_spawns", "Delete all map spawns");
    AddMenuOption(menu, "reload_spawns", "Reload map spawns (discard current changes)");

    bool shown;
    if (menuPosition == -1) {
        shown = menu.Display(client, MENU_TIME_FOREVER);
    } else {
        shown = menu.DisplayAt(client, menuPosition, MENU_TIME_FOREVER);
    }
    if (shown) {
        RememberEditorMenu(client, menu, EditorMenu_Main, menuPosition);
    }
}

public int EditorMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel) {
        ForgetEditorMenu(param1, menu);
        return 0;
    }
    if (action != MenuAction_Select) {
        return 0;
    }

    int client = param1;
    ForgetEditorMenu(client, menu);
    char choice[64];
    menu.GetItem(param2, choice, sizeof(choice));
    int menuPosition = GetMenuSelectionPosition();

    // These two leave the editor menu; every other item brings it back.
    if (StrEqual(choice, "end_edit")) {
        ExitEditMode();
        return 0;
    }
    if (StrEqual(choice, "add_spawn")) {
        GiveNewSpawnMenu(client);
        return 0;
    }

    if (StrEqual(choice, "change_site")) {
        ShowSpawns(GetOtherSite(g_EditingSite));

    } else if (StrEqual(choice, "goto_nearest_spawn")) {
        int spawn = FindClosestSpawn(client);
        if (IsValidSpawn(spawn)) {
            MoveToSpawnInEditor(client, spawn);
        } else {
            Retakes_Message(client, "No spawns found");
        }

    } else if (StrEqual(choice, "goto_next_spawn")) {
        StepToSpawnInEditor(client, 1);

    } else if (StrEqual(choice, "goto_prev_spawn")) {
        StepToSpawnInEditor(client, -1);

    } else if (StrEqual(choice, "delete_nearest_spawn")) {
        DeleteClosestSpawn(client);

    } else if (StrEqual(choice, "delete_map_spawns")) {
        DeleteMapSpawns();

    } else if (StrEqual(choice, "save_spawns")) {
        SaveSpawns();

    } else if (StrEqual(choice, "reload_spawns")) {
        ReloadSpawns();

    } else {
        LogError("unknown menu info string = %s", choice);
        return 0;
    }

    GiveEditorMenu(client, menuPosition);
    return 0;
}

void GiveNewSpawnMenu(int client) {
    Menu menu = new Menu(GiveNewSpawnMenuHandler);
    menu.SetTitle("Add a spawn");
    AddMenuOption(menu, "finish", "Finish spawn");
    AddMenuOption(menu, "team", "Team: %s", TEAMSTRING(g_EditingSpawnTeams[client]));
    AddMenuOption(menu, "site", "Bombsite: %s", SITESTRING(g_EditingSite));

    char typeString[32];
    if (g_EditingSpawnTypes[client] == SpawnType_Normal) {
        typeString = "Normal";
    } else if (g_EditingSpawnTypes[client] == SpawnType_OnlyWithBomb) {
        typeString = "Bomb-carrier only";
    } else {
        typeString = "Never bomb-carrier";
    }
    if (g_EditingSpawnTeams[client] == CS_TEAM_CT) {
        AddMenuOptionDisabled(menu, "type", "Spawn type: %s", typeString);
    } else {
        AddMenuOption(menu, "type", "T spawn type: %s", typeString);
    }

    menu.ExitButton = false;
    menu.ExitBackButton = true;

    if (menu.Display(client, MENU_TIME_FOREVER)) {
        RememberEditorMenu(client, menu, EditorMenu_NewSpawn, -1);
    }
}

public int GiveNewSpawnMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select || action == MenuAction_Cancel) {
        ForgetEditorMenu(param1, menu);
    }

    if (action == MenuAction_Select) {
        int client = param1;
        char choice[64];
        menu.GetItem(param2, choice, sizeof(choice));
        if (StrEqual(choice, "finish")) {
            AddSpawn(client);
        } else if (StrEqual(choice, "team")) {
            g_EditingSpawnTeams[client] = GetOtherTeam(g_EditingSpawnTeams[client]);
        } else if (StrEqual(choice, "site")) {
            SetEditingSite(GetOtherSite(g_EditingSite));
        } else if (StrEqual(choice, "type")) {
            g_EditingSpawnTypes[client] = NextSpawnType(g_EditingSpawnTypes[client]);
        } else {
            LogError("unknown menu info string = %s", choice);
            return 0;
        }
        GiveNewSpawnMenu(client);
    } else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack) {
        int client = param1;
        GiveEditorMenu(client);
    } else if (action == MenuAction_End) {
        delete menu;
    }

    return 0;
}

static SpawnType NextSpawnType(SpawnType type) {
    if (type == SpawnType_Normal) {
        return SpawnType_OnlyWithBomb;
    } else if (type == SpawnType_OnlyWithBomb) {
        return SpawnType_NeverWithBomb;
    } else {
        return SpawnType_Normal;
    }
}
