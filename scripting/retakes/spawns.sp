// Retake spawns: the bomb targets of the map, the spawn config file and the choice of
// a spawn for a player. Included only from retakes.sp.

Bombsite GetOtherSite(Bombsite site) {
    return (site == BombsiteA) ? BombsiteB : BombsiteA;
}

static void GetConfigFileName(char[] buffer, int size) {
    // get the map, with any workshop stuff before removed
    char mapName[128];
    GetCleanMapName(mapName, sizeof(mapName));
    BuildPath(Path_SM, buffer, size, "configs/retakes/%s.cfg", mapName);
}

/**
 * Reads the bounding box of an entity in world coordinates.
 */
static bool GetEntityWorldBounds(int entity, float mins[3], float maxs[3]) {
    // Checked on a live CS:S server: func_bomb_target in CS:S has m_vecMins/m_vecMaxs, and together with
    // m_vecOrigin they give the bomb target in world coordinates (a spawn inside the
    // bombsite is detected correctly).
    if (HasEntProp(entity, Prop_Send, "m_vecMins") && HasEntProp(entity, Prop_Send, "m_vecMaxs")) {
        GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
    } else if (HasEntProp(entity, Prop_Data, "m_vecMins") && HasEntProp(entity, Prop_Data, "m_vecMaxs")) {
        GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
    } else {
        return false;
    }

    // Brush entities usually have a zero origin, but that is not relied upon.
    float origin[3];
    if (HasEntProp(entity, Prop_Send, "m_vecOrigin")) {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    } else if (HasEntProp(entity, Prop_Data, "m_vecOrigin")) {
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
    }
    AddVectors(mins, origin, mins);
    AddVectors(maxs, origin, maxs);
    return true;
}

void FindSites() {
    g_SiteMins.Clear();
    g_SiteMaxs.Clear();

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "func_bomb_target")) != -1) {
        float vecBombsiteMin[3];
        float vecBombsiteMax[3];
        if (!GetEntityWorldBounds(entity, vecBombsiteMin, vecBombsiteMax)) {
            LogError("Could not read the bounds of func_bomb_target (entity %d)", entity);
            continue;
        }
        g_SiteMins.PushArray(vecBombsiteMin);
        g_SiteMaxs.PushArray(vecBombsiteMax);
    }

    if (g_SiteMins.Length == 0) {
        LogMessage("No bomb targets (func_bomb_target) were found on this map - retakes cannot be played on it");
    }
    DebugLog("map: found %d bomb target(s)", g_SiteMins.Length);
}

/**
 * Reads the scenario keyvalues config file and sets up the global scenario and player arrays.
 */
int ParseSpawns() {
    g_DirtySpawns = false;
    char configFile[PLATFORM_MAX_PATH];
    GetConfigFileName(configFile, sizeof(configFile));

    if (!FileExists(configFile)) {
        // Not an error: CS:S spawns are made with the editor (!edit), see configs/retakes/README.md.
        LogMessage("No retakes spawns for this map yet (%s). Create them with the editor: !edit", configFile);
        return 0;
    }

    KeyValues kv = new KeyValues("Spawns");
    if (!kv.ImportFromFile(configFile) || !kv.GotoFirstSubKey()) {
        LogError("The retakes config file was empty");
        delete kv;
        return 0;
    }

    int spawn = 0;

    do {
        char sBuf[32];
        float vec[3];

        // throw away the section name
        kv.GetSectionName(sBuf, sizeof(sBuf));

        kv.GetVector("origin", vec, NULL_VECTOR);
        g_SpawnPoints[spawn] = vec;

        kv.GetVector("angle", vec, NULL_VECTOR);
        g_SpawnAngles[spawn] = vec;

        kv.GetString("bombsite", sBuf, sizeof(sBuf), "A");
        g_SpawnSites[spawn] = (StrEqual(sBuf, "A")) ? BombsiteA : BombsiteB;

        kv.GetString("team", sBuf, sizeof(sBuf), "T");
        g_SpawnTeams[spawn] = (StrEqual(sBuf, "CT")) ? CS_TEAM_CT : CS_TEAM_T;

        // Backwards compatibility with "nobomb" key.
        // These are converted into the "type" key when spawns are saved.
        if (kv.GetNum("nobomb") == 1) {
            g_SpawnTypes[spawn] = SpawnType_NeverWithBomb;
        } else {
            int type = kv.GetNum("type");
            if (type < view_as<int>(SpawnType_Normal) || type > view_as<int>(SpawnType_NeverWithBomb)) {
                // (the original plugin took any number, and the rest of the code then
                // treated it as "never bomb-carrier")
                LogError("Spawn %d in %s has an unknown type %d, using a normal spawn", spawn, configFile, type);
                type = view_as<int>(SpawnType_Normal);
            }
            g_SpawnTypes[spawn] = view_as<SpawnType>(type);
        }

        g_SpawnDeleted[spawn] = false;

        spawn++;
        if (spawn == MAX_SPAWNS) {
            LogError("Hit the max number of spawns");
            break;
        }

    } while (kv.GotoNextKey());

    delete kv;
    return spawn;
}


/**
 * Writes the stored scenario structures back to the config file.
 * Returns the number of spawns written, or -1 if the file could not be written.
 */
int WriteSpawns() {
    KeyValues kv = new KeyValues("Spawns");
    int output_index = 0;

    for (int spawn = 0; spawn < g_NumSpawns; spawn++) {
        if (spawn == MAX_SPAWNS) {
            LogError("Hit the max number (%d) of spawns", MAX_SPAWNS);
            break;
        }

        if (g_SpawnDeleted[spawn])
            continue;

        char sBuf[32];
        IntToString(output_index, sBuf, sizeof(sBuf));
        output_index++;
        kv.JumpToKey(sBuf, true);

        kv.SetVector("origin", g_SpawnPoints[spawn]);
        kv.SetVector("angle", g_SpawnAngles[spawn]);
        kv.SetString("bombsite", SITESTRING(g_SpawnSites[spawn]));
        kv.SetString("team", TEAMSTRING(g_SpawnTeams[spawn]));
        kv.SetNum("type", view_as<int>(g_SpawnTypes[spawn]));

        kv.GoBack();
    }

    // The directory may be missing on a fresh server: no CS:S spawns are shipped.
    char configDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configDir, sizeof(configDir), "configs/retakes");
    if (!DirExists(configDir)) {
        CreateDirectory(configDir, 511);
    }

    char configFile[PLATFORM_MAX_PATH];
    GetConfigFileName(configFile, sizeof(configFile));

    DeleteFile(configFile);
    kv.Rewind();
    if (output_index == 0) {
        // Every spawn was deleted: no file at all, like on a map that was never set up.
        g_DirtySpawns = false;
    } else if (kv.ExportToFile(configFile)) {
        // Everything is on disk, there are no unsaved changes any more (the original
        // did not reset the flag here, so sm_retakes_validatespawns kept reporting
        // unsaved changes after a save).
        g_DirtySpawns = false;
    } else {
        LogError("Failed to write the retakes spawns to %s", configFile);
        output_index = -1;
    }
    delete kv;
    return output_index;
}

static bool InsideBombSite(float vec[3]) {
    for (int i = 0; i < g_SiteMaxs.Length; i++) {
        float min[3];
        float max[3];

        g_SiteMins.GetArray(i, min, sizeof(min));
        g_SiteMaxs.GetArray(i, max, sizeof(max));

        bool in_x = (min[0] <= vec[0] && vec[0] <= max[0]) || (max[0] <= vec[0] && vec[0] <= min[0]);
        bool in_y = (min[1] <= vec[1] && vec[1] <= max[1]) || (max[1] <= vec[1] && vec[1] <= min[1]);

        if (in_x && in_y) {
            return true;
        }

    }
    return false;
}

bool SpawnInsideBombSite(int spawnIndex) {
    return InsideBombSite(g_SpawnPoints[spawnIndex]);
}

/**
 * Returns if the bomb carrier may be put on a spawn.
 *
 * This is the rule of the original plugin and must stay as it is (see PORT/PROGRESS.md):
 * the bomb carrier may use any T spawn INSIDE a bomb target, except the ones marked
 * "never bomb-carrier". That is, not only SpawnType_OnlyWithBomb but an ordinary
 * SpawnType_Normal as well. The "bomb-carrier only" type does not tie the carrier to
 * that spawn, it only closes the spawn for the other terrorists (see
 * CanRegularPlayerSpawn). To make the carrier appear on dedicated spots only, mark the
 * other T spawns inside the bomb target as SpawnType_NeverWithBomb.
 *
 * If the site has no suitable spawn, SelectSpawn puts the carrier on any regular T spawn
 * and logs an error.
 */
bool CanBombCarrierSpawn(int spawn) {
    if (g_SpawnTeams[spawn] == CS_TEAM_CT)
        return false;
    return (g_SpawnTypes[spawn] != SpawnType_NeverWithBomb) && SpawnInsideBombSite(spawn);
}

/**
 * Returns if a player without the bomb may be put on a spawn.
 * A CT may use any CT spawn; a T may use any T spawn except "bomb-carrier only".
 * Whether the spawn is inside a bomb target does not matter here.
 */
bool CanRegularPlayerSpawn(int spawn) {
    if (g_SpawnTeams[spawn] == CS_TEAM_CT)
        return true;
    return g_SpawnTypes[spawn] != SpawnType_OnlyWithBomb;
}

/**
 * Returns if a bombsite has enough spawns to play a round with the given team sizes:
 * numT terrorist spawns (at least one of them usable by the bomb carrier) and numCT CT spawns.
 */
bool SiteHasSpawns(Bombsite site, int numT, int numCT) {
    int tCount = 0, ctCount = 0, bombCount = 0;
    for (int i = 0; i < g_NumSpawns; i++) {
        if (g_SpawnDeleted[i] || g_SpawnSites[i] != site) {
            continue;
        }
        if (g_SpawnTeams[i] == CS_TEAM_CT) {
            ctCount++;
        } else {
            tCount++;
            if (CanBombCarrierSpawn(i)) {
                bombCount++;
            }
        }
    }
    return tCount >= numT && ctCount >= numCT && bombCount >= 1;
}

/**
 * Returns an appropriate spawn index for a player.
 */
int SelectSpawn(int team, bool bombSpawn) {
    ArrayList potentialSpawns = new ArrayList();
    for (int i = 0; i < g_NumSpawns; i++) {
        if (g_SpawnDeleted[i]) {
            continue;
        }
        if (g_SpawnTeams[i] == team && !g_SpawnTaken[i] && g_Bombsite == g_SpawnSites[i]) {
            if ((bombSpawn && CanBombCarrierSpawn(i)) || (!bombSpawn && CanRegularPlayerSpawn(i))) {
                potentialSpawns.Push(i);
            }
        }
    }

    if (potentialSpawns.Length == 0) {
        delete potentialSpawns;
        char mapName[128];
        GetCurrentMap(mapName, sizeof(mapName));
        if (bombSpawn) {
            LogError("Had to resort to fallback spawn on %s, site=%d", mapName, g_Bombsite);
            return SelectSpawn(team, false);
        } else {
            LogError("Failed to get any spawn on %s, site=%d, team=%d", mapName, g_Bombsite, team);
            return -1;
        }
    } else {
        int choice = RandomElement(potentialSpawns);
        g_SpawnTaken[choice] = true;
        delete potentialSpawns;
        return choice;
    }
}

bool IsValidSpawn(int index) {
    return index >= 0 && index < g_NumSpawns && !g_SpawnDeleted[index];
}
