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
        // Не ошибка: для CS:S спавны создаются редактором (!edit), см. configs/retakes/README.md.
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

    // Каталог может отсутствовать на свежем сервере: готовых спавнов для CS:S в комплекте нет.
    char configDir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, configDir, sizeof(configDir), "configs/retakes");
    if (!DirExists(configDir)) {
        CreateDirectory(configDir, 511);
    }

    char configFile[PLATFORM_MAX_PATH];
    GetConfigFileName(configFile, sizeof(configFile));

    DeleteFile(configFile);
    kv.Rewind();
    if (!kv.ExportToFile(configFile)) {
        LogError("Failed to write the retakes spawns to %s", configFile);
    }
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

    // C4 здесь не выдаётся: этим после спавна всех игроков занимается FixBomb().
}

/**
 * Returns the weapon_c4 entity carried by a client, or -1.
 */
stock int GetClientC4(int client) {
    if (!HasEntProp(client, Prop_Send, "m_hMyWeapons")) {
        return -1;
    }

    char classname[32];
    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon > MaxClients && IsValidEntity(weapon)
            && GetEntityClassname(weapon, classname, sizeof(classname))
            && StrEqual(classname, "weapon_c4")) {
            return weapon;
        }
    }
    return -1;
}

/**
 * Makes sure there is exactly one C4 in the game and the bomb carrier has it.
 * CS:S has no mp_give_player_c4: on every round restart the game itself gives a C4 to a
 * random terrorist (after the players have spawned), so this runs shortly after round_start.
 */
public void FixBomb() {
    // Бомбер мог выйти между подготовкой раунда и его началом - берём другого живого T.
    if (!IsValidClient(g_BombOwner) || !IsPlayerAlive(g_BombOwner) || GetClientTeam(g_BombOwner) != CS_TEAM_T) {
        g_BombOwner = -1;
        ArrayList ts = new ArrayList();
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i) && IsPlayerAlive(i) && GetClientTeam(i) == CS_TEAM_T && g_Team[i] == CS_TEAM_T) {
                ts.Push(i);
            }
        }
        if (ts.Length >= 1) {
            g_BombOwner = RandomElement(ts);
        }
        delete ts;
    }

    int keep = -1;
    if (g_BombOwner != -1) {
        keep = GetClientC4(g_BombOwner);
    }

    // CSS-VERIFY: игра при рестарте раунда сама выдаёт C4 случайному T; удаление лишних weapon_c4
    // (RemovePlayerItem + Kill) ничего не ломает (радар, боты, условия победы).
    for (int i = 1; i <= MaxClients; i++) {
        if (i == g_BombOwner || !IsValidClient(i) || !IsPlayerAlive(i)) {
            continue;
        }
        int c4 = GetClientC4(i);
        if (c4 != -1) {
            RemovePlayerItem(i, c4);
            AcceptEntityInput(c4, "Kill");
        }
    }

    // Бомбы, лежащие на земле (выпали в прошлом раунде или при смене команды).
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "weapon_c4")) != -1) {
        if (entity != keep) {
            AcceptEntityInput(entity, "Kill");
        }
    }

    if (g_BombOwner == -1) {
        return;
    }

    if (keep == -1) {
        keep = GivePlayerItem(g_BombOwner, "weapon_c4");
        if (keep == -1) {
            LogError("Failed to give weapon_c4 to %L", g_BombOwner);
            return;
        }
    }

    // Человеку-бомберу через секунду достаём C4 в руки. Ботам не нужно: они ставят бомбу сами.
    if (!IsFakeClient(g_BombOwner)) {
        CreateTimer(1.0, Timer_SelectBomb, GetClientSerial(g_BombOwner), TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_SelectBomb(Handle timer, int serial) {
    int client = GetClientFromSerial(serial);
    if (client == 0 || client != g_BombOwner || g_bombPlanted || !Retakes_Live()) {
        return Plugin_Handled;
    }

    if (IsPlayerAlive(client) && GetClientC4(client) != -1) {
        // CSS-VERIFY: серверная команда "use weapon_c4" переключает игрока на C4 (в CS:GO для этого
        // плагин нажимал за игрока IN_USE, в CS:S так не работает). Если нет - попробовать ClientCommand "slot5".
        FakeClientCommand(client, "use weapon_c4");
    }

    return Plugin_Handled;
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
