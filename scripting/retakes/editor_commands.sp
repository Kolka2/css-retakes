// Admin commands of the spawn editor. Included only from retakes.sp.

/**
 * Common checks of the editor commands. Returns false, after telling the client why,
 * if the editor is disabled or (with needEditMode) edit mode is not on.
 */
static bool CheckEditorCommand(int client, bool needEditMode) {
    if (g_hEditorEnabled.IntValue == 0) {
        Retakes_Message(client, "The editor is currently disabled.");
        return false;
    }

    if (needEditMode && !g_EditMode) {
        Retakes_Message(client, "You are not in edit mode.");
        return false;
    }

    return true;
}

public Action Command_EditSpawns(int client, int args) {
    if (!CheckEditorCommand(client, false)) {
        return Plugin_Handled;
    }

    if (!g_EditMode) {
        // The flag itself turns on the editor's free play (respawn, endless round),
        // see editor_freeplay.sp.
        g_EditMode = true;
        // The bots leave the editor right away, without waiting for the one-second timer.
        UpdateBotQuota(false);
        for (int i = 1; i <= MaxClients; i++) {
            if (IsPlayer(i)) {
                MovePlayerToEditMode(i);
            }
        }

        Retakes_MessageToAll("Edit mode launched, basic commands:");
        Retakes_MessageToAll("!edit to bring up the editor menu");
        Retakes_MessageToAll("!show <a/b> to display spawn points for a site");
        Retakes_MessageToAll("!new <ct/t> <a/b> to add a spawn point");
        Retakes_MessageToAll("!delete to delete the nearest spawn");
        Retakes_MessageToAll("!endedit to leave edit mode");
    }

    GiveEditorMenu(client);
    return Plugin_Handled;
}

/**
 * Leaves edit mode, like the "Exit edit mode" item of the editor menu. The original
 * plugin has no such command, it was added at the owner's request.
 */
public Action Command_EndEdit(int client, int args) {
    if (CheckEditorCommand(client, true)) {
        ExitEditMode();
    }
    return Plugin_Handled;
}

public Action Command_ReloadSpawns(int client, int args) {
    if (CheckEditorCommand(client, false)) {
        ReloadSpawns();
    }
    return Plugin_Handled;
}

public Action Command_SaveSpawns(int client, int args) {
    if (CheckEditorCommand(client, false)) {
        // the original plugin printed g_NumSpawns here, which also counts deleted spawns
        int saved = SaveSpawns();
        if (saved >= 0) {
            Retakes_Message(client, "Saved %d spawns.", saved);
        }
    }
    return Plugin_Handled;
}

public Action Command_AddSpawn(int client, int args) {
    if (!CheckEditorCommand(client, true)) {
        return Plugin_Handled;
    }

    char arg1[32];
    char arg2[32];
    if (args >= 2 && GetCmdArg(1, arg1, sizeof(arg1)) && GetCmdArg(2, arg2, sizeof(arg2))) {
        int team;
        if (StrEqual(arg1, "CT", false)) {
            team = CS_TEAM_CT;
        } else if (StrEqual(arg1, "T", false)) {
            team = CS_TEAM_T;
        } else {
            ReplyToCommand(client, "Invalid team name: %s", arg1);
            return Plugin_Handled;
        }

        Bombsite site;
        if (StrEqual(arg2, "A", false)) {
            site = BombsiteA;
        } else if (StrEqual(arg2, "B", false)) {
            site = BombsiteB;
        } else {
            ReplyToCommand(client, "Invalid bomb site name: %s", arg2);
            return Plugin_Handled;
        }

        g_EditingSpawnTeams[client] = team;
        SetEditingSite(site);
        g_EditingSpawnTypes[client] = SpawnType_Normal;
        AddSpawn(client);
    } else {
        GiveNewSpawnMenu(client);
    }

    return Plugin_Handled;
}

public Action Command_Show(int client, int args) {
    if (!CheckEditorCommand(client, true)) {
        return Plugin_Handled;
    }

    char arg[32];
    if (args < 1 || !GetCmdArg(1, arg, sizeof(arg))) {
        ReplyToCommand(client, "Usage: sm_show <a|b>");
    } else if (StrEqual(arg, "A", false)) {
        ShowSpawns(BombsiteA);
    } else if (StrEqual(arg, "B", false)) {
        ShowSpawns(BombsiteB);
    } else {
        // the original plugin treated anything but "a" as bombsite B
        ReplyToCommand(client, "Invalid bomb site name: %s", arg);
    }
    return Plugin_Handled;
}

public Action Command_DeleteSpawn(int client, int args) {
    if (CheckEditorCommand(client, true)) {
        DeleteClosestSpawn(client);
    }
    return Plugin_Handled;
}

public Action Command_DeleteMapSpawns(int client, int args) {
    if (CheckEditorCommand(client, false)) {
        DeleteMapSpawns();
    }
    return Plugin_Handled;
}

/**
 * Starts the timer that takes a client to the next existing spawn at or after spawnIndex.
 */
static void ScheduleSpawnIteration(int serial, int spawnIndex) {
    DataPack pack;
    CreateDataTimer(2.0, Timer_IterateSpawns, pack);
    pack.WriteCell(serial);
    pack.WriteCell(spawnIndex);
}

public Action Command_IterateSpawns(int client, int args) {
    if (!CheckEditorCommand(client, true)) {
        return Plugin_Handled;
    }

    int startIndex = 0;
    char buf[32];
    if (args >= 1 && GetCmdArg(1, buf, sizeof(buf))) {
        startIndex = StringToInt(buf);
    }
    if (startIndex < 0) {
        startIndex = 0;
    }

    ScheduleSpawnIteration(GetClientSerial(client), startIndex);
    return Plugin_Handled;
}

public Action Timer_IterateSpawns(Handle timer, DataPack data) {
    data.Reset();
    int serial = data.ReadCell();
    int spawnIndex = data.ReadCell();
    int client = GetClientFromSerial(serial);

    if (!IsPlayer(client) || !g_EditMode)
        return Plugin_Handled;

    if (IsValidSpawn(spawnIndex)) {
        VisitSpawnInEditor(client, spawnIndex);
    }

    spawnIndex++;
    while (spawnIndex < g_NumSpawns && g_SpawnDeleted[spawnIndex]) {
        spawnIndex++;
    }

    if (spawnIndex < g_NumSpawns) {
        ScheduleSpawnIteration(serial, spawnIndex);
    }

    return Plugin_Handled;
}

public Action Command_GotoSpawn(int client, int args) {
    if (!CheckEditorCommand(client, true)) {
        return Plugin_Handled;
    }

    char buffer[32];
    if (args < 1 || !GetCmdArg(1, buffer, sizeof(buffer))) {
        ReplyToCommand(client, "Usage: sm_goto <spawn number>");
        return Plugin_Handled;
    }

    int spawn = StringToInt(buffer);
    if (IsValidSpawn(spawn)) {
        VisitSpawnInEditor(client, spawn);
    } else {
        // the original plugin stayed silent here
        ReplyToCommand(client, "There is no spawn #%d (the numbers go from 0 to %d, deleted spawns are skipped).",
                       spawn, g_NumSpawns - 1);
    }

    return Plugin_Handled;
}

public Action Command_GotoNearestSpawn(int client, int args) {
    if (!CheckEditorCommand(client, true)) {
        return Plugin_Handled;
    }

    int spawn = FindClosestSpawn(client);
    if (IsValidSpawn(spawn)) {
        MoveToSpawnInEditor(client, spawn);
    }

    return Plugin_Handled;
}

static Action StepSpawnCommand(int client, int direction) {
    if (CheckEditorCommand(client, true) && IsPlayer(client)) {
        StepToSpawnInEditor(client, direction);
    }
    return Plugin_Handled;
}

public Action Command_NextSpawn(int client, int args) {
    return StepSpawnCommand(client, 1);
}

public Action Command_PrevSpawn(int client, int args) {
    return StepSpawnCommand(client, -1);
}
