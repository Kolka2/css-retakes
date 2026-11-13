// Menus of the spawn editor. Included only from retakes.sp.

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

    if (menuPosition == -1) {
        menu.Display(client, MENU_TIME_FOREVER);
    } else {
        menu.DisplayAt(client, menuPosition, MENU_TIME_FOREVER);
    }
}

public int EditorMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_End) {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select) {
        return 0;
    }

    int client = param1;
    char choice[64];
    menu.GetItem(param2, choice, sizeof(choice));
    int menuPosition = GetMenuSelectionPosition();

    // These two leave the editor menu; every other item brings it back.
    if (StrEqual(choice, "end_edit")) {
        Retakes_MessageToAll("Exiting edit mode.");
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

    menu.Display(client, MENU_TIME_FOREVER);
}

public int GiveNewSpawnMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char choice[64];
        menu.GetItem(param2, choice, sizeof(choice));
        if (StrEqual(choice, "finish")) {
            AddSpawn(client);
        } else if (StrEqual(choice, "team")) {
            g_EditingSpawnTeams[client] = GetOtherTeam(g_EditingSpawnTeams[client]);
        } else if (StrEqual(choice, "site")) {
            g_EditingSite = GetOtherSite(g_EditingSite);
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
