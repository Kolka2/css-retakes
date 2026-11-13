// The spawn editor: entering and leaving edit mode, drawing the spawns, adding,
// deleting and visiting them. Included only from retakes.sp.

int g_iBeamSprite = 0;
int g_iHaloSprite = 0;
Bombsite g_EditingSite = BombsiteA;
int g_EditorCursor[MAXPLAYERS+1] = {-1, ...}; // the spawn the editor visited last (for !next / !prev)

/**
 * Precaches the sprites the editor draws the spawns with. Called on every map start.
 */
void PrecacheEditorSprites() {
    // CSS-VERIFY: CS:S has sprites/laserbeam.vmt and sprites/halo01.vmt (CS:GO had
    // sprites/halo.vmt); the spawn rings and arrows are visible in the editor.
    g_iBeamSprite = PrecacheModel("sprites/laserbeam.vmt", true);
    g_iHaloSprite = PrecacheModel("sprites/halo01.vmt", true);
}

/**
 * Closes the editor and starts the retakes. If a warmup is still running (it was kept
 * alive while the editor was open, see Warmup_OnEnding) it is ended first; its
 * Warmup_OnEnd then goes live.
 */
void ExitEditMode() {
    g_EditMode = false;
    if (Retakes_InWarmup()) {
        Warmup_End(false);
    } else {
        GoLive();
    }
}

void MovePlayerToEditMode(int client) {
    SwitchPlayerTeam(client, CS_TEAM_CT);
    CS_RespawnPlayer(client);
}

void ShowSpawns(Bombsite site) {
    g_EditingSite = site;
    Retakes_MessageToAll("Showing spawns for bombsite \x04%s.", SITESTRING(site));

    int ct_count = 0;
    int t_count = 0;
    for (int i = 0; i < g_NumSpawns; i++) {
        if (SpawnFilter(i)) {
            if (g_SpawnTeams[i] == CS_TEAM_CT) {
                ct_count++;
            } else {
                t_count++;
            }
        }
    }
    Retakes_MessageToAll("Found %d CT spawns.", ct_count);
    Retakes_MessageToAll("Found %d T spawns.", t_count);
}

public Action Timer_ShowSpawns(Handle timer) {
    if (!g_EditMode || g_hEditorEnabled.IntValue == 0)
        return Plugin_Continue;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsPlayer(i)) {
            continue;
        }

        for (int j = 0; j < g_NumSpawns; j++) {
            if (SpawnFilter(j)) {
                DisplaySpawnPoint(i, g_SpawnPoints[j], g_SpawnAngles[j], 40.0, g_SpawnTeams[j] == CS_TEAM_CT, g_SpawnTypes[j]);
            }
        }
    }

    return Plugin_Continue;
}

/**
 * Returns if a spawn exists and belongs to the bombsite the editor is showing.
 */
static bool SpawnFilter(int spawn) {
    return IsValidSpawn(spawn) && g_SpawnSites[spawn] == g_EditingSite;
}

void AddSpawn(int client) {
    g_DirtySpawns = true;
    if (g_NumSpawns + 1 >= MAX_SPAWNS) {
        Retakes_MessageToAll("{DARK_RED}WARNING: {NORMAL}the maximum number of spawns has been reached. New spawns cannot be added.");
        LogError("Maximum number of spawns reached");
        return;
    }

    GetClientAbsOrigin(client, g_SpawnPoints[g_NumSpawns]);
    GetClientEyeAngles(client, g_SpawnAngles[g_NumSpawns]);
    g_SpawnSites[g_NumSpawns] = g_EditingSite;
    g_SpawnTeams[g_NumSpawns] = g_EditingSpawnTeams[client];
    g_SpawnTypes[g_NumSpawns] = g_EditingSpawnTypes[client];
    g_SpawnDeleted[g_NumSpawns] = false;

    Retakes_MessageToAll("Added %s spawn for %s (#%d).",
                         TEAMSTRING(g_EditingSpawnTeams[client]),
                         SITESTRING(g_EditingSite),
                         g_NumSpawns);
    g_NumSpawns++;
}

/**
 * Draws a spawn for one client: a ring on the ground and a line in the view direction.
 * CT spawns are blue; T spawns are red (normal), green (bomb-carrier only) or
 * yellow (never bomb-carrier).
 */
static void DisplaySpawnPoint(int client, const float position[3], const float angles[3],
                              float size, bool ct, SpawnType spawnType) {
    float direction[3];
    GetAngleVectors(angles, direction, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(direction, size/2);
    AddVectors(position, direction, direction);

    int color[4] = {255, 0, 0, 255};
    if (ct) {
        color = {0, 0, 255, 255};
    } else if (spawnType == SpawnType_OnlyWithBomb) {
        color = {0, 255, 0, 255};
    } else if (spawnType != SpawnType_Normal) {
        color = {255, 255, 0, 255};
    }

    TE_SetupBeamRingPoint(position, 10.0, size, g_iBeamSprite, g_iHaloSprite, 0, 0, 1.0, 1.0, 0.0, color, 50, 0);
    TE_SendToClient(client);

    TE_SetupBeamPoints(position, direction, g_iBeamSprite, g_iHaloSprite, 0, 0, 1.0, 1.0, 1.0, 0, 0.0, color, 50);
    TE_SendToClient(client);
}

int FindClosestSpawn(int client) {
    float playerOrigin[3];
    GetClientAbsOrigin(client, playerOrigin);

    int closest = -1;
    float minDist = 0.0;
    for (int i = 0; i < g_NumSpawns; i++) {
        if (!SpawnFilter(i)) {
            continue;
        }

        float dist = GetVectorDistance(g_SpawnPoints[i], playerOrigin);
        if (closest < 0 || dist < minDist) {
            minDist = dist;
            closest = i;
        }
    }
    return closest;
}

void DeleteClosestSpawn(int client) {
    g_DirtySpawns = true;
    int closest = FindClosestSpawn(client);
    if (closest >= 0) {
        Retakes_MessageToAll("Deleted spawn #%d.", closest);
        g_SpawnDeleted[closest] = true;
    }
}

/**
 * Saves the spawns and tells everybody. Returns the number of spawns written, or -1.
 */
int SaveSpawns() {
    int saved = WriteSpawns();
    if (saved >= 0) {
        Retakes_MessageToAll("Map spawns saved.");
    } else {
        Retakes_MessageToAll("{DARK_RED}Failed to save the map spawns{NORMAL}, see the server error log.");
    }
    return saved;
}

void ReloadSpawns() {
    g_NumSpawns = ParseSpawns();
    Retakes_MessageToAll("Imported %d map spawns.", g_NumSpawns);
}

void DeleteMapSpawns() {
    g_NumSpawns = 0;
    Retakes_MessageToAll("All spawns for this map have been deleted");
}

void MoveToSpawnInEditor(int client, int spawnIndex) {
    g_EditorCursor[client] = spawnIndex;
    TeleportEntity(client, g_SpawnPoints[spawnIndex], g_SpawnAngles[spawnIndex], NULL_VECTOR);
    Retakes_Message(client, "Teleporting to spawn {GREEN}%d", spawnIndex);
    Retakes_Message(client, "   Team: {MOSS_GREEN}%s", TEAMSTRING(g_SpawnTeams[spawnIndex]));
    Retakes_Message(client, "   Site: {MOSS_GREEN}%s", SITESTRING(g_SpawnSites[spawnIndex]));
}

/**
 * Teleports the editor to the next (direction 1) or the previous (direction -1) spawn,
 * simply by spawn number, wrapping around at the ends. Deleted spawns are skipped.
 * The walk starts from the spawn the client visited last (any teleport command sets it).
 * The original plugin has no such command, it was added at the owner's request.
 */
void StepToSpawnInEditor(int client, int direction) {
    if (g_NumSpawns <= 0) {
        Retakes_Message(client, "No spawns found");
        return;
    }

    int index = g_EditorCursor[client];
    if (index < 0 || index >= g_NumSpawns) {
        // nowhere yet: "next" is the first spawn, "previous" is the last one
        index = (direction > 0) ? -1 : 0;
    }

    for (int step = 0; step < g_NumSpawns; step++) {
        index += direction;
        if (index >= g_NumSpawns) {
            index = 0;
        } else if (index < 0) {
            index = g_NumSpawns - 1;
        }

        if (IsValidSpawn(index)) {
            // show the rings of the site the spawn belongs to
            g_EditingSite = g_SpawnSites[index];
            MoveToSpawnInEditor(client, index);
            return;
        }
    }

    Retakes_Message(client, "No spawns found");
}
