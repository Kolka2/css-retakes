// Команда sm_retakes_validatespawns: проверка спавнов текущей карты.
// Подключается только из retakes.sp.

// Размеры игрока CS:S (стоя): 32x32x72. Проверяем чуть приподнятый и укороченный
// хулл, чтобы спавн на наклонном полу не считался застрявшим.
#define VALIDATE_HULL_LIFT 8.0
#define VALIDATE_HULL_HEIGHT 62.0

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask) {
    return entity < 1 || entity > MaxClients;
}

/**
 * Returns if a player standing on the spawn would be stuck in the map geometry.
 */
static bool IsSpawnBlocked(int spawn) {
    float pos[3];
    pos = g_SpawnPoints[spawn];
    pos[2] += VALIDATE_HULL_LIFT;

    float mins[3] = {-16.0, -16.0, 0.0};
    float maxs[3] = {16.0, 16.0, VALIDATE_HULL_HEIGHT};

    Handle trace = TR_TraceHullFilterEx(pos, pos, mins, maxs, MASK_PLAYERSOLID, TraceFilter_IgnorePlayers);
    bool blocked = TR_DidHit(trace);
    delete trace;
    return blocked;
}

static bool IsSpawnOutsideWorld(int spawn) {
    float pos[3];
    pos = g_SpawnPoints[spawn];
    pos[2] += 36.0; // середина игрока, а не подошвы
    return TR_PointOutsideWorld(pos);
}

public Action Command_ValidateSpawns(int client, int args) {
    int maxPlayers = g_hMaxPlayers.IntValue;
    int maxT = RoundToNearest(g_hRatioConstant.FloatValue * float(maxPlayers));
    if (maxT < 1) {
        maxT = 1;
    }
    int maxCT = maxPlayers - maxT;

    char mapName[128];
    GetCleanMapName(mapName, sizeof(mapName));
    ReplyToCommand(client, "[Retakes] Spawn check for %s (sm_retakes_maxplayers %d -> up to %d T + %d CT):",
                   mapName, maxPlayers, maxT, maxCT);

    int problems = 0;

    if (g_SiteMins.Length == 0) {
        ReplyToCommand(client, "  ERROR: no bomb targets (func_bomb_target) were found on this map");
        problems++;
    } else {
        ReplyToCommand(client, "  Bomb targets found on the map: %d", g_SiteMins.Length);
    }

    // [site][0] - все T, [1] - T, где может появиться бомбер, [2] - T, где может появиться не бомбер, [3] - CT
    int counts[2][4];
    int total = 0;

    for (int i = 0; i < g_NumSpawns; i++) {
        if (g_SpawnDeleted[i]) {
            continue;
        }
        total++;

        int site = (g_SpawnSites[i] == BombsiteA) ? 0 : 1;
        if (g_SpawnTeams[i] == CS_TEAM_CT) {
            counts[site][3]++;
        } else {
            counts[site][0]++;
            if (CanBombCarrierSpawn(i)) {
                counts[site][1]++;
            }
            if (CanRegularPlayerSpawn(i)) {
                counts[site][2]++;
            }

            if (g_SpawnTypes[i] == SpawnType_OnlyWithBomb && !SpawnInsideBombSite(i)) {
                ReplyToCommand(client, "  ERROR: spawn #%d (T, %s) is bomb-carrier only but is not inside a bomb target - it will never be used",
                               i, SITESTRING(g_SpawnSites[i]));
                problems++;
            }
        }

        if (IsSpawnOutsideWorld(i)) {
            ReplyToCommand(client, "  ERROR: spawn #%d (%s, %s) is outside of the map",
                           i, TEAMSTRING(g_SpawnTeams[i]), SITESTRING(g_SpawnSites[i]));
            problems++;
        } else if (IsSpawnBlocked(i)) {
            ReplyToCommand(client, "  WARNING: spawn #%d (%s, %s) is inside a wall or an object, a player may get stuck",
                           i, TEAMSTRING(g_SpawnTeams[i]), SITESTRING(g_SpawnSites[i]));
            problems++;
        }
    }

    for (int site = 0; site < 2; site++) {
        char siteName[4];
        strcopy(siteName, sizeof(siteName), site == 0 ? "A" : "B");
        int siteTotal = counts[site][0] + counts[site][3];

        ReplyToCommand(client, "  Site %s: %d T spawns (%d usable by the bomb carrier, %d by the others), %d CT spawns",
                       siteName, counts[site][0], counts[site][1], counts[site][2], counts[site][3]);

        if (counts[site][1] < 1) {
            ReplyToCommand(client, "  ERROR: site %s has no T spawn inside the bomb target for the bomb carrier", siteName);
            problems++;
        }
        if (counts[site][0] < maxT) {
            ReplyToCommand(client, "  ERROR: site %s needs at least %d T spawns, it has %d", siteName, maxT, counts[site][0]);
            problems++;
        } else if (counts[site][2] < maxT - 1) {
            ReplyToCommand(client, "  ERROR: site %s needs at least %d T spawns usable without the bomb, it has %d",
                           siteName, maxT - 1, counts[site][2]);
            problems++;
        }
        if (counts[site][3] < maxCT) {
            ReplyToCommand(client, "  ERROR: site %s needs at least %d CT spawns, it has %d", siteName, maxCT, counts[site][3]);
            problems++;
        }
        if (siteTotal < maxPlayers) {
            ReplyToCommand(client, "  WARNING: site %s has %d spawns in total, fewer than sm_retakes_maxplayers (%d)",
                           siteName, siteTotal, maxPlayers);
            problems++;
        }
    }

    if (total < maxPlayers) {
        ReplyToCommand(client, "  ERROR: the map has %d spawns, the plugin needs at least sm_retakes_maxplayers (%d) to run at all",
                       total, maxPlayers);
        problems++;
    }

    if (g_DirtySpawns) {
        ReplyToCommand(client, "  Note: there are unsaved spawn changes (use sm_savespawns)");
    }

    if (problems == 0) {
        ReplyToCommand(client, "[Retakes] %d spawns checked, no problems found.", total);
    } else {
        ReplyToCommand(client, "[Retakes] %d spawns checked, %d problem(s) found.", total, problems);
    }

    return Plugin_Handled;
}
