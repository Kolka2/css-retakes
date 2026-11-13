// Natives of include/retakes.inc. Included only from retakes.sp.

#define CHECK_CONNECTED(%1) if (!IsClientConnected(%1)) ThrowNativeError(SP_ERROR_PARAM, "Client %d is not connected", %1)

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    // This fork is for Counter-Strike: Source only (see PORT/PLAN.md, decision 1).
    if (GetEngineVersion() != Engine_CSS) {
        strcopy(error, err_max, "This build of Retakes only supports Counter-Strike: Source");
        return APLRes_Failure;
    }

    CreateNative("Retakes_IsJoined", Native_IsJoined);
    CreateNative("Retakes_IsInQueue", Native_IsInQueue);
    CreateNative("Retakes_Message", Native_RetakeMessage);
    CreateNative("Retakes_MessageToAll", Native_RetakeMessageToAll);
    CreateNative("Retakes_GetNumActiveTs", Native_GetNumActiveTs);
    CreateNative("Retakes_GetNumActiveCTs", Native_GetNumActiveCTs);
    CreateNative("Retakes_GetNumActivePlayers", Native_GetNumActivePlayers);
    CreateNative("Retakes_GetCurrrentBombsite", Native_GetCurrrentBombsite);
    CreateNative("Retakes_GetRoundPoints", Native_GetRoundPoints);
    CreateNative("Retakes_SetRoundPoints", Native_SetRoundPoints);
    CreateNative("Retakes_ChangeRoundPoints", Native_ChangeRoundPoints);
    CreateNative("Retakes_GetPlayerInfo", Native_GetPlayerInfo);
    CreateNative("Retakes_SetPlayerInfo", Native_SetPlayerInfo);
    CreateNative("Retakes_GetRetakeRoundsPlayed", Native_GetRetakeRoundsPlayed);
    CreateNative("Retakes_InEditMode", Native_InEditMode);
    CreateNative("Retakes_InWarmup", Native_InWarmup);
    CreateNative("Retakes_Enabled", Native_Enabled);
    CreateNative("Retakes_GetMaxPlayers", Native_GetMaxPlayers);
    RegPluginLibrary("retakes");
    return APLRes_Success;
}

public int Native_IsJoined(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsParticipant(client))
        return false;
    return IsOnTeam(client) || Queue_Find(g_hWaitingQueue, client) != -1;
}

public int Native_IsInQueue(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsPlayer(client))
        return false;
    return Queue_Find(g_hWaitingQueue, client) != -1;
}

#define MESSAGE_LENGTH 1024
#define PREFIX_LENGTH 64

/**
 * Formats the message of the calling native (the format string is native parameter
 * formatParam) for one client and sends it: to the chat, or to the server console for
 * client 0. Returns the length of the message with the prefix.
 */
static int SendRetakesMessage(int client, int formatParam) {
    char text[MESSAGE_LENGTH];
    int bytesWritten = 0;
    SetGlobalTransTarget(client);
    FormatNativeString(0, formatParam, formatParam + 1, sizeof(text), bytesWritten, text);

    char prefix[PREFIX_LENGTH];
    g_MessagePrefix.GetString(prefix, sizeof(prefix));

    char msg[MESSAGE_LENGTH];
    int length;
    if (client == 0) {
        length = Format(msg, sizeof(msg), "%s %s", prefix, text);
        Colorize(msg, sizeof(msg), true);
        PrintToConsole(0, "%s", msg);
    } else {
        // A CS:S chat message must start with \x01, or the color codes in it do not work.
        length = Format(msg, sizeof(msg), "\x01%s %s", prefix, text);
        Colorize(msg, sizeof(msg));
        PrintToChat(client, "%s", msg);
    }
    return length;
}

public int Native_RetakeMessage(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (client != 0 && !IsPlayer(client)) {
        // nothing to tell to bots and to players that have left
        return 0;
    }
    return SendRetakesMessage(client, 2);
}

public int Native_RetakeMessageToAll(Handle plugin, int numParams) {
    int length = SendRetakesMessage(0, 1);

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            SendRetakesMessage(i, 1);
        }
    }

    // The return value is kept as the original plugin computed it.
    return length + PREFIX_LENGTH - 1;
}

public int Native_GetNumActiveTs(Handle plugin, int numParams) {
    return g_NumT;
}

public int Native_GetNumActiveCTs(Handle plugin, int numParams) {
    return g_NumCT;
}

public int Native_GetNumActivePlayers(Handle plugin, int numParams) {
    return g_NumT + g_NumCT;
}

public int Native_GetCurrrentBombsite(Handle plugin, int numParams) {
    return view_as<int>(g_Bombsite);
}

public int Native_GetRoundPoints(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    CHECK_CONNECTED(client);
    return g_RoundPoints[client];
}

public int Native_SetRoundPoints(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    CHECK_CONNECTED(client);
    int points = GetNativeCell(2);
    g_RoundPoints[client] = points;

    return 0;
}

public int Native_ChangeRoundPoints(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    CHECK_CONNECTED(client);
    int dp = GetNativeCell(2);
    g_RoundPoints[client] += dp;

    return 0;
}

public int Native_GetPlayerInfo(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    CHECK_CONNECTED(client);
    SetNativeString(2, g_PlayerPrimary[client], WEAPON_STRING_LENGTH);
    SetNativeString(3, g_PlayerSecondary[client], WEAPON_STRING_LENGTH);
    SetNativeString(4, g_PlayerNades[client], NADE_STRING_LENGTH);

    SetNativeCellRef(5, g_PlayerHealth[client]);
    SetNativeCellRef(6, g_PlayerArmor[client]);
    SetNativeCellRef(7, g_PlayerHelmet[client]);
    SetNativeCellRef(8, g_PlayerKit[client]);

    return 0;
}

public int Native_SetPlayerInfo(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    CHECK_CONNECTED(client);

    GetNativeString(2, g_PlayerPrimary[client], WEAPON_STRING_LENGTH);
    GetNativeString(3, g_PlayerSecondary[client], WEAPON_STRING_LENGTH);
    GetNativeString(4, g_PlayerNades[client], NADE_STRING_LENGTH);

    g_PlayerHealth[client] = GetNativeCell(5);
    g_PlayerArmor[client] = GetNativeCell(6);
    g_PlayerHelmet[client] = GetNativeCell(7);
    g_PlayerKit[client] = GetNativeCell(8);

    return 0;
}

public int Native_GetRetakeRoundsPlayed(Handle plugin, int numParams) {
    return g_RoundCount;
}

public int Native_InEditMode(Handle plugin, int numParams) {
    return g_EditMode;
}

public int Native_InWarmup(Handle plugin, int numParams) {
    // CS:S has no m_bWarmupPeriod; the warmup is run by the optional warmup plugin.
    return InWarmup();
}

public int Native_Enabled(Handle plugin, int numParams) {
    return g_Enabled;
}

public int Native_GetMaxPlayers(Handle plugin, int numParams) {
    return g_hMaxPlayers.IntValue;
}
