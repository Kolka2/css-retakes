static void GetConfigFileName(char[] buffer, int size) {
    // get the map, with any workshop stuff before removed
    char mapName[128];
    GetCleanMapName(mapName, sizeof(mapName));
    BuildPath(Path_SM, buffer, size, "configs/retakes/%s.cfg", mapName);
}

public void FindSites() {
    g_SiteMins.Clear();
    g_SiteMaxs.Clear();

    int maxEnt = GetMaxEntities();
    char sClassName[128];
    for (int i = MaxClients; i < maxEnt; i++) {
        bool valid = IsValidEdict(i) && IsValidEntity(i);
        if (valid && GetEdictClassname(i, sClassName, sizeof(sClassName))) {
            if (StrEqual(sClassName, "func_bomb_target")) {
                float vecBombsiteMin[3];
                float vecBombsiteMax[3];
                GetEntPropVector(i, Prop_Send, "m_vecMins", vecBombsiteMin);
                GetEntPropVector(i, Prop_Send, "m_vecMaxs", vecBombsiteMax);
                g_SiteMins.PushArray(vecBombsiteMin);
                g_SiteMaxs.PushArray(vecBombsiteMax);
            }
        }
    }
}

/**
 * Reads the scenario keyvalues config file and sets up the global scenario and player arrays.
 */
public int ParseSpawns() {
    g_DirtySpawns = false;
    char configFile[PLATFORM_MAX_PATH];
    GetConfigFileName(configFile, sizeof(configFile));

    if (!FileExists(configFile)) {
        LogError("The retakes config file (%s) does not exist", configFile);
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
            g_SpawnTypes[spawn] = view_as<SpawnType>(kv.GetNum("type"));
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
 */
public void WriteSpawns() {
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

    char configFile[PLATFORM_MAX_PATH];
    GetConfigFileName(configFile, sizeof(configFile));

    DeleteFile(configFile);
    kv.Rewind();
    kv.ExportToFile(configFile);
    delete kv;
}

/**
 * Sets up a player for the round, giving weapons, teleporting, etc.
 */
public void SetupPlayer(int client) {
    int spawnIndex = g_SpawnIndices[client];
    if (spawnIndex < 0)
        return;

    SwitchPlayerTeam(client, g_Team[client]);
    MoveToSpawn(client, spawnIndex);
    GiveWeapons(client);
}

public void MoveToSpawn(int client, int spawnIndex) {
    TeleportEntity(client, g_SpawnPoints[spawnIndex], g_SpawnAngles[spawnIndex], NULL_VECTOR);
}

/**
 * Gives a weapon by its class name. Empty names are skipped (an allocator may leave
 * the primary weapon empty). Returns the weapon entity or -1.
 */
static int GiveWeapon(int client, const char[] weapon) {
    if (weapon[0] == '\0') {
        return -1;
    }

    int entity = GivePlayerItem(client, weapon);
    if (entity == -1) {
        // Чаще всего это имя оружия из CS:GO, пришедшее от стороннего аллокатора.
        LogError("Failed to give \"%s\" to %L: no such weapon in CS:S?", weapon, client);
    }
    return entity;
}

/**
 * Fills the reserve ammo of every firearm the client carries.
 */
static void RefillAmmo(int client) {
    if (!HasEntProp(client, Prop_Send, "m_hMyWeapons")) {
        return;
    }

    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon <= MaxClients || !IsValidEntity(weapon)) {
            continue;
        }

        // У ножа, гранат и C4 магазина нет (m_iClip1 == -1): их не трогаем,
        // иначе, например, флешек стало бы две.
        if (!HasEntProp(weapon, Prop_Send, "m_iClip1") || GetEntProp(weapon, Prop_Send, "m_iClip1") < 0) {
            continue;
        }
        if (!HasEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType")) {
            continue;
        }

        int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
        if (ammoType >= 0) {
            // CSS-VERIFY: GivePlayerAmmo в CS:S обрезает запас до максимума для типа патронов
            // (AK-47: 30/90, а не 30/999), а оружие от GivePlayerItem приходит с полным магазином.
            GivePlayerAmmo(client, 999, ammoType, true);
        }
    }
}

/**
 * Sets the money of a client. Retakes hands out the equipment itself, so nobody
 * (the bots first of all) should be able to buy on top of it.
 */
stock void SetClientMoney(int client, int money) {
    // CSS-VERIFY: у CCSPlayer есть m_iAccount, при нуле ни люди, ни боты ничего не покупают.
    if (HasEntProp(client, Prop_Send, "m_iAccount")) {
        SetEntProp(client, Prop_Send, "m_iAccount", money);
    }
}

public void GiveWeapons(int client) {
    if (!IsValidClient(client)) {
        return;
    }

    // CSS-VERIFY: снятие и выдача оружия прямо в player_spawn работают в CS:S: игра не выдаёт
    // после события стандартный пистолет поверх нашего и не оставляет игрока без ножа.
    RemoveAllWeapons(client);

    // В CS:S один нож на обе команды (weapon_knife_t нет).
    GiveWeapon(client, "weapon_knife");
    GiveWeapon(client, g_PlayerPrimary[client]);
    GiveWeapon(client, g_PlayerSecondary[client]);

    SetClientArmor(client, g_PlayerArmor[client]);
    SetEntityHealth(client, g_PlayerHealth[client]);

    // CSS-VERIFY: у CCSPlayer есть m_bHasHelmet и m_bHasDefuser.
    if (HasEntProp(client, Prop_Send, "m_bHasHelmet")) {
        SetEntProp(client, Prop_Send, "m_bHasHelmet", g_PlayerHelmet[client]);
    }
    if (HasEntProp(client, Prop_Send, "m_bHasDefuser")) {
        SetEntProp(client, Prop_Send, "m_bHasDefuser", g_Team[client] == CS_TEAM_CT && g_PlayerKit[client]);
    }

    // В CS:S есть только осколочная, световая и дымовая гранаты.
    // Остальные буквы (m, i, d из CS:GO) молча пропускаются.
    int len = strlen(g_PlayerNades[client]);
    for (int i = 0; i < len; i++) {
        switch (g_PlayerNades[client][i]) {
            case 'h': GiveWeapon(client, "weapon_hegrenade");
            case 'f': GiveWeapon(client, "weapon_flashbang");
            case 's': GiveWeapon(client, "weapon_smokegrenade");
        }
    }

    RefillAmmo(client);
    SetClientMoney(client, 0);

    if (g_BombOwner == client) {
        g_bombPlantSignal = false;
        GivePlayerItem(client, "weapon_c4");
        CreateTimer(1.0, Timer_StartPlant, client);
    }
}

public Action Timer_StartPlant(Handle timer, int client) {
    if (IsPlayer(client)) {
        g_bombPlantSignal = true;
    }

    return Plugin_Continue;
}

public bool InsideBombSite(float vec[3]) {
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

public bool SpawnInsideBombSite(int spawnIndex) {
    return InsideBombSite(g_SpawnPoints[spawnIndex]);
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3],
                             int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2]) {
    // Forces the player to get the bomb out on their spawn.
    // The signal is fired by a timer after the bomb-carrier's spawn.
    if (g_bombPlantSignal && !g_bombPlanted && client == g_BombOwner) {
        buttons |= IN_USE;
        g_bombPlantSignal = false;
    }

    return Plugin_Continue;
}

public bool CanBombCarrierSpawn(int spawn) {
    if (g_SpawnTeams[spawn] == CS_TEAM_CT)
        return false;
    return (g_SpawnTypes[spawn] != SpawnType_NeverWithBomb) && SpawnInsideBombSite(spawn);
}

public bool CanRegularPlayerSpawn(int spawn) {
    if (g_SpawnTeams[spawn] == CS_TEAM_CT)
        return true;
    return g_SpawnTypes[spawn] != SpawnType_OnlyWithBomb;
}

/**
 * Returns an appropriate spawn index for a player.
 */
public int SelectSpawn(int team, bool bombSpawn) {
    ArrayList potentialSpawns = new ArrayList();
    for (int i = 0; i < g_NumSpawns; i++) {
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

public bool IsValidSpawn(int index) {
    return index >= 0 && index < g_NumSpawns && !g_SpawnDeleted[index];
}
